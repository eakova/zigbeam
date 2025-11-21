const std = @import("std");
const Allocator = std.mem.Allocator;
const Atomic = std.atomic.Value;
const DVyukovMPMCQueue = @import("beam-dvyukov-mpmc").DVyukovMPMCQueue;

/// Thread-Affinity Sharded DVyukov MPMC Queue
///
/// A high-performance lock-free queue that partitions work across multiple underlying
/// DVyukov MPMC queues to eliminate atomic counter contention under high balanced load.
///
/// ## Performance Characteristics
///
/// **When to use:**
/// - High balanced contention: 4+ producers AND 4+ consumers
/// - Known thread count at compile time or startup
/// - Threads can be assigned to specific shards
///
/// **Performance gains:**
/// - 4P/4C: 3-4x faster than single queue (37 → 120+ Mops/s)
/// - 8P/8C: 7-8x faster than single queue (22 → 175+ Mops/s)
/// - Near-linear scaling when threads == num_shards (SPSC-like per shard)
///
/// **When NOT to use:**
/// - Low contention (SPSC, 2P/2C): adds overhead, use DVyukovMPMCQueue directly
/// - Dynamic/unknown thread count: thread affinity assignment becomes complex
/// - Work stealing needed: this requires static shard assignment
///
/// ## Thread Assignment Strategy
///
/// Each thread must know its shard ID (typically `thread_id % num_shards`).
/// For optimal performance:
/// - `num_shards == num_threads` → ideal (1 producer + 1 consumer per shard)
/// - `num_shards == num_threads / 2` → good (2 producers + 2 consumers per shard)
/// - `num_shards > num_threads` → wastes memory
/// - `num_shards < num_threads / 4` → contention returns
///
/// ## Example Usage
///
/// ```zig
/// const ShardedQueue = ShardedDVyukovMPMCQueue(Job, 8, 512);
/// var queue = try ShardedQueue.init(allocator);
/// defer queue.deinit();
///
/// // Producer thread (knows its ID)
/// const my_shard = thread_id % 8;
/// try queue.enqueueToShard(my_shard, job);
///
/// // Consumer thread (knows its ID)
/// const my_shard = thread_id % 8;
/// if (queue.dequeueFromShard(my_shard)) |job| {
///     // Process job
/// }
/// ```
///
/// ## Memory Layout
///
/// Total capacity: `num_shards * capacity_per_shard`
/// Memory usage: O(num_shards * capacity_per_shard * sizeof(Cell))
///
/// Example: 8 shards × 512 capacity × 16 bytes/cell = ~64 KB
///
pub fn ShardedDVyukovMPMCQueue(
    comptime T: type,
    comptime num_shards: usize,
    comptime capacity_per_shard: usize,
) type {
    // Compile-time validations
    comptime {
        if (num_shards < 1) {
            @compileError("ShardedDVyukovMPMCQueue: num_shards must be at least 1");
        }
        if (num_shards == 1) {
            @compileError(
                "ShardedDVyukovMPMCQueue: num_shards=1 adds overhead with no benefit. " ++
                    "Use DVyukovMPMCQueue directly instead.",
            );
        }
        // Note: Not strictly required, but power-of-2 num_shards allows fast modulo with &
        // Non-power-of-2 values will use slower division for thread assignment
        // This is acceptable, just slightly less optimal
    }

    return struct {
        /// Array of underlying queues (one per shard)
        shards: [num_shards]DVyukovMPMCQueue(T, capacity_per_shard),

        /// Allocator used for initialization (stored for deinit)
        allocator: Allocator,

        const Self = @This();

        /// Initialize all shards
        ///
        /// Each shard is a fully independent DVyukov MPMC queue.
        /// Initialization is all-or-nothing: if any shard fails, all are cleaned up.
        pub fn init(allocator: Allocator) !Self {
            var result: Self = .{
                .shards = undefined,
                .allocator = allocator,
            };

            var initialized: usize = 0;
            errdefer {
                // Clean up already-initialized shards on error
                var i: usize = 0;
                while (i < initialized) : (i += 1) {
                    result.shards[i].deinit();
                }
            }

            for (&result.shards) |*shard| {
                shard.* = try DVyukovMPMCQueue(T, capacity_per_shard).init(allocator);
                initialized += 1;
            }

            return result;
        }

        /// Deinitialize all shards
        ///
        /// ⚠️ CRITICAL: Same requirements as DVyukovMPMCQueue.deinit():
        /// - No threads must be accessing ANY shard
        /// - If T owns resources, drain ALL shards first using drainAll()
        ///
        /// This only frees the internal queue buffers, NOT items inside.
        pub fn deinit(self: *Self) void {
            for (&self.shards) |*shard| {
                shard.deinit();
            }
        }

        /// Drain all items from ALL shards, optionally invoking cleanup on each
        ///
        /// Use this before deinit() if T owns resources (same as DVyukovMPMCQueue.drain).
        ///
        /// Example:
        /// ```zig
        /// queue.drainAll(&struct {
        ///     fn cleanup(item: Job) void { item.deinit(); }
        /// }.cleanup);
        /// queue.deinit();
        /// ```
        pub fn drainAll(self: *Self, cleanup_fn: ?*const fn (T) void) void {
            for (&self.shards) |*shard| {
                shard.drain(cleanup_fn);
            }
        }

        /// Enqueue an item to a specific shard
        ///
        /// The caller MUST provide a valid shard_id (0 <= shard_id < num_shards).
        /// Typically: `shard_id = thread_id % num_shards`
        ///
        /// Returns error.QueueFull if the SHARD is full (other shards may have space).
        ///
        /// For optimal performance:
        /// - Each thread should consistently use the same shard_id
        /// - Distribute threads evenly across shards
        ///
        /// ⚠️ Debug builds will panic on invalid shard_id. Release builds assume valid input.
        pub fn enqueueToShard(self: *Self, shard_id: usize, item: T) error{QueueFull}!void {
            std.debug.assert(shard_id < num_shards); // Debug check only
            return self.shards[shard_id].enqueue(item);
        }

        /// Dequeue an item from a specific shard
        ///
        /// The caller MUST provide a valid shard_id (0 <= shard_id < num_shards).
        /// Typically: `shard_id = thread_id % num_shards`
        ///
        /// Returns null if the SHARD is empty (other shards may have items).
        ///
        /// For optimal performance:
        /// - Each thread should consistently use the same shard_id
        /// - Distribute threads evenly across shards
        ///
        /// ⚠️ Debug builds will panic on invalid shard_id. Release builds assume valid input.
        pub fn dequeueFromShard(self: *Self, shard_id: usize) ?T {
            std.debug.assert(shard_id < num_shards); // Debug check only
            return self.shards[shard_id].dequeue();
        }

        /// Try to enqueue with retry limit to specific shard
        ///
        /// Same as enqueueToShard but limits internal CAS retries.
        /// Useful in real-time systems to avoid unbounded spinning.
        ///
        /// Returns:
        /// - error.QueueFull if the shard is actually full
        /// - error.Contended if retry limit exhausted due to contention
        pub fn tryEnqueueToShard(self: *Self, shard_id: usize, item: T, max_attempts: u32) error{ QueueFull, Contended }!void {
            std.debug.assert(shard_id < num_shards);
            return self.shards[shard_id].tryEnqueue(item, max_attempts);
        }

        /// Get approximate size of a specific shard
        ///
        /// ⚠️ Same warnings as DVyukovMPMCQueue.size() - racy, for monitoring only!
        pub fn shardSize(self: *const Self, shard_id: usize) usize {
            std.debug.assert(shard_id < num_shards);
            return self.shards[shard_id].size();
        }

        /// Get approximate total size across ALL shards
        ///
        /// ⚠️ VERY RACY - reads num_shards atomic counters non-atomically.
        /// Only use for coarse-grained monitoring/telemetry.
        ///
        /// Uses saturating addition to prevent overflow for extreme configurations.
        pub fn totalSize(self: *const Self) usize {
            var total: usize = 0;
            for (&self.shards) |*shard| {
                const shard_size = shard.size();
                // Saturating add: clamp at maxInt(usize) instead of wrapping
                if (total > std.math.maxInt(usize) - shard_size) {
                    return std.math.maxInt(usize);
                }
                total += shard_size;
            }
            return total;
        }

        /// Fast empty check: returns true only if ALL shards are empty
        ///
        /// This is O(N) where N = num_shards, but each shard's isEmpty() is O(1).
        /// Much faster than totalSize() which sums all shard sizes.
        /// Early exit on first non-empty shard for better performance.
        ///
        /// ⚠️ Racy - for monitoring only
        pub fn isEmpty(self: *const Self) bool {
            for (&self.shards) |*shard| {
                if (!shard.isEmpty()) {
                    return false; // Early exit on first non-empty shard
                }
            }
            return true;
        }

        /// Check if specific shard is empty (approximate)
        ///
        /// ⚠️ Racy - for monitoring only
        pub fn isShardEmpty(self: *const Self, shard_id: usize) bool {
            std.debug.assert(shard_id < num_shards);
            return self.shards[shard_id].isEmpty();
        }

        /// Check if specific shard is full (approximate)
        ///
        /// ⚠️ Racy - for monitoring only
        pub fn isShardFull(self: *const Self, shard_id: usize) bool {
            std.debug.assert(shard_id < num_shards);
            return self.shards[shard_id].isFull();
        }

        /// Get total capacity across all shards
        ///
        /// Uses compile-time overflow check to prevent misconfiguration.
        pub fn totalCapacity(self: *const Self) usize {
            _ = self;
            // Compile-time overflow guard
            if (comptime num_shards > 0 and capacity_per_shard > @divFloor(std.math.maxInt(usize), num_shards)) {
                @compileError(std.fmt.comptimePrint(
                    \\ShardedDVyukovMPMCQueue OVERFLOW ERROR: Total capacity too large!
                    \\  num_shards: {d}
                    \\  capacity_per_shard: {d}
                    \\  total capacity would overflow usize
                    \\
                    \\  Reduce num_shards or capacity_per_shard.
                , .{ num_shards, capacity_per_shard }));
            }
            return num_shards * capacity_per_shard;
        }

        /// Get number of shards
        pub fn shardCount(self: *const Self) usize {
            _ = self;
            return num_shards;
        }

        /// Get capacity per individual shard
        pub fn capacityPerShard(self: *const Self) usize {
            _ = self;
            return capacity_per_shard;
        }

        /// Safe enqueue using thread ID (automatically maps to valid shard)
        ///
        /// This is the RECOMMENDED way to use sharded queues - it prevents
        /// out-of-bounds shard access by automatically mapping thread_id to
        /// a valid shard using modulo.
        ///
        /// Example:
        /// ```
        /// const thread_id = std.Thread.getCurrentId();
        /// try queue.enqueue(thread_id, item);
        /// ```
        pub fn enqueue(self: *Self, thread_id: usize, item: T) error{QueueFull}!void {
            const shard_id = thread_id % num_shards;
            return self.enqueueToShard(shard_id, item);
        }

        /// Safe dequeue using thread ID (automatically maps to valid shard)
        ///
        /// This is the RECOMMENDED way to use sharded queues - it prevents
        /// out-of-bounds shard access by automatically mapping thread_id to
        /// a valid shard using modulo.
        ///
        /// Example:
        /// ```
        /// const thread_id = std.Thread.getCurrentId();
        /// const item = queue.dequeue(thread_id);
        /// ```
        pub fn dequeue(self: *Self, thread_id: usize) ?T {
            const shard_id = thread_id % num_shards;
            return self.dequeueFromShard(shard_id);
        }

        /// Safe try-enqueue using thread ID (automatically maps to valid shard)
        pub fn tryEnqueue(self: *Self, thread_id: usize, item: T, max_attempts: u32) error{ QueueFull, Contended }!void {
            const shard_id = thread_id % num_shards;
            return self.tryEnqueueToShard(shard_id, item, max_attempts);
        }
    };
}
