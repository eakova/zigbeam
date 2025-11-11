const std = @import("std");
const testing = std.testing;
const ArcModule = @import("arc.zig");

const InlineArcU32 = ArcModule.Arc(u32);
const InlineArcU64 = ArcModule.Arc(u64);
const HeapArc = ArcModule.Arc(TrackedValue);
const HeapArcBytes = ArcModule.Arc([32]u8);

const TrackedValue = struct {
    payload: usize,
    flag: *bool,

    pub fn init(flag: *bool, payload: usize) TrackedValue {
        return .{ .payload = payload, .flag = flag };
    }

    pub fn deinit(self: *TrackedValue) void {
        self.flag.* = true;
    }
};

test "Arc inline clone/release/tryUnwrap" {
    var arc = try InlineArcU32.init(testing.allocator, 42);
    try testing.expect(arc.isInline());
    try testing.expectEqual(@as(u32, 42), arc.get().*);

    var clone = arc.clone();
    try testing.expect(clone.isInline());
    try testing.expectEqual(@as(u32, 42), clone.get().*);
    clone.release();

    const value = try arc.tryUnwrap();
    try testing.expectEqual(@as(u32, 42), value);
}

test "Arc heap deinit runs when last reference drops" {
    var deinit_called = false;
    var arc = try HeapArc.init(testing.allocator, TrackedValue.init(&deinit_called, 99));
    try testing.expect(!deinit_called);
    arc.release();
    try testing.expect(deinit_called);
}

test "Arc tryUnwrap enforces uniqueness" {
    var payload = [_]u8{55} ** 32;
    var arc = try HeapArcBytes.init(testing.allocator, payload);
    var clone = arc.clone();
    try testing.expectError(error.NotUnique, arc.tryUnwrap());
    clone.release();
    const value = try arc.tryUnwrap();
    try testing.expectEqualSlices(u8, payload[0..], value[0..]);
}

test "Arc makeMut clones shared inline data" {
    var arc = try InlineArcU64.init(testing.allocator, 5);
    defer arc.release();
    var clone = arc.clone();
    defer clone.release();

    const mut_ptr = try arc.makeMut();
    mut_ptr.* = 99;
    try testing.expectEqual(@as(u64, 99), arc.get().*);
    try testing.expectEqual(@as(u64, 5), clone.get().*);
}

test "ArcWeak upgrades while strong refs remain" {
    var deinit_called = false;
    var arc = try HeapArc.init(testing.allocator, TrackedValue.init(&deinit_called, 7));

    const weak_opt = arc.downgrade();
    try testing.expect(weak_opt != null);
    var weak = weak_opt.?;

    var clone = arc.clone();

    const upgraded = weak.upgrade();
    try testing.expect(upgraded != null);
    upgraded.?.release();

    clone.release();
    arc.release();
    weak.release();

    try testing.expect(deinit_called);
}
