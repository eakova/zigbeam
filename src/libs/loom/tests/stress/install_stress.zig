// Install Stress Test
//
// Stress tests for install() with nested parallel regions.
// Tests:
// - Many nested install() calls
// - Concurrent installs on different pools
// - Context restoration under load
// - Nested parallelism with different pools

const std = @import("std");
const zigparallel = @import("loom");
const ThreadPool = zigparallel.ThreadPool;
const par_iter = zigparallel.par_iter;
const scopeOnPool = zigparallel.scopeOnPool;
const join = zigparallel.join;
const Scope = zigparallel.Scope;
const getCurrentPool = zigparallel.getCurrentPool;
const getGlobalPool = zigparallel.getGlobalPool;

const NUM_ITERATIONS = 100;
const NUM_POOLS = 4;

// Static state for stress tests (needed because Zig doesn't support closures capturing mutable state)
const TestState = struct {
    var pools: [NUM_POOLS]*ThreadPool = undefined;
    var total_sum: i64 = 0;
    var join_total: i32 = 0;
    var scope_counter: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);
    var error_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);
};

// Nested install test helpers
const Level3 = struct {
    fn execute() void {
        if (getCurrentPool() != TestState.pools[3]) {
            std.debug.print("ERROR: Wrong pool at level 3\n", .{});
            _ = TestState.error_count.fetchAdd(1, .acq_rel);
        }

        // Do some work at deepest level
        var data = [_]i32{ 1, 2, 3, 4, 5 };
        const sum = par_iter(&data).sum();
        std.mem.doNotOptimizeAway(sum);
    }
};

const Level2 = struct {
    fn execute() void {
        if (getCurrentPool() != TestState.pools[2]) {
            std.debug.print("ERROR: Wrong pool at level 2\n", .{});
            _ = TestState.error_count.fetchAdd(1, .acq_rel);
        }

        TestState.pools[3].install(Level3.execute);

        // Verify context restored
        if (getCurrentPool() != TestState.pools[2]) {
            std.debug.print("ERROR: Context not restored after level 3\n", .{});
            _ = TestState.error_count.fetchAdd(1, .acq_rel);
        }
    }
};

const Level1 = struct {
    fn execute() void {
        if (getCurrentPool() != TestState.pools[1]) {
            std.debug.print("ERROR: Wrong pool at level 1\n", .{});
            _ = TestState.error_count.fetchAdd(1, .acq_rel);
        }

        TestState.pools[2].install(Level2.execute);

        // Verify context restored
        if (getCurrentPool() != TestState.pools[1]) {
            std.debug.print("ERROR: Context not restored after level 2\n", .{});
            _ = TestState.error_count.fetchAdd(1, .acq_rel);
        }
    }
};

const Level0 = struct {
    fn execute() void {
        if (getCurrentPool() != TestState.pools[0]) {
            std.debug.print("ERROR: Wrong pool at level 0\n", .{});
            _ = TestState.error_count.fetchAdd(1, .acq_rel);
        }

        TestState.pools[1].install(Level1.execute);

        // Verify context restored
        if (getCurrentPool() != TestState.pools[0]) {
            std.debug.print("ERROR: Context not restored after level 1\n", .{});
            _ = TestState.error_count.fetchAdd(1, .acq_rel);
        }
    }
};

// Test 2: Parallel work helper
const ParallelWorkHelper = struct {
    fn work() void {
        var data = [_]i64{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
        const sum = par_iter(&data).sum();
        // Use atomic add since multiple iterations may overlap
        _ = @atomicRmw(i64, &TestState.total_sum, .Add, sum, .acq_rel);
    }
};

// Test 3: Join helper
const JoinHelper = struct {
    fn work() void {
        const results = join(
            left,
            .{},
            right,
            .{},
        );
        _ = @atomicRmw(i32, &TestState.join_total, .Add, results[0] + results[1], .acq_rel);
    }

    fn left() i32 {
        return 10;
    }

    fn right() i32 {
        return 20;
    }
};

// Test 4: Scope helper
const ScopeHelper = struct {
    fn work() void {
        const current = getGlobalPool();
        scopeOnPool(current, body);
    }

    fn body(s: *Scope) void {
        s.spawn(task, .{});
    }

    fn task() void {
        _ = TestState.scope_counter.fetchAdd(1, .acq_rel);
    }
};

pub fn main() !void {
    std.debug.print("=== Install Stress Test ===\n", .{});
    std.debug.print("Iterations: {d}, Pools: {d}\n\n", .{ NUM_ITERATIONS, NUM_POOLS });

    const allocator = std.heap.page_allocator;

    // Create multiple pools
    for (0..NUM_POOLS) |i| {
        TestState.pools[i] = try ThreadPool.init(allocator, .{ .num_threads = @intCast(2 + i) });
    }
    defer {
        for (TestState.pools) |pool| {
            pool.deinit();
        }
    }

    std.debug.print("Pools created:\n", .{});
    for (TestState.pools, 0..) |pool, i| {
        std.debug.print("  Pool {d}: {d} workers\n", .{ i, pool.numWorkers() });
    }
    std.debug.print("\n", .{});

    // ========================================================================
    // Test 1: Nested install() stress
    // ========================================================================
    std.debug.print("--- Test 1: Nested install() Stress ---\n", .{});

    TestState.error_count = std.atomic.Value(usize).init(0);
    const nest_start = std.time.nanoTimestamp();

    for (0..NUM_ITERATIONS) |_| {
        TestState.pools[0].install(Level0.execute);
    }

    const nest_end = std.time.nanoTimestamp();
    const nest_ms = @as(f64, @floatFromInt(nest_end - nest_start)) / 1_000_000.0;

    const nest_errors = TestState.error_count.load(.acquire);
    if (nest_errors == 0) {
        std.debug.print("Completed {d} nested install iterations in {d:.2}ms\n", .{ NUM_ITERATIONS, nest_ms });
        std.debug.print("PASS: Nested install() context correctly maintained\n\n", .{});
    } else {
        std.debug.print("FAIL: {d} errors during nested install\n\n", .{nest_errors});
    }

    // ========================================================================
    // Test 2: Install with parallel work
    // ========================================================================
    std.debug.print("--- Test 2: Install with Parallel Work ---\n", .{});

    TestState.total_sum = 0;
    const work_start = std.time.nanoTimestamp();

    for (0..NUM_ITERATIONS) |i| {
        const pool_idx = i % NUM_POOLS;
        const pool = TestState.pools[pool_idx];
        pool.install(ParallelWorkHelper.work);
    }

    const work_end = std.time.nanoTimestamp();
    const work_ms = @as(f64, @floatFromInt(work_end - work_start)) / 1_000_000.0;

    const expected_total: i64 = 55 * NUM_ITERATIONS;
    const actual_total = @atomicLoad(i64, &TestState.total_sum, .acquire);
    if (actual_total == expected_total) {
        std.debug.print("PASS: All parallel work completed correctly (sum = {d})\n", .{actual_total});
    } else {
        std.debug.print("FAIL: Incorrect total sum {d}, expected {d}\n", .{ actual_total, expected_total });
    }
    std.debug.print("Time: {d:.2}ms\n\n", .{work_ms});

    // ========================================================================
    // Test 3: Install with join
    // ========================================================================
    std.debug.print("--- Test 3: Install with Join ---\n", .{});

    TestState.join_total = 0;
    const join_start = std.time.nanoTimestamp();

    for (0..NUM_ITERATIONS) |i| {
        const pool_idx = i % NUM_POOLS;
        const pool = TestState.pools[pool_idx];
        pool.install(JoinHelper.work);
    }

    const join_end = std.time.nanoTimestamp();
    const join_ms = @as(f64, @floatFromInt(join_end - join_start)) / 1_000_000.0;

    const expected_join_total: i32 = 30 * NUM_ITERATIONS;
    const actual_join_total = @atomicLoad(i32, &TestState.join_total, .acquire);
    if (actual_join_total == expected_join_total) {
        std.debug.print("PASS: All join operations completed correctly (total = {d})\n", .{actual_join_total});
    } else {
        std.debug.print("FAIL: Incorrect join total {d}, expected {d}\n", .{ actual_join_total, expected_join_total });
    }
    std.debug.print("Time: {d:.2}ms\n\n", .{join_ms});

    // ========================================================================
    // Test 4: Install with scope
    // ========================================================================
    std.debug.print("--- Test 4: Install with Scope ---\n", .{});

    TestState.scope_counter = std.atomic.Value(usize).init(0);
    const scope_start = std.time.nanoTimestamp();

    for (0..NUM_ITERATIONS) |i| {
        const pool_idx = i % NUM_POOLS;
        const pool = TestState.pools[pool_idx];
        pool.install(ScopeHelper.work);
    }

    const scope_end = std.time.nanoTimestamp();
    const scope_ms = @as(f64, @floatFromInt(scope_end - scope_start)) / 1_000_000.0;

    const scope_count = TestState.scope_counter.load(.acquire);
    if (scope_count == NUM_ITERATIONS) {
        std.debug.print("PASS: All scope operations completed (count = {d})\n", .{scope_count});
    } else {
        std.debug.print("FAIL: Incorrect scope count {d}, expected {d}\n", .{ scope_count, NUM_ITERATIONS });
    }
    std.debug.print("Time: {d:.2}ms\n\n", .{scope_ms});

    // ========================================================================
    // Summary
    // ========================================================================
    std.debug.print("=== Results Summary ===\n", .{});
    std.debug.print("Nested install: {d:.2}ms ({d} errors)\n", .{ nest_ms, nest_errors });
    std.debug.print("Parallel work:  {d:.2}ms (sum = {d})\n", .{ work_ms, actual_total });
    std.debug.print("Join work:      {d:.2}ms (total = {d})\n", .{ join_ms, actual_join_total });
    std.debug.print("Scope work:     {d:.2}ms (count = {d})\n", .{ scope_ms, scope_count });

    const all_passed = (nest_errors == 0) and
        (actual_total == expected_total) and
        (actual_join_total == expected_join_total) and
        (scope_count == NUM_ITERATIONS);

    if (all_passed) {
        std.debug.print("\nINSTALL STRESS TEST PASSED\n", .{});
    } else {
        std.debug.print("\nINSTALL STRESS TEST FAILED\n", .{});
    }
}
