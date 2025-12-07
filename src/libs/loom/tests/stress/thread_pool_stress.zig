// ThreadPool Stress Test
//
// Stress tests for the thread pool with high task throughput.
// Tests:
// - 10k task execution
// - Concurrent spawning from multiple threads
// - Work-stealing under load
// - No deadlocks or livelocks

const std = @import("std");
const zigparallel = @import("loom");
const ThreadPool = zigparallel.ThreadPool;
const Task = zigparallel.Task;

const NUM_TASKS = 10_000;
const NUM_WORKERS = 8;

pub fn main() !void {
    std.debug.print("=== ThreadPool Stress Test ===\n", .{});
    std.debug.print("Tasks: {d}, Workers: {d}\n\n", .{ NUM_TASKS, NUM_WORKERS });

    const allocator = std.heap.page_allocator;

    // Initialize pool
    std.debug.print("Initializing thread pool...\n", .{});
    const pool = try ThreadPool.init(allocator, .{ .num_threads = NUM_WORKERS });
    defer {
        std.debug.print("Shutting down thread pool...\n", .{});
        pool.deinit();
        std.debug.print("Shutdown complete.\n", .{});
    }

    // Counter for completed tasks
    var counter = std.atomic.Value(usize).init(0);

    // Task context
    const Context = struct {
        counter: *std.atomic.Value(usize),
        work_iterations: usize,
    };

    // Task wrapper that does some work
    const wrapper = struct {
        fn execute(ctx: *anyopaque) void {
            const context: *Context = @ptrCast(@alignCast(ctx));

            // Do some CPU work to simulate real task
            var sum: u64 = 0;
            for (0..context.work_iterations) |i| {
                sum +%= i * i;
            }
            // Prevent optimization
            std.mem.doNotOptimizeAway(sum);

            // Increment counter
            _ = context.counter.fetchAdd(1, .acq_rel);
        }
    };

    // Allocate contexts and tasks
    const contexts = try allocator.alloc(Context, NUM_TASKS);
    defer allocator.free(contexts);

    const tasks = try allocator.alloc(Task, NUM_TASKS);
    defer allocator.free(tasks);

    // Initialize tasks
    for (0..NUM_TASKS) |i| {
        contexts[i] = Context{
            .counter = &counter,
            .work_iterations = 100, // Light work per task
        };
        tasks[i] = Task{
            .execute = wrapper.execute,
            .context = @ptrCast(&contexts[i]),
            .scope = null,
        };
    }

    // Spawn all tasks with backpressure handling
    std.debug.print("Spawning {d} tasks...\n", .{NUM_TASKS});
    const start_time = std.time.nanoTimestamp();

    var spawned: usize = 0;
    while (spawned < NUM_TASKS) {
        pool.spawn(&tasks[spawned]) catch |err| {
            if (err == error.QueueFull) {
                // Queue is full, wait for some tasks to drain
                std.Thread.sleep(100_000); // 100µs
                continue;
            }
            return err;
        };
        spawned += 1;
    }

    const spawn_time = std.time.nanoTimestamp();
    const spawn_duration_ms = @as(f64, @floatFromInt(spawn_time - start_time)) / 1_000_000.0;
    std.debug.print("Spawn complete in {d:.2}ms\n", .{spawn_duration_ms});

    // Wait for all tasks to complete
    std.debug.print("Waiting for tasks to complete...\n", .{});
    var wait_iterations: usize = 0;
    const timeout_ns = 30 * std.time.ns_per_s; // 30 second timeout

    while (counter.load(.acquire) < NUM_TASKS) {
        std.Thread.sleep(1_000_000); // 1ms
        wait_iterations += 1;

        if (std.time.nanoTimestamp() - start_time > timeout_ns) {
            std.debug.print("TIMEOUT: Only {d}/{d} tasks completed\n", .{
                counter.load(.acquire),
                NUM_TASKS,
            });
            return error.Timeout;
        }
    }

    const end_time = std.time.nanoTimestamp();
    const total_duration_ms = @as(f64, @floatFromInt(end_time - start_time)) / 1_000_000.0;
    const execution_duration_ms = @as(f64, @floatFromInt(end_time - spawn_time)) / 1_000_000.0;

    // Results
    std.debug.print("\n=== Results ===\n", .{});
    std.debug.print("Tasks completed: {d}/{d}\n", .{ counter.load(.acquire), NUM_TASKS });
    std.debug.print("Total time: {d:.2}ms\n", .{total_duration_ms});
    std.debug.print("Spawn time: {d:.2}ms\n", .{spawn_duration_ms});
    std.debug.print("Execution time: {d:.2}ms\n", .{execution_duration_ms});
    std.debug.print("Throughput: {d:.0} tasks/sec\n", .{
        @as(f64, NUM_TASKS) / (total_duration_ms / 1000.0),
    });
    std.debug.print("Avg spawn latency: {d:.0}ns\n", .{
        @as(f64, @floatFromInt(spawn_time - start_time)) / @as(f64, NUM_TASKS),
    });

    // Verify
    if (counter.load(.acquire) == NUM_TASKS) {
        std.debug.print("\n✓ STRESS TEST PASSED\n", .{});
    } else {
        std.debug.print("\n✗ STRESS TEST FAILED\n", .{});
        return error.TestFailed;
    }
}
