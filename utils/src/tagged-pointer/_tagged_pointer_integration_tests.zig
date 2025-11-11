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
