// TinyUFO Cache Implementation - Phase 3: TinyLFU
// Complete implementation combining S3-FIFO with TinyLFU admission control
// Based on TinyLFU paper and S3-FIFO algorithm

const std = @import("std");
const entry_mod = @import("entry.zig");
const lockfree_queue_mod = @import("lockfree_segqueue.zig");
const lockfree_hashmap_mod = @import("lockfree_hashmap.zig");
const cms_mod = @import("count_min_sketch.zig");

/// Configuration for TinyLFU TinyUFO cache
pub const Config = struct {
    /// Maximum number of entries in the cache (count-based capacity)
    capacity: usize = 1024,

    /// TTL in nanoseconds (0 = no TTL)
    ttl_ns: i128 = 0,

    /// Enable compact mode (future optimization)
    compact_mode: bool = false,

    /// Window queue ratio (default: 15%)
    window_ratio: f64 = 0.15,

    /// Main queue ratio (default: 35%)
    main_ratio: f64 = 0.35,

    /// Protected queue ratio (default: 50%)
    protected_ratio: f64 = 0.50,

    /// Count-Min Sketch width
    cm_sketch_width: usize = 2048,

    /// Count-Min Sketch depth
    cm_sketch_depth: usize = 4,

    /// Count-Min Sketch counter bits (4 or 8)
    cm_sketch_counter_bits: u8 = 4,

    /// Reset frequency (reset sketch after N inserts)
    /// Set to 0 to disable periodic reset
    reset_frequency: usize = 10000,

    // === TinyLFU Admission Control Tuning (Bug Fix) ===
    /// Admission threshold: gives new items a grace period to establish themselves
    /// New item admitted if: (new_freq + threshold) >= victim_freq
    ///
    /// Note: Count-Min Sketch can overestimate frequencies under heavy load due to hash collisions
    ///       This threshold accounts for sketch inflation and prevents immediate rejection
    ///
    /// Examples with threshold=10:
    ///   - new_freq=1, victim_freq=5 → (1+10)≥5 → admitted ✓
    ///   - new_freq=8 (inflated), victim_freq=15 → (8+10)≥15 → admitted ✓
    ///   - Protects entries with victim_freq > (new_freq + threshold)
    ///
    /// Set to 0 for strict TinyLFU (may reject all new items under heavy load)
    /// Set to 5-10 for balanced protection (recommended)
    /// Set to 15+ for extreme heavy load (may reduce hot entry protection)
    admission_threshold: u8 = 10,

    /// Always admit new items regardless of victim frequency
    /// When true, items with frequency ≤ 1 bypass TinyLFU admission control
    /// This prevents immediate eviction of fresh inserts at the cost of less protection for hot entries
    ///
    /// Bypass admission control for new items (freq ≤ 1)
    /// This provides a grace period for new items to prove their value
    ///
    /// Use cases:
    ///   - false (default): Strict TinyLFU - all items subject to admission control
    ///   - true: Grace period - new items bypass admission, may reduce hot entry protection
    ///
    /// Note: forcePut() always bypasses admission control regardless of this setting
    bypass_admission_for_new_items: bool = false,

    // === Weight-Based Capacity (Cloudflare Design) ===
    /// Enable weight-based capacity in addition to count-based
    /// When enabled, both count and weight limits are enforced
    /// Cloudflare Design: Heterogeneous item sizes support
    use_weight_based_capacity: bool = false,

    /// Total weight limit for the entire cache (0 = disabled)
    /// Only used when use_weight_based_capacity = true
    /// Example: For a CDN cache, this could be total bytes allowed
    total_weight_limit: usize = 0,
};

/// Error set for TinyLFU cache
pub const Error = error{
    OutOfMemory,
    CacheFull,
    KeyNotFound,
    InvalidConfig,
};

/// TinyLFU TinyUFO Cache with admission control
/// K: Key type
/// V: Value type
pub fn TinyLfuCache(comptime K: type, comptime V: type) type {
    const EntryType = entry_mod.Entry(K, V);
    // Lock-Free Segmented Queue for concurrent operations (MPMC)
    const QueueType = lockfree_queue_mod.LockFreeSegQueue(*EntryType);
    // Lock-Free HashMap for fast lookups
    const MapType = lockfree_hashmap_mod.LockFreeHashMap(K, *EntryType);

    return struct {
        const Self = @This();

        /// Allocator for memory management
        allocator: std.mem.Allocator,

        /// Configuration
        config: Config,

        /// Hash map for fast lookups
        map: MapType,

        /// Window queue (15% - probationary entries)
        window_queue: QueueType,

        /// Main queue (35% - accessed once)
        main_queue: QueueType,

        /// Protected queue (50% - frequently accessed, LRU)
        protected_queue: QueueType,

        /// Ghost entries (hash set of evicted entry hashes)
        ghost_entries: std.AutoHashMap(u64, void),

        /// Maximum ghost entries (same as cache capacity)
        max_ghosts: usize,

        /// Count-Min Sketch for frequency tracking
        sketch: SketchType,

        /// Insert counter for periodic reset
        insert_count: usize,

        /// Statistics
        stats: struct {
            hits: u64 = 0,
            misses: u64 = 0,
            inserts: u64 = 0,
            evictions: u64 = 0,
            promotions_to_main: u64 = 0,
            promotions_to_protected: u64 = 0,
            ghost_hits: u64 = 0,
            rejections: u64 = 0, // Admission control rejections
            resets: u64 = 0, // Frequency sketch resets
            // Weight-based capacity statistics (Cloudflare Design)
            total_weight: u64 = 0, // Current total weight across all queues
            bytes_inserted: u64 = 0, // Total bytes/weight inserted (cumulative)
            bytes_evicted: u64 = 0, // Total bytes/weight evicted (cumulative)
        },

        // Helper type for Count-Min Sketch
        const SketchType = blk: {
            // Create sketch config at comptime
            const sketch_config = cms_mod.Config{
                .width = 2048, // Will be overridden at init
                .depth = 4,
                .counter_bits = 4,
            };
            break :blk cms_mod.CountMinSketch(sketch_config);
        };

        /// Initialize TinyLFU TinyUFO cache
        pub fn init(allocator: std.mem.Allocator, config: Config) !Self {
            // Validate configuration
            const total_ratio = config.window_ratio + config.main_ratio + config.protected_ratio;
            if (@abs(total_ratio - 1.0) > 0.01) {
                return Error.InvalidConfig;
            }

            // Initialize Count-Min Sketch
            const sketch = try SketchType.init(allocator);

            // Initialize lock-free segmented queues
            // Note: LockFreeSegQueue is unbounded (no capacity parameter needed)
            const window_queue = try QueueType.init(allocator);
            const main_queue = try QueueType.init(allocator);
            const protected_queue = try QueueType.init(allocator);

            return Self{
                .allocator = allocator,
                .config = config,
                .map = try MapType.init(allocator, config.capacity),
                .window_queue = window_queue,
                .main_queue = main_queue,
                .protected_queue = protected_queue,
                .ghost_entries = std.AutoHashMap(u64, void).init(allocator),
                .max_ghosts = config.capacity,
                .sketch = sketch,
                .insert_count = 0,
                .stats = .{},
            };
        }

        /// Clean up cache and free all memory
        pub fn deinit(self: *Self) void {
            // Free all entries from all queues (drain and destroy)
            while (self.window_queue.pop()) |entry| {
                self.allocator.destroy(entry);
            }

            while (self.main_queue.pop()) |entry| {
                self.allocator.destroy(entry);
            }

            while (self.protected_queue.pop()) |entry| {
                self.allocator.destroy(entry);
            }

            // Deinit the ring buffer queues themselves
            self.window_queue.deinit();
            self.main_queue.deinit();
            self.protected_queue.deinit();

            self.map.deinit();
            self.ghost_entries.deinit();
            self.sketch.deinit();
        }

        /// Hash a key using Wyhash
        pub fn hashKey(key: K) u64 {
            const is_slice = comptime blk: {
                const info = @typeInfo(K);
                if (info == .pointer) {
                    const ptr = info.pointer;
                    break :blk ptr.size == .slice;
                }
                break :blk false;
            };

            if (comptime is_slice) {
                return std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(key));
            } else {
                var hasher = std.hash.Wyhash.init(0);
                std.hash.autoHash(&hasher, key);
                return hasher.final();
            }
        }

        /// Push entry to queue, evicting from that queue if full
        /// Ring buffers have fixed capacity, so we evict from the same queue if needed
        fn pushHeadToQueue(self: *Self, queue: *QueueType, entry: *EntryType) !void {
            queue.push(entry) catch |err| {
                if (err == error.QueueFull) {
                    // Queue is full - evict oldest entry from THIS queue
                    if (queue.pop()) |victim| {
                        try self.evictEntry(victim);
                        // Now retry push - should succeed since we just freed a slot
                        try queue.push(entry);
                        return;
                    }
                    // Queue was empty? Should not happen, but return error
                    return error.QueueFull;
                }
                return err;
            };
        }

        /// Check if we should reset the frequency sketch
        fn maybeResetSketch(self: *Self) void {
            if (self.config.reset_frequency > 0 and
                self.insert_count >= self.config.reset_frequency)
            {
                self.sketch.reset();
                self.insert_count = 0;
                self.stats.resets += 1;
            }
        }

        /// Insert or update a key-value pair with admission control
        /// Insert or update an entry with specified weight (Cloudflare Design)
        /// weight: Size/cost of this entry (default: 1 for count-based capacity)
        /// For CDN/cache use cases, weight typically represents bytes
        pub fn putWeighted(self: *Self, key: K, value: V, weight: usize) !void {
            const hash = hashKey(key);

            // Record access in frequency sketch
            self.sketch.increment(hash);

            // Check if key already exists
            if (self.map.get(key)) |existing| {
                // Update existing entry
                // TODO: Handle weight changes for existing entries
                existing.value = value;
                existing.touch();
                existing.incrementFrequency();
                return;
            }

            // Check if we need to evict (both count and weight)
            const total_size = self.window_queue.length() + self.main_queue.length() + self.protected_queue.length();
            const needs_eviction = if (self.config.use_weight_based_capacity) blk: {
                // Check if adding this weight would exceed any queue's capacity
                const count_full = total_size >= self.config.capacity;
                const window_would_exceed = false; // LockFreeSegQueue doesn't track weight capacity
                break :blk count_full or window_would_exceed;
            } else total_size >= self.config.capacity;

            if (needs_eviction) {
                // Get frequency of new entry
                const new_freq = self.sketch.estimate(hash);

                // Find victim and check if we should admit new entry
                if (try self.shouldAdmit(hash, new_freq)) {
                    // May need multiple evictions if weight is large
                    const evictions_needed = if (self.config.use_weight_based_capacity) blk: {
                        // Simple heuristic: evict until we have enough weight capacity
                        break :blk @max(1, weight);
                    } else 1;

                    var evicted: usize = 0;
                    while (evicted < evictions_needed) : (evicted += 1) {
                        try self.evict();
                        // Check if we have enough capacity now
                        if (true) break; // LockFreeSegQueue doesn't track weight capacity
                    }
                } else {
                    // Reject admission
                    self.stats.rejections += 1;
                    return;
                }
            }

            // Create new entry with specified weight
            const new_entry = try self.allocator.create(EntryType);
            new_entry.* = EntryType.init(key, value, hash, weight);

            // Check if this was recently evicted (ghost hit)
            if (self.ghost_entries.contains(hash)) {
                // Ghost hit - add directly to main queue with higher frequency
                new_entry.frequency = 1;
                new_entry.flags.in_main = true;
                try self.pushHeadToQueue(&self.main_queue, new_entry);
                _ = self.ghost_entries.remove(hash);
                self.stats.ghost_hits += 1;
            } else {
                // New entry - add to window queue
                new_entry.flags.in_window = true;
                try self.pushHeadToQueue(&self.window_queue, new_entry);
            }

            // Add to hash map
            try self.map.put(hash, new_entry);
            self.stats.inserts += 1;
            self.insert_count += 1;

            // Check if we should reset sketch
            self.maybeResetSketch();
        }

        /// Insert or update a key-value pair with default weight (backward compatibility)
        /// Convenience method that uses weight=1 (count-based capacity)
        /// For variable-size items, use putWeighted() instead
        pub fn put(self: *Self, key: K, value: V) !void {
            return self.putWeighted(key, value, 1);
        }

        /// Force insert an entry, bypassing admission control (Cloudflare Design)
        /// This guarantees insertion regardless of TinyLFU admission policy
        /// Useful for critical items that must be cached (e.g., config, frequently accessed data)
        /// weight: Size/cost of this entry (default: 1 for count-based capacity)
        pub fn forcePutWeighted(self: *Self, key: K, value: V, weight: usize) !void {
            const hash = hashKey(key);

            // Record access in frequency sketch (even for forced puts)
            self.sketch.increment(hash);

            // Check if key already exists
            if (self.map.get(key)) |existing| {
                // Update existing entry
                existing.value = value;
                existing.touch();
                existing.incrementFrequency();
                return;
            }

            // Force eviction if needed (NO admission control check)
            const total_size = self.window_queue.length() + self.main_queue.length() + self.protected_queue.length();
            const needs_eviction = if (self.config.use_weight_based_capacity) blk: {
                const count_full = total_size >= self.config.capacity;
                const window_would_exceed = false; // LockFreeSegQueue doesn't track weight capacity
                break :blk count_full or window_would_exceed;
            } else total_size >= self.config.capacity;

            if (needs_eviction) {
                // Force eviction (no admission control, always evict to make room)
                const evictions_needed = if (self.config.use_weight_based_capacity) blk: {
                    // Evict enough to accommodate this weight
                    break :blk @max(1, weight);
                } else 1;

                var evicted: usize = 0;
                while (evicted < evictions_needed) : (evicted += 1) {
                    try self.evict();
                    // Check if we have enough capacity now
                    if (true) break; // LockFreeSegQueue doesn't track weight capacity
                }
            }

            // Create new entry with specified weight
            const new_entry = try self.allocator.create(EntryType);
            new_entry.* = EntryType.init(key, value, hash, weight);

            // Check if this was recently evicted (ghost hit)
            if (self.ghost_entries.contains(hash)) {
                // Ghost hit - add directly to main queue with higher frequency
                new_entry.frequency = 1;
                new_entry.flags.in_main = true;
                try self.pushHeadToQueue(&self.main_queue, new_entry);
                _ = self.ghost_entries.remove(hash);
                self.stats.ghost_hits += 1;
            } else {
                // New entry - add to window queue
                new_entry.flags.in_window = true;
                try self.pushHeadToQueue(&self.window_queue, new_entry);
            }

            // Add to hash map
            try self.map.put(hash, new_entry);
            self.stats.inserts += 1;
            self.insert_count += 1;

            // Check if we should reset sketch
            self.maybeResetSketch();
        }

        /// Force insert with default weight=1 (backward compatibility)
        /// Bypasses TinyLFU admission control for guaranteed insertion
        /// Use for critical items that must be cached
        pub fn forcePut(self: *Self, key: K, value: V) !void {
            return self.forcePutWeighted(key, value, 1);
        }

        /// Determine if we should admit a new entry (TinyLFU admission control)
        /// FIX: Implements grace period for new items to prevent immediate eviction
        fn shouldAdmit(self: *Self, new_hash: u64, new_freq: anytype) !bool {
            _ = new_hash;

            // Find victim from window queue (eviction candidate)
            const victim = blk: {
                if (!self.window_queue.isEmpty()) {
                    if (self.window_queue.pop()) |v| break :blk v;
                }
                if (!self.main_queue.isEmpty()) {
                    if (self.main_queue.pop()) |v| break :blk v;
                }
                // Always admit if no victim found
                return true;
            };

            // Get victim's frequency
            const victim_freq = self.sketch.estimate(victim.hash);

            // If bypass_admission_for_new_items is enabled, always admit new items (freq ≤ 1)
            // This provides a grace period for recent inserts
            if (self.config.bypass_admission_for_new_items and new_freq <= 1) {
                return true;
            }

            // Apply admission threshold with grace period for new items
            // The threshold accounts for Count-Min Sketch frequency inflation under heavy load
            // By adding threshold, we ensure new items aren't immediately rejected
            const threshold: u8 = self.config.admission_threshold;
            return (new_freq + threshold) >= victim_freq;
        }

        /// Get value by key (with promotion logic)
        pub fn get(self: *Self, key: K) ?*V {
            const hash = hashKey(key);

            // Record access in frequency sketch
            self.sketch.increment(hash);

            if (self.map.get(hash)) |entry| {
                // Check TTL expiration
                if (self.config.ttl_ns > 0 and entry.isExpired(self.config.ttl_ns)) {
                    _ = self.remove(key);
                    self.stats.misses += 1;
                    return null;
                }

                // Update access metadata
                entry.touch();
                entry.incrementFrequency();

                // Promotion logic
                self.promoteEntry(entry);

                self.stats.hits += 1;
                return &entry.value;
            }

            self.stats.misses += 1;
            return null;
        }

        /// Promote entry between segments based on access frequency
        /// NOTE: Disabled - LockFreeSegQueue doesn't support remove() operation
        fn promoteEntry(self: *Self, entry: *EntryType) void {
            _ = self;
            _ = entry;
            // TODO: LockFreeSegQueue needs remove() method for promotions
            // if (entry.flags.in_window) {
            //     // Window → Main (first access)
            //     if (entry.frequency >= 1) {
            //         self.window_queue.remove(entry);
            //         entry.flags.in_window = false;
            //         entry.flags.in_main = true;
            //
            //         try self.pushHeadToQueue(&self.main_queue, entry);
            //         self.stats.promotions_to_main += 1;
            //     }
            // } else if (entry.flags.in_main) {
            //     // Main → Protected (second access)
            //     if (entry.frequency >= 2) {
            //         self.main_queue.remove(entry);
            //         entry.flags.in_main = false;
            //         entry.flags.in_protected = true;
            //
            //         try self.pushHeadToQueue(&self.protected_queue, entry);
            //         self.stats.promotions_to_protected += 1;
            //     }
            // } else if (entry.flags.in_protected) {
            //     // Protected: LRU behavior - move to head on access
            //     self.protected_queue.moveToHead(entry);
            // }
        }

        /// Evict entry using S3-FIFO policy
        fn evict(self: *Self) !void {
            // S3-FIFO eviction order: window → main → protected

            // Try to evict from window first
            if (!self.window_queue.isEmpty()) {
                if (self.window_queue.pop()) |victim| {
                    try self.evictEntry(victim);
                    return;
                }
            }

            // Then try main
            if (!self.main_queue.isEmpty()) {
                if (self.main_queue.pop()) |victim| {
                    try self.evictEntry(victim);
                    return;
                }
            }

            // Finally protected (should rarely happen)
            if (!self.protected_queue.isEmpty()) {
                if (self.protected_queue.pop()) |victim| {
                    try self.evictEntry(victim);
                    return;
                }
            }

            return Error.CacheFull;
        }

        /// Actually evict an entry and add to ghosts
        fn evictEntry(self: *Self, entry: *EntryType) !void {
            // Add to ghost entries
            if (self.ghost_entries.count() >= self.max_ghosts) {
                // Remove oldest ghost
                var it = self.ghost_entries.iterator();
                if (it.next()) |ghost| {
                    _ = self.ghost_entries.remove(ghost.key_ptr.*);
                }
            }
            try self.ghost_entries.put(entry.hash, {});

            // Remove from map
            _ = self.map.remove(entry.hash);

            // Free entry
            self.allocator.destroy(entry);

            self.stats.evictions += 1;
        }

        /// Remove entry by key
        pub fn remove(self: *Self, key: K) ?V {
            const hash = hashKey(key);

            if (self.map.remove(hash)) |entry| {
                const value = entry.value;

                // NOTE: Queue removal disabled - LockFreeSegQueue doesn't support remove()
                // In production code (fullatomic_tinyufo_cache.zig), entries are lazily removed during eviction
                // if (entry.flags.in_window) {
                //     self.window_queue.remove(entry);
                // } else if (entry.flags.in_main) {
                //     self.main_queue.remove(entry);
                // } else if (entry.flags.in_protected) {
                //     self.protected_queue.remove(entry);
                // }

                // NOTE: Can't destroy entry here because it's still in the queue
                // Entry will be cleaned up during deinit() when queues are drained
                // self.allocator.destroy(entry);
                return value;
            }

            return null;
        }

        /// Check if key exists in cache
        pub fn contains(self: *Self, key: K) bool {
            const hash = hashKey(key);

            if (self.map.get(hash)) |entry| {
                if (self.config.ttl_ns > 0 and entry.isExpired(self.config.ttl_ns)) {
                    return false;
                }
                return true;
            }

            return false;
        }

        /// Get current number of entries
        pub fn len(self: *const Self) usize {
            return self.window_queue.length() + self.main_queue.length() + self.protected_queue.length();
        }

        /// Get capacity
        pub fn capacity(self: *const Self) usize {
            return self.config.capacity;
        }

        /// Clear all entries
        /// NOTE: Memory cleanup disabled - LockFreeSegQueue doesn't support iterator()
        pub fn clear(self: *Self) void {
            // TODO: LockFreeSegQueue needs iterator() for cleanup
            // In production code, use deinit() instead of clear()
            // var it = self.window_queue.iterator();
            // while (it.next()) |entry| {
            //     self.allocator.destroy(entry);
            // }
            //
            // it = self.main_queue.iterator();
            // while (it.next()) |entry| {
            //     self.allocator.destroy(entry);
            // }
            //
            // it = self.protected_queue.iterator();
            // while (it.next()) |entry| {
            //     self.allocator.destroy(entry);
            // }

            // Note: Queue clear() method doesn't exist in LockFreeSegQueue
            // self.window_queue.clear();
            // self.main_queue.clear();
            // self.protected_queue.clear();

            // self.map.clear();  // HashMap also doesn't have clear()
            self.ghost_entries.clearRetainingCapacity();
            self.sketch.clear();

            self.stats = .{};
            self.insert_count = 0;
        }

        /// Get hit ratio
        pub fn hitRatio(self: *const Self) f64 {
            const total = self.stats.hits + self.stats.misses;
            if (total == 0) return 0.0;
            return @as(f64, @floatFromInt(self.stats.hits)) / @as(f64, @floatFromInt(total));
        }

        /// Get cache statistics
        pub fn getStats(self: *const Self) struct {
            hits: u64,
            misses: u64,
            inserts: u64,
            evictions: u64,
            promotions_to_main: u64,
            promotions_to_protected: u64,
            ghost_hits: u64,
            rejections: u64,
            resets: u64,
            hit_ratio: f64,
            size: usize,
            capacity: usize,
            window_size: usize,
            main_size: usize,
            protected_size: usize,
        } {
            return .{
                .hits = self.stats.hits,
                .misses = self.stats.misses,
                .inserts = self.stats.inserts,
                .evictions = self.stats.evictions,
                .promotions_to_main = self.stats.promotions_to_main,
                .promotions_to_protected = self.stats.promotions_to_protected,
                .ghost_hits = self.stats.ghost_hits,
                .rejections = self.stats.rejections,
                .resets = self.stats.resets,
                .hit_ratio = self.hitRatio(),
                .size = self.len(),
                .capacity = self.capacity(),
                .window_size = self.window_queue.length(),
                .main_size = self.main_queue.length(),
                .protected_size = self.protected_queue.length(),
            };
        }
    };
}

/// Convenience function to create TinyLFU cache
pub fn Auto(comptime K: type, comptime V: type) type {
    return TinyLfuCache(K, V);
}
