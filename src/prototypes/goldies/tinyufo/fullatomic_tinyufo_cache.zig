// Fully Lock-Free TinyUFO Cache
// Complete concurrent implementation matching Cloudflare's architecture
// NO LOCKS - Pure atomic operations

const std = @import("std");
const atomic_entry_mod = @import("atomic_entry.zig");
const atomic_cms_mod = @import("atomic_count_min_sketch.zig");
const lockfree_hashmap_mod = @import("lockfree_hashmap.zig");
const lockfree_segqueue_mod = @import("lockfree_segqueue.zig");

const AtomicEntry = atomic_entry_mod.AtomicEntry;
const QueueId = atomic_entry_mod.QueueId;
const AtomicCountMinSketch = atomic_cms_mod.AtomicCountMinSketch;
const LockFreeHashMap = lockfree_hashmap_mod.LockFreeHashMap;
const LockFreeSegQueue = lockfree_segqueue_mod.LockFreeSegQueue;

/// Cache statistics
pub const Stats = struct {
    hits: usize,
    misses: usize,
    hit_ratio: f64,
    size: usize,
};

/// Configuration for FullAtomic TinyUFO cache
pub const Config = struct {
    /// Total capacity (number of entries)
    capacity: usize,

    /// Window queue size ratio (0.0 - 1.0)
    /// Default: 0.30 (30%) - Optimal for balanced workloads
    /// Smaller values (1-10%) reduce hit rate, larger values (>30%) don't improve it
    window_ratio: f32 = 0.30,

    /// Main queue size ratio (0.0 - 1.0)
    /// Default: 0.50 (50%) - Optimal for most workloads
    main_ratio: f32 = 0.50,

    /// Protected queue size ratio (0.0 - 1.0)
    /// Default: 0.20 (20%) - Hot data protection
    protected_ratio: f32 = 0.20,

    /// Count-Min Sketch width (for frequency estimation)
    /// Default: 2048 - Good balance between accuracy and memory
    cm_sketch_width: usize = 2048,

    /// Count-Min Sketch depth (for frequency estimation)
    /// Default: 4 - Optimal for collision resistance
    cm_sketch_depth: usize = 4,

    /// Enable TinyLFU admission control (rejects cold items when cache is full)
    /// Default: true - Recommended for production
    /// true = Use frequency-based admission (higher hit rate)
    /// false = Accept all items without filtering (faster but lower hit rate)
    use_admission_control: bool = true,
};

pub const Error = error{
    OutOfMemory,
    CacheFull,
    KeyNotFound,
};

/// Fully lock-free TinyUFO cache
pub fn FullAtomicTinyUFO(comptime K: type, comptime V: type) type {
    return struct {
        const Self = @This();
        const EntryType = AtomicEntry(K, V);
        const HashMapType = LockFreeHashMap(K, *EntryType);
        const QueueType = LockFreeSegQueue(*EntryType);
        const SketchType = AtomicCountMinSketch(2048, 4);

        /// Lock-free hashmap for key-value lookups
        map: HashMapType,

        /// Lock-free queues for S3-FIFO
        window_queue: QueueType,
        main_queue: QueueType,
        protected_queue: QueueType,

        /// Entry Pool for lock-free entry recycling (reduces allocator pressure)
        entry_pool: QueueType,

        /// Atomic size counters (cache-line aligned to prevent false sharing)
        window_size: std.atomic.Value(usize) align(64),
        main_size: std.atomic.Value(usize) align(64),
        protected_size: std.atomic.Value(usize) align(64),

        /// Atomic total size
        total_size: std.atomic.Value(usize) align(64),

        /// Statistics counters (cache-line aligned)
        hits: std.atomic.Value(usize) align(64),
        misses: std.atomic.Value(usize) align(64),

        /// Count-Min Sketch for frequency estimation
        sketch: SketchType,

        /// Configuration
        window_capacity: usize,
        main_capacity: usize,
        protected_capacity: usize,
        total_capacity: usize,

        config: Config,
        allocator: std.mem.Allocator,

        /// Initialize cache
        pub fn init(allocator: std.mem.Allocator, config: Config) !Self {
            // Calculate queue capacities
            const window_capacity = @as(usize, @intFromFloat(@as(f32, @floatFromInt(config.capacity)) * config.window_ratio));
            const main_capacity = @as(usize, @intFromFloat(@as(f32, @floatFromInt(config.capacity)) * config.main_ratio));
            const protected_capacity = @as(usize, @intFromFloat(@as(f32, @floatFromInt(config.capacity)) * config.protected_ratio));

            // Initialize components
            const map = try HashMapType.init(allocator, config.capacity * 2);
            const window_queue = try QueueType.init(allocator);
            const main_queue = try QueueType.init(allocator);
            const protected_queue = try QueueType.init(allocator);
            const entry_pool = try QueueType.init(allocator);

            return Self{
                .map = map,
                .window_queue = window_queue,
                .main_queue = main_queue,
                .protected_queue = protected_queue,
                .entry_pool = entry_pool,
                .window_size = std.atomic.Value(usize).init(0),
                .main_size = std.atomic.Value(usize).init(0),
                .protected_size = std.atomic.Value(usize).init(0),
                .total_size = std.atomic.Value(usize).init(0),
                .hits = std.atomic.Value(usize).init(0),
                .misses = std.atomic.Value(usize).init(0),
                .sketch = SketchType.init(),
                .window_capacity = window_capacity,
                .main_capacity = main_capacity,
                .protected_capacity = protected_capacity,
                .total_capacity = config.capacity,
                .config = config,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            // Clean up entry pool (free all pooled entries)
            while (self.entry_pool.pop()) |entry| {
                entry.deinit(self.allocator);
            }
            self.entry_pool.deinit();

            // Clean up other components
            self.map.deinit();
            self.window_queue.deinit();
            self.main_queue.deinit();
            self.protected_queue.deinit();
        }

        /// Lock-free GET operation (pure atomic loads)
        pub fn get(self: *const Self, key: K) ?V {
            // Look up in hashmap (lock-free) - returns *EntryType
            const entry_ptr = self.map.get(key) orelse {
                _ = @constCast(&self.misses).fetchAdd(1, .monotonic);
                return null;
            };

            // Cache hit
            _ = @constCast(&self.hits).fetchAdd(1, .monotonic);

            // Increment entry frequency (for promotion logic)
            entry_ptr.incrementFrequency();

            // Note: Sketch updates removed to reduce contention (only updated on PUT)

            // Return value (atomic load)
            return entry_ptr.getValue();
        }

        /// Lock-free PUT operation
        pub fn put(self: *Self, key: K, value: V) !void {
            // Check if key exists
            if (self.map.get(key)) |existing| {
                // Update existing entry (lock-free atomic store)
                existing.setValue(value);
                existing.incrementFrequency();

                // Update sketch (for admission control)
                const key_hash = std.hash.Wyhash.hash(0, std.mem.asBytes(&key));
                self.sketch.increment(key_hash);
                return;
            }

            // Balanced capacity enforcement: Soft limit with aggressive admission control
            const key_hash = std.hash.Wyhash.hash(0, std.mem.asBytes(&key));
            const soft_limit = self.total_capacity + (self.total_capacity / 10); // 110%

            var reservation_attempts: usize = 0;
            while (reservation_attempts < 100) : (reservation_attempts += 1) {
                const current_size = self.total_size.load(.monotonic);

                // Hard limit: absolutely refuse if we're way over
                if (current_size >= soft_limit) {
                    return; // Silent rejection, no error
                }

                // At capacity: use simplified admission control
                if (current_size >= self.total_capacity and self.config.use_admission_control) {
                    const new_freq = self.sketch.estimate(key_hash);

                    // Aggressive admission threshold: Only admit items with freq > 1
                    if (new_freq <= 1) {
                        return; // Admission rejected - item too cold
                    }

                    // Passed admission control - try async eviction (best effort)
                    self.evict() catch {};
                }

                // Near capacity: trigger opportunistic eviction (best effort, non-blocking)
                if (current_size >= self.total_capacity) {
                    self.evict() catch {};
                }

                // Try to atomically reserve a slot with CAS
                const result = self.total_size.cmpxchgWeak(
                    current_size,
                    current_size + 1,
                    .monotonic,
                    .monotonic,
                );

                if (result == null) {
                    // CAS succeeded - we atomically reserved the slot, exit loop
                    break;
                }
                // CAS failed - another thread modified size, retry
            } else {
                // Too many retries, give up
                return;
            }

            // We now have an atomically reserved slot (total_size already incremented)
            // Create new entry
            // Try to acquire from pool first (lock-free, ~20-50 cycles)
            // If pool is empty, allocate new entry from allocator (~200-400 cycles)
            const entry = if (self.entry_pool.pop()) |pooled_entry| blk: {
                pooled_entry.reinit(key, value);
                break :blk pooled_entry;
            } else try EntryType.init(self.allocator, key, value);
            errdefer {
                entry.deinit(self.allocator);
                // Rollback the reserved slot on error
                _ = self.total_size.fetchSub(1, .monotonic);
            }

            // Insert into hashmap (lock-free)
            try self.map.put(key, entry);

            // Add to window queue (lock-free)
            entry.setQueue(.Window);
            try self.window_queue.push(entry);

            // Increment window size (total_size already incremented by CAS above)
            _ = self.window_size.fetchAdd(1, .monotonic);

            // Update sketch
            self.sketch.increment(key_hash);

            // Check if window queue exceeds capacity
            const window_sz = self.window_size.load(.acquire);
            if (window_sz > self.window_capacity) {
                try self.evictFromWindow();
            }
        }

        /// Evict from window queue (S3-FIFO logic)
        fn evictFromWindow(self: *Self) !void {
            var attempts: usize = 0;
            const max_attempts = 10;

            while (attempts < max_attempts) : (attempts += 1) {
                const entry = self.window_queue.pop() orelse return;

                const freq = entry.getFrequency();

                if (freq > 1) {
                    // Promote to main queue
                    entry.setQueue(.Main);
                    entry.setFrequency(0);
                    try self.main_queue.push(entry);

                    _ = self.window_size.fetchSub(1, .monotonic);
                    _ = self.main_size.fetchAdd(1, .monotonic);

                    // Check main queue capacity
                    const main_sz = self.main_size.load(.acquire);
                    if (main_sz > self.main_capacity) {
                        try self.evictFromMain();
                    }
                    return;
                } else {
                    // Evict entry
                    entry.setQueue(.None);
                    _ = self.map.remove(entry.getKey());
                    _ = self.window_size.fetchSub(1, .monotonic);
                    _ = self.total_size.fetchSub(1, .monotonic);

                    // Return entry to pool instead of freeing (lock-free recycling)
                    if (entry.release()) {
                        self.entry_pool.push(entry) catch {
                            // Pool is full, free entry instead
                            entry.deinit(self.allocator);
                        };
                    }
                    return;
                }
            }
        }

        /// Evict from main queue
        fn evictFromMain(self: *Self) !void {
            var attempts: usize = 0;
            const max_attempts = 10;

            while (attempts < max_attempts) : (attempts += 1) {
                const entry = self.main_queue.pop() orelse return;

                const freq = entry.getFrequency();

                if (freq > 1) {
                    // Promote to protected queue
                    entry.setQueue(.Protected);
                    entry.setFrequency(0);
                    try self.protected_queue.push(entry);

                    _ = self.main_size.fetchSub(1, .monotonic);
                    _ = self.protected_size.fetchAdd(1, .monotonic);

                    // Check protected queue capacity
                    const protected_sz = self.protected_size.load(.acquire);
                    if (protected_sz > self.protected_capacity) {
                        try self.evictFromProtected();
                    }
                    return;
                } else {
                    // Evict entry
                    entry.setQueue(.None);
                    _ = self.map.remove(entry.getKey());
                    _ = self.main_size.fetchSub(1, .monotonic);
                    _ = self.total_size.fetchSub(1, .monotonic);

                    // Return entry to pool instead of freeing
                    if (entry.release()) {
                        self.entry_pool.push(entry) catch {
                            entry.deinit(self.allocator);
                        };
                    }
                    return;
                }
            }
        }

        /// Evict from protected queue
        fn evictFromProtected(self: *Self) !void {
            var attempts: usize = 0;
            const max_attempts = 10;

            while (attempts < max_attempts) : (attempts += 1) {
                const entry = self.protected_queue.pop() orelse return;

                const freq = entry.getFrequency();

                if (freq > 0) {
                    // Demote to main queue
                    entry.setQueue(.Main);
                    entry.setFrequency(0);
                    try self.main_queue.push(entry);

                    _ = self.protected_size.fetchSub(1, .monotonic);
                    _ = self.main_size.fetchAdd(1, .monotonic);
                    return;
                } else {
                    // Evict entry
                    entry.setQueue(.None);
                    _ = self.map.remove(entry.getKey());
                    _ = self.protected_size.fetchSub(1, .monotonic);
                    _ = self.total_size.fetchSub(1, .monotonic);

                    // Return entry to pool instead of freeing
                    if (entry.release()) {
                        self.entry_pool.push(entry) catch {
                            entry.deinit(self.allocator);
                        };
                    }
                    return;
                }
            }
        }

        /// Generic evict (try all queues)
        fn evict(self: *Self) !void {
            // Try window first
            const window_sz = self.window_size.load(.acquire);
            if (window_sz > 0) {
                try self.evictFromWindow();
                return;
            }

            // Try main
            const main_sz = self.main_size.load(.acquire);
            if (main_sz > 0) {
                try self.evictFromMain();
                return;
            }

            // Try protected
            const protected_sz = self.protected_size.load(.acquire);
            if (protected_sz > 0) {
                try self.evictFromProtected();
                return;
            }

            return error.CacheFull;
        }

        /// Get cache size (atomic load)
        pub fn size(self: *const Self) usize {
            return self.total_size.load(.acquire);
        }

        /// Get cache length (alias for size)
        pub fn len(self: *const Self) usize {
            return self.size();
        }

        /// Get cache capacity
        pub fn capacity(self: *const Self) usize {
            return self.total_capacity;
        }

        /// Check if cache contains key (lock-free)
        pub fn contains(self: *const Self, key: K) bool {
            return self.map.get(key) != null;
        }

        /// Remove entry (lock-free)
        pub fn remove(self: *Self, key: K) ?V {
            const entry = self.map.get(key) orelse return null;
            const value = entry.getValue();

            // Remove from map
            _ = self.map.remove(key);

            // Update sizes based on queue
            const queue = entry.getQueue();
            switch (queue) {
                .Window => _ = self.window_size.fetchSub(1, .monotonic),
                .Main => _ = self.main_size.fetchSub(1, .monotonic),
                .Protected => _ = self.protected_size.fetchSub(1, .monotonic),
                .None => {},
            }

            _ = self.total_size.fetchSub(1, .monotonic);

            // Return entry to pool instead of freeing
            if (entry.release()) {
                self.entry_pool.push(entry) catch {
                    entry.deinit(self.allocator);
                };
            }

            return value;
        }

        /// Get cache statistics
        pub fn getStats(self: *const Self) Stats {
            const hit_count = self.hits.load(.acquire);
            const miss_count = self.misses.load(.acquire);
            const total_accesses = hit_count + miss_count;

            const hit_ratio = if (total_accesses > 0)
                @as(f64, @floatFromInt(hit_count)) / @as(f64, @floatFromInt(total_accesses))
            else
                0.0;

            return Stats{
                .hits = hit_count,
                .misses = miss_count,
                .hit_ratio = hit_ratio,
                .size = self.total_size.load(.acquire),
            };
        }

        /// Batch put operation
        pub fn putBatch(self: *Self, keys: []const K, values: []const V) !void {
            if (keys.len != values.len) return error.MismatchedLengths;
            for (keys, values) |key, value| {
                try self.put(key, value);
            }
        }

        /// Batch get operation
        pub fn getBatch(self: *const Self, keys: []const K, results: []?V) void {
            for (keys, 0..) |key, i| {
                results[i] = self.get(key);
            }
        }

        /// Clear all entries
        pub fn clear(self: *Self) void {
            // Drain all queues
            while (self.window_queue.pop()) |entry| {
                if (entry.release()) {
                    entry.deinit(self.allocator);
                }
            }

            while (self.main_queue.pop()) |entry| {
                if (entry.release()) {
                    entry.deinit(self.allocator);
                }
            }

            while (self.protected_queue.pop()) |entry| {
                if (entry.release()) {
                    entry.deinit(self.allocator);
                }
            }

            // Reset sizes
            self.window_size.store(0, .release);
            self.main_size.store(0, .release);
            self.protected_size.store(0, .release);
            self.total_size.store(0, .release);

            // Reset statistics
            self.hits.store(0, .release);
            self.misses.store(0, .release);

            // Reset sketch
            self.sketch.reset();
        }
    };
}

/// Convenience type with default config
pub fn Auto(comptime K: type, comptime V: type) type {
    return FullAtomicTinyUFO(K, V);
}
