const std = @import("std");
const Task = @import("task.zig").Task;

// 1. Define your worker.
// First argument MUST be `Task.Context`.
fn myWorker(ctx: Task.Context, name: []const u8) void {
    std.debug.print("[{s}] Started.\n", .{name});

    var counter: i32 = 0;

    // Check cancelled() in your loop condition
    while (!ctx.cancelled()) {
        counter += 1;
        std.debug.print("[{s}] Working {d}...\n", .{ name, counter });

        // Smart Sleep: Replaces std.time.sleep
        // Returns true immediately if cancel() is called.
        if (ctx.sleep(500)) {
            std.debug.print("[{s}] Interrupted by Cancel!\n", .{name});
            break;
        }
    }

    std.debug.print("[{s}] Cleanup and Exit.\n", .{name});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();

    std.debug.print("Main: Spawning task...\n", .{});

    // 2. Spawn
    // Pass args as a tuple: .{ "Worker A" }
    const t = try Task.spawn(alloc, myWorker, .{"Worker A"});

    // Let it run for 1.2 seconds
    std.time.sleep(1200 * std.time.ns_per_ms);

    std.debug.print("Main: Calling cancel()...\n", .{});

    // 3. Cancel
    t.cancel();

    // 4. Wait (Join & Free)
    t.wait();

    std.debug.print("Main: Finished.\n", .{});
}
