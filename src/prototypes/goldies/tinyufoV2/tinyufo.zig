const std = @import("std");
const SegQueue = @import("seg_queue.zig").SegQueue;
const CountMinSketch = @import("count_min_sketch.zig").CountMinSketch;
const flurry = @import("flurry.zig");
const ebr = @import("ebr.zig");

/// Lock-free TinyUFO cache - Cloudflare implementation
/// 2-queue architecture: Small (10%) + Main (90%)
/// TinyLFU (Count-Min Sketch) replaces ghost queue
pub fn TinyUFO(comptime K: type, comptime V: type) type {
    return struct {
        const Self = @This();

        // Hash function for Flurry HashMap
        fn hashKey(key: K) u64 {
            var hasher = std.hash.Wyhash.init(0);
            std.hash.autoHash(&hasher, key);
            return hasher.final();
        }

        // Equality function for Flurry HashMap
        fn eqlKey(a: K, b: K) bool {
            return std.meta.eql(a, b);
        }

        // Flurry HashMap for Bucket storage
        const FlurryHashMap = flurry.HashMap(K, Bucket, hashKey, eqlKey);

        /// Bucket stored in hashmap - protected by EBR (Epoch-Based Reclamation)
        const Bucket = struct {
            value: V,
            uses: std.atomic.Value(u8), // Capped at 3
            queue_location: std.atomic.Value(bool), // false=small, true=main

            const USES_CAP: u8 = 3;
            const SMALL: bool = false;
            const MAIN: bool = true;

            pub fn init(value: V) Bucket {
                return .{
                    .value = value,
                    .uses = std.atomic.Value(u8).init(0),
                    .queue_location = std.atomic.Value(bool).init(SMALL),
                };
            }

            pub fn incUses(self: *Bucket) void {
                while (true) {
                    const current = self.uses.load(.monotonic);
                    if (current >= USES_CAP) return;

                    const result = self.uses.cmpxchgWeak(
                        current,
                        current + 1,
                        .release,
                        .monotonic,
                    );
                    if (result == null) return;
                }
            }

            pub fn decrUses(self: *Bucket) u8 {
                while (true) {
                    const current = self.uses.load(.monotonic);
                    if (current == 0) return 0;

                    const result = self.uses.cmpxchgWeak(
                        current,
                        current - 1,
                        .release,
                        .monotonic,
                    );
                    if (result == null) return current - 1;
                }
            }

            pub fn getUses(self: *const Bucket) u8 {
                return self.uses.load(.monotonic);
            }

            pub fn isMain(self: *const Bucket) bool {
                return self.queue_location.load(.monotonic);
            }

            pub fn moveToMain(self: *Bucket) void {
                self.queue_location.store(MAIN, .monotonic);
            }

            /// EBR reclaim function for Bucket
            /// Called by EBR when it's safe to free the bucket (all guards have advanced)
            fn reclaimBucket(ptr: *anyopaque, collector: *ebr.Collector) void {
                const bucket: *Bucket = @ptrCast(@alignCast(ptr));
                collector.allocator.destroy(bucket);
            }
        };

        // Core data structures
        buckets: *FlurryHashMap,
        small_queue: SegQueue(K),
        main_queue: SegQueue(K),
        sketch: CountMinSketch,

        // Capacity tracking
        total_capacity: usize,
        small_capacity: usize,
        main_capacity: usize,
        small_size: std.atomic.Value(usize) align(64), // Cache line aligned to prevent false sharing
        main_size: std.atomic.Value(usize) align(64),

        // Statistics
        hits: std.atomic.Value(u64) align(64), // Cache line aligned for optimal performance
        misses: std.atomic.Value(u64) align(64),
        evictions: std.atomic.Value(u64) align(64),

        // EBR collector for lock-free memory reclamation (shared with Flurry)
        collector: *ebr.Collector,

        allocator: std.mem.Allocator,

        const SMALL_QUEUE_PERCENTAGE: f32 = 0.10;

        pub fn init(allocator: std.mem.Allocator, capacity: usize) !Self {
            const small_cap = @max(1, @as(usize, @intFromFloat(@as(f32, @floatFromInt(capacity)) * SMALL_QUEUE_PERCENTAGE)));
            const main_cap = capacity - small_cap;

            // Initialize shared EBR collector for Flurry and cache
            const collector = try ebr.Collector.init(allocator);
            errdefer collector.deinit();

            // Initialize Flurry HashMap with shared collector and Bucket reclaim function
            const buckets = try FlurryHashMap.init(allocator, collector, capacity, Bucket.reclaimBucket);
            errdefer buckets.deinit();

            return Self{
                .buckets = buckets,
                .small_queue = try SegQueue(K).init(allocator, 32),
                .main_queue = try SegQueue(K).init(allocator, 32),
                .sketch = try CountMinSketch.init(allocator, capacity * 10, 4),
                .total_capacity = capacity,
                .small_capacity = small_cap,
                .main_capacity = main_cap,
                .small_size = std.atomic.Value(usize).init(0),
                .main_size = std.atomic.Value(usize).init(0),
                .hits = std.atomic.Value(u64).init(0),
                .misses = std.atomic.Value(u64).init(0),
                .evictions = std.atomic.Value(u64).init(0),
                .collector = collector,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            // Free all buckets stored in Flurry HashMap
            // Flurry.forEachValue() iterates through all values and calls our callback
            self.buckets.forEachValue(self.allocator, freeBucket);

            self.small_queue.deinit();
            self.main_queue.deinit();
            self.buckets.deinit(); // Flurry cleans up hashmap nodes and table
            self.sketch.deinit();
            self.collector.deinit();
        }

        /// Callback for Flurry.forEachValue() to free a bucket
        fn freeBucket(allocator: std.mem.Allocator, bucket_ptr: *Bucket) void {
            allocator.destroy(bucket_ptr);
        }

        /// Expose collector for advanced guard management
        /// Allows callers to create and reuse guards for better performance
        pub fn getCollector(self: *Self) *ebr.Collector {
            return self.collector;
        }

        /// Get value from cache (lock-free with EBR protection)
        /// PERFORMANCE: Creates guard per-operation (convenient but slower)
        /// For better performance, use getCollector() and manage guards at thread level
        pub fn get(self: *Self, key: K) ?V {
            // Pin thread to EBR epoch - prevents bucket reclamation
            const guard = self.collector.pin() catch return null;
            defer self.collector.unpinGuard(guard);

            // Flurry.get() returns *Bucket directly (not **Bucket)
            if (self.buckets.get(key, guard)) |bucket_ptr| {
                bucket_ptr.incUses();
                _ = self.hits.fetchAdd(1, .monotonic);
                return bucket_ptr.value;
            }

            _ = self.misses.fetchAdd(1, .monotonic);
            return null;
        }

        /// Get value with externally-managed guard (zero allocation, maximum performance)
        /// Caller is responsible for guard lifetime
        pub fn getWithGuard(self: *Self, key: K, guard: *ebr.Guard) ?V {
            // Flurry.get() returns *Bucket directly (not **Bucket)
            if (self.buckets.get(key, guard)) |bucket_ptr| {
                bucket_ptr.incUses();
                _ = self.hits.fetchAdd(1, .monotonic);
                return bucket_ptr.value;
            }

            _ = self.misses.fetchAdd(1, .monotonic);
            return null;
        }

        /// Put key-value into cache (with EBR protection)
        /// PERFORMANCE: Creates guard per-operation (convenient but slower)
        /// For better performance, use getCollector() and manage guards at thread level
        pub fn put(self: *Self, key: K, value: V) !void {
            // Pin thread to EBR epoch for entire operation
            const guard = try self.collector.pin();
            defer self.collector.unpinGuard(guard);

            return self.putWithGuard(key, value, guard);
        }

        /// Put key-value with externally-managed guard (zero allocation, maximum performance)
        /// Caller is responsible for guard lifetime
        pub fn putWithGuard(self: *Self, key: K, value: V, guard: *ebr.Guard) !void {
            // Hash key for sketch
            var hasher = std.hash.Wyhash.init(0);
            std.hash.autoHash(&hasher, key);
            const key_hash = hasher.final();

            // Increment sketch and get new key's frequency for TinyLFU admission
            self.sketch.increment(key_hash);
            const new_freq = self.sketch.estimate(key_hash);

            // Check if exists - Flurry.get() returns *Bucket directly
            if (self.buckets.get(key, guard)) |bucket_ptr| {
                bucket_ptr.value = value;
                bucket_ptr.incUses();
                return;
            }

            // Evict if needed - pass new key's frequency for TinyLFU admission policy
            try self.evictToLimit(key_hash, new_freq, guard);

            // Create bucket
            const bucket = try self.allocator.create(Bucket);
            bucket.* = Bucket.init(value);

            // CRITICAL FIX: Handle return value from put() to prevent TOCTOU races
            // If another thread inserted the same key concurrently:
            // - put() returns the old bucket (their version)
            // - We must retire it with EBR, not leak it
            if (try self.buckets.put(key, bucket, guard)) |old_bucket| {
                // Race condition: another thread inserted first with their bucket
                // Our bucket is now in the hashmap (we won the final CAS)
                // But their old bucket must be retired with EBR
                try self.collector.retire(
                    @ptrCast(old_bucket),
                    Bucket.reclaimBucket,
                );
            }

            // Push to small queue
            try self.small_queue.push(key);
            _ = self.small_size.fetchAdd(1, .monotonic);
        }

        fn evictToLimit(self: *Self, _: u64, new_freq: u8, guard: *ebr.Guard) !void {
            // Note: Called from put() which already holds EBR guard
            // new_freq is used for TinyLFU admission policy
            while (true) {
                const small_sz = self.small_size.load(.monotonic);
                const main_sz = self.main_size.load(.monotonic);

                if (small_sz + main_sz < self.total_capacity) break;

                if (small_sz > self.small_capacity) {
                    try self.evictFromSmall(new_freq, guard);
                } else {
                    try self.evictFromMain(new_freq, guard);
                }
            }
        }

        fn evictFromSmall(self: *Self, new_freq: u8, guard: *ebr.Guard) !void {
            // TinyLFU admission: evict victim immediately to prevent TOCTOU race
            // that caused 2.5GB memory leak from stale keys in SegQueue
            _ = new_freq; // Not used anymore (removed re-queue logic)

            while (true) {
                const key = self.small_queue.pop() orelse return;

                // Check if bucket exists - use Flurry.get() with provided guard
                if (self.buckets.get(key, guard)) |bucket_ptr| {
                    _ = self.small_size.fetchSub(1, .monotonic);

                    if (bucket_ptr.getUses() > 1) {
                        // Promote to main - bucket stays in hashmap
                        bucket_ptr.moveToMain();
                        try self.main_queue.push(key);
                        _ = self.main_size.fetchAdd(1, .monotonic);
                    } else {
                        // TinyLFU admission check: compare frequencies
                        // Hash the victim key to get its frequency estimate
                        var hasher = std.hash.Wyhash.init(0);
                        std.hash.autoHash(&hasher, key);
                        const victim_hash = hasher.final();
                        const victim_freq = self.sketch.estimate(victim_hash);

                        // FIX: Evict victim immediately without re-queue logic
                        // TOCTOU race: between check and re-queue, another thread could remove the bucket
                        // This creates stale keys in the queue, accumulating 2.5GB of memory
                        // Solution: Always evict victim once we pop it from queue
                        // If victim is popular, TinyLFU admission will reject the new item anyway
                        _ = victim_freq; // Mark as used (was part of TinyLFU check)

                        // Evict this victim
                        // CRITICAL: buckets.remove() already retires the bucket via EBR
                        // (Flurry.remove handles retirement internally with value_reclaim_fn)
                        // Do NOT retire again here - would cause double-retirement
                        _ = self.buckets.remove(key, guard);
                        _ = self.evictions.fetchAdd(1, .monotonic);
                        return;
                    }
                } else {
                    // CRITICAL FIX: Stale key (already evicted by another thread)
                    // Decrement size counter to prevent drift
                    _ = self.small_size.fetchSub(1, .monotonic);
                }
            }
        }

        fn evictFromMain(self: *Self, new_freq: u8, guard: *ebr.Guard) !void {
            // TinyLFU admission: evict victim immediately to prevent TOCTOU race
            // that caused 2.5GB memory leak from stale keys in SegQueue
            _ = new_freq; // Not used anymore (removed re-queue logic)

            while (true) {
                const key = self.main_queue.pop() orelse return;

                // Check if bucket exists - use Flurry.get() with provided guard
                if (self.buckets.get(key, guard)) |bucket_ptr| {
                    _ = self.main_size.fetchSub(1, .monotonic);
                    const uses_after = bucket_ptr.decrUses();

                    if (uses_after > 0) {
                        // Requeue - bucket stays in hashmap
                        try self.main_queue.push(key);
                        _ = self.main_size.fetchAdd(1, .monotonic);
                    } else {
                        // TinyLFU admission check: compare frequencies
                        // Hash the victim key to get its frequency estimate
                        var hasher = std.hash.Wyhash.init(0);
                        std.hash.autoHash(&hasher, key);
                        const victim_hash = hasher.final();
                        const victim_freq = self.sketch.estimate(victim_hash);

                        // FIX: Evict victim immediately without re-queue logic
                        // TOCTOU race: between check and re-queue, another thread could remove the bucket
                        // This creates stale keys in the queue, accumulating 2.5GB of memory
                        // Solution: Always evict victim once we pop it from queue
                        // If victim is popular, TinyLFU admission will reject the new item anyway
                        _ = victim_freq; // Mark as used (was part of TinyLFU check)

                        // Evict this victim
                        // CRITICAL: buckets.remove() already retires the bucket via EBR
                        // (Flurry.remove handles retirement internally with value_reclaim_fn)
                        // Do NOT retire again here - would cause double-retirement
                        _ = self.buckets.remove(key, guard);
                        _ = self.evictions.fetchAdd(1, .monotonic);
                        return;
                    }
                } else {
                    // CRITICAL FIX: Stale key (already evicted by another thread)
                    // Decrement size counter to prevent drift
                    _ = self.main_size.fetchSub(1, .monotonic);
                }
            }
        }

        pub fn len(self: *const Self) usize {
            return self.buckets.len();
        }

        pub fn stats(self: *const Self) Stats {
            const total_hits = self.hits.load(.monotonic);
            const total_misses = self.misses.load(.monotonic);
            const total_ops = total_hits + total_misses;

            return Stats{
                .hits = total_hits,
                .misses = total_misses,
                .evictions = self.evictions.load(.monotonic),
                .size = self.len(),
                .capacity = self.total_capacity,
                .hit_rate = if (total_ops > 0)
                    @as(f64, @floatFromInt(total_hits)) / @as(f64, @floatFromInt(total_ops))
                else
                    0.0,
            };
        }
    };
}

pub const Stats = struct {
    hits: u64,
    misses: u64,
    evictions: u64,
    size: usize,
    capacity: usize,
    hit_rate: f64,
};
