// Atomic Count-Min Sketch for Lock-Free TinyUFO
// Thread-safe frequency estimation with atomic counters
// No locks - pure atomic operations

const std = @import("std");

/// Atomic Count-Min Sketch with configurable dimensions
pub fn AtomicCountMinSketch(comptime width: usize, comptime depth: usize) type {
    return struct {
        const Self = @This();

        /// 2D array of atomic counters
        counters: [depth][width]std.atomic.Value(u32),

        /// Seed for hash functions (one per depth)
        seeds: [depth]u64,

        /// Initialize sketch with zero counters
        pub fn init() Self {
            var self = Self{
                .counters = undefined,
                .seeds = undefined,
            };

            // Initialize all counters to zero
            for (0..depth) |d| {
                for (0..width) |w| {
                    self.counters[d][w] = std.atomic.Value(u32).init(0);
                }
            }

            // Generate deterministic seeds for hash functions
            for (0..depth) |d| {
                const d_u64: u64 = @intCast(d);
                self.seeds[d] = 0x123456789abcdef0 +% (d_u64 *% 0x9e3779b97f4a7c15);
            }

            return self;
        }

        /// Hash function for specific depth level
        fn hash(self: *const Self, key: u64, level: usize) usize {
            const seed = self.seeds[level];
            const hash_val = std.hash.Wyhash.hash(seed, std.mem.asBytes(&key));
            return @as(usize, @intCast(hash_val % width));
        }

        /// Atomically increment frequency counter for key
        pub fn increment(self: *Self, key: u64) void {
            for (0..depth) |d| {
                const idx = self.hash(key, d);
                _ = self.counters[d][idx].fetchAdd(1, .monotonic);
            }
        }

        /// Atomically increment by custom amount
        pub fn add(self: *Self, key: u64, count: u32) void {
            for (0..depth) |d| {
                const idx = self.hash(key, d);
                _ = self.counters[d][idx].fetchAdd(count, .monotonic);
            }
        }

        /// Estimate frequency (minimum across all depths)
        pub fn estimate(self: *const Self, key: u64) u32 {
            var min_count: u32 = std.math.maxInt(u32);

            for (0..depth) |d| {
                const idx = self.hash(key, d);
                const count = self.counters[d][idx].load(.acquire);
                min_count = @min(min_count, count);
            }

            return min_count;
        }

        /// Reset all counters to zero (for periodic decay)
        pub fn reset(self: *Self) void {
            for (0..depth) |d| {
                for (0..width) |w| {
                    self.counters[d][w].store(0, .release);
                }
            }
        }

        /// Halve all counters (for aging)
        pub fn decay(self: *Self) void {
            for (0..depth) |d| {
                for (0..width) |w| {
                    const current = self.counters[d][w].load(.acquire);
                    const halved = current / 2;
                    self.counters[d][w].store(halved, .release);
                }
            }
        }

        /// Compare two keys' frequencies
        pub fn compare(self: *const Self, key1: u64, key2: u64) std.math.Order {
            const freq1 = self.estimate(key1);
            const freq2 = self.estimate(key2);

            if (freq1 < freq2) return .lt;
            if (freq1 > freq2) return .gt;
            return .eq;
        }
    };
}

/// Default configuration (balanced)
pub const Default = AtomicCountMinSketch(2048, 4);

/// Large configuration (high accuracy)
pub const Large = AtomicCountMinSketch(4096, 8);

/// Compact configuration (low memory)
pub const Compact = AtomicCountMinSketch(1024, 4);
