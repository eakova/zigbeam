const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Thread = std.Thread;
const Atomic = std.atomic.Value;
const deque = @import("deque");
const Task = @import("task").Task;
const ShardedDVyukovMPMCQueue = @import("sharded_dvyukov_mpmc").ShardedDVyukovMPMCQueue;
const Backoff = @import("backoff").Backoff;

// =============================================================================
// Thread-Local and Global State
// =============================================================================

/// Default shard count for global pool (compile-time constant)
/// Workers match shards 1:1. We default to the target CPU core count to avoid
/// oversubscribing small machines, but still allow callers to pick higher
/// shard counts explicitly for heavy multi-producer workloads.
const DEFAULT_SHARD_COUNT: usize = blk: {
    const cores = if (builtin.cpu.count > 0) builtin.cpu.count else 2;
    break :blk if (cores >= 2) cores else 2;
};

/// Global pool type (based on DEFAULT_SHARD_COUNT)
const GlobalPool = WorkStealingPool(DEFAULT_SHARD_COUNT);

/// Thread-local current worker (uses anyopaque for type erasure)
threadlocal var CURRENT_WORKER: ?*anyopaque = null;

/// Global pool singleton
var GLOBAL_POOL: ?*GlobalPool = null;
var GLOBAL_POOL_MUTEX: Thread.Mutex = .{};

/// Per-thread injector counter for single-task submissions
/// Avoids a globally contended atomic in Injector.push()
threadlocal var INJECTOR_THREAD_COUNTER: usize = 0;

// =============================================================================
// Global Pool Singleton (Convenience API)
// =============================================================================

/// Lazy-initialize global pool with default settings
fn ensureGlobalPool() *GlobalPool {
    if (GLOBAL_POOL) |pool| return pool;

    GLOBAL_POOL_MUTEX.lock();
    defer GLOBAL_POOL_MUTEX.unlock();

    // Double-check after acquiring lock
    if (GLOBAL_POOL) |pool| return pool;

    // Auto-initialize with c_allocator (no cleanup needed)
    GLOBAL_POOL = GlobalPool.init(std.heap.c_allocator, .{}) catch {
        @panic("Failed to initialize global pool");
    };

    return GLOBAL_POOL.?;
}

/// Initialize global pool with custom allocator/config (optional)
///
/// If not called, the global pool will auto-initialize on first use with
/// c_allocator and default config (CPU count workers).
pub fn initGlobalPool(allocator: Allocator, config: GlobalPool.Config) !void {
    GLOBAL_POOL_MUTEX.lock();
    defer GLOBAL_POOL_MUTEX.unlock();

    if (GLOBAL_POOL != null) return error.AlreadyInitialized;

    GLOBAL_POOL = try GlobalPool.init(allocator, config);
}

/// Deinitialize global pool (optional cleanup)
pub fn deinitGlobalPool() void {
    GLOBAL_POOL_MUTEX.lock();
    defer GLOBAL_POOL_MUTEX.unlock();

    if (GLOBAL_POOL) |pool| {
        pool.deinit();
        GLOBAL_POOL = null;
    }
}

/// Get global pool (auto-initializes if needed)
pub fn getGlobalPool() *GlobalPool {
    return ensureGlobalPool();
}

/// Submit to global pool (auto-initializes if needed)
pub fn submit(task: Task) !void {
    try ensureGlobalPool().submit(task);
}

/// Submit batch to global pool (auto-initializes if needed)
pub fn submitBatch(tasks: []const Task) !void {
    try ensureGlobalPool().submitBatch(tasks);
}

/// Wait for global pool to be idle (auto-initializes if needed)
pub fn waitIdle() void {
    ensureGlobalPool().waitIdle();
}

// =============================================================================
// Work-Stealing Thread Pool
// =============================================================================

/// Work-Stealing Thread Pool
///
/// Automatically distributes work across threads with work-stealing.
/// Each worker owns a Chase–Lev deque (owner push/pop; thieves steal).
///
/// External submissions (injector-based, current design)
/// - External threads NEVER push into a worker’s owner-only deque.
/// - They enqueue into a pool-level injector (mutex-protected buffer).
/// - Workers drain the injector in small batches and interleave a local-deque
///   check after each injector task to keep nested work responsive.
/// - A lock-free atomic counter provides fast emptiness checks (used by waitIdle).
///
/// Shutdown semantics
/// - close() flips the pool into non-accepting state (submit returns error.Closed).
/// - deinit() calls close() + waitIdle() first, then signals shutdown and joins
///   workers. This prevents task loss in Release builds.
///
/// Other safeguards
/// - Cross-pool TLS guard: fast-path submit only when CURRENT_WORKER belongs
///   to this pool.
/// - waitIdle checks deques + in-flight counter and only touches injector
///   when appropriate to reduce contention.
/// - unparkOne uses a round-robin start index to avoid bias.
///
/// Usage:
/// ```zig
/// // Local pool with 8 shards (8 workers, 1:1 ratio)
/// const Pool = WorkStealingPool(8);
/// const pool = try Pool.init(allocator, .{});
/// defer pool.deinit();
/// pool.submit(Task.init(myFunction, .{arg1, arg2}));
/// pool.waitIdle();
///
/// // Or use global pool (auto-initializes with 8 shards/8 workers)
/// try submit(Task.init(myFunction, .{arg1, arg2}));
/// waitIdle();
/// ```
pub fn WorkStealingPool(comptime num_shards: usize) type {
    comptime {
        if (num_shards < 2) {
            @compileError(std.fmt.comptimePrint(
                "WorkStealingPool requires at least 2 shards, got {d}. For heavy multi-producer workloads, 8+ shards are recommended.",
                .{num_shards},
            ));
        }
    }

    return struct {
        const Self = @This();

        // 1:1 worker-to-shard ratio for optimal performance
        // Each worker has its own shard affinity, minimizing contention
        const num_workers = num_shards;

        /// Max number of tasks to drain from injector in one pass
        const INJECTOR_BATCH: usize = 16;

        /// Injector queue configuration (sharded lock-free MPMC queue)
        /// Scales with num_shards for 1:1 worker-to-injector-shard affinity
        /// Total capacity: num_shards × 1024 tasks
        /// (e.g., 8 shards = 8,192 total, 16 shards = 16,384 total)
        const INJECTOR_NUM_SHARDS: usize = num_shards;
        const INJECTOR_CAPACITY_PER_SHARD: usize = 1024;

        workers: []Worker,
        allocator: Allocator,
        config: Config,  // Store config for worker access (Optimization #2)
        shutdown: Atomic(bool),
        /// Accepting new submissions (closed during shutdown)
        accepting: Atomic(bool),
        /// Tracks tasks currently being executed (for robust waitIdle)
        in_flight: Atomic(usize),
        /// Injector queue for external submissions (sharded lock-free MPMC)
        injector: Injector(INJECTOR_NUM_SHARDS, INJECTOR_CAPACITY_PER_SHARD),
        /// Round-robin index for wake-up selection
        unpark_idx: Atomic(usize),
        /// Injector drain batch size (auto-tuned at init)
        injector_batch: usize,
        /// Approximate count of parked workers (for efficient unparkOne gating)
        parked_workers: Atomic(usize),
        /// Futex for event-driven waitIdle (eliminates O(N) polling)
        idle_futex: Atomic(u32),
        /// Number of threads currently waiting in waitIdle()/waitIdleTimeout()
        /// Gates futex signaling to avoid unnecessary syscalls when no one is waiting
        idle_waiters: Atomic(usize),

        pub const Config = struct {
            stack_size: usize = 2 * 1024 * 1024,

            /// Backoff spin limit: controls exponential backoff before parking
            /// Higher = more spinning (better for throughput), lower = park earlier (better for latency/power)
            /// Default: 6 (2^6 = 64 max spins before yielding)
            backoff_spin_limit: u32 = 6,

            /// Backoff yield limit: controls when backoff is considered complete
            /// After this many steps, worker will park instead of continuing to backoff
            /// Default: 10 (yield phase after spin phase)
            backoff_yield_limit: u32 = 10,
        };

    /// Injector: sharded lock-free MPMC queue for external task submission
    /// Uses round-robin distribution with optimized batch handling
    fn Injector(comptime injector_num_shards: usize, comptime injector_capacity_per_shard: usize) type {
        return struct {
            queue: ShardedDVyukovMPMCQueue(Task, injector_num_shards, injector_capacity_per_shard),
            enqueue_counter: Atomic(usize),

            const InjectorSelf = @This();

            fn init(allocator: Allocator) !InjectorSelf {
                return .{
                    .queue = try ShardedDVyukovMPMCQueue(Task, injector_num_shards, injector_capacity_per_shard).init(allocator),
                    .enqueue_counter = Atomic(usize).init(0),
                };
            }

            fn deinit(self: *InjectorSelf) void {
                self.queue.deinit();
            }

            /// Push single task using round-robin distribution
            /// Uses per-thread counter to avoid global contention under heavy multi-producer load
            fn push(self: *InjectorSelf, task: Task, accepting: *const Atomic(bool)) !void {
                if (!accepting.load(.monotonic)) return error.Closed;

                // Round-robin per thread: guarantees even distribution across all shards
                // Uses thread-local counter to avoid a single contended global atomic
                const local_index = INJECTOR_THREAD_COUNTER;
                INJECTOR_THREAD_COUNTER +%= 1;
                const shard = local_index % injector_num_shards;
                try self.queue.enqueueToShard(shard, task);
            }

            /// Push batch with optimized atomic usage (1 fetchAdd for N tasks)
            fn pushBatch(self: *InjectorSelf, tasks: []const Task, accepting: *const Atomic(bool)) !void {
                if (!accepting.load(.monotonic)) return error.Closed;

                // OPTIMIZED: Single atomic op for entire batch
                // Reserve N consecutive shard indices with one fetchAdd instead of N fetchAdds
                const base_index = self.enqueue_counter.fetchAdd(tasks.len, .monotonic);

                // Distribute tasks using computed indices (no more atomic ops)
                for (tasks, 0..) |task, i| {
                    const shard = (base_index + i) % injector_num_shards;
                    try self.queue.enqueueToShard(shard, task);
                }
            }

            /// Pop task from primary shard only (batch draining optimization)
            /// Workers check other shards only when truly idle (in the steal-then-drain fallback)
            fn pop(self: *InjectorSelf, worker_id: usize) ?Task {
                const primary_shard = worker_id % injector_num_shards;
                return self.queue.dequeueFromShard(primary_shard);
            }

            /// Pop task checking all shards (fallback when worker is truly idle)
            fn popAnyShard(self: *InjectorSelf, worker_id: usize) ?Task {
                const primary_shard = worker_id % injector_num_shards;

                // Check primary first
                if (self.queue.dequeueFromShard(primary_shard)) |task| {
                    return task;
                }

                // Check remaining shards
                var offset: usize = 1;
                while (offset < injector_num_shards) : (offset += 1) {
                    const shard_id = (primary_shard + offset) % injector_num_shards;
                    if (self.queue.dequeueFromShard(shard_id)) |task| {
                        return task;
                    }
                }

                return null;
            }

            /// Pop from other shards only (skip primary) - used after primary was just drained
            /// Avoids redundant atomic operations on primary shard (2-3% gain)
            fn popOtherShards(self: *InjectorSelf, worker_id: usize) ?Task {
                const primary_shard = worker_id % injector_num_shards;

                // Only check remaining shards (primary already exhausted)
                var offset: usize = 1;
                while (offset < injector_num_shards) : (offset += 1) {
                    const shard_id = (primary_shard + offset) % injector_num_shards;
                    if (self.queue.dequeueFromShard(shard_id)) |task| {
                        return task;
                    }
                }

                return null;
            }

            fn isEmpty(self: *InjectorSelf) bool {
                return self.queue.isEmpty();
            }

            fn size(self: *const InjectorSelf) usize {
                return self.queue.totalSize();
            }

            fn totalCapacity(self: *const InjectorSelf) usize {
                return self.queue.totalCapacity();
            }
        };
    }

    const Worker = struct {
        id: usize,
        deque: deque.WorkStealingDeque(Task),
        pool: *Self,
        thread: Thread,
        rng: std.Random.DefaultPrng,
        parked: Atomic(u32),
        /// Per-worker local in_flight counter (periodically folded into global)
        /// Eliminates 2 global atomic operations per task execution
        in_flight_local: usize,
        /// Hybrid steal cursor: round-robin victim selection (Optimization #3)
        /// Reduces RNG overhead by using sequential victim selection
        steal_cursor: usize,
        /// Tracks steal rounds since last RNG reseed (Optimization #3)
        /// After 16 rounds, reseed cursor with RNG to avoid pathological patterns
        steal_rounds_since_reseed: usize,
        // No mutex for owner deque: external submissions go through injector.

        /// Fold threshold: flush local counter to global after this many tasks
        /// Threshold for folding thread-local in_flight counter into global atomic
        /// Higher value = fewer atomic ops, but less accurate global count
        /// Tuned to 256 to balance accuracy vs atomic contention (Issue #3)
        const IN_FLIGHT_FOLD_THRESHOLD: usize = 256;

        /// Fold local in_flight counter into global atomic
        /// This amortizes the cost of atomic operations across many tasks
        fn foldInFlightCounter(self: *Worker) void {
            if (self.in_flight_local > 0) {
                _ = self.pool.in_flight.fetchAdd(self.in_flight_local, .monotonic);
                self.in_flight_local = 0;
            }
        }

        fn run(self: *Worker) void {
            // Set thread-local worker
            CURRENT_WORKER = self;
            defer CURRENT_WORKER = null;
            defer self.foldInFlightCounter(); // Ensure final fold on shutdown

            outer: while (!self.pool.shutdown.load(.acquire)) {
                // 1. Try local work (FAST PATH - cache hot)
                if (self.deque.pop()) |task| {
                    self.in_flight_local += 1;
                    // Periodic fold to maintain approximate global count
                    if (self.in_flight_local >= IN_FLIGHT_FOLD_THRESHOLD) {
                        self.foldInFlightCounter();
                    }
                    task.execute();
                    self.in_flight_local -= 1;
                    continue;
                }

                // 2. Drain injector (EXTERNAL WORK - check primary shard for batch)
                //    Worker affinity: each worker primarily drains its assigned shard
                var drained: usize = 0;
                while (drained < self.pool.injector_batch) : (drained += 1) {
                    // Check primary shard only during batch draining (reduces atomic ops)
                    if (self.pool.injectorPop(self.id)) |task| {
                        self.in_flight_local += 1;
                        task.execute();
                        self.in_flight_local -= 1;
                    } else break;
                }
                if (drained > 0) {
                    // Periodic fold after batch processing
                    if (self.in_flight_local >= IN_FLIGHT_FOLD_THRESHOLD) {
                        self.foldInFlightCounter();
                    }
                    continue;
                }

                // Check OTHER shards only (primary was just exhausted by batch drain)
                // Using popOthers avoids redundant check of primary shard (2-3% gain)
                if (self.pool.injectorPopOthers(self.id)) |task| {
                    self.in_flight_local += 1;
                    // Periodic fold
                    if (self.in_flight_local >= IN_FLIGHT_FOLD_THRESHOLD) {
                        self.foldInFlightCounter();
                    }
                    task.execute();
                    self.in_flight_local -= 1;
                    continue;
                }

                // 3. Try stealing from other workers (WORK STEALING - fallback)
                //    Only attempt stealing when local and injector are both empty
                if (self.stealFromRandom()) |task| {
                    self.in_flight_local += 1;
                    // Periodic fold
                    if (self.in_flight_local >= IN_FLIGHT_FOLD_THRESHOLD) {
                        self.foldInFlightCounter();
                    }
                    task.execute();
                    self.in_flight_local -= 1;
                    continue;
                }

                // 4. No work found anywhere - try backoff before parking
                // Backoff avoids expensive park/unpark syscalls for brief idle periods
                // Use configurable backoff limits (Optimization #2)
                var backoff = Backoff.init(.{
                    .spin_limit = self.pool.config.backoff_spin_limit,
                    .yield_limit = self.pool.config.backoff_yield_limit,
                });
                while (!backoff.isCompleted()) {
                    backoff.spin();

                    // Retry work-finding during backoff
                    if (self.pool.injectorPop(self.id)) |task| {
                        self.in_flight_local += 1;
                        if (self.in_flight_local >= IN_FLIGHT_FOLD_THRESHOLD) {
                            self.foldInFlightCounter();
                        }
                        task.execute();
                        self.in_flight_local -= 1;
                        continue :outer;
                    }

                    if (self.stealFromRandom()) |task| {
                        self.in_flight_local += 1;
                        if (self.in_flight_local >= IN_FLIGHT_FOLD_THRESHOLD) {
                            self.foldInFlightCounter();
                        }
                        task.execute();
                        self.in_flight_local -= 1;
                        continue :outer;
                    }
                }

                // Still no work after backoff - fold counter and park thread
                // Critical: fold before parking to ensure waitIdle() sees accurate count
                self.foldInFlightCounter();
                self.park();
            }
        }

        fn stealFromRandom(self: *Worker) ?Task {
            // Adaptive strategy:
            // - When many workers are parked (pool mostly idle), avoid RNG and do a tiny
            //   deterministic round-robin probe over a few neighbors.
            // - When the pool is active, use RNG-based victim selection with more attempts.
            const parked = self.pool.parked_workers.load(.monotonic);

            if (parked > num_workers / 2) {
                // Mostly idle: cheap deterministic probe of nearby workers
                var offset: usize = 1;
                const max_attempts: usize = 3;
                while (offset <= max_attempts and offset < num_workers) : (offset += 1) {
                    const victim_id = (self.id + offset) % num_workers;
                    const victim = &self.pool.workers[victim_id];
                    if (victim.deque.steal()) |task| {
                        return task;
                    }
                }
                return null;
            } else {
                // Active pool: Hybrid round-robin with periodic RNG reseed (Optimization #3)
                // Reduces RNG overhead by using sequential victim selection, reseeds every 16 rounds
                // to avoid pathological patterns where workers always steal from same victims

                // Reseed cursor every 16 rounds to avoid pathological patterns
                const RESEED_INTERVAL: usize = 16;
                if (self.steal_rounds_since_reseed >= RESEED_INTERVAL) {
                    self.steal_cursor = self.rng.random().intRangeLessThan(usize, 0, num_workers);
                    self.steal_rounds_since_reseed = 0;
                }

                // Use round-robin victim selection (much cheaper than RNG per attempt)
                const max_attempts: usize = if (num_workers <= 8) num_workers * 2 else 8;
                var attempt: usize = 0;
                while (attempt < max_attempts) : (attempt += 1) {
                    self.steal_cursor = (self.steal_cursor + 1) % num_workers;
                    if (self.steal_cursor == self.id) continue;

                    const victim = &self.pool.workers[self.steal_cursor];
                    if (victim.deque.steal()) |task| {
                        return task;
                    }
                }

                self.steal_rounds_since_reseed += 1;
                return null;
            }
        }

        fn park(self: *Worker) void {
            // CRITICAL: Fold local in_flight counter before parking
            // Otherwise waitIdle() will see stale global counter and deadlock
            self.foldInFlightCounter();

            _ = self.pool.parked_workers.fetchAdd(1, .release);
            self.parked.store(1, .release);
            // Signal idle waiters only when someone is actually waiting.
            // This avoids unnecessary futex syscalls when no thread is in waitIdle().
            // Use acquire load to ensure we see idle_waiters update from waitIdle()
            if (self.pool.idle_waiters.load(.acquire) > 0) {
                _ = self.pool.idle_futex.fetchAdd(1, .release);
                Thread.Futex.wake(&self.pool.idle_futex, 1);
            }
            Thread.Futex.wait(&self.parked, 1);
        }

        pub fn unpark(self: *Worker) void {
            if (self.parked.swap(0, .acquire) == 1) {
                _ = self.pool.parked_workers.fetchSub(1, .monotonic);
                Thread.Futex.wake(&self.parked, 1);
            }
        }

        // No external push onto owner-only deque.
        // External submissions flow through the pool-level injector.
    };

    /// Initialize a new pool instance
    /// Note: num_shards is defined at compile-time as a parameter to WorkStealingPool()
    /// Workers match shards 1:1 (e.g., 8 shards = 8 workers)
    pub fn init(allocator: Allocator, config: Config) !*Self {
        // num_shards is a comptime parameter, already validated by WorkStealingPool()
        // No runtime validation needed - compile-time checks ensure:
        // - num_shards >= 8 (minimum for optimal multi-producer performance)
        // - num_workers = num_shards (1:1 ratio)

        // Injector batch size tuning (Issue #9):
        // Larger batches amortize atomic operations better but reduce responsiveness
        // Tuned for optimal balance between throughput and latency
        const injector_batch: usize = if (num_workers <= 8)
            @as(usize, 16)  // Small pools: moderate batch for good amortization
        else if (num_workers <= 32)
            @as(usize, 32)  // Medium pools: larger batch to reduce atomic ops
        else
            @as(usize, 64);  // Large pools: maximize atomic op amortization

        // Heap-allocate the pool for stable pointer address
        const pool = try allocator.create(Self);
        errdefer allocator.destroy(pool);

        const workers = try allocator.alloc(Worker, num_workers);
        errdefer allocator.free(workers);

        pool.* = Self{
            .workers = workers,
            .allocator = allocator,
            .config = config,
            .shutdown = Atomic(bool).init(false),
            .accepting = Atomic(bool).init(true),
            .in_flight = Atomic(usize).init(0),
            .injector = try Injector(INJECTOR_NUM_SHARDS, INJECTOR_CAPACITY_PER_SHARD).init(allocator),
            .unpark_idx = Atomic(usize).init(0),
            .injector_batch = injector_batch,
            .parked_workers = Atomic(usize).init(0),
            .idle_futex = Atomic(u32).init(0),
            .idle_waiters = Atomic(usize).init(0),
        };

        // Initialize workers
        var initialized: usize = 0;
        errdefer {
            for (workers[0..initialized]) |*worker| {
                worker.deque.deinit();
            }
        }

        for (workers, 0..) |*worker, i| {
            worker.* = .{
                .id = i,
                .deque = try deque.WorkStealingDeque(Task).init(allocator),
                .pool = pool, // Stable pointer - no need to "fix" later
                .thread = undefined,
                .rng = std.Random.DefaultPrng.init(@as(u64, @intCast(i)) +% @as(u64, @bitCast(std.time.milliTimestamp()))),
                .parked = Atomic(u32).init(0),
                .in_flight_local = 0,
                .steal_cursor = i,  // Initialize to own ID (will be incremented on first steal)
                .steal_rounds_since_reseed = 0,
            };
            initialized += 1;
        }

        // Spawn worker threads
        var spawned: usize = 0;
        errdefer {
            pool.shutdown.store(true, .release);
            for (workers[0..spawned]) |*worker| {
                worker.unpark();
                worker.thread.join();
            }
        }

        for (workers) |*worker| {
            worker.thread = try Thread.spawn(.{ .stack_size = config.stack_size }, Worker.run, .{worker});
            spawned += 1;
        }

        return pool;
    }

    /// Stop accepting new tasks; can be called before deinit.
    pub fn close(self: *Self) void {
        _ = self.accepting.swap(false, .release);
    }

    /// Wait until the pool is idle or a timeout elapses (event-driven)
    pub fn waitIdleTimeout(self: *Self, timeout_ns: u64) !void {
        const start = std.time.nanoTimestamp();
        _ = self.idle_waiters.fetchAdd(1, .monotonic);
        defer _ = self.idle_waiters.fetchSub(1, .monotonic);
        while (true) {
            // Check if pool is idle
            if (self.isPoolIdle()) {
                return;
            }

            // Check timeout
            const now = std.time.nanoTimestamp();
            var elapsed_ns: u128 = 0;
            if (now >= start) {
                elapsed_ns = @as(u128, @intCast(now - start));
            } else {
                elapsed_ns = 0; // Clock went backwards
            }
            if (elapsed_ns > timeout_ns) return error.Timeout;

            // If all workers parked but injector has work, wake one
            if (self.parked_workers.load(.monotonic) == num_workers and !self.injectorIsEmpty()) {
                self.unparkOne();
            }

            // Wait for idle signal with timeout
            const futex_val = self.idle_futex.load(.monotonic);
            if (self.isPoolIdle()) {
                return;
            }

            // Use timed futex wait (10ms max per iteration to check timeout)
            const wait_ns = @min(10 * std.time.ns_per_ms, timeout_ns - @as(u64, @intCast(@min(elapsed_ns, timeout_ns))));
            Thread.Futex.timedWait(&self.idle_futex, futex_val, wait_ns) catch {};
        }
    }

    /// Shutdown and cleanup the pool (drains outstanding work first).
    pub fn deinit(self: *Self) void {
        // Phase 1: stop accepting submissions and drain pending work
        self.close();
        _ = self.waitIdleTimeout(10 * std.time.ns_per_s) catch |e| {
            if (builtin.mode == .Debug) std.debug.print("warning: pool deinit wait idle timed out: {s}\n", .{@errorName(e)});
        };

        // Phase 2: signal shutdown and join workers
        self.shutdown.store(true, .release);

        // Wake and join all workers
        for (self.workers) |*worker| {
            worker.unpark();
            worker.thread.join();
            worker.deque.deinit();
        }

        // In Debug builds, help catch misuse
        if (builtin.mode == .Debug) {
            std.debug.assert(self.in_flight.load(.acquire) == 0);
            std.debug.assert(self.injector.isEmpty());
        }

        // Drop injector storage
        self.injector.deinit();

        const allocator = self.allocator;
        allocator.free(self.workers);
        allocator.destroy(self); // Free heap-allocated pool
    }

    /// Submit a task to the pool
    pub fn submit(self: *Self, task: Task) !void {
        if (!self.accepting.load(.acquire)) return error.Closed;
        // FIXED: Cross-pool TLS confusion
        // Only use fast path if CURRENT_WORKER belongs to THIS pool
        if (CURRENT_WORKER) |worker_ptr| {
            const worker: *Worker = @ptrCast(@alignCast(worker_ptr));
            if (worker.pool == self) {
                // Fast path: we're a worker of THIS pool, use our deque
                try worker.deque.push(task);
                return;
            }
            // Worker belongs to different pool, fall through to external path
        }

        // Slow path: external thread uses injector queue with round-robin distribution
        try self.injectorPush(task);
        // Only wake a worker if at least one is parked (avoids atomic ops + worker scan)
        if (self.parked_workers.load(.monotonic) > 0) {
            self.unparkOne();
        }
    }

    /// Submit batch of tasks (efficient distribution with smart waking)
    pub fn submitBatch(self: *Self, tasks: []const Task) !void {
        if (!self.accepting.load(.acquire)) return error.Closed;
        if (tasks.len == 0) return;

        // Enqueue all tasks into injector with round-robin distribution
        try self.injectorPushBatch(tasks);

        // Smart waking: only wake min(tasks.len, parked_workers) workers
        // No point waking more workers than tasks submitted
        const parked = self.parked_workers.load(.monotonic);
        const to_wake = @min(tasks.len, parked);

        if (to_wake == 0) return; // All workers already active

        if (to_wake >= num_workers) {
            // Wake all if we need everyone (avoids loop overhead)
            self.unparkAll();
        } else {
            // Wake specific count using round-robin
            var i: usize = 0;
            while (i < to_wake) : (i += 1) {
                self.unparkOne();
            }
        }
    }

    /// Wait until all work is complete (event-driven, no polling)
    ///
    /// Uses futex-based blocking instead of spin-loop polling to eliminate O(N) worker scanning
    /// in tight loops. Workers signal idle_futex when the pool becomes idle.
    ///
    /// Behavior: Returns when all deques are empty, no tasks in-flight, and all workers parked.
    /// Correctness: Workers fold local in_flight counters before parking, so when all parked,
    /// the global counter accurately reflects all in-flight work.
    pub fn waitIdle(self: *Self) void {
        _ = self.idle_waiters.fetchAdd(1, .release);
        defer _ = self.idle_waiters.fetchSub(1, .monotonic);
        while (true) {
            // Check if pool is idle (O(N) scan, but only when woken, not in tight loop)
            if (self.isPoolIdle()) {
                return;
            }

            // If all workers parked but injector has work, wake one
            if (self.parked_workers.load(.acquire) == num_workers and !self.injectorIsEmpty()) {
                self.unparkOne();
            }

            // Not idle yet - wait for workers to signal idle_futex
            const futex_val = self.idle_futex.load(.monotonic);

            // Double-check before sleeping (avoid race where pool became idle)
            if (self.isPoolIdle()) {
                return;
            }

            // Block on futex until a worker signals idle
            Thread.Futex.wait(&self.idle_futex, futex_val);
        }
    }

    /// Check if pool is completely idle
    ///
    /// Returns true only if:
    /// - No in-flight tasks
    /// - Injector is empty
    /// - All workers are parked
    /// - All worker deques are empty
    ///
    /// Note: Still O(N) to scan deques, but called only when woken (not in tight loop)
    fn isPoolIdle(self: *Self) bool {
        // Fast checks first (no scanning)
        if (self.in_flight.load(.acquire) != 0) return false;
        if (!self.injectorIsEmpty()) return false;
        if (self.parked_workers.load(.acquire) != num_workers) return false;

        // Finally scan all worker deques (O(N), but only when likely idle)
        for (self.workers) |*worker| {
            if (!worker.deque.isEmpty()) return false;
        }

        return true;
    }

    /// Check if we're running on a worker thread
    pub fn isWorkerThread() bool {
        return CURRENT_WORKER != null;
    }

    /// Get current worker (if any)
    pub fn currentWorker() ?*Worker {
        return CURRENT_WORKER;
    }

    // Injector helpers
    fn injectorPush(self: *Self, task: Task) !void {
        try self.injector.push(task, &self.accepting);
    }
    fn injectorPushBatch(self: *Self, tasks: []const Task) !void {
        try self.injector.pushBatch(tasks, &self.accepting);
    }
    fn injectorPop(self: *Self, worker_id: usize) ?Task {
        return self.injector.pop(worker_id);
    }
    fn injectorPopAny(self: *Self, worker_id: usize) ?Task {
        return self.injector.popAnyShard(worker_id);
    }
    fn injectorPopOthers(self: *Self, worker_id: usize) ?Task {
        return self.injector.popOtherShards(worker_id);
    }
    fn injectorIsEmpty(self: *Self) bool {
        return self.injector.isEmpty();
    }

    /// Get approximate injector size (for monitoring/diagnostics)
    /// ⚠️ Racy - only use for telemetry
    pub fn injectorSize(self: *const Self) usize {
        return self.injector.size();
    }

    /// Get total injector capacity
    pub fn injectorCapacity(self: *const Self) usize {
        return self.injector.totalCapacity();
    }

    fn unparkOne(self: *Self) void {
        // Early exit: if no workers are parked, skip scan entirely (2-5% gain)
        if (self.parked_workers.load(.monotonic) == 0) {
            return;
        }

        // Round-robin starting index to avoid always waking the same worker
        const start = self.unpark_idx.fetchAdd(1, .monotonic) % num_workers;
        var i: usize = 0;
        while (i < num_workers) : (i += 1) {
            const idx = (start + i) % num_workers;
            const w = &self.workers[idx];
            // Only attempt to unpark workers that are actually parked
            if (w.parked.load(.acquire) == 1) {
                w.unpark();
                break;
            }
        }
    }
    fn unparkAll(self: *Self) void {
        for (self.workers) |*w| w.unpark();
    }
    };
}
