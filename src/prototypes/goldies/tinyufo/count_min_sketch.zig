// Count-Min Sketch - Probabilistic frequency estimator
// Used for TinyLFU admission control
//
// A Count-Min Sketch uses multiple hash functions to estimate
// the frequency of elements with sub-linear space complexity.
//
// Properties:
// - Width (w): Number of counters per row
// - Depth (d): Number of independent hash functions (rows)
// - Counter size: 4-bit counters (0-15)
// - Space: O(w * d) bits
// - Query time: O(d)
// - Update time: O(d)

const std = @import("std");

/// Configuration for Count-Min Sketch
pub const Config = struct {
    /// Width - number of counters per row (power of 2)
    width: usize = 2048,

    /// Depth - number of hash functions (rows)
    depth: usize = 4,

    /// Counter bits (4 or 8)
    counter_bits: u8 = 4,
};

/// Count-Min Sketch for frequency estimation
pub fn CountMinSketch(comptime config: Config) type {
    // Validate configuration
    comptime {
        if (config.counter_bits != 4 and config.counter_bits != 8) {
            @compileError("counter_bits must be 4 or 8");
        }
        if (config.depth == 0 or config.depth > 16) {
            @compileError("depth must be between 1 and 16");
        }
        if (!std.math.isPowerOfTwo(config.width)) {
            @compileError("width must be a power of 2");
        }
    }

    const CounterType = if (config.counter_bits == 4) u4 else u8;
    const max_count: CounterType = std.math.maxInt(CounterType);

    return struct {
        const Self = @This();

        /// Allocator for memory management
        allocator: std.mem.Allocator,

        /// Counter table [depth][width]
        /// Stored as flat array for cache efficiency
        counters: []CounterType,

        /// Width mask (width - 1) for fast modulo
        width_mask: usize,

        /// Total number of increments (for reset logic)
        total_count: u64,

        /// Initialize Count-Min Sketch
        pub fn init(allocator: std.mem.Allocator) !Self {
            const total_counters = config.width * config.depth;
            const counters = try allocator.alloc(CounterType, total_counters);

            // Initialize all counters to 0
            @memset(counters, 0);

            return Self{
                .allocator = allocator,
                .counters = counters,
                .width_mask = config.width - 1,
                .total_count = 0,
            };
        }

        /// Clean up and free memory
        pub fn deinit(self: *Self) void {
            self.allocator.free(self.counters);
        }

        /// Hash function for row i
        /// Uses multiplicative hashing with different seeds per row
        fn hash(self: *const Self, key: u64, row: usize) usize {
            // Use different prime multipliers for each row
            const primes = [_]u64{
                0x9e3779b97f4a7c15, // Golden ratio * 2^64
                0xbf58476d1ce4e5b9, // Random prime 1
                0x94d049bb133111eb, // Random prime 2
                0xc2b2ae3d27d4eb4f, // Random prime 3
                0x165667b19e3779f9, // Random prime 4
                0xd6e8feb86659fd93, // Random prime 5
                0x8cb92ba72f3d8dd7, // Random prime 6
                0xabc98388fb7dafa1, // Random prime 7
                0x9c422a4c95c49e5b, // Random prime 8
                0xa3b195354a39b70d, // Random prime 9
                0xc53a1b5f58f3d0e7, // Random prime 10
                0xd7b4e2e91a8f7619, // Random prime 11
                0xe8c537da945b8c93, // Random prime 12
                0xf1d6e8ab3c5f7821, // Random prime 13
                0xa9e14c7b56d8f3e5, // Random prime 14
                0xb8f1d6e9c7a42d91, // Random prime 15
            };

            const prime = primes[row % primes.len];
            const h = key *% prime;

            // Use upper bits for better distribution
            const result = (h >> 32) ^ h;
            return @as(usize, @truncate(result)) & self.width_mask;
        }

        /// Increment frequency counter for a key
        pub fn increment(self: *Self, key: u64) void {
            var i: usize = 0;
            while (i < config.depth) : (i += 1) {
                const idx = i * config.width + self.hash(key, i);

                // Increment counter if not at max
                if (self.counters[idx] < max_count) {
                    self.counters[idx] += 1;
                }
            }

            self.total_count += 1;
        }

        /// Estimate frequency of a key (minimum of all counters)
        pub fn estimate(self: *const Self, key: u64) CounterType {
            var min_count: CounterType = max_count;

            var i: usize = 0;
            while (i < config.depth) : (i += 1) {
                const idx = i * config.width + self.hash(key, i);
                const count = self.counters[idx];

                if (count < min_count) {
                    min_count = count;
                }
            }

            return min_count;
        }

        /// Reset all counters by halving (aging mechanism)
        /// This prevents counters from saturating and allows
        /// the sketch to adapt to changing access patterns
        pub fn reset(self: *Self) void {
            for (self.counters) |*counter| {
                counter.* = counter.* / 2;
            }
            self.total_count = 0;
        }

        /// Clear all counters to zero
        pub fn clear(self: *Self) void {
            @memset(self.counters, 0);
            self.total_count = 0;
        }

        /// Get total number of increments
        pub fn getTotalCount(self: *const Self) u64 {
            return self.total_count;
        }

        /// Get configuration
        pub fn getConfig(self: *const Self) Config {
            _ = self;
            return config;
        }

        /// Calculate memory usage in bytes
        pub fn memoryUsage(self: *const Self) usize {
            return self.counters.len * @sizeOf(CounterType);
        }

        // === Lock-Free Atomic Operations (Phase 4b) ===

        /// Atomically increment frequency counter (lock-free)
        /// Note: May lose some counts due to CAS failures, but this is acceptable
        /// for frequency estimation as it maintains approximate correctness
        pub fn incrementAtomic(self: *Self, key: u64) void {
            var i: usize = 0;
            while (i < config.depth) : (i += 1) {
                const idx = i * config.width + self.hash(key, i);

                // Atomic increment using CAS loop
                while (true) {
                    const current = @atomicLoad(CounterType, &self.counters[idx], .monotonic);
                    if (current >= max_count) break; // Saturated

                    // Try to increment
                    const result = @cmpxchgWeak(
                        CounterType,
                        &self.counters[idx],
                        current,
                        current + 1,
                        .monotonic,
                        .monotonic,
                    );

                    if (result == null) {
                        // CAS succeeded
                        break;
                    }
                    // CAS failed, retry (or could accept loss and break)
                }
            }

            // Note: total_count increment is not atomic - only approximate
            // This is acceptable for frequency estimation
            _ = @atomicRmw(u64, &self.total_count, .Add, 1, .monotonic);
        }

        /// Atomically estimate frequency (lock-free read)
        pub fn estimateAtomic(self: *const Self, key: u64) CounterType {
            var min_count: CounterType = max_count;

            var i: usize = 0;
            while (i < config.depth) : (i += 1) {
                const idx = i * config.width + self.hash(key, i);
                const count = @atomicLoad(CounterType, &self.counters[idx], .monotonic);

                if (count < min_count) {
                    min_count = count;
                }
            }

            return min_count;
        }

        /// Atomically reset all counters by halving (approximate aging)
        /// Note: This is NOT fully atomic - reads may see intermediate states
        /// This is acceptable as it's only used for periodic maintenance
        pub fn resetAtomic(self: *Self) void {
            for (self.counters) |*counter| {
                while (true) {
                    const current = @atomicLoad(CounterType, counter, .monotonic);
                    const new_value = current / 2;

                    const result = @cmpxchgWeak(
                        CounterType,
                        counter,
                        current,
                        new_value,
                        .monotonic,
                        .monotonic,
                    );

                    if (result == null) break; // Success
                    // Retry on failure
                }
            }
            @atomicStore(u64, &self.total_count, 0, .monotonic);
        }

        /// Atomically load total count
        pub fn getTotalCountAtomic(self: *const Self) u64 {
            return @atomicLoad(u64, &self.total_count, .monotonic);
        }
    };
}

/// Default Count-Min Sketch with standard parameters
pub const Default = CountMinSketch(.{
    .width = 2048,
    .depth = 4,
    .counter_bits = 4,
});

/// Large Count-Min Sketch for high-accuracy scenarios
pub const Large = CountMinSketch(.{
    .width = 8192,
    .depth = 8,
    .counter_bits = 8,
});

/// Compact Count-Min Sketch for memory-constrained scenarios
pub const Compact = CountMinSketch(.{
    .width = 1024,
    .depth = 4,
    .counter_bits = 4,
});
