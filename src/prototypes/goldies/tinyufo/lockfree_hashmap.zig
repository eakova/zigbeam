// Lock-Free HashMap for TinyUFO Cache
// High-performance concurrent hashmap with atomic CAS operations
// Designed for lock-free reads and writes with minimal contention

const std = @import("std");

/// Lock-free hashmap with sharded buckets for reduced contention
pub fn LockFreeHashMap(comptime K: type, comptime V: type) type {
    return struct {
        const Self = @This();

        /// Bucket entry - atomic pointer to key-value pair
        const Entry = struct {
            key: K,
            value: std.atomic.Value(V),
            hash: u64,
            next: std.atomic.Value(?*Entry),

            fn init(allocator: std.mem.Allocator, key: K, value: V, hash_val: u64) !*Entry {
                const entry = try allocator.create(Entry);
                entry.* = Entry{
                    .key = key,
                    .value = std.atomic.Value(V).init(value),
                    .hash = hash_val,
                    .next = std.atomic.Value(?*Entry).init(null),
                };
                return entry;
            }
        };

        /// Bucket with atomic head pointer (lock-free linked list)
        const Bucket = struct {
            head: std.atomic.Value(?*Entry),

            fn init() Bucket {
                return Bucket{
                    .head = std.atomic.Value(?*Entry).init(null),
                };
            }

            /// Lock-free insert with CAS retry
            fn insert(self: *Bucket, allocator: std.mem.Allocator, key: K, value: V, hash_val: u64) !void {
                const new_entry = try Entry.init(allocator, key, value, hash_val);

                var retries: usize = 0;
                const max_retries = 100;

                while (retries < max_retries) : (retries += 1) {
                    const current_head = self.head.load(.acquire);

                    // Check if key already exists
                    var node = current_head;
                    while (node) |n| {
                        if (n.hash == hash_val and std.meta.eql(n.key, key)) {
                            // Update existing value
                            n.value.store(value, .release);
                            allocator.destroy(new_entry);
                            return;
                        }
                        node = n.next.load(.acquire);
                    }

                    // Try to insert new entry at head
                    new_entry.next.store(current_head, .release);

                    if (self.head.cmpxchgWeak(
                        current_head,
                        new_entry,
                        .acq_rel,
                        .acquire,
                    )) |_| {
                        // CAS failed, retry
                        continue;
                    }

                    // Successfully inserted
                    return;
                }

                allocator.destroy(new_entry);
                return error.CASRetryLimitExceeded;
            }

            /// Lock-free get (pure atomic loads)
            fn get(self: *const Bucket, key: K, hash_val: u64) ?V {
                var node = self.head.load(.acquire);

                while (node) |n| {
                    if (n.hash == hash_val and std.meta.eql(n.key, key)) {
                        return n.value.load(.acquire);
                    }
                    node = n.next.load(.acquire);
                }

                return null;
            }

            /// Lock-free delete with CAS
            fn remove(self: *Bucket, allocator: std.mem.Allocator, key: K, hash_val: u64) ?V {
                var retries: usize = 0;
                const max_retries = 100;

                while (retries < max_retries) : (retries += 1) {
                    const current_head = self.head.load(.acquire);
                    if (current_head == null) return null;

                    // Check if head matches
                    if (current_head.?.hash == hash_val and std.meta.eql(current_head.?.key, key)) {
                        const next = current_head.?.next.load(.acquire);
                        if (self.head.cmpxchgWeak(
                            current_head,
                            next,
                            .acq_rel,
                            .acquire,
                        )) |_| {
                            continue;
                        }

                        const value = current_head.?.value.load(.acquire);
                        allocator.destroy(current_head.?);
                        return value;
                    }

                    // Search in rest of list
                    var prev = current_head.?;
                    var node = prev.next.load(.acquire);

                    while (node) |n| {
                        if (n.hash == hash_val and std.meta.eql(n.key, key)) {
                            const next = n.next.load(.acquire);
                            if (prev.next.cmpxchgWeak(
                                node,
                                next,
                                .acq_rel,
                                .acquire,
                            )) |_| {
                                // Another thread modified, retry from start
                                break;
                            }

                            const value = n.value.load(.acquire);
                            allocator.destroy(n);
                            return value;
                        }
                        prev = n;
                        node = n.next.load(.acquire);
                    }

                    retries += 1;
                }

                return null;
            }

            fn deinit(self: *Bucket, allocator: std.mem.Allocator) void {
                var node = self.head.load(.acquire);
                while (node) |n| {
                    const next = n.next.load(.acquire);
                    allocator.destroy(n);
                    node = next;
                }
            }
        };

        /// Sharded buckets for reduced contention
        buckets: []Bucket,
        bucket_count: usize,
        allocator: std.mem.Allocator,

        /// Initialize hashmap with given capacity
        pub fn init(allocator: std.mem.Allocator, capacity: usize) !Self {
            // Use 8x capacity for better distribution (reduces contention)
            // Round up to power of 2 for efficient modulo
            const bucket_count = std.math.ceilPowerOfTwo(usize, capacity * 8) catch capacity * 8;
            const buckets = try allocator.alloc(Bucket, bucket_count);

            for (buckets) |*bucket| {
                bucket.* = Bucket.init();
            }

            return Self{
                .buckets = buckets,
                .bucket_count = bucket_count,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.buckets) |*bucket| {
                bucket.deinit(self.allocator);
            }
            self.allocator.free(self.buckets);
        }

        /// Compute hash for key
        fn hash(self: *const Self, key: K) u64 {
            _ = self;
            return std.hash.Wyhash.hash(0, std.mem.asBytes(&key));
        }

        /// Get bucket from hash value
        fn getBucket(self: *Self, hash_val: u64) *Bucket {
            const idx = hash_val % self.bucket_count;
            return &self.buckets[idx];
        }

        /// Lock-free put operation
        pub fn put(self: *Self, key: K, value: V) !void {
            const hash_val = self.hash(key);
            const bucket = self.getBucket(hash_val);
            try bucket.insert(self.allocator, key, value, hash_val);
        }

        /// Lock-free get operation (pure reads, no locks)
        pub fn get(self: *const Self, key: K) ?V {
            const hash_val = std.hash.Wyhash.hash(0, std.mem.asBytes(&key));
            const idx = hash_val % self.bucket_count;
            const bucket = &self.buckets[idx];
            return bucket.get(key, hash_val);
        }

        /// Lock-free remove operation
        pub fn remove(self: *Self, key: K) ?V {
            const hash_val = self.hash(key);
            const bucket = self.getBucket(hash_val);
            return bucket.remove(self.allocator, key, hash_val);
        }

        /// Get entry pointer (for direct manipulation)
        pub fn getEntry(self: *const Self, key: K) ?*Entry {
            const hash_val = std.hash.Wyhash.hash(0, std.mem.asBytes(&key));
            const idx = hash_val % self.bucket_count;
            const bucket = &self.buckets[idx];

            var node = bucket.head.load(.acquire);
            while (node) |n| {
                if (n.hash == hash_val and std.meta.eql(n.key, key)) {
                    return n;
                }
                node = n.next.load(.acquire);
            }
            return null;
        }
    };
}
