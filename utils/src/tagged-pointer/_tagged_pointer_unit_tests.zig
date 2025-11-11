const std = @import("std");
const TaggedPointer = @import("tagged_pointer.zig").TaggedPointer;

const TestNode = struct {
    value: usize,
};

const NodePtr = *TestNode;

test "TaggedPointer basic operations" {
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
    var node = TestNode{ .value = 1 };
    const ptr: NodePtr = @ptrCast(&node);
    const Pointer = TaggedPointer(NodePtr, 1);

    try std.testing.expectError(error.TagTooLarge, Pointer.new(ptr, 2));
}

test "TaggedPointer preserves pointer bits when toggling tag" {
    var node = TestNode{ .value = 7 };
    const ptr: NodePtr = @ptrCast(&node);
    const Pointer = TaggedPointer(NodePtr, 1);

    var tagged = try Pointer.new(ptr, 0);
    tagged.setTag(1);
    tagged.setTag(0);
    try std.testing.expectEqual(ptr, tagged.getPtr());
}
