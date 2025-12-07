const std = @import("std");

/// Lock-free concurrent hashmap for cache entries
/// Uses sharded buckets with atomic operations for thread safety
pub fn ConcurrentHashMap(comptime K: type, comptime V: type) type {
    return struct {
        const Self = @This();

        /// Hash bucket node (linked list)
        pub const Node = struct {
            key: K,
            value: V,
            hash: u64,
            next: std.atomic.Value(?*Node),

            pub fn init(key: K, value: V, hash: u64) Node {
                return Node{
                    .key = key,
                    .value = value,
                    .hash = hash,
                    .next = std.atomic.Value(?*Node).init(null),
                };
            }
        };

        /// Shard for reduced contention
        const Shard = struct {
            buckets: []std.atomic.Value(?*Node),
            bucket_mask: usize,
            mutex: std.Thread.Mutex, // For write operations only

            fn init(allocator: std.mem.Allocator, bucket_count: usize) !Shard {
                const buckets = try allocator.alloc(std.atomic.Value(?*Node), bucket_count);
                @memset(buckets, std.atomic.Value(?*Node).init(null));

                return Shard{
                    .buckets = buckets,
                    .bucket_mask = bucket_count - 1,
                    .mutex = std.Thread.Mutex{},
                };
            }

            fn deinit(self: *Shard, allocator: std.mem.Allocator) void {
                // Free all nodes in all buckets
                for (self.buckets) |*bucket| {
                    var current = bucket.load(.acquire);
                    while (current) |node| {
                        const next = node.next.load(.acquire);
                        allocator.destroy(node);
                        current = next;
                    }
                }
                allocator.free(self.buckets);
            }

            fn getBucketIndex(self: *const Shard, hash: u64) usize {
                return @as(usize, @intCast(hash)) & self.bucket_mask;
            }
        };

        shards: []Shard,
        shard_mask: usize,
        allocator: std.mem.Allocator,
        size: std.atomic.Value(usize),

        /// Initialize concurrent hashmap
        /// capacity: Initial capacity (rounded to power of 2)
        /// shard_count: Number of shards (default: 64)
        pub fn init(allocator: std.mem.Allocator, capacity: usize, shard_count: usize) !Self {
            const actual_shard_count = std.math.ceilPowerOfTwo(usize, shard_count) catch shard_count;
            const buckets_per_shard = std.math.ceilPowerOfTwo(usize, capacity / actual_shard_count) catch 16;

            const shards = try allocator.alloc(Shard, actual_shard_count);
            errdefer allocator.free(shards);

            for (shards, 0..) |*shard, i| {
                shard.* = try Shard.init(allocator, buckets_per_shard);
                errdefer {
                    // Clean up previously initialized shards
                    for (shards[0..i]) |*s| {
                        s.deinit(allocator);
                    }
                }
            }

            return Self{
                .shards = shards,
                .shard_mask = actual_shard_count - 1,
                .allocator = allocator,
                .size = std.atomic.Value(usize).init(0),
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.shards) |*shard| {
                shard.deinit(self.allocator);
            }
            self.allocator.free(self.shards);
        }

        fn getShardIndex(self: *const Self, hash: u64) usize {
            return @as(usize, @intCast(hash >> 32)) & self.shard_mask;
        }

        fn getShard(self: *Self, hash: u64) *Shard {
            return &self.shards[self.getShardIndex(hash)];
        }

        /// Hash function for keys
        fn hashKey(key: K) u64 {
            // Use Zig's built-in hash
            var hasher = std.hash.Wyhash.init(0);
            if (@TypeOf(key) == u64) {
                std.hash.autoHash(&hasher, key);
            } else {
                std.hash.autoHash(&hasher, key);
            }
            return hasher.final();
        }

        /// Get value for key (lock-free read)
        pub fn get(self: *Self, key: K) ?V {
            const hash = hashKey(key);
            const shard = self.getShard(hash);
            const bucket_idx = shard.getBucketIndex(hash);

            var current = shard.buckets[bucket_idx].load(.acquire);
            while (current) |node| {
                if (node.hash == hash and std.meta.eql(node.key, key)) {
                    return node.value;
                }
                current = node.next.load(.acquire);
            }

            return null;
        }

        /// Get pointer to value for key (lock-free read, allows mutation)
        pub fn getPtr(self: *Self, key: K) ?*V {
            const hash = hashKey(key);
            const shard = self.getShard(hash);
            const bucket_idx = shard.getBucketIndex(hash);

            var current = shard.buckets[bucket_idx].load(.acquire);
            while (current) |node| {
                if (node.hash == hash and std.meta.eql(node.key, key)) {
                    return &node.value;
                }
                current = node.next.load(.acquire);
            }

            return null;
        }

        /// Put key-value pair (uses shard-level lock for simplicity)
        pub fn put(self: *Self, key: K, value: V) !void {
            const hash = hashKey(key);
            const shard = self.getShard(hash);
            const bucket_idx = shard.getBucketIndex(hash);

            shard.mutex.lock();
            defer shard.mutex.unlock();

            // Check if key already exists
            var current = shard.buckets[bucket_idx].load(.acquire);
            while (current) |node| {
                if (node.hash == hash and std.meta.eql(node.key, key)) {
                    // Update existing value
                    node.value = value;
                    return;
                }
                current = node.next.load(.acquire);
            }

            // Insert new node at head
            const new_node = try self.allocator.create(Node);
            new_node.* = Node.init(key, value, hash);

            const head = shard.buckets[bucket_idx].load(.acquire);
            new_node.next.store(head, .release);
            shard.buckets[bucket_idx].store(new_node, .release);

            _ = self.size.fetchAdd(1, .monotonic);
        }

        /// Remove key (uses shard-level lock)
        pub fn remove(self: *Self, key: K) ?V {
            const hash = hashKey(key);
            const shard = self.getShard(hash);
            const bucket_idx = shard.getBucketIndex(hash);

            shard.mutex.lock();
            defer shard.mutex.unlock();

            var prev: ?*Node = null;
            var current = shard.buckets[bucket_idx].load(.acquire);

            while (current) |node| {
                if (node.hash == hash and std.meta.eql(node.key, key)) {
                    const value = node.value;
                    const next = node.next.load(.acquire);

                    if (prev) |p| {
                        p.next.store(next, .release);
                    } else {
                        shard.buckets[bucket_idx].store(next, .release);
                    }

                    self.allocator.destroy(node);
                    _ = self.size.fetchSub(1, .monotonic);
                    return value;
                }

                prev = node;
                current = node.next.load(.acquire);
            }

            return null;
        }

        /// Check if key exists (lock-free)
        pub fn contains(self: *Self, key: K) bool {
            return self.get(key) != null;
        }

        /// Get current size
        pub fn len(self: *const Self) usize {
            return self.size.load(.monotonic);
        }

        /// Clear all entries
        pub fn clear(self: *Self) void {
            for (self.shards) |*shard| {
                shard.mutex.lock();
                defer shard.mutex.unlock();

                for (shard.buckets) |*bucket| {
                    var current = bucket.swap(null, .acquire);
                    while (current) |node| {
                        const next = node.next.load(.acquire);
                        self.allocator.destroy(node);
                        current = next;
                    }
                }
            }

            self.size.store(0, .release);
        }
    };
}

test "ConcurrentHashMap basic operations" {
    const allocator = std.testing.allocator;

    var map = try ConcurrentHashMap(u64, u64).init(allocator, 100, 16);
    defer map.deinit();

    // Test put and get
    try map.put(42, 100);
    try std.testing.expectEqual(@as(?u64, 100), map.get(42));
    try std.testing.expectEqual(@as(usize, 1), map.len());

    // Test update
    try map.put(42, 200);
    try std.testing.expectEqual(@as(?u64, 200), map.get(42));
    try std.testing.expectEqual(@as(usize, 1), map.len());

    // Test multiple entries
    try map.put(10, 1000);
    try map.put(20, 2000);
    try std.testing.expectEqual(@as(usize, 3), map.len());

    // Test remove
    const removed = map.remove(42);
    try std.testing.expectEqual(@as(?u64, 200), removed);
    try std.testing.expectEqual(@as(?u64, null), map.get(42));
    try std.testing.expectEqual(@as(usize, 2), map.len());

    // Test contains
    try std.testing.expect(map.contains(10));
    try std.testing.expect(!map.contains(999));
}
