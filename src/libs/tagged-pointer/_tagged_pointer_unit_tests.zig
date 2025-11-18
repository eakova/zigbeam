//! Unit tests for `TaggedPointer`.
//! Each test highlights a specific promise (tag bounds, raw round-trips, etc.)
//! so new contributors can tie behavior back to the implementation quickly.

const std = @import("std");
const TaggedPointer = @import("tagged_pointer.zig").TaggedPointer;

const TestNode = struct {
    value: usize,
};

const NodePtr = *TestNode;

test "TaggedPointer basic operations" {
    // Happy-path: create, mutate pointer/tag, and read them back.
    var node = TestNode{ .value = 42 };
    const ptr: NodePtr = @ptrCast(&node);
    const Pointer = TaggedPointer(NodePtr, 2);

    var tagged = try Pointer.new(ptr, 1);
    try std.testing.expectEqual(ptr, tagged.getPtr());
    try std.testing.expectEqual(@as(u2, 1), tagged.getTag());

    var other = TestNode{ .value = 99 };
    const other_ptr: NodePtr = @ptrCast(&other);
    tagged.setPtr(other_ptr);
    tagged.setTag(2);

    try std.testing.expectEqual(other_ptr, tagged.getPtr());
    try std.testing.expectEqual(@as(u2, 2), tagged.getTag());
}

test "TaggedPointer rejects oversized tag" {
    // Defensive check: fail fast when the requested tag does not fit.
    var node = TestNode{ .value = 1 };
    const ptr: NodePtr = @ptrCast(&node);
    const Pointer = TaggedPointer(NodePtr, 1);

    try std.testing.expectError(error.TagTooLarge, Pointer.new(ptr, 2));
}

test "TaggedPointer preserves pointer bits when toggling tag" {
    // Ensure repeated tag writes never corrupt the pointer payload.
    var node = TestNode{ .value = 7 };
    const ptr: NodePtr = @ptrCast(&node);
    const Pointer = TaggedPointer(NodePtr, 1);

    var tagged = try Pointer.new(ptr, 0);
    tagged.setTag(1);
    tagged.setTag(0);
    try std.testing.expectEqual(ptr, tagged.getPtr());
}

test "TaggedPointer supports maximum tag space" {
    // Exercise all possible tag values for a 3-bit configuration.
    const Ptr = TaggedPointer(*align(8) TestNode, 3);
    var nodes: [4]TestNode = undefined;
    var idx: usize = 0;
    while (idx < nodes.len) : (idx += 1) {
        nodes[idx] = .{ .value = idx };
    }

    idx = 0;
    while (idx < nodes.len) : (idx += 1) {
        const tag: u3 = @intCast(idx);
        const node_ptr: *align(8) TestNode = @ptrCast(&nodes[idx]);
        var tagged = try Ptr.new(node_ptr, tag);
        try std.testing.expectEqual(@as(u3, tag), @as(u3, @intCast(tagged.getTag())));
        try std.testing.expectEqual(node_ptr, tagged.getPtr());
    }
}

test "TaggedPointer raw bits roundtrip across multiple nodes" {
    // Store multiple tagged pointers as raw integers and rebuild them later.
    const Ptr = TaggedPointer(NodePtr, 2);
    var nodes: [3]TestNode = undefined;
    var idx: usize = 0;
    while (idx < nodes.len) : (idx += 1) {
        nodes[idx] = .{ .value = 10 * (idx + 1) };
    }
    var storage: [3]usize = undefined;

    idx = 0;
    while (idx < storage.len) : (idx += 1) {
        const tag: u2 = @intCast(idx);
        var tagged = try Ptr.new(@ptrCast(&nodes[idx]), tag);
        storage[idx] = tagged.toUnsigned();
    }

    idx = 0;
    while (idx < storage.len) : (idx += 1) {
        const restored = Ptr.fromUnsigned(storage[idx]);
        try std.testing.expectEqual(@as(u2, @intCast(idx)), @as(u2, @intCast(restored.getTag())));
        try std.testing.expectEqual(@as(NodePtr, @ptrCast(&nodes[idx])), restored.getPtr());
    }
}
