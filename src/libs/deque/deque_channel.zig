const std = @import("std");
const Allocator = std.mem.Allocator;
const Atomic = std.atomic.Value;
const Deque = @import("deque").Deque;
const DVyukovMPMCQueue = @import("dvyukov-mpmc").DVyukovMPMCQueue;

/// DequeChannel - High-Performance MPMC Channel with Work-Stealing
///
/// Architecture:
/// - Local deques: Each worker has a private bounded Deque (fast path)
/// - Global queue: Shared DVyukovMPMCQueue for overflow (safety valve)
/// - Work-stealing: Idle workers steal from busy workers' deques (load balancer)
///
/// Design Philosophy:
/// - Bounded with back-pressure: send() returns error.Full when system is saturated
/// - Non-blocking API: Applications build blocking operations on top as needed
/// - Explicit parameters: No thread-local storage, worker context passed explicitly
///
/// Performance Characteristics:
/// - Send fast path: ~5-15ns (local deque push)
/// - Send slow path: ~50-100ns (batch offload to global queue)
/// - Recv priority 1: ~5-15ns (local pop)
/// - Recv priority 2: ~30-60ns (global dequeue)
/// - Recv priority 3: ~40-80ns (steal from random victim)
///
/// Usage:
/// ```zig
/// const Channel = DequeChannel(Task, 256, 4096);
/// var result = try Channel.init(allocator, 8); // 8 workers
/// defer result.channel.deinit(&result.workers);
///
/// // Worker threads:
/// try result.workers[worker_id].send(task);
/// if (result.workers[worker_id].recv()) |task| {
///     // Process task
/// }
/// ```
pub fn DequeChannel(
    comptime T: type,
    comptime local_capacity: usize,
    comptime global_capacity: usize,
) type {
    // Compile-time validation
    comptime {
        if (!std.math.isPowerOfTwo(local_capacity)) {
            @compileError("local_capacity must be a power of 2");
        }
        if (!std.math.isPowerOfTwo(global_capacity)) {
            @compileError("global_capacity must be a power of 2");
        }

        // Enforce pointer types for large T to prevent false sharing
        const type_info = @typeInfo(T);
        const is_pointer = switch (type_info) {
            .pointer => true,
            else => false,
        };
        const size = @sizeOf(T);

        if (size > std.atomic.cache_line and !is_pointer) {
            @compileError(std.fmt.comptimePrint(
                "DequeChannel: Type '{s}' ({d} bytes) exceeds cache line size ({d} bytes). " ++
                "Use *{s} instead for better performance and to avoid false sharing.",
                .{ @typeName(T), size, std.atomic.cache_line, @typeName(T) }
            ));
        }
    }

    return struct {
        const Self = @This();
        const GlobalQueue = DVyukovMPMCQueue(T, global_capacity);

        /// Cache-line padded stealer handle to prevent false sharing
        const PaddedStealer = struct {
            stealer: Deque(T).Stealer,
            _padding: [std.atomic.cache_line - @sizeOf(Deque(T).Stealer)]u8 = undefined,
        };

        /// Array of padded stealers (one per worker)
        local_stealers: []PaddedStealer,

        /// Global overflow queue (shared by all workers)
        global_queue: *GlobalQueue,

        /// Allocator for cleanup
        allocator: Allocator,

        // /// Channel-level RNG (reserved for future use, currently unused)
        // channel_rng: std.Random.DefaultPrng,

        /// Worker handle - grants access to send() and recv()
        /// Contains the Deque worker, worker ID, RNG, and channel reference
        pub const Worker = struct {
            deque_worker: Deque(T).Worker,
            worker_id: usize,
            rng: std.Random.DefaultPrng,
            channel: *Self,

            /// Deinitialize the worker's deque
            pub fn deinit(self: *Worker) void {
                self.deque_worker.deinit();
            }

            /// Get the worker's capacity
            pub fn capacity(self: *const Worker) usize {
                return self.deque_worker.capacity();
            }

            /// Get the approximate size of the worker's deque
            pub fn size(self: *const Worker) usize {
                return self.deque_worker.size();
            }

            /// Send an item to the channel
            ///
            /// Fast path: Push to local deque (~5-15ns)
            /// Slow path: Offload to global queue and retry (~50-100ns)
            ///
            /// Returns error.Full when both local and global queues are saturated.
            pub fn send(self: *Worker, item: T) !void {
                // Fast path: Try local push
                self.push(item) catch |err| {
                    if (err != error.Full) return err;
                    // Slow path: Delegate offload handling to channel
                    try self.channel.handleOffload(self, item);
                };
            }

            /// Receive an item from the channel
            ///
            /// Three-tier priority:
            /// 1. Local deque (LIFO, ~5-15ns)
            /// 2. Global queue (FIFO, ~30-60ns)
            /// 3. Work-stealing (FIFO, ~40-80ns)
            ///
            /// Returns null if no work available after all attempts.
            pub fn recv(self: *Worker) ?T {
                // Fast path: Try local pop
                if (self.pop()) |item| {
                    return item;
                }
                // Slow path: Delegate to channel for global queue and work-stealing
                return self.channel.recvSlowPath(self);
            }

            // Internal methods - not part of public API

            /// Push an item to the worker's deque (internal use only)
            fn push(self: *Worker, item: T) !void {
                try self.deque_worker.push(item);
            }

            /// Pop an item from the worker's deque (internal use only)
            fn pop(self: *Worker) ?T {
                return self.deque_worker.pop();
            }
        };

        /// Result of initialization
        pub const InitResult = struct {
            channel: *Self,
            workers: []Worker,
        };

        /// Initialize the channel
        ///
        /// Parameters:
        /// - allocator: Memory allocator
        /// - num_workers: Number of worker threads
        ///
        /// Returns both the channel and an array of worker handles.
        /// The caller must distribute worker handles to threads.
        ///
        /// Cleanup:
        /// ```zig
        /// defer result.channel.deinit(&result.workers);
        /// ```
        pub fn init(allocator: Allocator, num_workers: usize) !InitResult {
            // Allocate stealers array
            const stealers = try allocator.alloc(PaddedStealer, num_workers);
            errdefer allocator.free(stealers);

            // Allocate workers array
            const workers = try allocator.alloc(Worker, num_workers);
            errdefer allocator.free(workers);

            // Initialize global queue
            const global_queue = try allocator.create(GlobalQueue);
            errdefer allocator.destroy(global_queue);

            global_queue.* = try GlobalQueue.init(allocator);
            errdefer global_queue.deinit();

            // Allocate channel on heap (workers need stable pointer)
            const channel = try allocator.create(Self);
            errdefer allocator.destroy(channel);

            channel.* = Self{
                .local_stealers = stealers,
                .global_queue = global_queue,
                .allocator = allocator,
                // Channel-level RNG reserved for future use (currently commented out)
                // .channel_rng = std.Random.DefaultPrng.init(num_workers * 1000),
            };

            // Initialize local deques
            var initialized: usize = 0;
            errdefer {
                // Cleanup already initialized deques
                var i: usize = 0;
                while (i < initialized) : (i += 1) {
                    workers[i].deinit();
                }
            }

            // Issue 47 fix: Use entropy-mixed seeds to decorrelate victim selection
            // Combining worker ID, pointer address, and timestamp prevents synchronized steals
            const base_entropy = @as(u64, @truncate(@as(u128, @bitCast(std.time.nanoTimestamp()))));

            var i: usize = 0;
            while (i < num_workers) : (i += 1) {
                const result = try Deque(T).init(allocator, local_capacity);

                // Mix worker ID with pointer and timestamp for unique, decorrelated seeds
                const ptr_entropy = @as(u64, @truncate(@intFromPtr(&workers[i])));
                const seed = @as(u64, i) ^ ptr_entropy ^ base_entropy;

                workers[i] = Worker{
                    .deque_worker = result.worker,
                    .worker_id = i,
                    .rng = std.Random.DefaultPrng.init(seed),
                    .channel = channel,
                };
                stealers[i] = PaddedStealer{
                    .stealer = result.stealer,
                };
                initialized += 1;
            }

            return InitResult{
                .channel = channel,
                .workers = workers,
            };
        }

        /// Cleanup the channel
        ///
        /// CRITICAL: All worker threads must be stopped before calling deinit()
        /// The workers array is consumed and freed by this function.
        /// The channel itself is also freed.
        pub fn deinit(self: *Self, workers: *[]Worker) void {
            const allocator = self.allocator;

            // Deinit all worker deques
            for (workers.*) |*worker| {
                worker.deinit();
            }

            // Free workers array
            allocator.free(workers.*);

            // Deinit global queue
            self.global_queue.deinit();
            allocator.destroy(self.global_queue);

            // Free stealers array
            allocator.free(self.local_stealers);

            // Free the channel itself
            allocator.destroy(self);
        }

        /// Handle offload when local deque is full (internal - called by worker.send())
        ///
        /// Strategy: Pop items from deque, offload to global queue, retry original push
        ///
        /// Returns error.Full when both local deque and global queue are saturated.
        /// This provides system-wide back-pressure.
        ///
        /// Note: During offload, thieves may concurrently steal from the deque.
        /// This is fine - we only offload as many items as we can successfully pop.
        ///
        /// Thread-safety: Only the owner of this worker can call this
        fn handleOffload(self: *Self, worker: *Worker, item: T) !void {
            // Local deque is full, try to offload to global queue
            // Issue 52 fix: Adaptive offload based on global queue fill level
            // If global queue is > 50% full, use smaller batches to reduce contention
            const global_fill = self.global_queue.size();
            const target_offload = if (global_fill > global_capacity / 2)
                worker.capacity() / 4 // Smaller batch if global is busy
            else
                worker.capacity() / 2;

            var offloaded: usize = 0;
            while (offloaded < target_offload) {
                // Pop from bottom of our deque
                // Note: May return null if thieves stole items concurrently
                const offload_item = worker.pop() orelse break;

                // Try to enqueue to global queue
                self.global_queue.enqueue(offload_item) catch {
                    // Global queue is full - push the item back and fail
                    // We don't try to restore all offloaded items (fail fast)
                    // The partial offload is okay - creates space for future sends
                    try worker.push(offload_item);
                    return error.Full;
                };

                offloaded += 1;
            }

            // Retry the original push
            // May succeed now due to: offloaded items OR thieves stealing
            try worker.push(item);
        }

        /// Slow path for recv - global queue and work-stealing (internal - called by worker.recv())
        ///
        /// Two-tier fallback after local pop failed:
        /// - Priority 1: Dequeue from global queue (FIFO, shared fallback, ~30-60ns)
        /// - Priority 2: Steal from random victims (FIFO, load balancing, ~40-80ns, num_workers attempts)
        ///
        /// Returns null if no work is available after all attempts.
        ///
        /// Thread-safety: Only the owner of this worker can call this
        fn recvSlowPath(self: *Self, worker: *Worker) ?T {
            // Priority 1: Global work (FIFO)
            if (self.global_queue.dequeue()) |item| {
                return item;
            }

            // Priority 2: Work-stealing (FIFO from victims' perspective)
            const num_workers = self.local_stealers.len;

            // Can't steal from ourselves if we're the only worker
            if (num_workers <= 1) {
                return null;
            }

            // Get worker ID and RNG from worker
            const worker_id = worker.worker_id;
            const rng = worker.rng.random();

            // Issue 51 fix: Cap steal attempts to avoid futile probes on large-core systems
            // Linear scaling (max_attempts = num_workers) means 64 attempts on 64 cores
            // Most will fail on lightly loaded systems, wasting cycles
            const max_attempts = @min(num_workers, 8);

            var attempt: usize = 0;
            while (attempt < max_attempts) : (attempt += 1) {
                // Pick a random victim, ensuring it's not ourself
                // Algorithm: Generate random in [0, num_workers-1], then adjust if >= worker_id
                var victim_id = rng.intRangeLessThan(usize, 0, num_workers - 1);
                if (victim_id >= worker_id) {
                    victim_id += 1;
                }
                // Wraparound safety (should never trigger with correct num_workers)
                if (victim_id >= num_workers) {
                    victim_id = 0;
                }

                const stealer = &self.local_stealers[victim_id].stealer;
                if (stealer.steal()) |item| {
                    return item;
                }

                // Adaptive backoff: scale with worker count and attempt number
                // More workers = more contention = more backoff needed
                // More attempts = likely high load = exponential backoff
                if (attempt < max_attempts - 1 and num_workers > 2) {
                    // Backoff increases with attempt number and worker count
                    // Formula: min(attempt + 1, num_workers / 2) spins
                    const backoff_factor = @min(attempt + 1, num_workers / 2);
                    var spin: usize = 0;
                    while (spin < backoff_factor) : (spin += 1) {
                        std.atomic.spinLoopHint(); // CPU pause (~1-2 cycles each)
                    }
                }
            }

            // All attempts failed
            return null;
        }

        /// Get approximate total items in the system (racy, for debugging/monitoring)
        pub fn approxSize(self: *const Self, workers: []const Worker) usize {
            var total: usize = 0;

            // Sum local deques
            for (workers) |*worker| {
                total += worker.size();
            }

            // Add global queue
            total += self.global_queue.size();

            return total;
        }
    };
}
