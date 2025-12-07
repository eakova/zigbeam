const std = @import("std");

/// Lock-free Count-Min Sketch for frequency estimation
/// Based on Cloudflare TinyUFO design:
/// - Width: 10× capacity
/// - Depth: 4 hash functions
/// - 4-bit counters (0-15)
/// - Auto-reset every 10× insertions
pub const CountMinSketch = struct {
    const Self = @This();

    // 4-bit counters packed 2 per byte
    counters: []std.atomic.Value(u8),
    width: usize,
    depth: usize,

    // Track total insertions for reset
    insertions: std.atomic.Value(u64),
    reset_threshold: u64,

    allocator: std.mem.Allocator,

    /// Initialize Count-Min Sketch
    /// width: Number of buckets per hash function (typically 10× capacity)
    /// depth: Number of hash functions (typically 4)
    pub fn init(allocator: std.mem.Allocator, width: usize, depth: usize) !Self {
        // Round width up to power of 2 for fast modulo
        const actual_width = std.math.ceilPowerOfTwo(usize, width) catch width;

        const total_counters = actual_width * depth;
        const counter_bytes = (total_counters + 1) / 2; // 2 counters per byte

        const counters = try allocator.alloc(std.atomic.Value(u8), counter_bytes);
        @memset(counters, std.atomic.Value(u8).init(0));

        return Self{
            .counters = counters,
            .width = actual_width,
            .depth = depth,
            .insertions = std.atomic.Value(u64).init(0),
            .reset_threshold = actual_width * 10, // Reset every 10× width insertions
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.counters);
    }

    /// Hash function for a given depth level
    fn hash(self: *const Self, key_hash: u64, depth_idx: usize) usize {
        // Mix the hash with depth index
        const h = key_hash +% (@as(u64, @intCast(depth_idx)) *% 0x9e3779b97f4a7c15);
        const mixed = h ^ (h >> 32);
        return @as(usize, @intCast(mixed % self.width));
    }

    /// Get counter index and shift for a given position
    fn getCounterPos(row: usize, col: usize, width: usize) struct { byte_idx: usize, shift: u3 } {
        const linear_idx = row * width + col;
        const byte_idx = linear_idx / 2;
        const is_high_nibble = (linear_idx % 2) == 1;
        const shift: u3 = if (is_high_nibble) 4 else 0;
        return .{ .byte_idx = byte_idx, .shift = shift };
    }

    /// Increment counter at position (saturates at 15)
    fn incrementCounter(self: *Self, row: usize, col: usize) void {
        const pos = getCounterPos(row, col, self.width);

        while (true) {
            const current = self.counters[pos.byte_idx].load(.acquire);
            const counter_val = (current >> pos.shift) & 0x0F;

            if (counter_val >= 15) return; // Saturated

            const new_counter = counter_val + 1;
            const mask: u8 = @as(u8, 0x0F) << pos.shift;
            const new_byte = (current & ~mask) | (@as(u8, @intCast(new_counter)) << pos.shift);

            const result = self.counters[pos.byte_idx].cmpxchgWeak(
                current,
                new_byte,
                .release,
                .acquire,
            );

            if (result == null) return; // Success
            // CAS failed, retry
        }
    }

    /// Get counter value at position
    fn getCounter(self: *const Self, row: usize, col: usize) u8 {
        const pos = getCounterPos(row, col, self.width);
        const byte_val = self.counters[pos.byte_idx].load(.acquire);
        return (byte_val >> pos.shift) & 0x0F;
    }

    /// Halve all counters (called during reset)
    /// CRITICAL FIX: Each byte contains 2 nibbles (4-bit counters)
    /// Must extract, halve, and recombine each nibble separately
    /// Otherwise shifting high nibble corrupts bit positions
    fn halveAllCounters(self: *Self) void {
        for (self.counters) |*counter| {
            while (true) {
                const current = counter.load(.acquire);
                
                // Extract each nibble
                const low = current & 0x0F;        // Bits 0-3
                const high = (current >> 4) & 0x0F; // Bits 4-7
                
                // Halve each nibble
                const halved_low = low >> 1;
                const halved_high = high >> 1;
                
                // Recombine: high nibble goes back to bits 4-7
                const new_val = (halved_high << 4) | halved_low;

                const result = counter.cmpxchgWeak(
                    current,
                    new_val,
                    .release,
                    .acquire,
                );

                if (result == null) break; // Success
            }
        }
    }

    /// Record access to a key (increment frequency)
    pub fn increment(self: *Self, key_hash: u64) void {
        // Increment all depth counters
        for (0..self.depth) |d| {
            const col = self.hash(key_hash, d);
            self.incrementCounter(d, col);
        }

        // Track total insertions
        const insertions = self.insertions.fetchAdd(1, .monotonic) + 1;

        // Reset if threshold reached
        if (insertions >= self.reset_threshold) {
            // Try to atomically reset counter
            const result = self.insertions.cmpxchgStrong(
                insertions,
                0,
                .release,
                .acquire,
            );

            // Only one thread will succeed and perform the reset
            if (result == null) {
                self.halveAllCounters();
            }
        }
    }

    /// Estimate frequency for a key (minimum of all depth counters)
    pub fn estimate(self: *const Self, key_hash: u64) u8 {
        var min_count: u8 = 15;

        for (0..self.depth) |d| {
            const col = self.hash(key_hash, d);
            const count = self.getCounter(d, col);
            min_count = @min(min_count, count);
        }

        return min_count;
    }

    /// Reset all counters to 0
    pub fn reset(self: *Self) void {
        for (self.counters) |*counter| {
            counter.store(0, .release);
        }
        self.insertions.store(0, .release);
    }
};

test "CountMinSketch basic operations" {
    const allocator = std.testing.allocator;

    var sketch = try CountMinSketch.init(allocator, 100, 4);
    defer sketch.deinit();

    // Test increment and estimate
    const hash1: u64 = 12345;
    const hash2: u64 = 67890;

    // Initially should be 0
    try std.testing.expectEqual(@as(u8, 0), sketch.estimate(hash1));
    try std.testing.expectEqual(@as(u8, 0), sketch.estimate(hash2));

    // Increment hash1 multiple times
    sketch.increment(hash1);
    sketch.increment(hash1);
    sketch.increment(hash1);

    // hash1 should have frequency >= 1 (may be approximate)
    const freq1 = sketch.estimate(hash1);
    try std.testing.expect(freq1 >= 1);
    try std.testing.expect(freq1 <= 15);

    // hash2 should still be 0
    try std.testing.expectEqual(@as(u8, 0), sketch.estimate(hash2));

    // Test saturation at 15
    for (0..20) |_| {
        sketch.increment(hash1);
    }
    const freq_saturated = sketch.estimate(hash1);
    try std.testing.expect(freq_saturated <= 15);
}
