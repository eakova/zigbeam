const std = @import("std");
const SegQueue = @import("seg_queue.zig").SegQueue;
const Est = @import("estimator.zig");

// Two-FIFO structure with weight accounting and TinyLFU-based admission.

pub const Fifos = struct {
    small: SegQueue(u64),
    main: SegQueue(u64),
    small_weight: std.atomic.Value(u64),
    main_weight: std.atomic.Value(u64),
    weight_limit: u64,
    tlfu: Est.TinyLfu,

    pub fn init(allocator: std.mem.Allocator, weight_limit: u64, est_items: usize) !Fifos {
        return .{
            .small = try SegQueue(u64).init(allocator),
            .main = try SegQueue(u64).init(allocator),
            .small_weight = std.atomic.Value(u64).init(0),
            .main_weight = std.atomic.Value(u64).init(0),
            .weight_limit = weight_limit,
            .tlfu = try Est.TinyLfu.new(allocator, est_items),
        };
    }

    pub fn deinit(self: *Fifos) void {
        self.small.deinit();
        self.main.deinit();
        self.tlfu.deinit();
    }

    pub fn record(self: *Fifos, key: u64) void { self.tlfu.incr(key); }

    pub fn admit(self: *Fifos, key: u64, weight: u16, victim_key: ?u64) bool {
        // TinyLFU compares frequency of candidate vs victim; if no victim, admit to small by default
        const f_new = self.tlfu.freq(key);
        const f_old: u16 = if (victim_key) |v| self.tlfu.freq(v) else 0;
        if (victim_key == null or f_new >= f_old) {
            // Admit to small
            self.small.push(key) catch {};
            _ = self.small_weight.fetchAdd(weight, .acq_rel);
            return true;
        }
        return false;
    }

    pub fn promote_to_main(self: *Fifos, key: u64, weight: u16) void {
        self.main.push(key) catch {};
        _ = self.main_weight.fetchAdd(weight, .acq_rel);
        // Remove from small weight if present (best-effort)
        _ = self.small_weight.fetchSub(@intCast(weight), .acq_rel);
    }

    pub fn evict_until_with(self: *Fifos, allocator: std.mem.Allocator, on_evict: fn (u64) u16) void {
        _ = allocator;
        var total = self.small_weight.load(.seq_cst) + self.main_weight.load(.seq_cst);
        while (total > self.weight_limit) {
            if (self.main.pop()) |k| {
                const w = on_evict(k);
                _ = self.main_weight.fetchSub(w, .acq_rel);
            } else if (self.small.pop()) |k2| {
                const w2 = on_evict(k2);
                _ = self.small_weight.fetchSub(w2, .acq_rel);
            } else break;
            total = self.small_weight.load(.seq_cst) + self.main_weight.load(.seq_cst);
        }
    }

    pub fn pop_main(self: *Fifos) ?u64 { return self.main.pop(); }
    pub fn pop_small(self: *Fifos) ?u64 { return self.small.pop(); }
};

test "fifos: admit/promote/evict" {
    const gpa = std.testing.allocator;
    var f = try Fifos.init(gpa, 100, 64);
    defer f.deinit();

    const on_evict = struct { fn cb(_: u64) u16 { return 10; } }.cb;
    try std.testing.expect(f.admit(1, 10, null));
    f.promote_to_main(1, 10);
    f.evict_until_with(gpa, on_evict);
}
