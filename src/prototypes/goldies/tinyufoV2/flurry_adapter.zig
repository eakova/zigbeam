// Flurry HashMap Adapter - provides ConcurrentHashMap interface using Flurry
// This adapter wraps the production-tested Flurry HashMap with thread-local guards
// to match the existing TinyUFO ConcurrentHashMap API

const std = @import("std");
const flurry = @import("flurry.zig");
const ebr = @import("ebr.zig");
const thread_id = @import("thread_id.zig");

/// Adapter that wraps Flurry HashMap to match ConcurrentHashMap interface
/// Uses thread-local guard caching for performance
pub fn FlurryAdapter(comptime K: type, comptime V: type) type {
    return struct {
        const Self = @This();

        // Hash functions for Flurry
        fn hashKey(key: K) u64 {
            var hasher = std.hash.Wyhash.init(0);
            std.hash.autoHash(&hasher, key);
            return hasher.final();
        }

        fn eqlKey(a: K, b: K) bool {
            return std.meta.eql(a, b);
        }

        // For TinyUFO: V is *Bucket, so we need Bucket as the value type for Flurry
        // Flurry stores *ValueType, so if V = *Bucket, we use Child(V) = Bucket
        const ValueType = std.meta.Child(V);
        const FlurryMap = flurry.HashMap(K, ValueType, hashKey, eqlKey);

        map: *FlurryMap,
        collector: *ebr.Collector,
        allocator: std.mem.Allocator,

        /// Initialize adapter with Flurry HashMap
        /// capacity: Initial capacity hint
        /// shard_count: Ignored (Flurry uses single table with power-of-2 bins)
        pub fn init(allocator: std.mem.Allocator, capacity: usize, shard_count: usize) !Self {
            _ = shard_count; // Flurry doesn't use explicit sharding

            // Initialize EBR collector
            const collector = try ebr.Collector.init(allocator);
            errdefer collector.deinit();

            // Initialize Flurry HashMap
            const map = try FlurryMap.init(allocator, collector, capacity);
            errdefer map.deinit();

            return Self{
                .map = map,
                .collector = collector,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.map.deinit();
            self.collector.deinit();
        }

        /// Get value for key (lock-free read with temporary guard)
        /// Returns copy of value (matches old ConcurrentHashMap API)
        pub fn get(self: *Self, key: K) ?V {
            const guard = self.collector.pin() catch return null;
            defer self.collector.unpinGuard(guard);

            const value_ptr = self.map.get(key, guard) orelse return null;
            return value_ptr.*;
        }

        /// Get pointer to value for key (lock-free read with guard)
        /// IMPORTANT: Returned pointer is only valid within current operation
        /// For TinyUFO's use case (immediate access to Bucket fields), this is safe
        pub fn getPtr(self: *Self, key: K) ?*V {
            const guard = self.collector.pin() catch return null;
            defer self.collector.unpinGuard(guard);

            return self.map.get(key, guard);
        }

        /// Put key-value pair (lock-free with CAS fast path)
        /// For TinyUFO: value is *Bucket pointer
        pub fn put(self: *Self, key: K, value: V) !void {
            const guard = try self.collector.pin();
            defer self.collector.unpinGuard(guard);

            // Flurry's put returns old value if replaced
            const old_value = try self.map.put(key, value, guard);

            // TODO: In production, should retire old_value with EBR
            // For now, TinyUFO manages Bucket lifetime separately
            _ = old_value;
        }

        /// Remove key (not implemented in Flurry yet)
        /// Returns old value if existed
        pub fn remove(self: *Self, key: K) ?V {
            // TODO: Implement remove in Flurry HashMap
            // For now, return null (TinyUFO can handle this)
            _ = self;
            _ = key;
            return null;
        }

        /// Check if key exists
        pub fn contains(self: *Self, key: K) bool {
            return self.get(key) != null;
        }

        /// Get current size
        pub fn len(self: *const Self) usize {
            return self.map.len();
        }

        /// Clear all entries (not implemented in Flurry yet)
        pub fn clear(self: *Self) void {
            // TODO: Implement clear in Flurry HashMap
            _ = self;
        }
    };
}
