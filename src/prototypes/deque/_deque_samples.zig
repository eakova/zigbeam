const std = @import("std");
const deque_mod = @import("deque.zig");
const pool_mod = @import("deque_pool");
const Task = @import("task").Task;

/// Work-Stealing Deque & Thread Pool - Comprehensive Samples
///
/// This file contains comprehensive samples demonstrating:
/// 0. Chase-Lev deque (low-level API)
/// 1. Local pool with various features
/// 2. Global pool (singleton)
/// 3. Injector queue (external submissions)

// =============================================================================
// Sample 0: Chase-Lev Work-Stealing Deque (Low-Level API)
// =============================================================================

fn sample0_basic_deque() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const TaskItem = struct {
        id: usize,
        value: i32,
    };

    std.debug.print("\n=== Sample 0: Chase-Lev Deque (Low-Level) ===\n\n", .{});

    // --- Demo 0.1: Basic operations ---
    std.debug.print("--- 0.1: Basic Push/Pop/Steal ---\n", .{});

    var work_queue = try deque_mod.WorkStealingDeque(TaskItem).init(allocator);
    defer work_queue.deinit();

    std.debug.print("Owner: Pushing tasks 1-5\n", .{});
    try work_queue.push(TaskItem{ .id = 1, .value = 10 });
    try work_queue.push(TaskItem{ .id = 2, .value = 20 });
    try work_queue.push(TaskItem{ .id = 3, .value = 30 });
    try work_queue.push(TaskItem{ .id = 4, .value = 40 });
    try work_queue.push(TaskItem{ .id = 5, .value = 50 });

    std.debug.print("Deque size: {}\n\n", .{work_queue.size()});

    // Owner pops (LIFO - newest first)
    std.debug.print("Owner: Popping from bottom (LIFO)\n", .{});
    if (work_queue.pop()) |task| {
        std.debug.print("  Popped task {}: value = {}\n", .{ task.id, task.value });
    }
    if (work_queue.pop()) |task| {
        std.debug.print("  Popped task {}: value = {}\n\n", .{ task.id, task.value });
    }

    // Thieves steal (FIFO - oldest first)
    std.debug.print("Thief: Stealing from top (FIFO)\n", .{});
    if (work_queue.steal()) |task| {
        std.debug.print("  Stole task {}: value = {}\n", .{ task.id, task.value });
    }
    if (work_queue.steal()) |task| {
        std.debug.print("  Stole task {}: value = {}\n\n", .{ task.id, task.value });
    }

    std.debug.print("Remaining size: {}\n", .{work_queue.size()});

    // Owner takes the last item
    if (work_queue.pop()) |task| {
        std.debug.print("Owner: Got last task {}\n\n", .{task.id});
    }

    std.debug.print("Empty: {}\n\n", .{work_queue.isEmpty()});

    // --- Demo 0.2: Dynamic growth ---
    std.debug.print("--- 0.2: Dynamic Growth ---\n", .{});

    var large_queue = try deque_mod.WorkStealingDeque(usize).initCapacity(allocator, 4);
    defer large_queue.deinit();

    std.debug.print("Initial capacity: 4, pushing 100 items...\n", .{});
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        try large_queue.push(i);
    }

    std.debug.print("Size: {}\n", .{large_queue.size()});
    std.debug.print("All items pushed successfully (buffer grew automatically)!\n", .{});
    std.debug.print("\nChase-Lev deque: Lock-free, dynamic growth!\n", .{});
}

// =============================================================================
// Sample 1: Local Pool with Various Features
// =============================================================================

fn sample1_local_pool() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n=== Sample 1: Local Pool Features ===\n\n", .{});

    // Initialize LOCAL pool with 4 workers
    const pool = try pool_mod.WorkStealingPool.init(allocator, .{ .num_threads = 4 });
    defer pool.deinit();

    std.debug.print("Pool initialized with {} workers\n\n", .{pool.num_workers});

    // --- Demo 1.1: Basic task submission ---
    std.debug.print("--- 1.1: Basic Task Submission ---\n", .{});

    var counter = std.atomic.Value(usize).init(0);

    const worker_fn = struct {
        fn run(ctx: *std.atomic.Value(usize), id: usize) void {
            std.Thread.sleep(10 * std.time.ns_per_ms);
            _ = ctx.fetchAdd(1, .monotonic);
            std.debug.print("  Task {} completed on worker {?}\n", .{
                id,
                if (pool_mod.WorkStealingPool.currentWorker()) |w| w.id else null,
            });
        }
    }.run;

    std.debug.print("Submitting 20 tasks...\n", .{});
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        try pool.submit(try Task.init(allocator, worker_fn, .{ &counter, i }));
    }

    pool.waitIdle();
    std.debug.print("Completed: {} tasks\n\n", .{counter.load(.monotonic)});

    // --- Demo 1.2: Batch submission ---
    std.debug.print("--- 1.2: Batch Submission ---\n", .{});

    counter.store(0, .monotonic);

    var tasks: [100]Task = undefined;
    for (&tasks, 0..) |*task, idx| {
        task.* = try Task.init(allocator, worker_fn, .{ &counter, idx });
    }

    std.debug.print("Submitting 100 tasks in batch...\n", .{});
    try pool.submitBatch(&tasks);

    pool.waitIdle();
    std.debug.print("Completed: {} tasks\n\n", .{counter.load(.monotonic)});

    // --- Demo 1.3: Nested parallelism ---
    std.debug.print("--- 1.3: Nested Parallelism ---\n", .{});

    const nested_fn = struct {
        fn run(p: *pool_mod.WorkStealingPool, alloc: std.mem.Allocator, id: usize) void {
            std.debug.print("  Outer task {} spawning 3 nested tasks\n", .{id});

            var j: usize = 0;
            while (j < 3) : (j += 1) {
                const inner_fn = struct {
                    fn run2(outer_id: usize, inner_id: usize) void {
                        std.debug.print("    Inner task {}-{} running\n", .{ outer_id, inner_id });
                    }
                }.run2;

                p.submit(Task.init(alloc, inner_fn, .{ id, j }) catch unreachable) catch unreachable;
            }
        }
    }.run;

    std.debug.print("Submitting 5 outer tasks (15 total nested tasks)...\n", .{});
    i = 0;
    while (i < 5) : (i += 1) {
        try pool.submit(try Task.init(allocator, nested_fn, .{ pool, allocator, i }));
    }

    pool.waitIdle();
    std.debug.print("All nested tasks completed!\n\n", .{});

    // --- Demo 1.4: Work-stealing visualization ---
    std.debug.print("--- 1.4: Work-Stealing Visualization ---\n", .{});

    var work_counts = [_]std.atomic.Value(usize){
        std.atomic.Value(usize).init(0),
        std.atomic.Value(usize).init(0),
        std.atomic.Value(usize).init(0),
        std.atomic.Value(usize).init(0),
    };

    const stealing_fn = struct {
        fn run(counts: *[4]std.atomic.Value(usize)) void {
            if (pool_mod.WorkStealingPool.currentWorker()) |worker| {
                _ = counts[worker.id].fetchAdd(1, .monotonic);
            }
            std.Thread.sleep(5 * std.time.ns_per_ms);
        }
    }.run;

    std.debug.print("Submitting 50 tasks (will be stolen across workers)...\n", .{});
    i = 0;
    while (i < 50) : (i += 1) {
        try pool.submit(try Task.init(allocator, stealing_fn, .{&work_counts}));
    }

    pool.waitIdle();

    std.debug.print("\nWork distribution across workers:\n", .{});
    for (&work_counts, 0..) |*count, worker_id| {
        const work_done = count.load(.monotonic);
        std.debug.print("  Worker {}: {} tasks ({}%)\n", .{
            worker_id,
            work_done,
            (work_done * 100) / 50,
        });
    }

    std.debug.print("\nWork-stealing successfully balanced load!\n", .{});
}

// =============================================================================
// Sample 2: Global Pool (Singleton)
// =============================================================================

fn sample2_global_pool() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n=== Sample 2: Global Pool (Singleton) ===\n\n", .{});

    // Global pool auto-initializes on first use
    // Can also manually initialize with: pool_mod.initGlobalPool(allocator, .{})

    var counter = std.atomic.Value(usize).init(0);

    const worker_fn = struct {
        fn run(ctx: *std.atomic.Value(usize), id: usize) void {
            std.Thread.sleep(10 * std.time.ns_per_ms);
            _ = ctx.fetchAdd(1, .monotonic);
            std.debug.print("  Global pool task {} completed\n", .{id});
        }
    }.run;

    std.debug.print("Submitting 10 tasks to global pool...\n", .{});
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        try pool_mod.submit(try Task.init(allocator, worker_fn, .{ &counter, i }));
    }

    pool_mod.waitIdle();

    std.debug.print("\nCompleted: {} tasks\n", .{counter.load(.monotonic)});
    std.debug.print("Global pool workers: {}\n", .{pool_mod.getGlobalPool().num_workers});

    // Optional cleanup (not required for c_allocator)
    defer pool_mod.deinitGlobalPool();

    std.debug.print("Global pool: Auto-initialized, easy to use!\n", .{});
}

// =============================================================================
// Sample 3: Injector Queue (External Submissions)
// =============================================================================

fn sample3_injector() !void {
    const allocator = std.heap.c_allocator;

    std.debug.print("\n=== Sample 3: Injector Queue (External Submissions) ===\n\n", .{});

    var pool = try pool_mod.WorkStealingPool.initLocal(allocator, .{ .num_threads = 4 });
    defer pool.deinit();

    // --- Demo 3.1: External submissions ---
    std.debug.print("--- 3.1: External Thread Submissions ---\n", .{});

    var counter1 = std.atomic.Value(usize).init(0);
    const N1: usize = 50_000;

    std.debug.print("Main thread submitting {} tasks (via injector)...\n", .{N1});
    for (0..N1) |_| {
        try pool.submit(try Task.init(allocator, struct {
            fn run(c: *std.atomic.Value(usize)) void {
                _ = c.fetchAdd(1, .monotonic);
            }
        }.run, .{&counter1}));
    }

    pool.waitIdle();
    std.debug.print("External submit: processed = {} (expected {})\n\n", .{ counter1.load(.monotonic), N1 });

    // --- Demo 3.2: Worker fast-path (nested submissions) ---
    std.debug.print("--- 3.2: Worker Fast-Path (Nested) ---\n", .{});

    var counter2 = std.atomic.Value(usize).init(0);
    const N2_outer: usize = 1;
    const N2_inner: usize = 20_000;

    std.debug.print("Worker task spawning {} nested tasks (fast-path)...\n", .{N2_inner});

    for (0..N2_outer) |_| {
        try pool.submit(try Task.init(allocator, struct {
            fn run(p: *pool_mod.WorkStealingPool, c: *std.atomic.Value(usize)) void {
                var i: usize = 0;
                while (i < N2_inner) : (i += 1) {
                    p.submit(Task.init(std.heap.c_allocator, struct {
                        fn run(c2: *std.atomic.Value(usize)) void {
                            _ = c2.fetchAdd(1, .monotonic);
                        }
                    }.run, .{c}) catch @panic("alloc")) catch unreachable;
                }
            }
        }.run, .{ pool, &counter2 }));
    }

    pool.waitIdle();
    std.debug.print("Worker-enqueued: processed = {} (expected {})\n\n", .{ counter2.load(.monotonic), N2_outer * N2_inner });

    // --- Demo 3.3: Batch submission ---
    std.debug.print("--- 3.3: Batch Submission (Injector) ---\n", .{});

    var counter3 = std.atomic.Value(usize).init(0);
    const N3: usize = 40_000;

    std.debug.print("Batch submitting {} tasks...\n", .{N3});

    const tasks = try allocator.alloc(Task, N3);
    defer allocator.free(tasks);

    for (tasks) |*t| {
        t.* = try Task.init(allocator, struct {
            fn run(c: *std.atomic.Value(usize)) void {
                _ = c.fetchAdd(1, .monotonic);
            }
        }.run, .{&counter3});
    }

    try pool.submitBatch(tasks);
    pool.waitIdle();

    std.debug.print("Batch submit: processed = {} (expected {})\n", .{ counter3.load(.monotonic), N3 });
    std.debug.print("\nInjector queue: Efficient external + worker submissions!\n", .{});
}

// =============================================================================
// Main - Run All Samples
// =============================================================================

pub fn main() !void {
    std.debug.print("\n" ++ "=" ** 60 ++ "\n", .{});
    std.debug.print("  Work-Stealing Deque & Thread Pool - Comprehensive Samples\n", .{});
    std.debug.print("=" ** 60 ++ "\n", .{});

    try sample0_basic_deque();
    try sample1_local_pool();
    try sample2_global_pool();
    try sample3_injector();

    std.debug.print("\n" ++ "=" ** 60 ++ "\n", .{});
    std.debug.print("  All Samples Completed Successfully!\n", .{});
    std.debug.print("=" ** 60 ++ "\n\n", .{});
}
