/// TinyUFO v3 - High-performance cache with TinyLFU admission
/// Weight-based capacity, dual FIFOs, EBR-protected values

const std = @import("std");
const Atomic = std.atomic.Value;

const ebr = @import("ebr.zig");
const Collector = ebr.Collector;

const seg_queue_mod = @import("seg_queue.zig");
const SegQueue = seg_queue_mod.SegQueue;

const estimator_mod = @import("estimator.zig");
const TinyLFU = estimator_mod.TinyLFU;

const model_mod = @import("model.zig");
const Uses = model_mod.Uses;
const Location = model_mod.Location;
const Bucket = model_mod.Bucket;

const fifos_mod = @import("fifos.zig");
const FIFOs = fifos_mod.FIFOs;
const Key = fifos_mod.Key;

const buckets_mod = @import("buckets.zig");
const BucketsInterface = buckets_mod.BucketsInterface;
const BucketsFast = buckets_mod.BucketsFast;
const BucketsCompact = buckets_mod.BucketsCompact;

pub const BackendType = enum {
    Fast,
    Compact,
};

/// Evicted item info for admission control (Rust: lib.rs line 192)
pub fn EvictedItem(comptime V: type) type {
    return struct {
        key: u64,
        weight: u16,
        data: V,
    };
}

/// Statistics for cache monitoring
pub const CacheStats = struct {
    hits: u64,
    misses: u64,
    evictions: u64,
    total_weight: u64,
};

/// TinyUFO cache with generic value type
pub fn TinyUFO(comptime V: type) type {
    return struct {
        allocator: std.mem.Allocator,

        // Core components
        collector: *Collector,
        fifos: *FIFOs,

        // Pluggable bucket backend (Fast or Compact)
        buckets: *BucketsInterface,
        backend_fast: ?*BucketsFast = null,
        backend_compact: ?*BucketsCompact = null,

        // Statistics (atomic)
        stats_hits: Atomic(u64),
        stats_misses: Atomic(u64),
        stats_evictions: Atomic(u64),

        // Tracking for TinyLFU admission control
        last_evicted_key: Atomic(u64),
        last_evicted_weight: Atomic(u16),

        capacity: u64,
        weight_limit: u64,

        const Self = @This();

        /// Create new cache with capacity (weight-based) using specified backend
        pub fn init(allocator: std.mem.Allocator, weight_limit: u64) !*Self {
            return try init_with_backend(allocator, weight_limit, .Fast);
        }

        /// Create new cache with explicit backend selection
        pub fn init_with_backend(allocator: std.mem.Allocator, weight_limit: u64, backend_type: BackendType) !*Self {
            const cache = try allocator.create(Self);

            const collector = try Collector.init(allocator, 256);
            const fifos = try FIFOs.init(allocator, weight_limit, weight_limit);

            // Initialize appropriate backend
            const buckets_iface: *BucketsInterface = switch (backend_type) {
                .Fast => blk: {
                    const backend = try BucketsFast.init(allocator, weight_limit);
                    const iface_ptr = try allocator.create(BucketsInterface);
                    iface_ptr.* = backend.as_interface();
                    cache.backend_fast = backend;
                    break :blk iface_ptr;
                },
                .Compact => blk: {
                    const backend = try BucketsCompact.init(allocator, weight_limit);
                    const iface_ptr = try allocator.create(BucketsInterface);
                    iface_ptr.* = backend.as_interface();
                    cache.backend_compact = backend;
                    break :blk iface_ptr;
                },
            };

            cache.* = .{
                .allocator = allocator,
                .collector = collector,
                .fifos = fifos,
                .buckets = buckets_iface,
                .stats_hits = Atomic(u64).init(0),
                .stats_misses = Atomic(u64).init(0),
                .stats_evictions = Atomic(u64).init(0),
                .last_evicted_key = Atomic(u64).init(0),
                .last_evicted_weight = Atomic(u16).init(0),
                .capacity = weight_limit,
                .weight_limit = weight_limit,
            };

            return cache;
        }

        pub fn deinit(self: *Self) void {
            // Deallocate all remaining buckets before destroying backend structures
            // Buckets are stored as void pointers that actually point to Bucket(V) instances
            if (self.buckets.len() > 0) {
                // Get all keys first by collecting them
                // This is safer than modifying the map while iterating
                var temp_keys: [1024]u64 = undefined;
                var key_count: usize = 0;

                if (self.backend_fast) |backend| {
                    var iter = backend.map.keyIterator();
                    while (iter.next()) |key_ptr| {
                        if (key_count < temp_keys.len) {
                            temp_keys[key_count] = key_ptr.*;
                            key_count += 1;
                        }
                    }
                } else if (self.backend_compact) |backend| {
                    for (0..buckets_mod.SHARD_COUNT) |shard_idx| {
                        var iter = backend.shards[shard_idx].map.keyIterator();
                        while (iter.next()) |key_ptr| {
                            if (key_count < temp_keys.len) {
                                temp_keys[key_count] = key_ptr.*;
                                key_count += 1;
                            }
                        }
                    }
                }

                // Now remove and deallocate each bucket
                for (0..key_count) |i| {
                    if (self.buckets.remove(temp_keys[i])) |bucket_opaque| {
                        const bucket: *Bucket(V) = @ptrCast(@alignCast(bucket_opaque));
                        self.allocator.destroy(bucket);
                    }
                }
            }

            // Now destroy the backend and other structures
            if (self.backend_fast) |backend| {
                backend.deinit();
            } else if (self.backend_compact) |backend| {
                backend.deinit();
            }

            self.allocator.destroy(self.buckets);
            self.fifos.deinit();
            self.collector.deinit();
            self.allocator.destroy(self);
        }

        /// Get value for key (returns null if not found)
        pub fn get(self: *Self, key: u64) ?*V {
            const result = self.buckets.get(key);

            if (result) |bucket_opaque| {
                const bucket: *Bucket(V) = @ptrCast(@alignCast(bucket_opaque));

                // Hit
                _ = self.stats_hits.fetchAdd(1, .monotonic);

                // Record access
                bucket.access();
                _ = self.fifos.estimator.incr(key);  // Update frequency estimate

                return &bucket.data;
            }

            // Miss
            _ = self.stats_misses.fetchAdd(1, .monotonic);
            return null;
        }

        /// Insert or update value for key with weight
        /// Rust: lib.rs lines 149-242
        pub fn set(self: *Self, key: u64, value: V, weight: u16) !void {
            // Rust line 162: Update frequency first
            const new_freq = self.fifos.estimator.incr(key);

            // Check if exists
            const existing = self.buckets.get(key);
            if (existing) |bucket_opaque| {
                // Update existing
                // Rust lines 166-187: increment uses and update weight
                const bucket: *Bucket(V) = @ptrCast(@alignCast(bucket_opaque));
                const old_weight = bucket.weight;
                bucket.data = value;
                bucket.weight = weight;
                bucket.access(); // Increment uses

                // Update weight if changed
                if (old_weight != weight) {
                    if (bucket.location.is_main()) {
                        if (old_weight < weight) {
                            _ = self.fifos.main_weight.fetchAdd(weight - old_weight, .seq_cst);
                        } else {
                            _ = self.fifos.main_weight.fetchSub(old_weight - weight, .seq_cst);
                        }
                    } else {
                        if (old_weight < weight) {
                            _ = self.fifos.small_weight.fetchAdd(weight - old_weight, .seq_cst);
                        } else {
                            _ = self.fifos.small_weight.fetchSub(old_weight - weight, .seq_cst);
                        }
                    }
                }

                // Rust line 241: Final evict_to_limit(0)
                try self.evict_to_limit();
                return;
            }

            // New item path
            // Rust line 189: EAGER EVICTION BEFORE INSERT
            // Try to evict items to make room for the new weight

            // Reset evicted tracking
            self.last_evicted_key.store(std.math.maxInt(u64), .release);

            // Rust line 189: EAGER eviction BEFORE insert
            const evictions_during_put = try self.evict_to_limit_with_weight(weight);

            const evicted_key = self.last_evicted_key.load(.acquire);

            // Rust lines 192-208: TinyLFU admission control
            // Only check frequency if EXACTLY 1 item was evicted (Rust line 192)
            const admit_new_item = if (evictions_during_put == 1 and evicted_key != std.math.maxInt(u64)) blk: {
                // Exactly 1 item was evicted - apply TinyLFU admission
                const evicted_freq = self.fifos.estimator.get(evicted_key);

                // If evicted item is more popular, REJECT new item (Rust: line 197)
                if (evicted_freq > new_freq) {
                    // Reject - don't insert new item (put evicted one back)
                    break :blk false;
                }

                // Accept new item - it's at least as popular as what we evicted
                break :blk true;
            } else blk: {
                // Either nothing was evicted OR multiple items were evicted
                // In either case, always admit (Rust line 206)
                break :blk true;
            };

            // Only insert if admitted (Rust: lines 210-222)
            if (!admit_new_item) {
                return;
            }

            // Rust lines 210-215: Create new bucket with location=small, uses=0
            const new_bucket = try self.allocator.create(Bucket(V));
            new_bucket.* = Bucket(V).init(value, weight);

            // Rust line 216: Insert bucket (returns old value if existed)
            const old_bucket_opt = try self.buckets.insert(key, @ptrCast(new_bucket));

            // Rust line 217-222: Only push to queue if NEW insertion
            // After insert(), new_bucket is in cache regardless
            if (old_bucket_opt == null) {
                // NEW insertion - no previous bucket existed
                try self.fifos.small_queue_push(key, weight);
            } else {
                // RACE/UPDATE: Previous bucket existed and was replaced by new_bucket
                // Deallocate the old bucket that was replaced
                const old_bucket: *Bucket(V) = @ptrCast(@alignCast(old_bucket_opt.?));
                self.allocator.destroy(old_bucket);
                // Don't push to queue - the key was already in queue from before
                // (The old bucket had a queue entry)
            }

            // Rust line 225: RETURN EARLY (no final evict_to_limit for new items)
            // The evict_to_limit_with_weight(weight) call already ensured:
            //   small_weight + main_weight + weight <= total_weight_limit
            // Adding the item brings us to the limit, so no need for final eviction
            return;
        }

        /// Evict items until under capacity (Rust: lib.rs lines 246-265)
        /// extra_weight: reserve space for upcoming insertion
        /// Returns count of items evicted
        fn evict_to_limit_with_weight(self: *Self, extra_weight: u16) !u32 {
            var eviction_count: u32 = 0;
            while (self.fifos.is_over_capacity_with_weight(extra_weight)) {
                if (try self.evict_one()) {
                    // Item was evicted, continue
                    eviction_count += 1;
                } else {
                    // Nothing to evict
                    break;
                }
            }
            return eviction_count;
        }

        /// Evict items until under capacity (final pass)
        fn evict_to_limit(self: *Self) !void {
            _ = try self.evict_to_limit_with_weight(0);
        }

        /// Evict a single item (Rust: lib.rs lines 267-279)
        /// Returns true if item was evicted, false if nothing to evict
        fn evict_one(self: *Self) !bool {
            // Check if we should evict from small queue
            const evict_small = self.fifos.small_weight_limit() <= self.fifos.small_weight.load(.seq_cst);

            if (evict_small) {
                // Try to evict from small queue first
                // Rust lines 271-276: evict_one_from_small could promote, so check result
                if (try self.evict_one_from_small()) {
                    return true;
                }
            }

            // If nothing from small, evict from main
            // Rust line 278: evict_one_from_main
            return try self.evict_one_from_main();
        }

        /// Evict from small queue with smart promotion (Rust: lib.rs lines 285-321)
        fn evict_one_from_small(self: *Self) !bool {
            // Rust line 286: LOOP internally - keep trying until find something to evict
            while (true) {
                // Rust line 287: Pop from small queue
                const entry_ptr_opt = self.fifos.small_queue.pop();
                if (entry_ptr_opt == null) {
                    // Queue empty - Rust line 289: return None
                    return false;
                }

                const entry_ptr = entry_ptr_opt.?;
                const entry: *fifos_mod.QueueEntry = @ptrCast(@alignCast(entry_ptr));
                const key = entry.key;
                const weight = entry.weight;

                // Rust lines 292-313: Get bucket and check uses
                const bucket_opt = self.buckets.get(key);
                if (bucket_opt) |bucket_opaque| {
                    const bucket: *Bucket(V) = @ptrCast(@alignCast(bucket_opaque));

                    // Rust line 297: Check if hot (uses > 1)
                    if (bucket.uses.uses() > 1) {
                        // IMPORTANT: Rust line 295 update weight ONLY happens in both branches
                        // Rust line 295: Update small queue weight
                        _ = self.fifos.small_weight.fetchSub(weight, .seq_cst);
                        // Rust lines 299-301: PROMOTE to main (don't evict)
                        bucket.location.move_to_main();
                        try self.fifos.promote_to_main(key, weight);

                        // Deallocate the queue entry
                        self.allocator.destroy(entry);

                        // Rust line 303: Return None but CONTINUE LOOP
                        // (loop continues to next iteration, not break)
                    } else {
                        // Rust lines 305-312: EVICT (uses <= 1)
                        // Rust line 295: Update small queue weight
                        _ = self.fifos.small_weight.fetchSub(weight, .seq_cst);

                        if (self.buckets.remove(key)) |removed_opaque| {
                            _ = self.stats_evictions.fetchAdd(1, .monotonic);
                            const removed_bucket: *Bucket(V) = @ptrCast(@alignCast(removed_opaque));
                            // Store evicted info for admission control (Rust: lib.rs lines 192-208)
                            self.last_evicted_key.store(key, .release);
                            self.last_evicted_weight.store(weight, .release);
                            self.allocator.destroy(removed_bucket);
                        }

                        // Deallocate the queue entry
                        self.allocator.destroy(entry);

                        // Rust line 318: Return Some (evicted)
                        return true;
                    }
                } else {
                    // Bucket not found - just deallocate entry and continue looping
                    // (Don't adjust weight - bucket never existed or already removed)
                    self.allocator.destroy(entry);
                    // Continue loop to try next item
                }
            }
        }

        /// Evict from main queue with uses decrement (Rust: lib.rs lines 323-353)
        fn evict_one_from_main(self: *Self) !bool {
            // Rust line 324: LOOP internally - keep trying until find something to evict
            while (true) {
                // Rust line 325: Pop from main queue
                const entry_ptr_opt = self.fifos.main_queue.pop();
                if (entry_ptr_opt == null) {
                    return false;
                }

                const entry_ptr = entry_ptr_opt.?;
                const entry: *fifos_mod.QueueEntry = @ptrCast(@alignCast(entry_ptr));
                const key = entry.key;
                const weight = entry.weight;

                // Rust lines 327-346: Get bucket and check uses
                const bucket_opt = self.buckets.get(key);
                if (bucket_opt) |bucket_opaque| {
                    const bucket: *Bucket(V) = @ptrCast(@alignCast(bucket_opaque));

                    // Rust line 329: Decrement uses and check RETURNED value (before decrement)
                    const prev_uses = bucket.uses.decr_uses();
                    if (prev_uses > 0) {
                        // Rust lines 331-332: RE-QUEUE (don't evict)
                        // Create NEW entry for re-queueing (don't reuse old pointer!)
                        const new_entry = try self.allocator.create(fifos_mod.QueueEntry);
                        new_entry.* = fifos_mod.QueueEntry{
                            .key = key,
                            .weight = weight,
                        };
                        try self.fifos.main_queue.push(@ptrFromInt(@intFromPtr(new_entry)));
                        // Deallocate the old entry
                        self.allocator.destroy(entry);

                        // Rust line 333: Return None but CONTINUE LOOP
                        // (loop continues to next iteration)
                    } else {
                        // Rust lines 336-343: EVICT (prev_uses == 0)
                        _ = self.fifos.main_weight.fetchSub(weight, .seq_cst);

                        if (self.buckets.remove(key)) |removed_opaque| {
                            _ = self.stats_evictions.fetchAdd(1, .monotonic);
                            const removed_bucket: *Bucket(V) = @ptrCast(@alignCast(removed_opaque));
                            // Store evicted info for admission control (Rust: lib.rs lines 192-208)
                            self.last_evicted_key.store(key, .release);
                            self.last_evicted_weight.store(weight, .release);
                            self.allocator.destroy(removed_bucket);
                        }

                        // Deallocate the queue entry
                        self.allocator.destroy(entry);

                        // Rust line 350: Return Some (evicted)
                        return true;
                    }
                } else {
                    // Bucket not found - just deallocate entry and continue looping
                    // (Don't adjust weight - bucket never existed or already removed)
                    self.allocator.destroy(entry);
                    // Continue loop to try next item
                }
            }
        }

        /// Get current statistics
        pub fn stats(self: *Self) CacheStats {
            return .{
                .hits = self.stats_hits.load(.acquire),
                .misses = self.stats_misses.load(.acquire),
                .evictions = self.stats_evictions.load(.acquire),
                .total_weight = self.fifos.total_weight(),
            };
        }

        /// Get number of items
        pub fn len(self: *Self) usize {
            return self.buckets.len();
        }

        /// Clear all items
        pub fn clear(self: *Self) !void {
            self.buckets.clear();
            self.fifos.clear();

            self.stats_hits.store(0, .monotonic);
            self.stats_misses.store(0, .monotonic);
            self.stats_evictions.store(0, .monotonic);
        }

        /// Get hit rate (0.0 to 1.0)
        pub fn hit_rate(self: *Self) f64 {
            const hits = self.stats_hits.load(.acquire);
            const misses = self.stats_misses.load(.acquire);
            const total = hits + misses;

            if (total == 0) return 0.0;

            return @as(f64, @floatFromInt(hits)) / @as(f64, @floatFromInt(total));
        }
    };
}

/// ============================================================================
/// TESTS
/// ============================================================================

const testing = std.testing;
const test_alloc = testing.allocator;

test "TinyUFO: init and deinit" {
    const cache = try TinyUFO(u32).init(test_alloc, 1000);
    defer cache.deinit();

    try testing.expect(cache.weight_limit == 1000);
    try testing.expect(cache.len() == 0);
}

test "TinyUFO: set and get" {
    const cache = try TinyUFO(u32).init(test_alloc, 1000);
    defer cache.deinit();

    try cache.set(111, 42, 100);

    const value = cache.get(111);
    try testing.expect(value != null);
    try testing.expect(value.?.* == 42);
}

test "TinyUFO: get miss" {
    const cache = try TinyUFO(u32).init(test_alloc, 1000);
    defer cache.deinit();

    const value = cache.get(999);
    try testing.expect(value == null);
}

test "TinyUFO: multiple items" {
    const cache = try TinyUFO(u64).init(test_alloc, 5000);
    defer cache.deinit();

    try cache.set(1, 100, 100);
    try cache.set(2, 200, 100);
    try cache.set(3, 300, 100);

    try testing.expect(cache.len() == 3);

    try testing.expect(cache.get(1).?.* == 100);
    try testing.expect(cache.get(2).?.* == 200);
    try testing.expect(cache.get(3).?.* == 300);
}

test "TinyUFO: stats" {
    const cache = try TinyUFO(u32).init(test_alloc, 1000);
    defer cache.deinit();

    try cache.set(1, 42, 100);

    _ = cache.get(1); // hit
    _ = cache.get(2); // miss

    const s = cache.stats();
    try testing.expect(s.hits == 1);
    try testing.expect(s.misses == 1);
}

test "TinyUFO: clear" {
    const cache = try TinyUFO(u32).init(test_alloc, 1000);
    defer cache.deinit();

    try cache.set(1, 10, 50);
    try cache.set(2, 20, 50);

    try testing.expect(cache.len() == 2);

    try cache.clear();

    try testing.expect(cache.len() == 0);
}

test "TinyUFO: hit rate" {
    const cache = try TinyUFO(u32).init(test_alloc, 1000);
    defer cache.deinit();

    try cache.set(1, 42, 100);

    _ = cache.get(1); // hit
    _ = cache.get(1); // hit
    _ = cache.get(2); // miss

    const rate = cache.hit_rate();
    try testing.expect(rate > 0.5);
}

test "TinyUFO: weight limit enforcement" {
    const cache = try TinyUFO(u32).init(test_alloc, 300);
    defer cache.deinit();

    try cache.set(1, 10, 200);
    try cache.set(2, 20, 200);

    // Should evict due to weight
    const s = cache.stats();
    try testing.expect(s.evictions > 0 or cache.len() < 2);
}

test "TinyUFO: update existing" {
    const cache = try TinyUFO(u32).init(test_alloc, 1000);
    defer cache.deinit();

    try cache.set(1, 42, 100);
    try cache.set(1, 99, 100);

    try testing.expect(cache.get(1).?.* == 99);
}

test "TinyUFO: generic with string" {
    const cache = try TinyUFO([]const u8).init(test_alloc, 1000);
    defer cache.deinit();

    const key = 111;
    const value = "hello";

    try cache.set(key, value, 100);

    const retrieved = cache.get(key);
    try testing.expect(retrieved != null);
    try testing.expect(std.mem.eql(u8, retrieved.?.*, value));
}

test "TinyUFO: eviction counter" {
    const cache = try TinyUFO(u32).init(test_alloc, 200);
    defer cache.deinit();

    // Force evictions
    for (0..5) |i| {
        try cache.set(@intCast(i), @intCast(i), 100);
    }

    const s = cache.stats();
    try testing.expect(s.evictions > 0);
}

test "TinyUFO: capacity with small items" {
    const cache = try TinyUFO(u32).init(test_alloc, 1000);
    defer cache.deinit();

    // Add many small items
    for (0..20) |i| {
        try cache.set(@intCast(i), @intCast(i * 10), 10);
    }

    // All should fit
    try testing.expect(cache.len() >= 18);
}

test "TinyUFO: zero weight items" {
    const cache = try TinyUFO(u32).init(test_alloc, 1000);
    defer cache.deinit();

    try cache.set(1, 42, 0);

    try testing.expect(cache.get(1).?.* == 42);
}

test "TinyUFO: Fast backend" {
    const cache = try TinyUFO(u32).init_with_backend(test_alloc, 1000, .Fast);
    defer cache.deinit();

    try cache.set(111, 42, 100);

    const value = cache.get(111);
    try testing.expect(value != null);
    try testing.expect(value.?.* == 42);
}

test "TinyUFO: Compact backend" {
    const cache = try TinyUFO(u32).init_with_backend(test_alloc, 1000, .Compact);
    defer cache.deinit();

    try cache.set(222, 99, 100);

    const value = cache.get(222);
    try testing.expect(value != null);
    try testing.expect(value.?.* == 99);
}

test "TinyUFO: Fast backend multiple items" {
    const cache = try TinyUFO(u64).init_with_backend(test_alloc, 5000, .Fast);
    defer cache.deinit();

    try cache.set(1, 100, 100);
    try cache.set(2, 200, 100);
    try cache.set(3, 300, 100);

    try testing.expect(cache.len() == 3);
    try testing.expect(cache.get(1).?.* == 100);
    try testing.expect(cache.get(2).?.* == 200);
    try testing.expect(cache.get(3).?.* == 300);
}

test "TinyUFO: Compact backend multiple items" {
    const cache = try TinyUFO(u64).init_with_backend(test_alloc, 5000, .Compact);
    defer cache.deinit();

    try cache.set(10, 1000, 100);
    try cache.set(20, 2000, 100);
    try cache.set(30, 3000, 100);

    try testing.expect(cache.len() == 3);
    try testing.expect(cache.get(10).?.* == 1000);
    try testing.expect(cache.get(20).?.* == 2000);
    try testing.expect(cache.get(30).?.* == 3000);
}
