//! Integration tests that exercise `TaggedPointer` inside small helper types.
//! Focus: making real-world patterns (freelist flags, allocator-owned nodes)
//! obvious to newer contributors.

const std = @import("std");
const TaggedPointer = @import("tagged_pointer.zig").TaggedPointer;

const CacheNode = struct {
    value: usize,
};

const CachePtr = TaggedPointer(*CacheNode, 1);

const TaggedCache = struct {
    slots: [8]?usize = [_]?usize{null} ** 8,
    len: usize = 0,

    pub fn push(self: *TaggedCache, node: *CacheNode, tag: u1) void {
        const tagged = CachePtr.new(node, tag) catch unreachable;
        self.slots[self.len] = tagged.toUnsigned();
        self.len += 1;
    }

    pub fn pop(self: *TaggedCache) ?struct { node: *CacheNode, tag: u1 } {
        if (self.len == 0) return null;
        self.len -= 1;
        const bits = self.slots[self.len].?;
        self.slots[self.len] = null;
        const tagged = CachePtr.fromUnsigned(bits);
        return .{ .node = tagged.getPtr(), .tag = @intCast(tagged.getTag()) };
    }
};

test "TaggedPointer keeps freelist flag bits" {
    // Simulate a freelist where one tag bit indicates whether the slot is “hot”.
    var nodes: [2]CacheNode = .{ .{ .value = 1 }, .{ .value = 2 } };
    var cache = TaggedCache{};

    cache.push(&nodes[0], 0);
    cache.push(&nodes[1], 1);

    const first = cache.pop().?;
    try std.testing.expectEqual(@as(u1, 1), first.tag);
    try std.testing.expectEqual(@as(usize, 2), first.node.value);

    const second = cache.pop().?;
    try std.testing.expectEqual(@as(u1, 0), second.tag);
    try std.testing.expectEqual(@as(usize, 1), second.node.value);
}

test "TaggedPointer cooperates with allocator managed blocks" {
    // Prove we can tag pointers that came from a regular allocator.
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const block = try allocator.create(CacheNode);
    defer allocator.destroy(block);
    block.* = .{ .value = 123 };

    const tagged = try CachePtr.new(block, 1);
    try std.testing.expectEqual(@as(u1, 1), tagged.getTag());
    try std.testing.expectEqual(block, tagged.getPtr());

    const restored = CachePtr.fromUnsigned(tagged.toUnsigned());
    try std.testing.expectEqual(block, restored.getPtr());
}

test "TaggedPointer raw buffer shuffle remains consistent" {
    // Treat encoded pointers as raw integers, shuffle them, and rebuild.
    var nodes: [4]CacheNode = undefined;
    var idx: usize = 0;
    while (idx < nodes.len) : (idx += 1) {
        nodes[idx] = .{ .value = 10 * (idx + 1) };
    }
    var encoded: [4]usize = undefined;

    idx = 0;
    while (idx < nodes.len) : (idx += 1) {
        const tag: u1 = @intCast(idx % 2);
        const tagged = CachePtr.new(&nodes[idx], tag) catch unreachable;
        encoded[idx] = tagged.toUnsigned();
    }

    std.mem.reverse(usize, &encoded);

    idx = 0;
    while (idx < encoded.len) : (idx += 1) {
        const restored = CachePtr.fromUnsigned(encoded[idx]);
        const original_index = nodes.len - 1 - idx;
        try std.testing.expectEqual(@as(u1, @intCast(original_index % 2)), restored.getTag());
        try std.testing.expectEqual(@as(usize, nodes[original_index].value), restored.getPtr().value);
    }
}
