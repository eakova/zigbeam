//! Tiny, copy/paste-ready tagged-pointer examples.
//! Goal: show how to encode bits, store them, then decode.

const std = @import("std");
const TaggedPointer = @import("tagged-pointer").TaggedPointer;

/// Payload we will point to while sneaking 1 bit of metadata into the pointer.
const Block = struct {
    payload: usize,
};

/// Step-by-step encode helper.
/// 1. Wrap the raw pointer with `TaggedPointer`.
/// 2. Store the boolean `kind` flag in the lowest free bit.
/// 3. Return the combined `usize` so it can be stored anywhere.
pub fn exampleEncodePointer(block: *Block, kind: u1) !usize {
    const Ptr = TaggedPointer(*Block, 1);
    const tagged = try Ptr.new(block, kind);
    return tagged.toUnsigned();
}

/// Step-by-step decode helper.
/// 1. Rebuild the tagged pointer from the raw `usize`.
/// 2. Split it back into pointer + tag for callers.
pub fn exampleDecodePointer(bits: usize) struct { ptr: *Block, kind: u1 } {
    const Ptr = TaggedPointer(*Block, 1);
    const tagged = Ptr.fromUnsigned(bits);
    return .{ .ptr = tagged.getPtr(), .kind = @intCast(tagged.getTag()) };
}

pub fn main() !void {
    // Keep the main entry point short: encode -> decode -> print.
    var block = Block{ .payload = 42 };
    const encoded = try exampleEncodePointer(&block, 1);
    const decoded = exampleDecodePointer(encoded);
    std.debug.print("Tagged pointer sample -> payload={}, kind={}\n", .{ decoded.ptr.payload, decoded.kind });
}

test "sample: encode + decode" {
    var block = Block{ .payload = 11 };
    const ptr: *Block = &block;
    const bits = try exampleEncodePointer(ptr, 1);
    const decoded = exampleDecodePointer(bits);
    try std.testing.expectEqual(ptr, decoded.ptr);
    try std.testing.expectEqual(@as(u1, 1), decoded.kind);
}
