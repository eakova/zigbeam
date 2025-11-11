const std = @import("std");
const TaggedPointer = @import("tagged_pointer.zig").TaggedPointer;

const Block = struct {
    payload: usize,
};

pub fn exampleEncodePointer(block: *Block, kind: u1) !usize {
    const Ptr = TaggedPointer(*Block, 1);
    const tagged = try Ptr.new(block, kind);
    return tagged.toUnsigned();
}

pub fn exampleDecodePointer(bits: usize) struct { ptr: *Block, kind: u1 } {
    const Ptr = TaggedPointer(*Block, 1);
    const tagged = Ptr.fromUnsigned(bits);
    return .{ .ptr = tagged.getPtr(), .kind = @intCast(tagged.getTag()) };
}

test "sample: encode + decode" {
    var block = Block{ .payload = 11 };
    const ptr: *Block = &block;
    const bits = try exampleEncodePointer(ptr, 1);
    const decoded = exampleDecodePointer(bits);
    try std.testing.expectEqual(ptr, decoded.ptr);
    try std.testing.expectEqual(@as(u1, 1), decoded.kind);
}
