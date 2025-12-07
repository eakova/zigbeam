// Map Collect - Parallel Transformation Patterns
//
// Demonstrates parallel map and collect patterns.
// Transform data in parallel and collect results.
//
// Key concepts:
// - Parallel map transformation
// - Collect into new container
// - Chain multiple operations
//
// Usage: zig build sample-map-collect

const std = @import("std");
const zigparallel = @import("loom");
const par_iter = zigparallel.par_iter;
const ThreadPool = zigparallel.ThreadPool;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("╔═══════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║          Parallel Map & Collect Patterns                  ║\n", .{});
    std.debug.print("╚═══════════════════════════════════════════════════════════╝\n\n", .{});

    const pool = try ThreadPool.init(allocator, .{ .num_threads = 8 });
    defer pool.deinit();
    std.debug.print("Thread pool: 8 workers\n\n", .{});

    // ========================================================================
    // Simple map: square each element
    // ========================================================================
    std.debug.print("--- Map: Square each element ---\n", .{});
    {
        var data = [_]i32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
        std.debug.print("Input:  ", .{});
        for (data) |v| std.debug.print("{d} ", .{v});
        std.debug.print("\n", .{});

        const squared = try par_iter(&data).withPool(pool).withAlloc(allocator).map(i64, struct {
            fn square(x: i32) i64 {
                return @as(i64, x) * @as(i64, x);
            }
        }.square, null);
        defer allocator.free(squared);

        std.debug.print("Output: ", .{});
        for (squared) |v| std.debug.print("{d} ", .{v});
        std.debug.print("\n\n", .{});
    }

    // ========================================================================
    // Large-scale map benchmark
    // ========================================================================
    std.debug.print("--- Benchmark: Map 10M elements ---\n", .{});
    {
        const n = 10_000_000;
        const data = try allocator.alloc(f32, n);
        defer allocator.free(data);

        for (data, 0..) |*v, i| {
            v.* = @floatFromInt(i);
        }

        // Parallel map
        const par_start = std.time.nanoTimestamp();
        const result_par = try par_iter(data).withPool(pool).withAlloc(allocator).map(f32, struct {
            fn compute(x: f32) f32 {
                // Some computation
                return @sqrt(x * x + 1.0) * @sin(x * 0.001);
            }
        }.compute, null);
        defer allocator.free(result_par);
        const par_end = std.time.nanoTimestamp();
        const par_ms = @as(f64, @floatFromInt(par_end - par_start)) / 1_000_000.0;

        // Sequential map
        const result_seq = try allocator.alloc(f32, n);
        defer allocator.free(result_seq);

        const seq_start = std.time.nanoTimestamp();
        for (data, 0..) |v, i| {
            result_seq[i] = @sqrt(v * v + 1.0) * @sin(v * 0.001);
        }
        const seq_end = std.time.nanoTimestamp();
        const seq_ms = @as(f64, @floatFromInt(seq_end - seq_start)) / 1_000_000.0;

        const speedup = seq_ms / par_ms;

        std.debug.print("  Parallel:   {d:.2}ms\n", .{par_ms});
        std.debug.print("  Sequential: {d:.2}ms\n", .{seq_ms});
        std.debug.print("  Speedup:    {d:.2}x\n\n", .{speedup});
    }

    // ========================================================================
    // Filter pattern
    // ========================================================================
    std.debug.print("--- Filter: Keep even numbers ---\n", .{});
    {
        var data = [_]i32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
        std.debug.print("Input:    ", .{});
        for (data) |v| std.debug.print("{d} ", .{v});
        std.debug.print("\n", .{});

        const evens = try par_iter(&data).withPool(pool).withAlloc(allocator).filter(struct {
            fn isEven(x: i32) bool {
                return @mod(x, 2) == 0;
            }
        }.isEven, null);
        defer allocator.free(evens);

        std.debug.print("Filtered: ", .{});
        for (evens) |v| std.debug.print("{d} ", .{v});
        std.debug.print("\n\n", .{});
    }

    // ========================================================================
    // Reduce pattern
    // ========================================================================
    std.debug.print("--- Reduce: Sum and Product ---\n", .{});
    {
        var data = [_]i32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
        std.debug.print("Input: ", .{});
        for (data) |v| std.debug.print("{d} ", .{v});
        std.debug.print("\n", .{});

        const sum_result = par_iter(&data).withPool(pool).sum();
        const product_result = par_iter(&data).withPool(pool).product();
        const min_result = par_iter(&data).withPool(pool).min();
        const max_result = par_iter(&data).withPool(pool).max();

        std.debug.print("Sum:     {d}\n", .{sum_result});
        std.debug.print("Product: {d}\n", .{product_result});
        std.debug.print("Min:     {d}\n", .{min_result});
        std.debug.print("Max:     {d}\n\n", .{max_result});
    }

    std.debug.print("╔═══════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║                    Sample Complete                         ║\n", .{});
    std.debug.print("╚═══════════════════════════════════════════════════════════╝\n", .{});
}
