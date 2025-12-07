// Parallel Sum Sample
//
// Demonstrates parallel reduction to sum a large array.
// Shows the basic usage of par_iter with reduce/sum operations.

const std = @import("std");
const zigparallel = @import("loom");
const par_iter = zigparallel.par_iter;
const ThreadPool = zigparallel.ThreadPool;
const Reducer = zigparallel.Reducer;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("=== Parallel Sum Sample ===\n\n", .{});

    // Create a thread pool
    const pool = try ThreadPool.init(allocator, .{ .num_threads = 4 });
    defer pool.deinit();

    // Create test data: 1..N
    const N: usize = 100_000;
    const data = try allocator.alloc(i64, N);
    defer allocator.free(data);

    for (data, 0..) |*item, i| {
        item.* = @intCast(i + 1);
    }

    std.debug.print("Array size: {d} elements\n", .{N});

    // Parallel sum using the convenience method
    const start1 = std.time.nanoTimestamp();
    const sum1 = par_iter(data).withPool(pool).sum();
    const end1 = std.time.nanoTimestamp();

    std.debug.print("\nMethod 1: sum()\n", .{});
    std.debug.print("  Result: {d}\n", .{sum1});
    std.debug.print("  Time: {d:.2}ms\n", .{
        @as(f64, @floatFromInt(end1 - start1)) / 1_000_000.0,
    });

    // Parallel sum using explicit reducer
    const start2 = std.time.nanoTimestamp();
    const sum2 = par_iter(data).withPool(pool).reduce(Reducer(i64).sum());
    const end2 = std.time.nanoTimestamp();

    std.debug.print("\nMethod 2: reduce(Reducer.sum())\n", .{});
    std.debug.print("  Result: {d}\n", .{sum2});
    std.debug.print("  Time: {d:.2}ms\n", .{
        @as(f64, @floatFromInt(end2 - start2)) / 1_000_000.0,
    });

    // Sequential sum for comparison
    const start3 = std.time.nanoTimestamp();
    var seq_sum: i64 = 0;
    for (data) |item| {
        seq_sum += item;
    }
    const end3 = std.time.nanoTimestamp();

    std.debug.print("\nSequential sum (baseline):\n", .{});
    std.debug.print("  Result: {d}\n", .{seq_sum});
    std.debug.print("  Time: {d:.2}ms\n", .{
        @as(f64, @floatFromInt(end3 - start3)) / 1_000_000.0,
    });

    // Other reducers
    std.debug.print("\n--- Other Reducers ---\n", .{});

    // Product (on smaller array to avoid overflow)
    var small_data = [_]i64{ 1, 2, 3, 4, 5 };
    const product = par_iter(&small_data).reduce(Reducer(i64).product());
    std.debug.print("Product of [1,2,3,4,5]: {d}\n", .{product});

    // Min
    const min_val = par_iter(data).reduce(Reducer(i64).min());
    std.debug.print("Min of array: {d}\n", .{min_val});

    // Max
    const max_val = par_iter(data).reduce(Reducer(i64).max());
    std.debug.print("Max of array: {d}\n", .{max_val});

    // Verification
    const n: i64 = @intCast(N);
    const expected = @divExact(n * (n + 1), 2);
    std.debug.print("\nExpected sum (n*(n+1)/2): {d}\n", .{expected});

    if (sum1 == expected and sum2 == expected and seq_sum == expected) {
        std.debug.print("\nAll results match expected value.\n", .{});
    } else {
        std.debug.print("\nERROR: Results don't match!\n", .{});
    }
}
