const std = @import("std");
const TinyUFO = @import("tinyufo.zig").TinyUFO;

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    std.debug.print("Creating TinyUFO cache...\\n", .{});
    var cache = try TinyUFO(u64, u64).init(allocator, 100);
    defer cache.deinit();

    std.debug.print("Inserting 10 items...\\n", .{});
    for (0..10) |i| {
        try cache.put(i, i * 100);
        std.debug.print("  Put {}: {}\\n", .{i, i * 100});
    }

    std.debug.print("Getting items...\\n", .{});
    for (0..10) |i| {
        if (cache.get(i)) |val| {
            std.debug.print("  Get {}: {}\\n", .{i, val});
        }
    }

    std.debug.print("Success!\\n", .{});
}
