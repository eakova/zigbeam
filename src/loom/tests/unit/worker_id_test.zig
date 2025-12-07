// Worker ID Accessibility Tests
//
// Tests for worker ID and pool context accessibility (Layer 2).
// These tests verify:
// - getCurrentWorkerId returns null outside worker threads
// - getCurrentWorkerId returns valid ID inside worker threads
// - getCurrentPool respects install() context
// - install() properly scopes pool context

const std = @import("std");
const testing = std.testing;

const zigparallel = @import("loom");
const ThreadPool = zigparallel.ThreadPool;
const getCurrentWorkerId = zigparallel.getCurrentWorkerId;
const getCurrentPool = zigparallel.getCurrentPool;
const getGlobalPool = zigparallel.getGlobalPool;
const scopeOnPool = zigparallel.scopeOnPool;
const Scope = zigparallel.Scope;
const join = zigparallel.join;

// ============================================================================
// getCurrentWorkerId Tests
// ============================================================================

test "getCurrentWorkerId: returns null from main thread" {
    // Main thread is not a worker
    try testing.expectEqual(@as(?usize, null), getCurrentWorkerId());
}

test "getCurrentWorkerId: returns valid ID inside scope task" {
    const pool = try ThreadPool.init(testing.allocator, .{ .num_threads = 4 });
    defer pool.deinit();

    const TestHelper = struct {
        var worker_ids: [4]?usize = .{ null, null, null, null };
        var observed_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);

        fn body(s: *Scope) void {
            // Spawn tasks that record their worker IDs
            for (0..4) |i| {
                s.spawn(work, .{i});
            }
        }

        fn work(idx: usize) void {
            const id = getCurrentWorkerId();
            worker_ids[idx] = id;
            _ = observed_count.fetchAdd(1, .acq_rel);
        }
    };

    // Reset state
    TestHelper.worker_ids = .{ null, null, null, null };
    TestHelper.observed_count = std.atomic.Value(usize).init(0);

    scopeOnPool(pool, TestHelper.body);

    // All tasks completed
    try testing.expectEqual(@as(usize, 4), TestHelper.observed_count.load(.acquire));

    // All worker IDs should be non-null and within range
    for (TestHelper.worker_ids) |maybe_id| {
        try testing.expect(maybe_id != null);
        const id = maybe_id.?;
        try testing.expect(id < 4);
    }
}

// ============================================================================
// getCurrentPool Tests
// ============================================================================

test "getCurrentPool: returns null without install" {
    // No pool installed
    try testing.expectEqual(@as(?*ThreadPool, null), getCurrentPool());
}

test "getCurrentPool: returns installed pool" {
    const pool = try ThreadPool.init(testing.allocator, .{ .num_threads = 2 });
    defer pool.deinit();

    // Use static struct to store observed value (avoids closure capture issue)
    const TestHelper = struct {
        var observed_pool: ?*ThreadPool = null;

        fn closure() void {
            observed_pool = getCurrentPool();
        }
    };

    TestHelper.observed_pool = null;
    pool.install(TestHelper.closure);

    try testing.expectEqual(pool, TestHelper.observed_pool.?);

    // Outside install(), should be null again
    try testing.expectEqual(@as(?*ThreadPool, null), getCurrentPool());
}

test "getCurrentPool: nested install restores correctly" {
    const pool1 = try ThreadPool.init(testing.allocator, .{ .num_threads = 2 });
    defer pool1.deinit();

    const pool2 = try ThreadPool.init(testing.allocator, .{ .num_threads = 2 });
    defer pool2.deinit();

    // Use static struct to store observed values
    const TestHelper = struct {
        var outer_pool: ?*ThreadPool = null;
        var inner_pool: ?*ThreadPool = null;
        var after_inner: ?*ThreadPool = null;
        var pool2_ref: *ThreadPool = undefined;

        fn outerClosure() void {
            outer_pool = getCurrentPool();

            pool2_ref.install(innerClosure);

            after_inner = getCurrentPool();
        }

        fn innerClosure() void {
            inner_pool = getCurrentPool();
        }
    };

    TestHelper.outer_pool = null;
    TestHelper.inner_pool = null;
    TestHelper.after_inner = null;
    TestHelper.pool2_ref = pool2;

    pool1.install(TestHelper.outerClosure);

    try testing.expectEqual(pool1, TestHelper.outer_pool.?);
    try testing.expectEqual(pool2, TestHelper.inner_pool.?);
    try testing.expectEqual(pool1, TestHelper.after_inner.?);
}

// ============================================================================
// getGlobalPool with install() Tests
// ============================================================================

test "getGlobalPool: respects install context" {
    const custom_pool = try ThreadPool.init(testing.allocator, .{ .num_threads = 2 });
    defer custom_pool.deinit();

    const TestHelper = struct {
        var pool_in_install: ?*ThreadPool = null;

        fn closure() void {
            // Inside install, getGlobalPool should return the installed pool
            pool_in_install = getGlobalPool();
        }
    };

    TestHelper.pool_in_install = null;
    custom_pool.install(TestHelper.closure);

    try testing.expectEqual(custom_pool, TestHelper.pool_in_install.?);
}

// ============================================================================
// join() with install() Tests
// ============================================================================

test "join: uses installed pool context" {
    const pool = try ThreadPool.init(testing.allocator, .{ .num_threads = 2 });
    defer pool.deinit();

    const TestHelper = struct {
        var left_result: i32 = 0;
        var right_result: i32 = 0;

        fn closure() void {
            // Inside install, join() should use the installed pool
            const result = join(
                leftTask,
                .{},
                rightTask,
                .{},
            );
            left_result = result[0];
            right_result = result[1];
        }

        fn leftTask() i32 {
            return 1;
        }

        fn rightTask() i32 {
            return 2;
        }
    };

    TestHelper.left_result = 0;
    TestHelper.right_result = 0;
    pool.install(TestHelper.closure);

    // Verify join completed with correct results
    try testing.expectEqual(@as(i32, 1), TestHelper.left_result);
    try testing.expectEqual(@as(i32, 2), TestHelper.right_result);
}

// ============================================================================
// Worker ID Range Tests
// ============================================================================

test "worker IDs are unique and in range" {
    const num_workers = 4;
    const pool = try ThreadPool.init(testing.allocator, .{ .num_threads = num_workers });
    defer pool.deinit();

    const TestHelper = struct {
        var id_counts: [4]std.atomic.Value(usize) = .{
            std.atomic.Value(usize).init(0),
            std.atomic.Value(usize).init(0),
            std.atomic.Value(usize).init(0),
            std.atomic.Value(usize).init(0),
        };

        fn body(s: *Scope) void {
            for (0..100) |_| {
                s.spawn(work, .{});
            }
        }

        fn work() void {
            if (getCurrentWorkerId()) |id| {
                if (id < 4) {
                    _ = id_counts[id].fetchAdd(1, .acq_rel);
                }
            }
        }
    };

    // Reset state
    for (&TestHelper.id_counts) |*count| {
        count.* = std.atomic.Value(usize).init(0);
    }

    // Spawn many tasks and count how many times each worker ID is seen
    scopeOnPool(pool, TestHelper.body);

    // Verify total count equals 100
    var total: usize = 0;
    for (&TestHelper.id_counts) |*count| {
        total += count.load(.acquire);
    }
    try testing.expectEqual(@as(usize, 100), total);
}
