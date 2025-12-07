// ThreadPool Unit Tests
//
// Tests for the core thread pool functionality (Layer 2).
// These tests verify:
// - Pool initialization and shutdown
// - Worker thread management
// - Task spawning and execution
// - Global pool singleton
// - Worker ID accessibility

const std = @import("std");
const testing = std.testing;

const zigparallel = @import("loom");
const ThreadPool = zigparallel.ThreadPool;
const Config = zigparallel.Config;
const InitConfig = zigparallel.InitConfig;
const Task = zigparallel.Task;
const getGlobalPool = zigparallel.getGlobalPool;
const getCurrentWorkerId = zigparallel.getCurrentWorkerId;

// ============================================================================
// Basic Lifecycle Tests
// ============================================================================

test "ThreadPool: init with explicit thread count" {
    const pool = try ThreadPool.init(testing.allocator, .{ .num_threads = 4 });
    defer pool.deinit();

    try testing.expectEqual(@as(usize, 4), pool.numWorkers());
}

test "ThreadPool: init with default thread count" {
    const pool = try ThreadPool.init(testing.allocator, .{});
    defer pool.deinit();

    // Issue 57 fix: Default is CPU count - 1 to leave one core for OS
    const cpu_count = std.Thread.getCpuCount() catch 2;
    const expected = @max(1, cpu_count -| 1);
    try testing.expectEqual(expected, pool.numWorkers());
}

test "ThreadPool: init and deinit without spawning tasks" {
    const pool = try ThreadPool.init(testing.allocator, .{ .num_threads = 2 });
    pool.deinit();
    // Should not hang or crash
}

// ============================================================================
// Task Execution Tests
// ============================================================================

test "ThreadPool: spawn and execute single task" {
    const pool = try ThreadPool.init(testing.allocator, .{ .num_threads = 2 });
    defer pool.deinit();

    var executed = std.atomic.Value(bool).init(false);

    const Context = struct {
        executed: *std.atomic.Value(bool),
    };

    const wrapper = struct {
        fn execute(ctx: *anyopaque) void {
            const context: *Context = @ptrCast(@alignCast(ctx));
            context.executed.store(true, .release);
        }
    };

    var context = Context{ .executed = &executed };
    var task = Task{
        .execute = wrapper.execute,
        .context = @ptrCast(&context),
        .scope = null,
    };

    try pool.spawn(&task);

    // Wait for task to complete (with timeout)
    var attempts: usize = 0;
    while (!executed.load(.acquire) and attempts < 1000) : (attempts += 1) {
        std.Thread.sleep(1_000_000); // 1ms
    }

    try testing.expect(executed.load(.acquire));
}

test "ThreadPool: spawn multiple tasks" {
    const pool = try ThreadPool.init(testing.allocator, .{ .num_threads = 4 });
    defer pool.deinit();

    const num_tasks = 100;
    var counter = std.atomic.Value(usize).init(0);

    const Context = struct {
        counter: *std.atomic.Value(usize),
    };

    const wrapper = struct {
        fn execute(ctx: *anyopaque) void {
            const context: *Context = @ptrCast(@alignCast(ctx));
            _ = context.counter.fetchAdd(1, .acq_rel);
        }
    };

    // Use heap allocation for stability
    const contexts = try testing.allocator.alloc(Context, num_tasks);
    defer testing.allocator.free(contexts);

    const tasks = try testing.allocator.alloc(Task, num_tasks);
    defer testing.allocator.free(tasks);

    for (0..num_tasks) |i| {
        contexts[i] = Context{ .counter = &counter };
        tasks[i] = Task{
            .execute = wrapper.execute,
            .context = @ptrCast(&contexts[i]),
            .scope = null,
        };
        try pool.spawn(&tasks[i]);
    }

    // Wait for all tasks to complete
    var attempts: usize = 0;
    while (counter.load(.acquire) < num_tasks and attempts < 5000) : (attempts += 1) {
        std.Thread.sleep(1_000_000); // 1ms
    }

    try testing.expectEqual(@as(usize, num_tasks), counter.load(.acquire));
}

// ============================================================================
// Worker ID Tests
// ============================================================================

test "getCurrentWorkerId: returns null outside worker thread" {
    try testing.expectEqual(@as(?usize, null), getCurrentWorkerId());
}

// ============================================================================
// Configuration Tests
// ============================================================================

test "Config: default values (comptime)" {
    const cfg = Config{};
    try testing.expectEqual(@as(usize, 256), cfg.local_capacity);
    try testing.expectEqual(@as(usize, 4096), cfg.global_capacity);
    try testing.expectEqual(false, cfg.enable_stats);
}

test "InitConfig: default values (runtime)" {
    const init_cfg = InitConfig{};
    try testing.expectEqual(@as(?usize, null), init_cfg.num_threads);
    try testing.expectEqual(@as(?usize, null), init_cfg.stack_size);
}

test "Config: custom values with ThreadPoolFn" {
    // Custom pool type with different capacities
    const CustomPool = zigparallel.ThreadPoolFn(.{
        .local_capacity = 512,
        .global_capacity = 8192,
        .enable_stats = true,
    });
    try testing.expectEqual(@as(usize, 512), CustomPool.pool_config.local_capacity);
    try testing.expectEqual(@as(usize, 8192), CustomPool.pool_config.global_capacity);
    try testing.expectEqual(true, CustomPool.pool_config.enable_stats);
}
