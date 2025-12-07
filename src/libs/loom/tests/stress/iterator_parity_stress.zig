// Iterator Parity Stress Test
//
// Stress tests for Phase 9 iterator parity methods with large datasets.
// Tests find_first, find_last, find_map, min_by, max_by, step_by, rev,
// filter_map, and partition under heavy workloads.
//
// Usage: zig build stress-iterator-parity && ./zig-out/bin/iterator_parity_stress

const std = @import("std");
const zigparallel = @import("loom");
const par_iter = zigparallel.par_iter;
const ThreadPool = zigparallel.ThreadPool;

const ITERATIONS = 100;
const SMALL_SIZE = 10_000;
const MEDIUM_SIZE = 100_000;
const LARGE_SIZE = 1_000_000;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("╔═══════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║        Iterator Parity Stress Test (Phase 9)              ║\n", .{});
    std.debug.print("╚═══════════════════════════════════════════════════════════╝\n\n", .{});

    const pool = try ThreadPool.init(allocator, .{ .num_threads = 8 });
    defer pool.deinit();
    std.debug.print("Thread pool: 8 workers\n", .{});
    std.debug.print("Iterations per test: {d}\n\n", .{ITERATIONS});

    // ========================================================================
    // find_first / find_last stress
    // ========================================================================
    std.debug.print("--- find_first / find_last ({d} elements) ---\n", .{LARGE_SIZE});
    {
        var data: [LARGE_SIZE]i32 = undefined;
        for (&data, 0..) |*v, i| {
            v.* = @intCast(i);
        }
        // Place target near middle
        data[LARGE_SIZE / 2] = -1;

        var find_first_time: i128 = 0;
        var find_last_time: i128 = 0;
        var found_count: usize = 0;

        for (0..ITERATIONS) |_| {
            const start1 = std.time.nanoTimestamp();
            const result1 = par_iter(&data).withPool(pool).find_first(struct {
                fn pred(x: i32) bool {
                    return x < 0;
                }
            }.pred);
            find_first_time += std.time.nanoTimestamp() - start1;
            if (result1 != null) found_count += 1;

            const start2 = std.time.nanoTimestamp();
            const result2 = par_iter(&data).withPool(pool).find_last(struct {
                fn pred(x: i32) bool {
                    return x < 0;
                }
            }.pred);
            find_last_time += std.time.nanoTimestamp() - start2;
            if (result2 != null) found_count += 1;
        }

        const ff_avg = @as(f64, @floatFromInt(find_first_time)) / @as(f64, ITERATIONS) / 1_000.0;
        const fl_avg = @as(f64, @floatFromInt(find_last_time)) / @as(f64, ITERATIONS) / 1_000.0;
        std.debug.print("  find_first avg: {d:.2}us\n", .{ff_avg});
        std.debug.print("  find_last avg:  {d:.2}us\n", .{fl_avg});
        std.debug.print("  Total found:    {d}/{d}\n\n", .{ found_count, ITERATIONS * 2 });
    }

    // ========================================================================
    // find_map stress
    // ========================================================================
    std.debug.print("--- find_map ({d} elements) ---\n", .{MEDIUM_SIZE});
    {
        var data: [MEDIUM_SIZE]i32 = undefined;
        for (&data, 0..) |*v, i| {
            v.* = @intCast(i);
        }

        var total_time: i128 = 0;
        var found_count: usize = 0;

        for (0..ITERATIONS) |_| {
            const start = std.time.nanoTimestamp();
            const result = par_iter(&data).withPool(pool).find_map(i64, struct {
                fn func(x: i32) ?i64 {
                    if (x > MEDIUM_SIZE / 2) return @as(i64, x) * 2;
                    return null;
                }
            }.func);
            total_time += std.time.nanoTimestamp() - start;
            if (result != null) found_count += 1;
        }

        const avg_us = @as(f64, @floatFromInt(total_time)) / @as(f64, ITERATIONS) / 1_000.0;
        std.debug.print("  find_map avg:   {d:.2}us\n", .{avg_us});
        std.debug.print("  Found count:    {d}/{d}\n\n", .{ found_count, ITERATIONS });
    }

    // ========================================================================
    // min_by / max_by stress
    // ========================================================================
    std.debug.print("--- min_by / max_by ({d} elements) ---\n", .{LARGE_SIZE});
    {
        var data: [LARGE_SIZE]i32 = undefined;
        var rng = std.Random.DefaultPrng.init(12345);
        for (&data) |*v| {
            v.* = rng.random().intRangeAtMost(i32, -1_000_000, 1_000_000);
        }

        var min_time: i128 = 0;
        var max_time: i128 = 0;
        var min_sum: i64 = 0;
        var max_sum: i64 = 0;

        for (0..ITERATIONS) |_| {
            const start1 = std.time.nanoTimestamp();
            const min_result = par_iter(&data).withPool(pool).min_by(struct {
                fn less(a: i32, b: i32) bool {
                    return a < b;
                }
            }.less);
            min_time += std.time.nanoTimestamp() - start1;
            if (min_result) |m| min_sum += m;

            const start2 = std.time.nanoTimestamp();
            const max_result = par_iter(&data).withPool(pool).max_by(struct {
                fn less(a: i32, b: i32) bool {
                    return a < b;
                }
            }.less);
            max_time += std.time.nanoTimestamp() - start2;
            if (max_result) |m| max_sum += m;
        }

        const min_avg = @as(f64, @floatFromInt(min_time)) / @as(f64, ITERATIONS) / 1_000.0;
        const max_avg = @as(f64, @floatFromInt(max_time)) / @as(f64, ITERATIONS) / 1_000.0;
        std.debug.print("  min_by avg:     {d:.2}us\n", .{min_avg});
        std.debug.print("  max_by avg:     {d:.2}us\n", .{max_avg});
        std.debug.print("  min_sum:        {d}\n", .{min_sum});
        std.debug.print("  max_sum:        {d}\n\n", .{max_sum});
    }

    // ========================================================================
    // min_by_key / max_by_key stress
    // ========================================================================
    std.debug.print("--- min_by_key / max_by_key ({d} elements) ---\n", .{MEDIUM_SIZE});
    {
        const Item = struct {
            value: i32,
            key: u32,
        };

        var data: [MEDIUM_SIZE]Item = undefined;
        var rng = std.Random.DefaultPrng.init(54321);
        for (&data, 0..) |*v, i| {
            v.* = .{
                .value = @intCast(i),
                .key = rng.random().int(u32),
            };
        }

        var total_time: i128 = 0;
        var key_sum: u64 = 0;

        for (0..ITERATIONS) |_| {
            const start = std.time.nanoTimestamp();
            const result = par_iter(&data).withPool(pool).min_by_key(u32, struct {
                fn getKey(item: Item) u32 {
                    return item.key;
                }
            }.getKey);
            total_time += std.time.nanoTimestamp() - start;
            if (result) |r| key_sum += r.key;
        }

        const avg_us = @as(f64, @floatFromInt(total_time)) / @as(f64, ITERATIONS) / 1_000.0;
        std.debug.print("  min_by_key avg: {d:.2}us\n", .{avg_us});
        std.debug.print("  key_sum:        {d}\n\n", .{key_sum});
    }

    // ========================================================================
    // step_by stress
    // ========================================================================
    std.debug.print("--- step_by ({d} elements) ---\n", .{LARGE_SIZE});
    {
        var data: [LARGE_SIZE]i32 = undefined;
        for (&data, 0..) |*v, i| {
            v.* = @intCast(i);
        }

        var total_time: i128 = 0;
        var total_count: usize = 0;

        for (0..ITERATIONS) |_| {
            const start = std.time.nanoTimestamp();
            var iter = par_iter(&data).step_by(1000);
            var count: usize = 0;
            while (iter.next()) |_| {
                count += 1;
            }
            total_time += std.time.nanoTimestamp() - start;
            total_count += count;
        }

        const avg_us = @as(f64, @floatFromInt(total_time)) / @as(f64, ITERATIONS) / 1_000.0;
        const expected_count = (LARGE_SIZE + 999) / 1000;
        std.debug.print("  step_by(1000) avg:  {d:.2}us\n", .{avg_us});
        std.debug.print("  Elements per iter:  {d} (expected: {d})\n\n", .{ total_count / ITERATIONS, expected_count });
    }

    // ========================================================================
    // rev stress
    // ========================================================================
    std.debug.print("--- rev ({d} elements) ---\n", .{MEDIUM_SIZE});
    {
        var data: [MEDIUM_SIZE]i32 = undefined;
        for (&data, 0..) |*v, i| {
            v.* = @intCast(i);
        }

        var total_time: i128 = 0;

        for (0..ITERATIONS) |_| {
            const start = std.time.nanoTimestamp();
            _ = par_iter(&data).rev();
            total_time += std.time.nanoTimestamp() - start;
        }

        const avg_us = @as(f64, @floatFromInt(total_time)) / @as(f64, ITERATIONS) / 1_000.0;
        // Verify reversals (even number of iterations should restore original)
        const is_restored = data[0] == 0;
        std.debug.print("  rev avg:        {d:.2}us\n", .{avg_us});
        std.debug.print("  Data restored:  {}\n\n", .{is_restored});
    }

    // ========================================================================
    // filter_map stress
    // ========================================================================
    std.debug.print("--- filter_map ({d} elements) ---\n", .{MEDIUM_SIZE});
    {
        var data: [MEDIUM_SIZE]i32 = undefined;
        for (&data, 0..) |*v, i| {
            v.* = @intCast(i);
        }

        var total_time: i128 = 0;
        var total_len: usize = 0;

        for (0..ITERATIONS) |_| {
            const start = std.time.nanoTimestamp();
            const result = try par_iter(&data).withPool(pool).withAlloc(allocator).filter_map(i64, struct {
                fn func(x: i32) ?i64 {
                    if (@mod(x, 100) == 0) return @as(i64, x) * 2;
                    return null;
                }
            }.func, null);
            total_time += std.time.nanoTimestamp() - start;
            total_len += result.len;
            allocator.free(result);
        }

        const avg_us = @as(f64, @floatFromInt(total_time)) / @as(f64, ITERATIONS) / 1_000.0;
        const expected_len = MEDIUM_SIZE / 100;
        std.debug.print("  filter_map avg: {d:.2}us\n", .{avg_us});
        std.debug.print("  Result len:     {d} (expected: {d})\n\n", .{ total_len / ITERATIONS, expected_len });
    }

    // ========================================================================
    // partition stress
    // ========================================================================
    std.debug.print("--- partition ({d} elements) ---\n", .{MEDIUM_SIZE});
    {
        var data: [MEDIUM_SIZE]i32 = undefined;
        for (&data, 0..) |*v, i| {
            v.* = @intCast(i);
        }

        var total_time: i128 = 0;
        var total_matching: usize = 0;
        var total_non_matching: usize = 0;

        for (0..ITERATIONS) |_| {
            const start = std.time.nanoTimestamp();
            const result = try par_iter(&data).withPool(pool).withAlloc(allocator).partition(struct {
                fn isEven(x: i32) bool {
                    return @mod(x, 2) == 0;
                }
            }.isEven, null);
            total_time += std.time.nanoTimestamp() - start;
            total_matching += result.matching.len;
            total_non_matching += result.non_matching.len;
            allocator.free(result.matching);
            allocator.free(result.non_matching);
        }

        const avg_us = @as(f64, @floatFromInt(total_time)) / @as(f64, ITERATIONS) / 1_000.0;
        std.debug.print("  partition avg:  {d:.2}us\n", .{avg_us});
        std.debug.print("  Matching avg:   {d}\n", .{total_matching / ITERATIONS});
        std.debug.print("  Non-match avg:  {d}\n\n", .{total_non_matching / ITERATIONS});
    }

    // ========================================================================
    // Combined operations stress
    // ========================================================================
    std.debug.print("--- Combined operations ({d} elements) ---\n", .{SMALL_SIZE});
    {
        var data: [SMALL_SIZE]i32 = undefined;
        for (&data, 0..) |*v, i| {
            v.* = @intCast(i);
        }

        var total_time: i128 = 0;

        for (0..ITERATIONS) |_| {
            const start = std.time.nanoTimestamp();

            // Chain multiple operations
            _ = par_iter(&data).withPool(pool).rev();
            const min_result = par_iter(&data).withPool(pool).min_by(struct {
                fn less(a: i32, b: i32) bool {
                    return a < b;
                }
            }.less);
            _ = min_result;
            _ = par_iter(&data).withPool(pool).rev(); // Restore

            total_time += std.time.nanoTimestamp() - start;
        }

        const avg_us = @as(f64, @floatFromInt(total_time)) / @as(f64, ITERATIONS) / 1_000.0;
        std.debug.print("  Combined avg:   {d:.2}us\n\n", .{avg_us});
    }

    // ========================================================================
    // Summary
    // ========================================================================
    std.debug.print("╔═══════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║           Iterator Parity Stress Test Complete            ║\n", .{});
    std.debug.print("╚═══════════════════════════════════════════════════════════╝\n", .{});
}
