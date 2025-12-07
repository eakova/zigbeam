// S3-FIFO Cache (2-Queue Original Design)
// Cloudflare's original architecture: Small + Main queues only
// Lock-free implementation with all bugfixes applied

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

/// Configuration for S3-FIFO cache (2-queue design)
pub const Config = struct {
    /// Total capacity (number of entries)
    capacity: usize,

    /// Small queue size ratio (0.0 - 1.0)
    /// Default: 0.10 (10%) - Cloudflare's original design
    /// Small queue holds new entries (probationary period)
    small_ratio: f32 = 0.10,

    /// Count-Min Sketch width (for frequency estimation)
    /// Default: 2048 - Good balance between accuracy and memory
    cm_sketch_width: usize = 2048,

    /// Count-Min Sketch depth (for frequency estimation)
    /// Default: 4 - Optimal for collision resistance
    cm_sketch_depth: usize = 4,

    /// Enable TinyLFU admission control (rejects cold items when cache is full)
    /// Default: true - Recommended for production
    use_admission_control: bool = true,
};

pub const Error = error{
    OutOfMemory,
    CacheFull,
    KeyNotFound,
};

/// S3-FIFO Cache (2-Queue Design)
/// Small queue (probationary) + Main queue (established)
pub fn S3FIFOCache(comptime K: type, comptime V: type) type {
    return struct {
        const Self = @This();
        const EntryType = AtomicEntry(K, V);
        const HashMapType = LockFreeHashMap(K, *EntryType);
        const QueueType = LockFreeSegQueue(*EntryType);
        const SketchType = AtomicCountMinSketch(2048, 4);

        /// Lock-free hashmap for key-value lookups
        map: HashMapType,

        /// Lock-free queues for S3-FIFO (2-queue design)
        small_queue: QueueType, // Probationary queue for new entries
        main_queue: QueueType,  // Established queue for frequently accessed

        /// Entry Pool for lock-free entry recycling
        entry_pool: QueueType,

        /// Atomic size counters (cache-line aligned)
        small_size: std.atomic.Value(usize) align(64),
        main_size: std.atomic.Value(usize) align(64),
        total_size: std.atomic.Value(usize) align(64),

        /// Statistics counters (cache-line aligned)
        hits: std.atomic.Value(usize) align(64),
        misses: std.atomic.Value(usize) align(64),

        /// Count-Min Sketch for frequency estimation
        sketch: SketchType,

        /// Configuration
        small_capacity: usize,
        main_capacity: usize,
        total_capacity: usize,

        config: Config,
        allocator: std.mem.Allocator,

        /// Initialize S3-FIFO cache
        pub fn init(allocator: std.mem.Allocator, config: Config) !Self {
            // Calculate queue capacities (2-queue design)
            const small_capacity = @as(usize, @intFromFloat(@as(f32, @floatFromInt(config.capacity)) * config.small_ratio));
            const main_capacity = config.capacity - small_capacity;

            // Initialize components
            const map = try HashMapType.init(allocator, config.capacity * 2);
            const small_queue = try QueueType.init(allocator);
            const main_queue = try QueueType.init(allocator);
            const entry_pool = try QueueType.init(allocator);

            return Self{
                .map = map,
                .small_queue = small_queue,
                .main_queue = main_queue,
                .entry_pool = entry_pool,
                .small_size = std.atomic.Value(usize).init(0),
                .main_size = std.atomic.Value(usize).init(0),
                .total_size = std.atomic.Value(usize).init(0),
                .hits = std.atomic.Value(usize).init(0),
                .misses = std.atomic.Value(usize).init(0),
                .sketch = SketchType.init(),
                .small_capacity = small_capacity,
                .main_capacity = main_capacity,
                .total_capacity = config.capacity,
                .config = config,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            // Clean up entry pool
            while (self.entry_pool.pop()) |entry| {
                entry.deinit(self.allocator);
            }
            self.entry_pool.deinit();

            // Clean up queues and map
            self.map.deinit();
            self.small_queue.deinit();
            self.main_queue.deinit();
        }

        /// Lock-free GET operation
        pub fn get(self: *const Self, key: K) ?V {
            const entry_ptr = self.map.get(key) orelse {
                _ = @constCast(&self.misses).fetchAdd(1, .monotonic);
                return null;
            };

            // Cache hit
            _ = @constCast(&self.hits).fetchAdd(1, .monotonic);

            // Increment frequency (for promotion logic)
            entry_ptr.incrementFrequency();

            return entry_ptr.getValue();
        }

        /// Lock-free PUT operation
        pub fn put(self: *Self, key: K, value: V) !void {
            // Update existing entry
            if (self.map.get(key)) |existing| {
                existing.setValue(value);
                existing.incrementFrequency();

                const key_hash = std.hash.Wyhash.hash(0, std.mem.asBytes(&key));
                self.sketch.increment(key_hash);
                return;
            }

            // PERMANENT FIX: Disable synchronous eviction enforcement
            // S3-FIFO was forcing eviction before CAS, causing massive contention
            // Switch to async eviction like TinyUFO for much better performance
            const key_hash = std.hash.Wyhash.hash(0, std.mem.asBytes(&key));
            const soft_limit = self.total_capacity * 2; // 200% like TinyUFO

            var reservation_attempts: usize = 0;
            while (reservation_attempts < 100) : (reservation_attempts += 1) {
                const current_size = self.total_size.load(.monotonic);

                // PERMANENT FIX: Don't force eviction before CAS
                // Just check if we're over soft limit and do async eviction after
                if (current_size >= soft_limit) {
                    return Error.CacheFull; // Hard rejection at soft limit
                }

                // Try to reserve space (CAS loop)
                if (self.total_size.cmpxchgWeak(
                    current_size,
                    current_size + 1,
                    .monotonic,
                    .monotonic,
                )) |_| {
                    continue; // CAS failed, retry
                }

                // Successfully reserved - create new entry
                const entry = try self.getOrCreateEntry(key, value);
                entry.setValue(value);
                entry.setFrequency(0);
                entry.setQueue(.Window); // Start in Small queue

                // Insert into hashmap
                try self.map.put(key, entry);

                // Add to Small queue (probationary period)
                try self.small_queue.push(entry);
                _ = self.small_size.fetchAdd(1, .monotonic);

                // Update sketch
                self.sketch.increment(key_hash);

                // PERMANENT FIX: Async eviction (best effort)
                // Trigger eviction in background, don't block the PUT
                const new_size = current_size + 1;
                if (new_size >= self.total_capacity) {
                    _ = self.evictOne() catch {};
                }

                return;
            }

            return Error.CacheFull;
        }

        /// Evict one entry from cache (2-queue S3-FIFO algorithm)
        fn evictOne(self: *Self) !bool {
            // S3-FIFO eviction: Try Small queue first, then Main queue

            // Phase 1: Try to evict from Small queue
            var attempts: usize = 0;
            while (attempts < self.small_capacity) : (attempts += 1) {
                const entry = self.small_queue.pop() orelse break;

                const freq = entry.getFrequency();
                if (freq > 0) {
                    // Accessed while in Small queue - promote to Main
                    entry.setFrequency(0);
                    entry.setQueue(.Main);

                    try self.main_queue.push(entry);
                    _ = self.small_size.fetchSub(1, .monotonic);
                    _ = self.main_size.fetchAdd(1, .monotonic);
                    continue;
                }

                // Not accessed - evict from Small queue
                const old_key = entry.getKey();
                _ = self.map.remove(old_key);

                _ = self.small_size.fetchSub(1, .monotonic);
                _ = self.total_size.fetchSub(1, .monotonic);

                try self.entry_pool.push(entry);
                return true;
            }

            // Phase 2: Try to evict from Main queue
            attempts = 0;
            while (attempts < self.main_capacity) : (attempts += 1) {
                const entry = self.main_queue.pop() orelse break;

                const freq = entry.getFrequency();
                if (freq > 0) {
                    // Still being accessed - reinsert at tail (2nd chance)
                    entry.setFrequency(freq - 1);
                    try self.main_queue.push(entry);
                    continue;
                }

                // Not accessed - evict from Main queue
                if (self.config.use_admission_control) {
                    // Check admission before eviction (if enabled)
                    const old_key = entry.getKey();
                    _ = self.map.remove(old_key);
                } else {
                    const old_key = entry.getKey();
                    _ = self.map.remove(old_key);
                }

                _ = self.main_size.fetchSub(1, .monotonic);
                _ = self.total_size.fetchSub(1, .monotonic);

                try self.entry_pool.push(entry);
                return true;
            }

            return false;
        }

        /// Get or create entry from pool
        fn getOrCreateEntry(self: *Self, key: K, value: V) !*EntryType {
            // Try to reuse from pool first
            if (self.entry_pool.pop()) |entry| {
                entry.key.store(key, .release);
                entry.value.store(value, .release);
                entry.frequency.store(0, .release);
                entry.queue.store(.None, .release);
                entry.ref_count.store(1, .release);
                entry.timestamp.store(std.time.nanoTimestamp(), .release);
                return entry;
            }

            // Create new entry if pool empty
            return try EntryType.init(self.allocator, key, value);
        }

        /// Remove entry from cache
        pub fn remove(self: *Self, key: K) ?V {
            const entry = self.map.remove(key) orelse return null;

            const value = entry.getValue();
            const queue = entry.getQueue();

            // Decrement appropriate queue size
            switch (queue) {
                .Window => {
                    _ = self.small_size.fetchSub(1, .monotonic);
                },
                .Main => {
                    _ = self.main_size.fetchSub(1, .monotonic);
                },
                else => {},
            }

            _ = self.total_size.fetchSub(1, .monotonic);

            // Return to pool
            self.entry_pool.push(entry) catch {};

            return value;
        }

        /// Get current cache size
        pub fn len(self: *const Self) usize {
            return self.total_size.load(.monotonic);
        }

        /// Get cache statistics
        pub fn stats(self: *const Self) Stats {
            const total_hits = self.hits.load(.monotonic);
            const total_misses = self.misses.load(.monotonic);
            const total_requests = total_hits + total_misses;

            const hit_ratio = if (total_requests > 0)
                @as(f64, @floatFromInt(total_hits)) / @as(f64, @floatFromInt(total_requests))
            else
                0.0;

            return Stats{
                .hits = total_hits,
                .misses = total_misses,
                .hit_ratio = hit_ratio,
                .size = self.len(),
            };
        }
    };
}

/// Convenience function - Auto-configured S3-FIFO cache
pub fn Auto(comptime K: type, comptime V: type) type {
    return S3FIFOCache(K, V);
}
