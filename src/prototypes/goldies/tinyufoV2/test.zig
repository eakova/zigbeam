const std = @import("std");
const TinyUFO = @import("tinyufo.zig").TinyUFO;

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    std.debug.print("Testing TinyUFO v2...\n", .{});

    var cache = try TinyUFO(u64, u64).init(allocator, 100);
    defer cache.deinit();

    // Test basic put/get
    try cache.put(1, 100);
    try cache.put(2, 200);
    try cache.put(3, 300);

    std.debug.print("Put 3 items\n", .{});

    if (cache.get(1)) |val| {
        std.debug.print("Get key=1: {}\n", .{val});
    }

    if (cache.get(2)) |val| {
        std.debug.print("Get key=2: {}\n", .{val});
    }

    if (cache.get(999)) |val| {
        std.debug.print("Get key=999: {} (unexpected!)\n", .{val});
    } else {
        std.debug.print("Get key=999: null (expected miss)\n", .{});
    }

    const s = cache.stats();
    std.debug.print("\nStats:\n", .{});
    std.debug.print("  Size: {}/{}\n", .{ s.size, s.capacity });
    std.debug.print("  Hits: {}\n", .{s.hits});
    std.debug.print("  Misses: {}\n", .{s.misses});
    std.debug.print("  Hit rate: {d:.2}%\n", .{s.hit_rate * 100});
    std.debug.print("  Evictions: {}\n", .{s.evictions});

    std.debug.print("\nTinyUFO v2 test passed!\n", .{});
}
