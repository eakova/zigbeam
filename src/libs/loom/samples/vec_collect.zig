// Vec Collect - Parallel Fold/Reduce Patterns
//
// Demonstrates various parallel reduction and aggregation patterns.
// Shows fold, reduce, and custom aggregation strategies.
//
// Key concepts:
// - Parallel fold/reduce
// - Custom reduction operators
// - Statistical aggregation
//
// Usage: zig build sample-vec-collect

const std = @import("std");
const zigparallel = @import("loom");
const par_iter = zigparallel.par_iter;
const ThreadPool = zigparallel.ThreadPool;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("╔═══════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║          Parallel Fold/Reduce Patterns                    ║\n", .{});
    std.debug.print("╚═══════════════════════════════════════════════════════════╝\n\n", .{});

    const pool = try ThreadPool.init(allocator, .{ .num_threads = 8 });
    defer pool.deinit();
    std.debug.print("Thread pool: 8 workers\n\n", .{});

    // ========================================================================
    // Basic reductions
    // ========================================================================
    std.debug.print("--- Basic Reductions ---\n", .{});
    {
        var data = [_]i32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
        std.debug.print("Data: ", .{});
        for (data) |v| std.debug.print("{d} ", .{v});
        std.debug.print("\n\n", .{});

        // Sum
        const sum = par_iter(&data).withPool(pool).sum();
        std.debug.print("  sum()     = {d} (expected: 55)\n", .{sum});

        // Product
        const product = par_iter(&data).withPool(pool).product();
        std.debug.print("  product() = {d} (expected: 3628800)\n", .{product});

        // Min
        const min_val = par_iter(&data).withPool(pool).min();
        std.debug.print("  min()     = {d} (expected: 1)\n", .{min_val});

        // Max
        const max_val = par_iter(&data).withPool(pool).max();
        std.debug.print("  max()     = {d} (expected: 10)\n", .{max_val});

        // Count
        const even_count = par_iter(&data).withPool(pool).count(struct {
            fn isEven(x: i32) bool {
                return @mod(x, 2) == 0;
            }
        }.isEven);
        std.debug.print("  count(even) = {d} (expected: 5)\n\n", .{even_count});
    }

    // ========================================================================
    // Large-scale reduction benchmark
    // ========================================================================
    std.debug.print("--- Benchmark: 10M element reductions ---\n", .{});
    {
        const n = 10_000_000;
        const data = try allocator.alloc(i64, n);
        defer allocator.free(data);
        for (data, 0..) |*v, i| {
            v.* = @intCast(i + 1);
        }

        // Sum benchmark
        const par_start = std.time.nanoTimestamp();
        const par_sum = par_iter(data).withPool(pool).sum();
        const par_end = std.time.nanoTimestamp();
        const par_ms = @as(f64, @floatFromInt(par_end - par_start)) / 1_000_000.0;

        const seq_start = std.time.nanoTimestamp();
        var seq_sum: i64 = 0;
        for (data) |v| seq_sum += v;
        const seq_end = std.time.nanoTimestamp();
        const seq_ms = @as(f64, @floatFromInt(seq_end - seq_start)) / 1_000_000.0;

        const expected = @as(i64, n) * (@as(i64, n) + 1) / 2; // n(n+1)/2
        const speedup = seq_ms / par_ms;

        std.debug.print("  Sum:\n", .{});
        std.debug.print("    Parallel:   {d:.2}ms (result: {d})\n", .{ par_ms, par_sum });
        std.debug.print("    Sequential: {d:.2}ms (result: {d})\n", .{ seq_ms, seq_sum });
        std.debug.print("    Expected:   {d}\n", .{expected});
        std.debug.print("    Speedup:    {d:.2}x\n\n", .{speedup});
    }

    // ========================================================================
    // Boolean predicates
    // ========================================================================
    std.debug.print("--- Boolean Predicates ---\n", .{});
    {
        var data = [_]i32{ 2, 4, 6, 8, 10 };
        std.debug.print("Data: ", .{});
        for (data) |v| std.debug.print("{d} ", .{v});
        std.debug.print("\n", .{});

        const all_even = par_iter(&data).withPool(pool).all(struct {
            fn isEven(x: i32) bool {
                return @mod(x, 2) == 0;
            }
        }.isEven);
        std.debug.print("  all(even) = {} (expected: true)\n", .{all_even});

        const any_gt_5 = par_iter(&data).withPool(pool).any(struct {
            fn gt5(x: i32) bool {
                return x > 5;
            }
        }.gt5);
        std.debug.print("  any(>5)   = {} (expected: true)\n", .{any_gt_5});

        const any_gt_20 = par_iter(&data).withPool(pool).any(struct {
            fn gt20(x: i32) bool {
                return x > 20;
            }
        }.gt20);
        std.debug.print("  any(>20)  = {} (expected: false)\n\n", .{any_gt_20});
    }

    // ========================================================================
    // Find operations
    // ========================================================================
    std.debug.print("--- Find Operations ---\n", .{});
    {
        var data = [_]i32{ 1, 3, 5, 7, 9, 11, 13, 15 };
        std.debug.print("Data: ", .{});
        for (data) |v| std.debug.print("{d} ", .{v});
        std.debug.print("\n", .{});

        // Find first element > 6
        const found = par_iter(&data).withPool(pool).find(struct {
            fn gt6(x: i32) bool {
                return x > 6;
            }
        }.gt6);
        if (found) |val| {
            std.debug.print("  find(>6) = {d}\n", .{val});
        } else {
            std.debug.print("  find(>6) = null\n", .{});
        }

        // Position of element == 11
        const pos = par_iter(&data).withPool(pool).position(struct {
            fn eq11(x: i32) bool {
                return x == 11;
            }
        }.eq11);
        if (pos) |idx| {
            std.debug.print("  position(==11) = {d}\n\n", .{idx});
        } else {
            std.debug.print("  position(==11) = null\n\n", .{});
        }
    }

    // ========================================================================
    // Custom reduce with integers
    // ========================================================================
    std.debug.print("--- Integer Statistics ---\n", .{});
    {
        var data = [_]i32{ 15, 25, 35, 45, 55, 65, 75, 85, 95, 105 };
        std.debug.print("Data: ", .{});
        for (data) |v| std.debug.print("{d} ", .{v});
        std.debug.print("\n", .{});

        // Sum and average
        const sum = par_iter(&data).withPool(pool).sum();
        const avg = @divFloor(sum, @as(i32, @intCast(data.len)));
        std.debug.print("  Sum:     {d}\n", .{sum});
        std.debug.print("  Average: {d}\n", .{avg});

        // Min and max
        const min_val = par_iter(&data).withPool(pool).min();
        const max_val = par_iter(&data).withPool(pool).max();
        std.debug.print("  Min:     {d}\n", .{min_val});
        std.debug.print("  Max:     {d}\n", .{max_val});
    }

    std.debug.print("\n╔═══════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║                    Sample Complete                         ║\n", .{});
    std.debug.print("╚═══════════════════════════════════════════════════════════╝\n", .{});
}
