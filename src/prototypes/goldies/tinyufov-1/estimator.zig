/// TinyLFU Estimator - Count-Min Sketch frequency estimation
/// Ported from Cloudflare TinyUFO Rust estimation.rs

const std = @import("std");
const Atomic = std.atomic.Value;
const assert = std.debug.assert;

/// Count-Min Sketch with 2D array of atomic u8 counters
pub const Estimator = struct {
    hashes: usize,          // Number of independent hash functions (depth)
    slots: usize,           // Number of slots per hash (width)
    table: []Atomic(u8),    // 2D flattened array [hashes][slots]
    allocator: std.mem.Allocator,

    /// Calculate optimal parameters (hashes, slots) for desired accuracy
    /// Formulas:
    ///   width = ceil(e / epsilon)      for relative error epsilon
    ///   depth = ceil(ln(1-δ) / ln(0.5)) for confidence δ
    pub fn optimal_paras(allocator: std.mem.Allocator, items: u64) !struct { hashes: usize, slots: usize } {
        // Conservative defaults
        // For typical use (items < 1M): depth=4, width=64K gives good accuracy

        const depth: usize = if (items < 100_000)
            4
        else if (items < 1_000_000)
            5
        else
            6;

        const width: usize = if (items < 100_000)
            65536      // 64K
        else if (items < 1_000_000)
            131072     // 128K
        else
            262144;    // 256K

        _ = allocator;
        return .{ .hashes = depth, .slots = width };
    }

    /// Initialize Estimator with given dimensions
    pub fn init(allocator: std.mem.Allocator, hashes: usize, slots: usize) !*Estimator {
        const estimator = try allocator.create(Estimator);

        const table = try allocator.alloc(Atomic(u8), hashes * slots);

        for (table) |*counter| {
            counter.* = Atomic(u8).init(0);
        }

        estimator.* = .{
            .hashes = hashes,
            .slots = slots,
            .table = table,
            .allocator = allocator,
        };

        return estimator;
    }

    pub fn deinit(self: *Estimator) void {
        self.allocator.free(self.table);
        self.allocator.destroy(self);
    }

    /// Get index in flattened table for hash row and slot
    fn get_index(self: *const Estimator, hash_idx: usize, slot: usize) usize {
        return hash_idx * self.slots + slot;
    }

    /// Hash key using simple algorithm (in production would use RandomState)
    fn hash_key(key: u64, seed: u32) u32 {
        var h = key;
        h ^= h >> 33;
        h *%= 0xbf58476d1ce4e5b9;
        h ^= h >> 27;
        h *%= 0x94d049bb133111eb;
        h ^= h >> 33;
        return @intCast((h +% seed) & 0xffffffff);
    }

    /// Increment counter with no overflow (saturates at 255)
    fn incr_no_overflow(counter: *Atomic(u8)) void {
        var current = counter.load(.monotonic);

        while (current < 255) {
            const result = counter.cmpxchgWeak(
                current,
                current + 1,
                .acquire,
                .monotonic,
            );

            if (result == null) {
                return; // Success
            }

            current = result.?;
        }
    }

    /// Increment frequency counter for key
    pub fn incr(self: *Estimator, key: u64) void {
        for (0..self.hashes) |i| {
            const seed = @as(u32, @intCast(i));
            const slot = hash_key(key, seed) % @as(u32, @intCast(self.slots));

            const idx = self.get_index(i, @intCast(slot));
            incr_no_overflow(&self.table[idx]);
        }
    }

    /// Get frequency estimate for key (minimum across all hashes)
    pub fn get(self: *const Estimator, key: u64) u8 {
        var min_count: u8 = 255;

        for (0..self.hashes) |i| {
            const seed = @as(u32, @intCast(i));
            const slot = hash_key(key, seed) % @as(u32, @intCast(self.slots));

            const idx = self.get_index(i, @intCast(slot));
            const count = self.table[idx].load(.acquire);

            if (count < min_count) {
                min_count = count;
            }
        }

        return min_count;
    }

    /// Age/decay all counters by right-shifting (intentionally racy)
    pub fn age(self: *Estimator, shift: u32) void {
        for (self.table) |*counter| {
            const current = counter.load(.unordered);
            const aged = current >> @intCast(shift);
            counter.store(aged, .unordered); // Intentionally racy - OK for frequency estimation
        }
    }

    /// Reset all counters to zero (intentionally racy)
    pub fn reset(self: *Estimator) void {
        for (self.table) |*counter| {
            counter.store(0, .unordered);
        }
    }
};

/// ============================================================================
/// TINYLFU - Windowed frequency tracker with automatic aging
/// ============================================================================

pub const TinyLFU = struct {
    estimator: *Estimator,
    window_counter: Atomic(u64),      // Number of increments in current window
    window_limit: u64,                // When to trigger aging (8× capacity)
    cache_size: u64,
    allocator: std.mem.Allocator,

    /// Create new TinyLFU for cache of given size
    pub fn new(allocator: std.mem.Allocator, cache_size: u64) !*TinyLFU {
        const paras = try Estimator.optimal_paras(allocator, cache_size);
        const estimator = try Estimator.init(allocator, paras.hashes, paras.slots);

        const tinylfu = try allocator.create(TinyLFU);
        tinylfu.* = .{
            .estimator = estimator,
            .window_counter = Atomic(u64).init(0),
            .window_limit = cache_size * 8,
            .cache_size = cache_size,
            .allocator = allocator,
        };

        return tinylfu;
    }

    /// Create compact version (smaller window multiplier for memory)
    pub fn new_compact(allocator: std.mem.Allocator, cache_size: u64) !*TinyLFU {
        const paras = try Estimator.optimal_paras(allocator, cache_size);
        const estimator = try Estimator.init(allocator, paras.hashes, paras.slots);

        const tinylfu = try allocator.create(TinyLFU);
        tinylfu.* = .{
            .estimator = estimator,
            .window_counter = Atomic(u64).init(0),
            .window_limit = cache_size * 4,  // Smaller window for compact version
            .cache_size = cache_size,
            .allocator = allocator,
        };

        return tinylfu;
    }

    pub fn deinit(self: *TinyLFU) void {
        self.estimator.deinit();
        self.allocator.destroy(self);
    }

    /// Increment frequency for key with window management
    /// Increment frequency for key and return current frequency (Rust: lib.rs)
    pub fn incr(self: *TinyLFU, key: u64) u8 {
        // Increment in estimator
        self.estimator.incr(key);

        // Advance window counter
        const old_counter = self.window_counter.fetchAdd(1, .monotonic);

        // Check if we need to age
        if (old_counter >= self.window_limit) {
            // Age by right-shifting by 1 (divide by 2)
            self.estimator.age(1);

            // Reset window counter (intentionally racy - OK for this use case)
            self.window_counter.store(0, .unordered);
        }

        // Return current frequency of key (Rust: must return for admission control)
        return self.estimator.get(key);
    }

    /// Get frequency estimate for key
    pub fn get(self: *const TinyLFU, key: u64) u8 {
        return self.estimator.get(key);
    }

    /// Reset all frequencies (rarely used)
    pub fn reset(self: *TinyLFU) void {
        self.estimator.reset();
        self.window_counter.store(0, .unordered);
    }
};

/// Quick frequency comparison helper
pub fn compare_freq(tinylfu: *const TinyLFU, key_new: u64, key_old: u64) bool {
    const freq_new = tinylfu.get(key_new);
    const freq_old = tinylfu.get(key_old);
    return freq_new > freq_old;
}
