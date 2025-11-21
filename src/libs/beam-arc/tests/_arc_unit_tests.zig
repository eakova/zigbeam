//! Core `Arc` unit tests.
//! Each test covers a single promise (inline storage, heap drop, weak upgrade, etc.)
//! so it is easy to see which behavior fails.

const std = @import("std");
const testing = std.testing;
const ArcModule = @import("beam-arc");

const InlineArcU32 = ArcModule.Arc(u32);
const InlineArcU64 = ArcModule.Arc(u64);
const HeapArc = ArcModule.Arc(TrackedValue);
const HeapArcBytes = ArcModule.Arc([32]u8);
const HeapInlineArray = ArcModule.Arc([16]u8);

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

// Inline payload path should support clone/release/tryUnwrap.
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

// Heap payload should trigger user-supplied deinit once counts hit zero.
test "Arc heap deinit runs when last reference drops" {
    var deinit_called = false;
    var arc = try HeapArc.init(testing.allocator, TrackedValue.init(&deinit_called, 99));
    try testing.expect(!deinit_called);
    arc.release();
    try testing.expect(deinit_called);
}

// tryUnwrap must refuse when multiple owners exist.
test "Arc tryUnwrap enforces uniqueness" {
    var payload = [_]u8{55} ** 32;
    var arc = try HeapArcBytes.init(testing.allocator, payload);
    var clone = arc.clone();
    try testing.expectError(error.NotUnique, arc.tryUnwrap());
    clone.release();
    const value = try arc.tryUnwrap();
    try testing.expectEqualSlices(u8, payload[0..], value[0..]);
}

// makeMut should allocate a copy when data is shared.
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

// Weak upgrade path works until the last strong owner releases.
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

test "Arc tryUnwrap defers destruction while weak reference is alive" {
    var deinit_called = false;
    var arc = try HeapArc.init(testing.allocator, TrackedValue.init(&deinit_called, 11));
    const weak_opt = arc.downgrade();
    try testing.expect(weak_opt != null);
    var weak = weak_opt.?;

    var value = try arc.tryUnwrap();
    try testing.expect(!deinit_called);
    value.deinit();
    weak.release();
    try testing.expect(deinit_called);
}

test "ArcWeak upgrade returns null after final strong drop" {
    var deinit_called = false;
    var arc = try HeapArc.init(testing.allocator, TrackedValue.init(&deinit_called, 42));
    const weak_opt = arc.downgrade();
    try testing.expect(weak_opt != null);
    var weak = weak_opt.?;

    arc.release();
    try testing.expect(weak.upgrade() == null);
    weak.release();
    try testing.expect(deinit_called);
}

test "Arc heap makeMut keeps pointer when unique" {
    var arc = try HeapInlineArray.init(testing.allocator, [_]u8{1} ** 16);
    defer arc.release();

    const before = arc.get();
    const mut_ptr = try arc.makeMut();
    try testing.expectEqual(before, mut_ptr);

    mut_ptr.*[0] = 99;
    try testing.expectEqual(@as(u8, 99), arc.get().*[0]);
}

// In-place initializer should write payload without memcpy for inline and heap arcs.
test "Arc initWithInitializer works (inline and heap)" {
    // Inline (u32)
    var a_inline = try ArcModule.Arc(u32).initWithInitializer(testing.allocator, struct {
        fn init(p: *u32) void { p.* = 1234; }
    }.init);
    try testing.expect(a_inline.isInline());
    try testing.expectEqual(@as(u32, 1234), a_inline.get().*);
    a_inline.release();

    // Heap ([32]u8)
    var a_heap = try ArcModule.Arc([32]u8).initWithInitializer(testing.allocator, struct {
        fn init(p: *[32]u8) void { @memset(p, 9); }
    }.init);
    try testing.expect(!a_heap.isInline());
    try testing.expectEqual(@as(u8, 9), a_heap.get().*[0]);
    a_heap.release();
}

// newCyclic should allow constructing a value that captures a Weak to itself.
test "Arc newCyclic builds self-referential weak and upgrades before/after drop semantics" {
    const Node = struct {
        weak_self: ArcModule.ArcWeak(@This()) = ArcModule.ArcWeak(@This()).empty(),
        pub fn deinit(self: *@This()) void {
            self.weak_self.release();
        }
    };
    const ArcNode = ArcModule.Arc(Node);

    var arc = try ArcNode.newCyclic(testing.allocator, struct {
        fn ctor(w: ArcModule.ArcWeak(Node)) anyerror!Node {
            // Keep a counted weak by cloning the temporary weak
            const kept = w.clone();
            return Node{ .weak_self = kept };
        }
    }.ctor);
    // Upgrade succeeds while strong exists
    const up = arc.get().*.weak_self.upgrade();
    try testing.expect(up != null);
    if (up) |tmp| tmp.release();
    const weak_copy = arc.get().*.weak_self.clone();
    arc.release();
    // After last strong drop, upgrade must fail
    try testing.expect(weak_copy.upgrade() == null);
    weak_copy.release();
}
