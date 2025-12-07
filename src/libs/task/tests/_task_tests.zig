const std = @import("std");
const Task = @import("task").Task;

const AtomicBool = std.atomic.Value(bool);

test "Task.Context.sleep returns false when not cancelled (timeout path)" {
    const allocator = std.testing.allocator;

    const Worker = struct {
        fn run(ctx: Task.Context, result: *AtomicBool) void {
            const cancelled = ctx.sleep(10); // 10 ms, no external cancel
            // Store the result with release so the test thread sees it after join.
            result.store(cancelled, .release);
        }
    };

    var result = AtomicBool.init(true); // default to true; worker should overwrite to false

    var task = try Task.spawn(allocator, Worker.run, .{&result});
    defer task.wait();

    // Wait for worker to finish and then check the flag.
    task.wait();
    const value = result.load(.acquire);
    try std.testing.expect(value == false);
}

test "Task.cancel wakes sleeping task and sleep returns true" {
    const allocator = std.testing.allocator;

    const Worker = struct {
        fn run(ctx: Task.Context, result: *AtomicBool) void {
            // Long sleep that should be interrupted by cancel().
            const cancelled = ctx.sleep(60_000); // 60 seconds; test will cancel long before this
            result.store(cancelled, .release);
        }
    };

    var result = AtomicBool.init(false);

    var task = try Task.spawn(allocator, Worker.run, .{&result});

    // Give the worker a brief moment to start and enter sleep.
    std.Thread.sleep(5 * std.time.ns_per_ms);

    // Request cancellation; this should wake ctx.sleep.
    task.cancel();

    task.wait();
    const value = result.load(.acquire);
    try std.testing.expect(value == true);
}

test "Task.wait is idempotent" {
    const allocator = std.testing.allocator;

    const Worker = struct {
        fn run(ctx: Task.Context) void {
            // Minimal worker body; just ensure the thread can start and exit.
            _ = ctx;
        }
    };

    var task = try Task.spawn(allocator, Worker.run, .{});

    // First wait should join and free internal state.
    task.wait();
    // Second wait should be a no-op and must not crash or double-free.
    task.wait();
}
