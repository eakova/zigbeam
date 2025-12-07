// Parallel Find - Early Termination Search
//
// Demonstrates parallel search with early termination.
// Shows any/all/find predicates with short-circuit optimization.
//
// Key concepts:
// - Early termination on find
// - Parallel any/all predicates
// - Short-circuit optimization
//
// Usage: zig build sample-parallel-find

const std = @import("std");
const zigparallel = @import("loom");
const par_iter = zigparallel.par_iter;
const ThreadPool = zigparallel.ThreadPool;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("╔═══════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║        Parallel Search with Early Termination             ║\n", .{});
    std.debug.print("╚═══════════════════════════════════════════════════════════╝\n\n", .{});

    const pool = try ThreadPool.init(allocator, .{ .num_threads = 8 });
    defer pool.deinit();
    std.debug.print("Thread pool: 8 workers\n\n", .{});

    // ========================================================================
    // Test data setup
    // ========================================================================
    const n = 10_000_000;
    const data = try allocator.alloc(i32, n);
    defer allocator.free(data);

    // Fill with sequential values
    for (data, 0..) |*v, i| {
        v.* = @intCast(i);
    }

    // ========================================================================
    // any() - Check if ANY element satisfies predicate
    // ========================================================================
    std.debug.print("--- any() - Find if any element > 9,999,000 ---\n", .{});
    {
        const par_start = std.time.nanoTimestamp();
        const has_large = par_iter(data).withPool(pool).any(struct {
            fn pred(x: i32) bool {
                return x > 9_999_000;
            }
        }.pred);
        const par_end = std.time.nanoTimestamp();
        const par_ms = @as(f64, @floatFromInt(par_end - par_start)) / 1_000_000.0;

        std.debug.print("  Result: {} (expected: true)\n", .{has_large});
        std.debug.print("  Time:   {d:.3}ms\n\n", .{par_ms});
    }

    // ========================================================================
    // all() - Check if ALL elements satisfy predicate
    // ========================================================================
    std.debug.print("--- all() - Check if all elements >= 0 ---\n", .{});
    {
        const par_start = std.time.nanoTimestamp();
        const all_positive = par_iter(data).withPool(pool).all(struct {
            fn pred(x: i32) bool {
                return x >= 0;
            }
        }.pred);
        const par_end = std.time.nanoTimestamp();
        const par_ms = @as(f64, @floatFromInt(par_end - par_start)) / 1_000_000.0;

        std.debug.print("  Result: {} (expected: true)\n", .{all_positive});
        std.debug.print("  Time:   {d:.3}ms\n\n", .{par_ms});
    }

    // ========================================================================
    // find() - Find first element matching predicate
    // ========================================================================
    std.debug.print("--- find() - Find first element > 5,000,000 ---\n", .{});
    {
        const par_start = std.time.nanoTimestamp();
        const found = par_iter(data).withPool(pool).find(struct {
            fn pred(x: i32) bool {
                return x > 5_000_000;
            }
        }.pred);
        const par_end = std.time.nanoTimestamp();
        const par_ms = @as(f64, @floatFromInt(par_end - par_start)) / 1_000_000.0;

        if (found) |val| {
            std.debug.print("  Found: {d}\n", .{val});
        } else {
            std.debug.print("  Not found\n", .{});
        }
        std.debug.print("  Time:  {d:.3}ms\n\n", .{par_ms});
    }

    // ========================================================================
    // position() - Find index of first match
    // ========================================================================
    std.debug.print("--- position() - Find index where value == 7,777,777 ---\n", .{});
    {
        const par_start = std.time.nanoTimestamp();
        const pos = par_iter(data).withPool(pool).position(struct {
            fn pred(x: i32) bool {
                return x == 7_777_777;
            }
        }.pred);
        const par_end = std.time.nanoTimestamp();
        const par_ms = @as(f64, @floatFromInt(par_end - par_start)) / 1_000_000.0;

        if (pos) |idx| {
            std.debug.print("  Position: {d}\n", .{idx});
            std.debug.print("  Value:    {d}\n", .{data[idx]});
        } else {
            std.debug.print("  Not found\n", .{});
        }
        std.debug.print("  Time:     {d:.3}ms\n\n", .{par_ms});
    }

    // ========================================================================
    // count() - Count elements matching predicate
    // ========================================================================
    std.debug.print("--- count() - Count even numbers ---\n", .{});
    {
        const par_start = std.time.nanoTimestamp();
        const even_count = par_iter(data).withPool(pool).count(struct {
            fn pred(x: i32) bool {
                return @mod(x, 2) == 0;
            }
        }.pred);
        const par_end = std.time.nanoTimestamp();
        const par_ms = @as(f64, @floatFromInt(par_end - par_start)) / 1_000_000.0;

        std.debug.print("  Count: {d} (expected: 5,000,000)\n", .{even_count});
        std.debug.print("  Time:  {d:.3}ms\n\n", .{par_ms});
    }

    // ========================================================================
    // Early termination demonstration
    // ========================================================================
    std.debug.print("--- Early Termination Demo ---\n", .{});
    std.debug.print("Searching for element at position 100 in 10M array:\n", .{});
    {
        const par_start = std.time.nanoTimestamp();
        const found_early = par_iter(data).withPool(pool).find(struct {
            fn pred(x: i32) bool {
                return x == 100;
            }
        }.pred);
        const par_end = std.time.nanoTimestamp();
        const par_us = @as(f64, @floatFromInt(par_end - par_start)) / 1_000.0;

        std.debug.print("  Found: {any}\n", .{found_early});
        std.debug.print("  Time:  {d:.1}μs (early termination!)\n", .{par_us});
    }

    std.debug.print("\n╔═══════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║                    Sample Complete                         ║\n", .{});
    std.debug.print("╚═══════════════════════════════════════════════════════════╝\n", .{});
}
