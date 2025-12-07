// Parallel Iterator Stress Test
//
// Stress tests for parallel iteration over large data sets.
// Tests:
// - 1M elements forEach
// - 1M elements parallel sum
// - 1M elements parallel map
// - Verify correctness under parallel execution
// - Performance comparison vs sequential

const std = @import("std");
const zigparallel = @import("loom");
const ThreadPool = zigparallel.ThreadPool;
const par_iter = zigparallel.par_iter;
const Splitter = zigparallel.Splitter;
const Reducer = zigparallel.Reducer;

const NUM_ELEMENTS: usize = 1_000_000;
const NUM_WORKERS = 8;

pub fn main() !void {
    std.debug.print("=== Parallel Iterator Stress Test ===\n", .{});
    std.debug.print("Elements: {d}, Workers: {d}\n\n", .{ NUM_ELEMENTS, NUM_WORKERS });

    const allocator = std.heap.page_allocator;

    // Initialize pool
    std.debug.print("Initializing thread pool...\n", .{});
    const pool = try ThreadPool.init(allocator, .{ .num_threads = NUM_WORKERS });
    defer {
        std.debug.print("Shutting down thread pool...\n", .{});
        pool.deinit();
        std.debug.print("Shutdown complete.\n", .{});
    }

    // Allocate test data
    std.debug.print("Allocating {d} elements...\n", .{NUM_ELEMENTS});
    const data = try allocator.alloc(i64, NUM_ELEMENTS);
    defer allocator.free(data);

    // Initialize data with values 1..N
    for (data, 0..) |*item, i| {
        item.* = @intCast(i + 1);
    }

    // ========================================================================
    // Test 1: Parallel forEach
    // ========================================================================
    std.debug.print("\n--- Test 1: Parallel forEach (double all elements) ---\n", .{});

    const forEach_start = std.time.nanoTimestamp();

    par_iter(data).withPool(pool).withSplitter(Splitter.fixed(10000)).forEach(struct {
        fn double(x: *i64) void {
            x.* *= 2;
        }
    }.double);

    const forEach_end = std.time.nanoTimestamp();
    const forEach_ms = @as(f64, @floatFromInt(forEach_end - forEach_start)) / 1_000_000.0;

    // Verify: first few elements should be 2, 4, 6, ...
    var forEach_correct = true;
    for (0..10) |i| {
        const expected: i64 = @intCast((i + 1) * 2);
        if (data[i] != expected) {
            std.debug.print("  ERROR: data[{d}] = {d}, expected {d}\n", .{ i, data[i], expected });
            forEach_correct = false;
        }
    }

    if (forEach_correct) {
        std.debug.print("  Verification: PASSED\n", .{});
    }
    std.debug.print("  Time: {d:.2}ms\n", .{forEach_ms});
    std.debug.print("  Throughput: {d:.2}M elements/sec\n", .{
        @as(f64, NUM_ELEMENTS) / forEach_ms / 1000.0,
    });

    // ========================================================================
    // Test 2: Parallel Sum
    // ========================================================================
    std.debug.print("\n--- Test 2: Parallel Sum ---\n", .{});

    // Reset data for sum test
    for (data, 0..) |*item, i| {
        item.* = @intCast(i + 1);
    }

    const sum_start = std.time.nanoTimestamp();

    const parallel_sum = par_iter(data).withPool(pool).withSplitter(Splitter.fixed(10000)).sum();

    const sum_end = std.time.nanoTimestamp();
    const sum_ms = @as(f64, @floatFromInt(sum_end - sum_start)) / 1_000_000.0;

    // Expected sum: n*(n+1)/2 for 1..n
    const n: i64 = @intCast(NUM_ELEMENTS);
    const expected_sum = @divExact(n * (n + 1), 2);

    if (parallel_sum == expected_sum) {
        std.debug.print("  Verification: PASSED (sum = {d})\n", .{parallel_sum});
    } else {
        std.debug.print("  Verification: FAILED (got {d}, expected {d})\n", .{ parallel_sum, expected_sum });
    }
    std.debug.print("  Time: {d:.2}ms\n", .{sum_ms});
    std.debug.print("  Throughput: {d:.2}M elements/sec\n", .{
        @as(f64, NUM_ELEMENTS) / sum_ms / 1000.0,
    });

    // ========================================================================
    // Test 3: Sequential Sum (for comparison)
    // ========================================================================
    std.debug.print("\n--- Test 3: Sequential Sum (baseline) ---\n", .{});

    const seq_start = std.time.nanoTimestamp();

    var sequential_sum: i64 = 0;
    for (data) |item| {
        sequential_sum += item;
    }

    const seq_end = std.time.nanoTimestamp();
    const seq_ms = @as(f64, @floatFromInt(seq_end - seq_start)) / 1_000_000.0;

    std.debug.print("  Time: {d:.2}ms\n", .{seq_ms});
    std.debug.print("  Throughput: {d:.2}M elements/sec\n", .{
        @as(f64, NUM_ELEMENTS) / seq_ms / 1000.0,
    });
    std.debug.print("  Parallel speedup: {d:.2}x\n", .{seq_ms / sum_ms});

    // ========================================================================
    // Test 4: Parallel Map
    // ========================================================================
    std.debug.print("\n--- Test 4: Parallel Map (square each element) ---\n", .{});

    const map_start = std.time.nanoTimestamp();

    const mapped = try par_iter(data).withPool(pool).withSplitter(Splitter.fixed(10000)).map(i64, struct {
        fn square(x: i64) i64 {
            return x * x;
        }
    }.square, allocator);
    defer allocator.free(mapped);

    const map_end = std.time.nanoTimestamp();
    const map_ms = @as(f64, @floatFromInt(map_end - map_start)) / 1_000_000.0;

    // Verify first few elements
    var map_correct = true;
    for (0..10) |i| {
        const expected: i64 = data[i] * data[i];
        if (mapped[i] != expected) {
            std.debug.print("  ERROR: mapped[{d}] = {d}, expected {d}\n", .{ i, mapped[i], expected });
            map_correct = false;
        }
    }

    if (map_correct) {
        std.debug.print("  Verification: PASSED\n", .{});
    }
    std.debug.print("  Time: {d:.2}ms\n", .{map_ms});
    std.debug.print("  Throughput: {d:.2}M elements/sec\n", .{
        @as(f64, NUM_ELEMENTS) / map_ms / 1000.0,
    });

    // ========================================================================
    // Test 5: Parallel forEachIndexed
    // ========================================================================
    std.debug.print("\n--- Test 5: Parallel forEachIndexed ---\n", .{});

    // Reset data
    for (data) |*item| {
        item.* = 0;
    }

    const indexed_start = std.time.nanoTimestamp();

    par_iter(data).withPool(pool).withSplitter(Splitter.fixed(10000)).forEachIndexed(struct {
        fn setFromIndex(i: usize, x: *i64) void {
            x.* = @intCast(i * 2);
        }
    }.setFromIndex);

    const indexed_end = std.time.nanoTimestamp();
    const indexed_ms = @as(f64, @floatFromInt(indexed_end - indexed_start)) / 1_000_000.0;

    // Verify
    var indexed_correct = true;
    for (0..10) |i| {
        const expected: i64 = @intCast(i * 2);
        if (data[i] != expected) {
            std.debug.print("  ERROR: data[{d}] = {d}, expected {d}\n", .{ i, data[i], expected });
            indexed_correct = false;
        }
    }

    if (indexed_correct) {
        std.debug.print("  Verification: PASSED\n", .{});
    }
    std.debug.print("  Time: {d:.2}ms\n", .{indexed_ms});
    std.debug.print("  Throughput: {d:.2}M elements/sec\n", .{
        @as(f64, NUM_ELEMENTS) / indexed_ms / 1000.0,
    });

    // ========================================================================
    // Results Summary
    // ========================================================================
    std.debug.print("\n=== Results Summary ===\n", .{});
    std.debug.print("forEach:        {d:.2}ms ({d:.2}M elem/sec)\n", .{ forEach_ms, @as(f64, NUM_ELEMENTS) / forEach_ms / 1000.0 });
    std.debug.print("sum (parallel): {d:.2}ms ({d:.2}M elem/sec)\n", .{ sum_ms, @as(f64, NUM_ELEMENTS) / sum_ms / 1000.0 });
    std.debug.print("sum (seq):      {d:.2}ms ({d:.2}M elem/sec)\n", .{ seq_ms, @as(f64, NUM_ELEMENTS) / seq_ms / 1000.0 });
    std.debug.print("map:            {d:.2}ms ({d:.2}M elem/sec)\n", .{ map_ms, @as(f64, NUM_ELEMENTS) / map_ms / 1000.0 });
    std.debug.print("forEachIndexed: {d:.2}ms ({d:.2}M elem/sec)\n", .{ indexed_ms, @as(f64, NUM_ELEMENTS) / indexed_ms / 1000.0 });

    const all_passed = forEach_correct and (parallel_sum == expected_sum) and map_correct and indexed_correct;

    if (all_passed) {
        std.debug.print("\nPARALLEL ITERATOR STRESS TEST PASSED\n", .{});
    } else {
        std.debug.print("\nPARALLEL ITERATOR STRESS TEST FAILED\n", .{});
    }
}
