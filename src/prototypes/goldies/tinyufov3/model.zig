const std = @import("std");

pub const SMALL: bool = false;
pub const MAIN: bool = true;

pub const Uses = struct {
    v: std.atomic.Value(u8),

    pub fn init() Uses { return .{ .v = std.atomic.Value(u8).init(0) }; }
    pub fn uses(self: *const Uses) u8 { return self.v.load(.acquire); }
    pub fn inc(self: *Uses) void {
        var cur = self.v.load(.acquire);
        while (cur < 3) {
            const res = self.v.cmpxchgWeak(cur, cur + 1, .acq_rel, .acquire);
            if (res == null) return;
            cur = res.?;
        }
    }
    pub fn decr(self: *Uses) void {
        var cur = self.v.load(.acquire);
        while (cur > 0) {
            const res = self.v.cmpxchgWeak(cur, cur - 1, .acq_rel, .acquire);
            if (res == null) return;
            cur = res.?;
        }
    }
};

pub const Location = struct {
    main: std.atomic.Value(bool),
    pub fn new_small() Location { return .{ .main = std.atomic.Value(bool).init(false) }; }
    pub fn is_main(self: *const Location) bool { return self.main.load(.acquire); }
    pub fn move_to_main(self: *Location) void { self.main.store(true, .release); }
};

pub fn Bucket(comptime T: type) type {
    return struct {
        uses: Uses,
        loc: Location,
        weight: u16,
        data: T,

        pub fn init(data: T, weight: u16) @This() {
            return .{ .uses = Uses.init(), .loc = Location.new_small(), .weight = weight, .data = data };
        }
    };
}

test "model: uses/location" {
    var u = Uses.init();
    u.inc(); u.inc(); u.decr();
    try std.testing.expect(u.uses() <= 2);
    var l = Location.new_small();
    try std.testing.expect(!l.is_main());
    l.move_to_main();
    try std.testing.expect(l.is_main());
}

