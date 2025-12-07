// ThreadPool - Work-stealing thread pool with structured concurrency
//
// This is the core of ZigParallel's Layer 2. It manages a fixed set of worker
// threads that execute tasks via work-stealing.
//
// Features:
// - Global pool singleton with lazy initialization
// - Custom pools with configurable thread count
// - Work-stealing via mpmc.DequeChannel
// - Per-worker ID accessible via thread-local storage
//
// Usage:
// ```zig
// // Use global pool (recommended)
// const pool = getGlobalPool();
// try pool.spawn(task);
//
// // Or create custom pool with specific thread count
// const custom = try ThreadPool.init(allocator, .{ .num_threads = 4 });
// defer custom.deinit();
//
// // Or create custom pool with custom capacities
// const LargePool = ThreadPoolFn(.{ .local_capacity = 512, .global_capacity = 8192 });
// const pool = try LargePool.init(allocator, .{});
// ```

const std = @import("std");
const Allocator = std.mem.Allocator;
const Thread = std.Thread;
const Atomic = std.atomic.Value;

// Import primitives from beam libs
const backoff_mod = @import("backoff");
const Backoff = backoff_mod.Backoff;
const BackoffConfig = backoff_mod.Config;
const DequeChannel = @import("deque-channel").DequeChannel;

// Import task definition
const task_mod = @import("task.zig");
pub const Task = task_mod.Task;

// ============================================================================
// Configuration
// ============================================================================

/// Comptime configuration for queue capacities (determines type)
///
/// Usage:
/// ```zig
/// // Default capacities (most users)
/// const pool = try ThreadPool.init(allocator, .{});
///
/// // Custom capacities (advanced)
/// const LargePool = ThreadPoolFn(.{ .local_capacity = 512, .global_capacity = 8192 });
/// const pool = try LargePool.init(allocator, .{});
/// ```
pub const Config = struct {
    /// Per-worker deque capacity (must be power of 2)
    local_capacity: usize = 256,

    /// Global overflow queue capacity (must be power of 2)
    global_capacity: usize = 4096,

    /// Enable per-worker statistics collection (default: disabled for zero overhead)
    enable_stats: bool = false,
};

/// Backoff behavior mode for worker idle loops
///
/// Controls the trade-off between latency and power consumption.
pub const BackoffMode = enum {
    /// Best latency, highest CPU usage. For always-busy workloads.
    /// spin: 64, multi_spin: 128, sleep: 512, sleep_ns: 100µs
    low_latency,

    /// Good latency, medium CPU usage. For general purpose.
    /// spin: 32, multi_spin: 64, sleep: 128, sleep_ns: 1ms
    balanced,

    /// Higher latency, lowest CPU usage. For background/battery-sensitive.
    /// spin: 8, multi_spin: 16, sleep: 32, sleep_ns: 10ms
    power_saving,

    /// Convert to BackoffConfig
    pub fn toBackoffConfig(self: BackoffMode) BackoffConfig {
        return switch (self) {
            .low_latency => .{
                .spin_limit = 64,
                .multi_spin_limit = 128,
                .sleep_limit = 512,
                .sleep_ns = 100_000, // 100µs
            },
            .balanced => .{
                .spin_limit = 32,
                .multi_spin_limit = 64,
                .sleep_limit = 128,
                .sleep_ns = 1_000_000, // 1ms
            },
            .power_saving => .{
                .spin_limit = 8,
                .multi_spin_limit = 16,
                .sleep_limit = 32,
                .sleep_ns = 10_000_000, // 10ms
            },
        };
    }
};

/// Runtime configuration for thread pool initialization
///
/// Usage:
/// ```zig
/// // Auto-detect threads (uses full CPU count)
/// const pool = try ThreadPool.init(allocator, .{});
///
/// // Specific thread count
/// const pool = try ThreadPool.init(allocator, .{ .num_threads = 4 });
///
/// // Power-saving mode for background processing
/// const pool = try ThreadPool.init(allocator, .{ .backoff_mode = .power_saving });
/// ```
pub const InitConfig = struct {
    /// Number of worker threads (null = auto-detect: full CPU count)
    /// Issue 57 fix: Changed from CPU count / 2 to full CPU count
    /// for better throughput on compute-bound workloads
    num_threads: ?usize = null,

    /// Stack size per worker thread (null = system default)
    stack_size: ?usize = null,

    /// Backoff behavior for worker idle loops (default: low_latency)
    backoff_mode: BackoffMode = .low_latency,
};

// ============================================================================
// Worker Statistics
// ============================================================================

/// Per-worker statistics for debugging/monitoring
/// Only collected when Config.enable_stats = true
pub const WorkerStats = struct {
    /// Number of tasks executed by this worker
    tasks_executed: usize = 0,
};

// ============================================================================
// Thread Pool Lifecycle State
// ============================================================================

/// Thread pool lifecycle state
pub const PoolState = enum(u8) {
    /// Pool is initializing
    initializing = 0,
    /// Pool is running and accepting tasks
    running = 1,
    /// Pool is shutting down
    shutting_down = 2,
    /// Pool has terminated
    terminated = 3,
};

// ============================================================================
// Generic Thread Pool Type
// ============================================================================

/// Create a thread pool type with specific configuration
///
/// Usage:
/// ```zig
/// // Default everything
/// const pool = try ThreadPool.init(allocator, .{});
///
/// // Custom capacities
/// const LargePool = ThreadPoolFn(.{ .local_capacity = 512, .global_capacity = 8192 });
/// const pool = try LargePool.init(allocator, .{ .num_threads = 4 });
/// ```
pub fn ThreadPoolFn(comptime config: Config) type {
    // DequeChannel type for task distribution with specified capacities
    const Channel = DequeChannel(*Task, config.local_capacity, config.global_capacity);

    return struct {
        const Self = @This();

        /// Comptime configuration
        pub const pool_config = config;

        /// Worker thread state
        /// Issue 16/25 fix: Aligned to cache line to prevent false sharing in worker arrays
        /// The struct itself is aligned to ensure array elements don't share cache lines
        pub const Worker = struct {
            /// Unique worker identifier (0..num_threads-1)
            id: usize,

            /// OS thread handle
            thread: Thread,

            /// DequeChannel worker handle (owns local deque)
            channel_worker: Channel.Worker,

            /// Pool this worker belongs to (type-erased for thread-local storage)
            pool_ptr: *anyopaque,

            /// Shutdown flag (cache-line aligned to prevent false sharing)
            shutdown: Atomic(bool) align(std.atomic.cache_line),

            /// Statistics (for debugging/monitoring)
            stats: WorkerStats,

            /// Issue 16 fix: Padding to ensure each Worker occupies full cache lines,
            /// preventing false sharing when workers are stored in an array.
            /// Without this, adjacent workers' hot fields could share cache lines.
            _cache_padding: [std.atomic.cache_line]u8 align(std.atomic.cache_line) = undefined,

            /// Get the typed pool pointer
            pub fn pool(self: *Worker) *Self {
                return @ptrCast(@alignCast(self.pool_ptr));
            }

            /// Worker run loop
            ///
            /// Continuously:
            /// 1. Try to receive a task (local pop, global dequeue, steal)
            /// 2. Execute the task
            /// 3. Update statistics
            /// 4. Check for shutdown
            fn run(self: *Worker) void {
                // Set thread-local worker context (type-erased)
                current_worker_ptr = self;
                current_worker_id = self.id;
                defer {
                    current_worker_ptr = null;
                    current_worker_id = null;
                }

                // Use pool's backoff configuration
                var backoff = Backoff.init(self.pool().backoff_config);

                while (!self.shutdown.load(.acquire)) {
                    if (self.channel_worker.recv()) |task| {
                        // Issue 11 fix: Decrement active_tasks after task completes (or panics)
                        // Issue 61 fix: Use .release ordering (isIdle uses .acquire)
                        defer _ = self.pool().active_tasks.fetchSub(1, .release);

                        // Execute the task
                        task.run();
                        if (comptime config.enable_stats) {
                            self.stats.tasks_executed += 1;
                        }
                        backoff.reset();
                    } else {
                        // No work available, backoff
                        backoff.snooze();
                    }
                }
            }
        };

        /// Array of worker threads
        workers: []Worker,

        /// DequeChannel for work distribution
        channel: *Channel,

        /// Channel workers array (for deinit)
        channel_workers: []Channel.Worker,

        /// Pool state
        state: Atomic(PoolState),

        /// Allocator for cleanup
        allocator: Allocator,

        /// Backoff configuration for worker idle loops
        backoff_config: BackoffConfig,

        /// Issue 11 fix: Atomic counter for in-flight tasks
        /// Incremented on spawn, decremented when task completes.
        /// Provides exact idle detection instead of heuristic approxSize.
        ///
        /// Issue 61 fix: Uses .release ordering for fetchAdd/fetchSub instead of .acq_rel.
        /// The acquire-release pattern (release on modify, acquire on load in isIdle())
        /// is sufficient for correctness while reducing cache coherency traffic.
        /// On ARM64, .acq_rel generates dmb sy barrier vs just stlr for .release.
        active_tasks: Atomic(usize),

        /// Initialize a new thread pool
        ///
        /// Workers start immediately and wait for tasks.
        /// Issue 57 fix: Thread count from init_config (default: CPU count - 1).
        /// Leaves one core for OS/other processes to avoid system saturation.
        ///
        /// Returns error if thread creation fails.
        pub fn init(allocator: Allocator, init_config: InitConfig) !*Self {
            // Issue 45 fix: Ensure num_threads >= 1 even if explicitly set to 0
            // Issue 57 fix: Use CPU count - 1 to leave one core for OS
            const cpu_count = std.Thread.getCpuCount() catch 2;
            const raw_threads = init_config.num_threads orelse (cpu_count -| 1); // Saturating sub
            const num_threads = @max(1, raw_threads);

            // Allocate pool structure
            const pool = try allocator.create(Self);
            errdefer allocator.destroy(pool);

            // Initialize channel
            var channel_result = try Channel.init(allocator, num_threads);
            errdefer channel_result.channel.deinit(&channel_result.workers);

            // Allocate workers array
            const workers = try allocator.alloc(Worker, num_threads);
            errdefer allocator.free(workers);

            pool.* = Self{
                .workers = workers,
                .channel = channel_result.channel,
                .channel_workers = channel_result.workers,
                .state = Atomic(PoolState).init(.initializing),
                .allocator = allocator,
                .backoff_config = init_config.backoff_mode.toBackoffConfig(),
                .active_tasks = Atomic(usize).init(0),
            };

            // Initialize workers
            var started: usize = 0;
            errdefer {
                // Signal shutdown to started workers
                for (workers[0..started]) |*w| {
                    w.shutdown.store(true, .release);
                }
                // Wait for them to exit
                for (workers[0..started]) |*w| {
                    w.thread.join();
                }
            }

            for (workers, 0..) |*worker, i| {
                worker.* = Worker{
                    .id = i,
                    .thread = undefined,
                    .channel_worker = channel_result.workers[i],
                    .pool_ptr = pool,
                    .shutdown = Atomic(bool).init(false),
                    .stats = WorkerStats{},
                };

                // Spawn worker thread
                worker.thread = Thread.spawn(.{
                    .stack_size = init_config.stack_size orelse 0,
                }, Worker.run, .{worker}) catch |err| {
                    return err;
                };

                started += 1;
            }

            pool.state.store(.running, .release);
            return pool;
        }

        /// Shutdown and destroy the thread pool
        ///
        /// Following Rayon's approach:
        /// 1. Waits for all queued tasks to be processed (drains queues)
        /// 2. Signals all workers to shutdown
        /// 3. Joins all worker threads
        /// 4. Frees all allocated memory
        ///
        /// This ensures no tasks are dropped during shutdown.
        pub fn deinit(self: *Self) void {
            // Rayon approach: wait for all queued work to complete before shutdown
            // Workers continue running and processing tasks until queues are empty
            var backoff = Backoff.init(self.backoff_config);
            while (!self.isIdle()) {
                backoff.snooze();
            }

            self.state.store(.shutting_down, .release);

            // Signal all workers to shutdown
            for (self.workers) |*worker| {
                worker.shutdown.store(true, .release);
            }

            // Wait for all workers to exit
            for (self.workers) |*worker| {
                worker.thread.join();
            }

            self.state.store(.terminated, .release);

            // Free resources
            var workers_copy = self.channel_workers;
            self.channel.deinit(&workers_copy);
            self.allocator.free(self.workers);
            self.allocator.destroy(self);
        }

        /// Spawn a task into the thread pool
        ///
        /// Fast path: Push to caller's local deque (if on worker thread)
        /// Slow path: Push to global queue (external threads)
        ///
        /// Returns error.QueueFull if queues are saturated.
        /// Returns error.PoolShuttingDown if pool is shutting down.
        pub fn spawn(self: *Self, task: *Task) !void {
            // Use monotonic - just checking flag, no synchronization needed
            if (self.state.load(.monotonic) != .running) {
                return error.PoolShuttingDown;
            }

            // Issue 11 fix: Increment active_tasks before enqueuing
            // Issue 61 fix: Use .release ordering (isIdle uses .acquire)
            _ = self.active_tasks.fetchAdd(1, .release);

            // If we're on a worker thread of THIS pool, use local deque
            if (current_worker_ptr) |worker_ptr| {
                const worker: *Worker = @ptrCast(@alignCast(worker_ptr));
                if (worker.pool_ptr == @as(*anyopaque, @ptrCast(self))) {
                    worker.channel_worker.send(task) catch |err| {
                        // Rollback on failure
                        _ = self.active_tasks.fetchSub(1, .release);
                        return err;
                    };
                    return;
                }
            }

            // External thread: use global queue directly
            // IMPORTANT: Don't use worker deques from external threads!
            // The Deque is designed for single-owner (one thread does push/pop).
            // Using send() from external thread would violate this invariant.
            self.channel.global_queue.enqueue(task) catch |err| {
                // Rollback on failure
                _ = self.active_tasks.fetchSub(1, .release);
                return err;
            };
        }

        /// Execute a closure using this pool for nested parallel operations
        ///
        /// Sets this pool as the "current pool" for the calling thread.
        /// All parallel operations within the closure will use this pool.
        pub fn install(self: *Self, comptime closure: fn () void) void {
            const prev_pool = current_pool_ptr;
            current_pool_ptr = self;
            defer current_pool_ptr = prev_pool;

            closure();
        }

        /// Get the number of workers in this pool
        pub fn numWorkers(self: *const Self) usize {
            return self.workers.len;
        }

        /// Get statistics for a specific worker
        ///
        /// Only available when Config.enable_stats = true.
        /// Returns null if stats are disabled or worker_id is invalid.
        pub fn getWorkerStats(self: *const Self, worker_id: usize) ?WorkerStats {
            if (comptime !config.enable_stats) {
                return null;
            }
            if (worker_id >= self.workers.len) {
                return null;
            }
            return self.workers[worker_id].stats;
        }

        /// Get aggregated statistics across all workers
        ///
        /// Only available when Config.enable_stats = true.
        /// Returns null if stats are disabled.
        pub fn getTotalStats(self: *const Self) ?WorkerStats {
            if (comptime !config.enable_stats) {
                return null;
            }
            var total = WorkerStats{};
            for (self.workers) |*worker| {
                total.tasks_executed += worker.stats.tasks_executed;
            }
            return total;
        }

        /// Try to process one task from the pool
        ///
        /// This is used for "steal-while-wait" in fork-join operations.
        /// When waiting for a spawned task to complete, the caller helps
        /// by processing other tasks, preventing deadlock.
        ///
        /// Returns true if a task was executed, false if no work available.
        ///
        /// Must be called from a worker thread of this pool.
        pub fn tryProcessOneTask(self: *Self) bool {
            // Only works from worker threads
            if (current_worker_ptr) |worker_ptr| {
                const worker: *Worker = @ptrCast(@alignCast(worker_ptr));
                if (worker.pool_ptr == @as(*anyopaque, @ptrCast(self))) {
                    if (worker.channel_worker.recv()) |task| {
                        // Issue 11 fix: Decrement active_tasks after task completes (or panics)
                        // Issue 61 fix: Use .release ordering (isIdle uses .acquire)
                        defer _ = self.active_tasks.fetchSub(1, .release);

                        task.run();
                        if (comptime config.enable_stats) {
                            worker.stats.tasks_executed += 1;
                        }
                        return true;
                    }
                }
            }
            return false;
        }

        /// Check if the pool is idle (no in-flight tasks)
        ///
        /// Issue 11 fix: Uses atomic active_tasks counter for precise idle detection.
        /// This is exact, not approximate - returns true only when all tasks have completed.
        pub fn isIdle(self: *Self) bool {
            return self.active_tasks.load(.acquire) == 0;
        }

        /// Wait until all tasks are processed
        ///
        /// Blocks until all in-flight tasks have completed.
        /// Uses steal-while-wait if called from a worker thread, otherwise
        /// uses backoff-based polling.
        ///
        /// Issue 11 fix: Uses exact active_tasks counter instead of heuristic approxSize.
        /// This guarantees all work completes before returning.
        pub fn waitIdle(self: *Self) void {
            var backoff = Backoff.init(self.backoff_config);

            while (!self.isIdle()) {
                // If on a worker thread, help process tasks
                if (current_worker_ptr) |worker_ptr| {
                    const worker: *Worker = @ptrCast(@alignCast(worker_ptr));
                    if (worker.pool_ptr == @as(*anyopaque, @ptrCast(self))) {
                        if (worker.channel_worker.recv()) |task| {
                            // Issue 11 fix: Decrement active_tasks after task completes
                            // Issue 61 fix: Use .release ordering (isIdle uses .acquire)
                            defer _ = self.active_tasks.fetchSub(1, .release);

                            task.run();
                            if (comptime config.enable_stats) {
                                worker.stats.tasks_executed += 1;
                            }
                            backoff.reset();
                            continue;
                        }
                    }
                }
                backoff.snooze();
            }
        }
    };
}

/// Default thread pool type with standard capacities (256 local, 4096 global)
pub const ThreadPool = ThreadPoolFn(.{});

// ============================================================================
// Thread-Local State (type-erased to support any capacity variant)
// ============================================================================

/// Thread-local worker context (type-erased)
/// Set when worker thread starts, cleared on shutdown
/// Use getWorker(PoolType) to get typed pointer for a specific pool type
threadlocal var current_worker_ptr: ?*anyopaque = null;

/// Thread-local worker ID (stored separately to avoid struct layout assumptions)
/// Set when worker thread starts, cleared on shutdown
threadlocal var current_worker_id: ?usize = null;

/// Thread-local pool context for install() (type-erased)
threadlocal var current_pool_ptr: ?*anyopaque = null;

/// Get current worker ID (returns null if not in worker thread)
pub fn getCurrentWorkerId() ?usize {
    return current_worker_id;
}

/// Get the current pool context (set by install())
/// Returns the default ThreadPool type. For custom capacity pools,
/// use getGlobalPoolTyped(YourPoolType) instead.
pub fn getCurrentPool() ?*ThreadPool {
    if (current_pool_ptr) |pool_ptr| {
        return @ptrCast(@alignCast(pool_ptr));
    }
    return null;
}

// ============================================================================
// Global Pool
// ============================================================================

var global_pool: ?*ThreadPool = null;
var global_pool_mutex: Thread.Mutex = .{};

/// Get the lazily-initialized global thread pool
///
/// First call: Creates pool with CPU count workers
/// Subsequent calls: Returns cached pool
///
/// Thread-safe via double-checked locking.
///
/// Panics if pool initialization fails.
pub fn getGlobalPool() *ThreadPool {
    // First check if there's a pool context set by install()
    if (current_pool_ptr) |pool_ptr| {
        return @ptrCast(@alignCast(pool_ptr));
    }

    // Fast path: already initialized
    if (@atomicLoad(?*ThreadPool, &global_pool, .acquire)) |pool| {
        return pool;
    }

    // Slow path: initialize with lock
    global_pool_mutex.lock();
    defer global_pool_mutex.unlock();

    // Issue 29 fix: Re-check with atomic load after acquiring lock
    if (@atomicLoad(?*ThreadPool, &global_pool, .acquire)) |pool| {
        return pool;
    }

    // Initialize global pool
    const new_pool = ThreadPool.init(std.heap.page_allocator, .{}) catch |err| {
        std.debug.panic("Failed to initialize global thread pool: {}", .{err});
    };

    // Issue 38 fix: Use atomic store with release to ensure full initialization
    // is visible before pointer is seen by fast path's acquire load
    @atomicStore(?*ThreadPool, &global_pool, new_pool, .release);

    return new_pool;
}

/// Issue 20 fix: Shutdown and free the global thread pool
///
/// This function allows proper cleanup of the global pool in long-running
/// processes that reconfigure pools or reload loom. It:
/// 1. Waits for all queued work to complete
/// 2. Joins all worker threads
/// 3. Frees all allocations
/// 4. Resets the global pool pointer (allowing re-initialization)
///
/// Thread-safe. No-op if global pool was never initialized.
///
/// NOTE: After calling this, any subsequent calls to getGlobalPool()
/// will create a fresh pool. Existing references to the old pool
/// become invalid.
pub fn shutdownGlobalPool() void {
    global_pool_mutex.lock();
    defer global_pool_mutex.unlock();

    if (global_pool) |pool| {
        pool.deinit();
        global_pool = null;
    }
}

/// Check if the global pool has been initialized
///
/// Useful for determining whether cleanup is needed.
pub fn isGlobalPoolInitialized() bool {
    return @atomicLoad(?*ThreadPool, &global_pool, .acquire) != null;
}

// ============================================================================
// Tests
// ============================================================================

test "Config defaults" {
    const cfg = Config{};
    try std.testing.expectEqual(@as(usize, 256), cfg.local_capacity);
    try std.testing.expectEqual(@as(usize, 4096), cfg.global_capacity);
    try std.testing.expectEqual(false, cfg.enable_stats);
}

test "InitConfig defaults" {
    const cfg = InitConfig{};
    try std.testing.expectEqual(@as(?usize, null), cfg.num_threads);
    try std.testing.expectEqual(@as(?usize, null), cfg.stack_size);
}

test "ThreadPool default capacities" {
    // Default ThreadPool uses 256 local, 4096 global
    try std.testing.expectEqual(@as(usize, 256), ThreadPool.pool_config.local_capacity);
    try std.testing.expectEqual(@as(usize, 4096), ThreadPool.pool_config.global_capacity);
}

test "ThreadPoolFn custom capacities" {
    // Custom pool type with different capacities
    const LargePool = ThreadPoolFn(.{ .local_capacity = 512, .global_capacity = 8192 });
    try std.testing.expectEqual(@as(usize, 512), LargePool.pool_config.local_capacity);
    try std.testing.expectEqual(@as(usize, 8192), LargePool.pool_config.global_capacity);
}

test "ThreadPool init and deinit" {
    const pool = try ThreadPool.init(std.testing.allocator, .{ .num_threads = 2 });
    defer pool.deinit();

    try std.testing.expectEqual(@as(usize, 2), pool.numWorkers());
    try std.testing.expectEqual(PoolState.running, pool.state.load(.acquire));
}

test "getCurrentWorkerId returns null outside worker" {
    try std.testing.expectEqual(@as(?usize, null), getCurrentWorkerId());
}

test "stats disabled by default returns null" {
    // Default ThreadPool has enable_stats = false
    const pool = try ThreadPool.init(std.testing.allocator, .{ .num_threads = 2 });
    defer pool.deinit();

    // Stats API returns null when disabled
    try std.testing.expectEqual(@as(?WorkerStats, null), pool.getWorkerStats(0));
    try std.testing.expectEqual(@as(?WorkerStats, null), pool.getTotalStats());
}

test "stats enabled pool collects statistics" {
    // Create pool type with stats enabled
    const StatsPool = ThreadPoolFn(.{ .enable_stats = true });
    const pool = try StatsPool.init(std.testing.allocator, .{ .num_threads = 2 });
    defer pool.deinit();

    // Stats should be available and start at zero
    const worker_stats = pool.getWorkerStats(0);
    try std.testing.expect(worker_stats != null);
    try std.testing.expectEqual(@as(usize, 0), worker_stats.?.tasks_executed);

    const total_stats = pool.getTotalStats();
    try std.testing.expect(total_stats != null);
    try std.testing.expectEqual(@as(usize, 0), total_stats.?.tasks_executed);

    // Invalid worker ID returns null
    try std.testing.expectEqual(@as(?WorkerStats, null), pool.getWorkerStats(999));
}
