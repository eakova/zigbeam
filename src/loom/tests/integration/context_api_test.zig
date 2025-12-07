// Context API Integration Test
//
// Integration tests for the Context API functionality.
// Tests all context-aware operations with realistic use cases:
// - Parallel aggregation with atomic counter
// - Parallel file-like chunk processing
// - Indexed operations with context
// - Filter with dynamic criteria
// - Map with external parameters
// - Chunk processing with accumulation

const std = @import("std");
const loom = @import("loom");
const ThreadPool = loom.ThreadPool;
const par_iter = loom.par_iter;
const par_range = loom.par_range;
const Reducer = loom.Reducer;

pub fn main() !void {
    std.debug.print("=== Context API Integration Test ===\n\n", .{});

    const allocator = std.heap.page_allocator;

    const pool = try ThreadPool.init(allocator, .{ .num_threads = 4 });
    defer pool.deinit();

    std.debug.print("Pool workers: {d}\n\n", .{pool.numWorkers()});

    // ========================================================================
    // Test 1: Parallel Aggregation with Atomic Counter
    // ========================================================================
    std.debug.print("--- Test 1: Parallel Aggregation with Atomic Counter ---\n", .{});
    {
        var data: [1000]f64 = undefined;
        for (&data, 0..) |*d, i| {
            d.* = @as(f64, @floatFromInt(i));
        }

        const AggContext = struct {
            threshold: f64,
            counter: *std.atomic.Value(usize),
        };

        var atomic_count = std.atomic.Value(usize).init(0);
        const ctx = AggContext{
            .threshold = 500.0,
            .counter = &atomic_count,
        };

        par_iter(&data)
            .withPool(pool)
            .withContext(&ctx)
            .forEach(struct {
            fn check(c: *const AggContext, value: *f64) void {
                if (value.* > c.threshold) {
                    _ = c.counter.fetchAdd(1, .monotonic);
                }
            }
        }.check);

        const result = atomic_count.load(.acquire);
        // Values 501-999 are above 500.0, that's 499 values
        if (result == 499) {
            std.debug.print("PASS: Atomic aggregation works (count = {d})\n\n", .{result});
        } else {
            std.debug.print("FAIL: Expected 499, got {d}\n\n", .{result});
        }
    }

    // ========================================================================
    // Test 2: Context-aware Count
    // ========================================================================
    std.debug.print("--- Test 2: Context-aware Count ---\n", .{});
    {
        var data: [1000]i32 = undefined;
        for (&data, 0..) |*d, i| {
            d.* = @as(i32, @intCast(i % 100)); // Values 0-99 repeating
        }

        const CountContext = struct {
            min_value: i32,
            max_value: i32,
        };

        const ctx = CountContext{
            .min_value = 25,
            .max_value = 75,
        };

        const count = par_iter(&data)
            .withPool(pool)
            .withContext(&ctx)
            .count(struct {
            fn inRange(c: *const CountContext, value: i32) bool {
                return value >= c.min_value and value <= c.max_value;
            }
        }.inRange);

        // Values 25-75 inclusive = 51 values per 100, 10 cycles = 510
        if (count == 510) {
            std.debug.print("PASS: Context-aware count works (count = {d})\n\n", .{count});
        } else {
            std.debug.print("FAIL: Expected 510, got {d}\n\n", .{count});
        }
    }

    // ========================================================================
    // Test 3: Context-aware Map
    // ========================================================================
    std.debug.print("--- Test 3: Context-aware Map ---\n", .{});
    {
        const data = [_]i32{ 1, 2, 3, 4, 5 };

        const MapContext = struct {
            scale: f64,
            offset: f64,
        };

        const ctx = MapContext{
            .scale = 2.5,
            .offset = 10.0,
        };

        const result = try par_iter(&data)
            .withPool(pool)
            .withContext(&ctx)
            .map(f64, struct {
            fn transform(c: *const MapContext, value: i32) f64 {
                return @as(f64, @floatFromInt(value)) * c.scale + c.offset;
            }
        }.transform, allocator);
        defer allocator.free(result);

        // Expected: 1*2.5+10=12.5, 2*2.5+10=15.0, 3*2.5+10=17.5, 4*2.5+10=20.0, 5*2.5+10=22.5
        var pass = true;
        const expected = [_]f64{ 12.5, 15.0, 17.5, 20.0, 22.5 };
        for (result, expected) |r, e| {
            if (@abs(r - e) > 0.001) {
                pass = false;
                break;
            }
        }

        if (pass) {
            std.debug.print("PASS: Context-aware map works\n\n", .{});
        } else {
            std.debug.print("FAIL: Incorrect map results\n\n", .{});
        }
    }

    // ========================================================================
    // Test 4: Context-aware MapIndexed
    // ========================================================================
    std.debug.print("--- Test 4: Context-aware MapIndexed ---\n", .{});
    {
        const data = [_]i32{ 10, 20, 30, 40, 50 };

        const MapIdxContext = struct {
            base_id: usize,
        };

        const ctx = MapIdxContext{ .base_id = 1000 };

        const result = try par_iter(&data)
            .withPool(pool)
            .withContext(&ctx)
            .mapIndexed(usize, struct {
            fn transform(c: *const MapIdxContext, idx: usize, value: i32) usize {
                return c.base_id + idx + @as(usize, @intCast(value));
            }
        }.transform, allocator);
        defer allocator.free(result);

        // Expected: 1000+0+10=1010, 1000+1+20=1021, 1000+2+30=1032, 1000+3+40=1043, 1000+4+50=1054
        const expected = [_]usize{ 1010, 1021, 1032, 1043, 1054 };
        var pass = true;
        for (result, expected) |r, e| {
            if (r != e) {
                pass = false;
                break;
            }
        }

        if (pass) {
            std.debug.print("PASS: Context-aware mapIndexed works\n\n", .{});
        } else {
            std.debug.print("FAIL: Incorrect mapIndexed results\n\n", .{});
        }
    }

    // ========================================================================
    // Test 5: Base MapIndexed (no context)
    // ========================================================================
    std.debug.print("--- Test 5: Base MapIndexed (no context) ---\n", .{});
    {
        const data = [_]i32{ 100, 200, 300, 400, 500 };

        const result = try par_iter(&data)
            .withPool(pool)
            .mapIndexed(i64, struct {
            fn transform(idx: usize, value: i32) i64 {
                return @as(i64, value) + @as(i64, @intCast(idx)) * 1000;
            }
        }.transform, allocator);
        defer allocator.free(result);

        // Expected: 100+0=100, 200+1000=1200, 300+2000=2300, 400+3000=3400, 500+4000=4500
        const expected = [_]i64{ 100, 1200, 2300, 3400, 4500 };
        var pass = true;
        for (result, expected) |r, e| {
            if (r != e) {
                pass = false;
                break;
            }
        }

        if (pass) {
            std.debug.print("PASS: Base mapIndexed works\n\n", .{});
        } else {
            std.debug.print("FAIL: Incorrect base mapIndexed results\n\n", .{});
        }
    }

    // ========================================================================
    // Test 6: Context-aware Filter
    // ========================================================================
    std.debug.print("--- Test 6: Context-aware Filter ---\n", .{});
    {
        const Item = struct {
            value: i32,
            active: bool,
        };

        var data: [100]Item = undefined;
        for (&data, 0..) |*item, i| {
            item.* = Item{
                .value = @as(i32, @intCast(i)),
                .active = (i % 3 == 0), // Every 3rd is active
            };
        }

        const FilterContext = struct {
            min_value: i32,
            require_active: bool,
        };

        const ctx = FilterContext{
            .min_value = 50,
            .require_active = true,
        };

        const result = try par_iter(&data)
            .withPool(pool)
            .withContext(&ctx)
            .filter(struct {
            fn matches(c: *const FilterContext, item: Item) bool {
                return item.value >= c.min_value and
                    (!c.require_active or item.active);
            }
        }.matches, allocator);
        defer allocator.free(result);

        // Active items >= 50: 51, 54, 57, 60, 63, 66, 69, 72, 75, 78, 81, 84, 87, 90, 93, 96, 99
        // That's indices divisible by 3 and >= 50: 51,54,57,60,63,66,69,72,75,78,81,84,87,90,93,96,99
        // Count: 17 items
        if (result.len == 17) {
            std.debug.print("PASS: Context-aware filter works (filtered {d} items)\n\n", .{result.len});
        } else {
            std.debug.print("FAIL: Expected 17 items, got {d}\n\n", .{result.len});
        }
    }

    // ========================================================================
    // Test 7: Context-aware Find
    // ========================================================================
    std.debug.print("--- Test 7: Context-aware Find ---\n", .{});
    {
        const data = [_]i32{ 10, 25, 30, 45, 50, 65, 70, 85, 90 };

        const FindContext = struct {
            target_mod: i32,
            target_remainder: i32,
        };

        const ctx = FindContext{
            .target_mod = 7,
            .target_remainder = 0, // Find first divisible by 7
        };

        const found = par_iter(&data)
            .withPool(pool)
            .withContext(&ctx)
            .find(struct {
            fn matches(c: *const FindContext, value: i32) bool {
                return @mod(value, c.target_mod) == c.target_remainder;
            }
        }.matches);

        // First value divisible by 7: 70
        if (found) |f| {
            if (f == 70) {
                std.debug.print("PASS: Context-aware find works (found {d})\n\n", .{f});
            } else {
                std.debug.print("FAIL: Expected 70, found {d}\n\n", .{f});
            }
        } else {
            std.debug.print("FAIL: Expected to find 70, got null\n\n", .{});
        }
    }

    // ========================================================================
    // Test 8: par_range with Context
    // ========================================================================
    std.debug.print("--- Test 8: par_range with Context ---\n", .{});
    {
        var output: [100]usize = undefined;

        const RangeContext = struct {
            output: []usize,
            multiplier: usize,
        };

        const ctx = RangeContext{
            .output = &output,
            .multiplier = 10,
        };

        par_range(@as(usize, 0), @as(usize, 100))
            .withPool(pool)
            .withContext(&ctx)
            .forEach(struct {
            fn fill(c: *const RangeContext, idx: usize) void {
                c.output[idx] = idx * c.multiplier;
            }
        }.fill);

        // Verify: output[i] = i * 10
        var pass = true;
        for (output, 0..) |val, i| {
            if (val != i * 10) {
                pass = false;
                break;
            }
        }

        if (pass) {
            std.debug.print("PASS: par_range with context works\n\n", .{});
        } else {
            std.debug.print("FAIL: Incorrect par_range output\n\n", .{});
        }
    }

    // ========================================================================
    // Test 9: Context-aware Chunks
    // ========================================================================
    std.debug.print("--- Test 9: Context-aware Chunks ---\n", .{});
    {
        var data: [100]i32 = undefined;
        for (&data, 0..) |*d, i| {
            d.* = @as(i32, @intCast(i + 1)); // 1 to 100
        }

        var chunk_sum = std.atomic.Value(i64).init(0);
        var chunk_count = std.atomic.Value(usize).init(0);

        const ChunkContext = struct {
            multiplier: i32,
            sum: *std.atomic.Value(i64),
            count: *std.atomic.Value(usize),
        };

        const ctx = ChunkContext{
            .multiplier = 2,
            .sum = &chunk_sum,
            .count = &chunk_count,
        };

        par_iter(&data)
            .withPool(pool)
            .withContext(&ctx)
            .chunks(struct {
            fn process(c: *const ChunkContext, chunk_idx: usize, chunk: []i32) void {
                _ = chunk_idx;
                var local_sum: i64 = 0;
                for (chunk) |*item| {
                    item.* *= c.multiplier;
                    local_sum += item.*;
                }
                _ = c.sum.fetchAdd(local_sum, .monotonic);
                _ = c.count.fetchAdd(1, .monotonic);
            }
        }.process);

        // Sum of 1..100 = 5050, multiplied by 2 = 10100
        const total_sum = chunk_sum.load(.acquire);
        if (total_sum == 10100) {
            std.debug.print("PASS: Context-aware chunks works (sum = {d}, chunks = {d})\n\n", .{
                total_sum,
                chunk_count.load(.acquire),
            });
        } else {
            std.debug.print("FAIL: Expected sum 10100, got {d}\n\n", .{total_sum});
        }
    }

    // ========================================================================
    // Test 10: Context-aware ChunksConst
    // ========================================================================
    std.debug.print("--- Test 10: Context-aware ChunksConst ---\n", .{});
    {
        var data: [100]i32 = undefined;
        for (&data, 0..) |*d, i| {
            d.* = @as(i32, @intCast(i + 1)); // 1 to 100
        }

        var weighted_sum = std.atomic.Value(i64).init(0);

        const ConstChunkContext = struct {
            weight: i32,
            sum: *std.atomic.Value(i64),
        };

        const ctx = ConstChunkContext{
            .weight = 3,
            .sum = &weighted_sum,
        };

        par_iter(&data)
            .withPool(pool)
            .withContext(&ctx)
            .chunksConst(struct {
            fn analyze(c: *const ConstChunkContext, chunk_idx: usize, chunk: []const i32) void {
                _ = chunk_idx;
                var local_sum: i64 = 0;
                for (chunk) |item| {
                    local_sum += @as(i64, item) * c.weight;
                }
                _ = c.sum.fetchAdd(local_sum, .monotonic);
            }
        }.analyze);

        // Sum of 1..100 = 5050, multiplied by 3 = 15150
        const total_sum = weighted_sum.load(.acquire);
        if (total_sum == 15150) {
            std.debug.print("PASS: Context-aware chunksConst works (sum = {d})\n\n", .{total_sum});
        } else {
            std.debug.print("FAIL: Expected sum 15150, got {d}\n\n", .{total_sum});
        }
    }

    // ========================================================================
    // Test 11: Context-aware ForEachIndexed
    // ========================================================================
    std.debug.print("--- Test 11: Context-aware ForEachIndexed ---\n", .{});
    {
        var data = [_]i32{ 0, 0, 0, 0, 0 };

        const IdxContext = struct {
            base: i32,
            multiplier: i32,
        };

        const ctx = IdxContext{
            .base = 100,
            .multiplier = 10,
        };

        par_iter(&data)
            .withPool(pool)
            .withContext(&ctx)
            .forEachIndexed(struct {
            fn fill(c: *const IdxContext, idx: usize, item: *i32) void {
                item.* = c.base + @as(i32, @intCast(idx)) * c.multiplier;
            }
        }.fill);

        // Expected: 100, 110, 120, 130, 140
        const expected = [_]i32{ 100, 110, 120, 130, 140 };
        var pass = true;
        for (data, expected) |d, e| {
            if (d != e) {
                pass = false;
                break;
            }
        }

        if (pass) {
            std.debug.print("PASS: Context-aware forEachIndexed works\n\n", .{});
        } else {
            std.debug.print("FAIL: Incorrect forEachIndexed results\n\n", .{});
        }
    }

    // ========================================================================
    // Test 12: Context-aware Any/All
    // ========================================================================
    std.debug.print("--- Test 12: Context-aware Any/All ---\n", .{});
    {
        const data = [_]i32{ 10, 20, 30, 40, 50 };

        const ThresholdContext = struct {
            threshold: i32,
        };

        const ctx = ThresholdContext{ .threshold = 25 };

        const has_above = par_iter(&data)
            .withPool(pool)
            .withContext(&ctx)
            .any(struct {
            fn above(c: *const ThresholdContext, value: i32) bool {
                return value > c.threshold;
            }
        }.above);

        const all_above = par_iter(&data)
            .withPool(pool)
            .withContext(&ctx)
            .all(struct {
            fn above(c: *const ThresholdContext, value: i32) bool {
                return value > c.threshold;
            }
        }.above);

        if (has_above and !all_above) {
            std.debug.print("PASS: Context-aware any/all works (any={}, all={})\n\n", .{ has_above, all_above });
        } else {
            std.debug.print("FAIL: Expected any=true, all=false, got any={}, all={}\n\n", .{ has_above, all_above });
        }
    }

    // ========================================================================
    // Summary
    // ========================================================================
    std.debug.print("=== CONTEXT API INTEGRATION TEST COMPLETE ===\n", .{});
}
