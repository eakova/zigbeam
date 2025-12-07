const std = @import("std");

// Count-Min Sketch estimator + TinyLFU windowed admission

pub const Estimator = struct {
    // d hash functions (rows), w columns per row
    d: usize,
    w: usize,
    counters: []u16,
    allocator: std.mem.Allocator,

    pub fn new(allocator: std.mem.Allocator, depth: usize, width: usize) !Estimator {
        const total = depth * width;
        const mem = try allocator.alloc(u16, total);
        @memset(mem, 0);
        return .{ .d = depth, .w = width, .counters = mem, .allocator = allocator };
    }

    pub fn deinit(self: *Estimator) void {
        self.allocator.free(self.counters);
    }

    inline fn idx(self: *const Estimator, row: usize, col: usize) usize { return row * self.w + col; }

    inline fn hash_i(i: usize, key: u64) usize {
        // Simple independent-ish mix per row
        var x = key ^ (@as(u64, i) *% 0x9E3779B185EBCA87);
        x ^= x >> 33;
        x *%= 0xff51afd7ed558ccd;
        x ^= x >> 33;
        x *%= 0xc4ceb9fe1a85ec53;
        x ^= x >> 33;
        return @intCast(x);
    }

    pub fn incr_no_overflow(self: *Estimator, key: u64) void {
        // Increase all rows by 1, saturating at max u16
        var i: usize = 0;
        while (i < self.d) : (i += 1) {
            const col = hash_i(i, key) % self.w;
            const j = self.idx(i, col);
            const v = self.counters[j];
            if (v != std.math.maxInt(u16)) self.counters[j] = v + 1;
        }
    }

    pub fn incr(self: *Estimator, key: u64) void {
        self.incr_no_overflow(key);
    }

    pub fn get(self: *const Estimator, key: u64) u16 {
        var min: u16 = std.math.maxInt(u16);
        var i: usize = 0;
        while (i < self.d) : (i += 1) {
            const col = hash_i(i, key) % self.w;
            const j = self.idx(i, col);
            const v = self.counters[j];
            if (v < min) min = v;
        }
        return min;
    }

    pub fn age(self: *Estimator, shift: u3) void {
        // Age by right-shifting all counters
        if (shift == 0) return;
        for (self.counters) |*c| c.* = c.* >> shift;
    }
};

pub const TinyLfu = struct {
    est: Estimator,
    // Windowed admission: track number of samples and periodically age
    window: u64,
    limit: u64,

    pub fn new(allocator: std.mem.Allocator, cache_items: usize) !TinyLfu {
        // Heuristic: depth=4 rows, width = next power-of-two >= 4*cache_items
        const depth: usize = 4;
        var width: usize = std.math.ceilPowerOfTwo(usize, @max(8, cache_items * 4)) catch cache_items * 4;
        if (width == 0) width = 8;
        const est = try Estimator.new(allocator, depth, width);
        return .{ .est = est, .window = 0, .limit = @as(u64, @intCast(cache_items)) * 8 }; // ~8x capacity
    }

    pub fn deinit(self: *TinyLfu) void { self.est.deinit(); }

    pub fn incr(self: *TinyLfu, key: u64) void {
        self.est.incr_no_overflow(key);
        self.window += 1;
        if (self.window >= self.limit) {
            self.est.age(1);
            self.window = 0;
        }
    }

    pub fn freq(self: *const TinyLfu, key: u64) u16 { return self.est.get(key); }
};

test "estimator: basic incr/get/age" {
    const gpa = std.testing.allocator;
    var est = try Estimator.new(gpa, 4, 64);
    defer est.deinit();
    try std.testing.expectEqual(@as(u16, 0), est.get(42));
    est.incr(42);
    est.incr(42);
    try std.testing.expect(est.get(42) >= 2);
    est.age(1);
    try std.testing.expect(est.get(42) <= 2);
}

test "tinylfu: window aging" {
    const gpa = std.testing.allocator;
    var tlfu = try TinyLfu.new(gpa, 32);
    defer tlfu.deinit();
    const key: u64 = 123;
    var i: usize = 0;
    while (i < 100) : (i += 1) tlfu.incr(key);
    try std.testing.expect(tlfu.freq(key) > 0);
}
