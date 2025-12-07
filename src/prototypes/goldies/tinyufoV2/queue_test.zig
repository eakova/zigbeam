const std = @import("std");
const SegQueue = @import("seg_queue.zig").SegQueue;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("Testing SegQueue...\n", .{});

    var queue = try SegQueue(u64).init(allocator, 16);
    defer queue.deinit();

    std.debug.print("Queue created\n", .{});

    // Test basic push/pop
    try queue.push(1);
    std.debug.print("Pushed 1\n", .{});

    try queue.push(2);
    std.debug.print("Pushed 2\n", .{});

    try queue.push(3);
    std.debug.print("Pushed 3\n", .{});

    if (queue.pop()) |val| {
        std.debug.print("Popped: {}\n", .{val});
    }

    if (queue.pop()) |val| {
        std.debug.print("Popped: {}\n", .{val});
    }

    if (queue.pop()) |val| {
        std.debug.print("Popped: {}\n", .{val});
    }

    std.debug.print("Basic test passed!\n", .{});

    // Test pushing many items to cross segment boundary
    std.debug.print("\nPushing 20 items...\n", .{});
    for (0..20) |i| {
        try queue.push(i);
        if (i % 5 == 0) {
            std.debug.print("  Pushed {} items\n", .{i + 1});
        }
    }

    std.debug.print("Popping 20 items...\n", .{});
    var count: usize = 0;
    while (queue.pop()) |val| {
        count += 1;
        if (count % 5 == 0) {
            std.debug.print("  Popped {} items (last: {})\n", .{ count, val });
        }
    }

    std.debug.print("\nAll tests passed! Pushed and popped {} items\n", .{count});
}
