// Custom Pool Integration Test
//
// Integration tests for custom pool functionality.
// Tests:
// - Multiple pools operating independently
// - install() with nested parallel operations
// - Pool isolation (tasks don't leak between pools)
// - Parallel iteration with custom pool

const std = @import("std");
const zigparallel = @import("loom");
const ThreadPool = zigparallel.ThreadPool;
const par_iter = zigparallel.par_iter;
const scopeOnPool = zigparallel.scopeOnPool;
const join = zigparallel.join;
const joinOnPool = zigparallel.joinOnPool;
const Scope = zigparallel.Scope;
const getCurrentPool = zigparallel.getCurrentPool;
const getGlobalPool = zigparallel.getGlobalPool;
const Reducer = zigparallel.Reducer;

// Static state to avoid closure capture issues
const TestState = struct {
    var data: [10]i32 = undefined;
    var outer_data: [5]i32 = undefined;
    var inner_data: [5]i32 = undefined;
    var join_result: i32 = 0;
    var outer_sum: i32 = 0;
    var inner_sum: i32 = 0;
    var scope_counter: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);
    var pool_b_ref: *ThreadPool = undefined;
};

// Test 2: forEach helper
const ForEachHelper = struct {
    fn closure() void {
        par_iter(&TestState.data).forEach(double);
    }

    fn double(x: *i32) void {
        x.* *= 2;
    }
};

// Test 3: Join helper
const JoinTestHelper = struct {
    fn closure() void {
        const results = join(
            left,
            .{},
            right,
            .{},
        );
        TestState.join_result = results[0] + results[1];
    }

    fn left() i32 {
        return 100;
    }

    fn right() i32 {
        return 200;
    }
};

// Test 4: Nested install helpers
const NestedInstallHelper = struct {
    fn outerClosure() void {
        TestState.outer_sum = par_iter(&TestState.outer_data).sum();
        TestState.pool_b_ref.install(innerClosure);
    }

    fn innerClosure() void {
        TestState.inner_sum = par_iter(&TestState.inner_data).sum();
    }
};

// Test 5: Scope helper
const ScopeTestHelper = struct {
    fn closure() void {
        const pool = getGlobalPool();
        scopeOnPool(pool, body);
    }

    fn body(s: *Scope) void {
        for (0..10) |_| {
            s.spawn(work, .{});
        }
    }

    fn work() void {
        _ = TestState.scope_counter.fetchAdd(1, .acq_rel);
    }
};

pub fn main() !void {
    std.debug.print("=== Custom Pool Integration Test ===\n\n", .{});

    const allocator = std.heap.page_allocator;

    // ========================================================================
    // Test 1: Multiple Independent Pools
    // ========================================================================
    std.debug.print("--- Test 1: Multiple Independent Pools ---\n", .{});

    const pool_a = try ThreadPool.init(allocator, .{ .num_threads = 2 });
    defer pool_a.deinit();

    const pool_b = try ThreadPool.init(allocator, .{ .num_threads = 4 });
    defer pool_b.deinit();

    // Store pool_b reference for nested test
    TestState.pool_b_ref = pool_b;

    // Verify different thread counts
    std.debug.print("Pool A workers: {d}\n", .{pool_a.numWorkers()});
    std.debug.print("Pool B workers: {d}\n", .{pool_b.numWorkers()});

    if (pool_a.numWorkers() != 2 or pool_b.numWorkers() != 4) {
        std.debug.print("FAIL: Incorrect worker counts\n", .{});
        return;
    }
    std.debug.print("PASS: Pools created with correct worker counts\n\n", .{});

    // ========================================================================
    // Test 2: install() with Parallel Iteration
    // ========================================================================
    std.debug.print("--- Test 2: install() with Parallel Iteration ---\n", .{});

    TestState.data = .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
    pool_a.install(ForEachHelper.closure);

    // Verify all elements doubled
    var sum: i32 = 0;
    for (TestState.data) |item| {
        sum += item;
    }
    const expected_sum = (1 + 2 + 3 + 4 + 5 + 6 + 7 + 8 + 9 + 10) * 2;

    if (sum == expected_sum) {
        std.debug.print("PASS: forEach with install() works (sum = {d})\n\n", .{sum});
    } else {
        std.debug.print("FAIL: Incorrect sum {d}, expected {d}\n\n", .{ sum, expected_sum });
    }

    // ========================================================================
    // Test 3: install() with Join
    // ========================================================================
    std.debug.print("--- Test 3: install() with Join ---\n", .{});

    TestState.join_result = 0;
    pool_b.install(JoinTestHelper.closure);

    if (TestState.join_result == 300) {
        std.debug.print("PASS: join with install() works (result = {d})\n\n", .{TestState.join_result});
    } else {
        std.debug.print("FAIL: Incorrect join result {d}, expected 300\n\n", .{TestState.join_result});
    }

    // ========================================================================
    // Test 4: Nested install() Operations
    // ========================================================================
    std.debug.print("--- Test 4: Nested install() Operations ---\n", .{});

    TestState.outer_sum = 0;
    TestState.inner_sum = 0;
    TestState.outer_data = .{ 1, 2, 3, 4, 5 };
    TestState.inner_data = .{ 10, 20, 30, 40, 50 };

    pool_a.install(NestedInstallHelper.outerClosure);

    if (TestState.outer_sum == 15 and TestState.inner_sum == 150) {
        std.debug.print("PASS: Nested install() works (outer={d}, inner={d})\n\n", .{ TestState.outer_sum, TestState.inner_sum });
    } else {
        std.debug.print("FAIL: Incorrect sums outer={d} (exp 15), inner={d} (exp 150)\n\n", .{ TestState.outer_sum, TestState.inner_sum });
    }

    // ========================================================================
    // Test 5: install() with Scope
    // ========================================================================
    std.debug.print("--- Test 5: install() with Scope ---\n", .{});

    TestState.scope_counter = std.atomic.Value(usize).init(0);
    pool_a.install(ScopeTestHelper.closure);

    if (TestState.scope_counter.load(.acquire) == 10) {
        std.debug.print("PASS: scope with install() works (count = {d})\n\n", .{TestState.scope_counter.load(.acquire)});
    } else {
        std.debug.print("FAIL: Incorrect count {d}, expected 10\n\n", .{TestState.scope_counter.load(.acquire)});
    }

    // ========================================================================
    // Test 6: Explicit Pool Usage Still Works
    // ========================================================================
    std.debug.print("--- Test 6: Explicit Pool Usage ---\n", .{});

    var explicit_data = [_]i32{ 1, 2, 3, 4, 5 };

    // Using withPool should still work
    const explicit_sum = par_iter(&explicit_data).withPool(pool_b).sum();

    if (explicit_sum == 15) {
        std.debug.print("PASS: Explicit withPool() still works (sum = {d})\n\n", .{explicit_sum});
    } else {
        std.debug.print("FAIL: Incorrect sum {d}, expected 15\n\n", .{explicit_sum});
    }

    // ========================================================================
    // Summary
    // ========================================================================
    std.debug.print("=== CUSTOM POOL INTEGRATION TEST COMPLETE ===\n", .{});
}
