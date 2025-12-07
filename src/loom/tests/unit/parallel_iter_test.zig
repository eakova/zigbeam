// Parallel Iterator Unit Tests
//
// Tests for the parallel iterator functionality (Layer 4).
// These tests verify:
// - forEach parallel execution
// - forEachIndexed with indices
// - reduce operations (sum, product, min, max)
// - map transformations
// - filter operations
// - Sequential fallback for small data

const std = @import("std");
const testing = std.testing;

const zigparallel = @import("loom");
const par_iter = zigparallel.par_iter;
const ParallelIterator = zigparallel.ParallelIterator;
const Splitter = zigparallel.Splitter;
const Reducer = zigparallel.Reducer;
const ThreadPool = zigparallel.ThreadPool;

// ============================================================================
// forEach Tests
// ============================================================================

test "parallel_iter: forEach doubles all elements" {
    const pool = try ThreadPool.init(testing.allocator, .{ .num_threads = 4 });
    defer pool.deinit();

    var data = [_]i32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };

    par_iter(&data).withPool(pool).forEach(struct {
        fn double(x: *i32) void {
            x.* *= 2;
        }
    }.double);

    const expected = [_]i32{ 2, 4, 6, 8, 10, 12, 14, 16, 18, 20 };
    try testing.expectEqualSlices(i32, &expected, &data);
}

test "parallel_iter: forEach with sequential fallback" {
    var data = [_]i32{ 1, 2, 3 };

    // Force sequential with high threshold
    par_iter(&data).withSplitter(Splitter.fixed(1000)).forEach(struct {
        fn increment(x: *i32) void {
            x.* += 1;
        }
    }.increment);

    try testing.expectEqualSlices(i32, &[_]i32{ 2, 3, 4 }, &data);
}

test "parallel_iter: forEachIndexed with indices" {
    const pool = try ThreadPool.init(testing.allocator, .{ .num_threads = 2 });
    defer pool.deinit();

    var data = [_]i32{ 0, 0, 0, 0, 0 };

    par_iter(&data).withPool(pool).forEachIndexed(struct {
        fn setIndex(i: usize, x: *i32) void {
            x.* = @intCast(i * 10);
        }
    }.setIndex);

    try testing.expectEqualSlices(i32, &[_]i32{ 0, 10, 20, 30, 40 }, &data);
}

// ============================================================================
// reduce Tests
// ============================================================================

test "parallel_iter: sum reduction" {
    const pool = try ThreadPool.init(testing.allocator, .{ .num_threads = 4 });
    defer pool.deinit();

    var data = [_]i32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
    const result = par_iter(&data).withPool(pool).sum();

    try testing.expectEqual(@as(i32, 55), result);
}

test "parallel_iter: custom reducer (product)" {
    var data = [_]i32{ 1, 2, 3, 4, 5 };
    const result = par_iter(&data)
        .withSplitter(Splitter.fixed(1000)) // Force sequential for test
        .reduce(Reducer(i32).product());

    try testing.expectEqual(@as(i32, 120), result); // 1*2*3*4*5 = 120
}

test "parallel_iter: min reduction" {
    var data = [_]i32{ 5, 3, 8, 1, 9, 2 };
    const result = par_iter(&data)
        .withSplitter(Splitter.fixed(1000))
        .reduce(Reducer(i32).min());

    try testing.expectEqual(@as(i32, 1), result);
}

test "parallel_iter: max reduction" {
    var data = [_]i32{ 5, 3, 8, 1, 9, 2 };
    const result = par_iter(&data)
        .withSplitter(Splitter.fixed(1000))
        .reduce(Reducer(i32).max());

    try testing.expectEqual(@as(i32, 9), result);
}

// ============================================================================
// map Tests
// ============================================================================

test "parallel_iter: map transformation" {
    const pool = try ThreadPool.init(testing.allocator, .{ .num_threads = 2 });
    defer pool.deinit();

    var data = [_]i32{ 1, 2, 3, 4, 5 };
    const result = try par_iter(&data).withPool(pool).map(i64, struct {
        fn square(x: i32) i64 {
            return @as(i64, x) * @as(i64, x);
        }
    }.square, testing.allocator);
    defer testing.allocator.free(result);

    try testing.expectEqualSlices(i64, &[_]i64{ 1, 4, 9, 16, 25 }, result);
}

test "parallel_iter: map with sequential fallback" {
    var data = [_]i32{ 1, 2, 3 };
    const result = try par_iter(&data)
        .withSplitter(Splitter.fixed(1000))
        .map(i32, struct {
        fn negate(x: i32) i32 {
            return -x;
        }
    }.negate, testing.allocator);
    defer testing.allocator.free(result);

    try testing.expectEqualSlices(i32, &[_]i32{ -1, -2, -3 }, result);
}

// ============================================================================
// filter Tests
// ============================================================================

test "parallel_iter: filter even numbers" {
    var data = [_]i32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
    const result = try par_iter(&data).filter(struct {
        fn isEven(x: i32) bool {
            return @mod(x, 2) == 0;
        }
    }.isEven, testing.allocator);
    defer testing.allocator.free(result);

    try testing.expectEqual(@as(usize, 5), result.len);
    // Order may vary due to parallel execution, but we should have all evens
    var sum: i32 = 0;
    for (result) |x| {
        sum += x;
    }
    try testing.expectEqual(@as(i32, 30), sum); // 2+4+6+8+10 = 30
}

test "parallel_iter: filter with no matches" {
    var data = [_]i32{ 1, 3, 5, 7, 9 };
    const result = try par_iter(&data).filter(struct {
        fn isNegative(x: i32) bool {
            return x < 0;
        }
    }.isNegative, testing.allocator);
    defer testing.allocator.free(result);

    try testing.expectEqual(@as(usize, 0), result.len);
}

// ============================================================================
// Predicate Tests (any, all, find, count)
// ============================================================================

test "parallel_iter: any predicate" {
    var data = [_]i32{ 1, 2, 3, 4, 5 };

    const has_even = par_iter(&data).any(struct {
        fn isEven(x: i32) bool {
            return @mod(x, 2) == 0;
        }
    }.isEven);
    try testing.expect(has_even);

    const has_negative = par_iter(&data).any(struct {
        fn isNegative(x: i32) bool {
            return x < 0;
        }
    }.isNegative);
    try testing.expect(!has_negative);
}

test "parallel_iter: all predicate" {
    var positive = [_]i32{ 1, 2, 3, 4, 5 };
    var mixed = [_]i32{ 1, -2, 3, 4, 5 };

    const all_positive = par_iter(&positive).all(struct {
        fn isPositive(x: i32) bool {
            return x > 0;
        }
    }.isPositive);
    try testing.expect(all_positive);

    const all_positive_mixed = par_iter(&mixed).all(struct {
        fn isPositive(x: i32) bool {
            return x > 0;
        }
    }.isPositive);
    try testing.expect(!all_positive_mixed);
}

test "parallel_iter: find first match" {
    var data = [_]i32{ 1, 3, 5, 4, 7 };

    const first_even = par_iter(&data).find(struct {
        fn isEven(x: i32) bool {
            return @mod(x, 2) == 0;
        }
    }.isEven);
    try testing.expectEqual(@as(?i32, 4), first_even);

    const first_negative = par_iter(&data).find(struct {
        fn isNegative(x: i32) bool {
            return x < 0;
        }
    }.isNegative);
    try testing.expectEqual(@as(?i32, null), first_negative);
}

test "parallel_iter: count matches" {
    var data = [_]i32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };

    const even_count = par_iter(&data).count(struct {
        fn isEven(x: i32) bool {
            return @mod(x, 2) == 0;
        }
    }.isEven);
    try testing.expectEqual(@as(usize, 5), even_count);
}

// ============================================================================
// Splitter Configuration Tests
// ============================================================================

test "parallel_iter: withSplitter configuration" {
    var data = [_]i32{ 1, 2, 3, 4, 5 };

    // Fixed chunk size
    const iter1 = par_iter(&data).withSplitter(Splitter.fixed(2));
    try testing.expectEqual(@as(usize, 2), iter1.splitter.min_chunk_size);

    // Adaptive splitting
    const iter2 = par_iter(&data).withSplitter(Splitter.adaptive(4));
    try testing.expectEqual(@as(usize, 4), iter2.splitter.min_chunk_size);
}

test "parallel_iter: withPool configuration" {
    const pool = try ThreadPool.init(testing.allocator, .{ .num_threads = 2 });
    defer pool.deinit();

    var data = [_]i32{ 1, 2, 3, 4, 5 };
    const iter = par_iter(&data).withPool(pool);

    try testing.expect(iter.pool != null);
    try testing.expectEqual(pool, iter.pool.?);
}

// ============================================================================
// Empty Slice Tests
// ============================================================================

test "parallel_iter: empty slice operations" {
    const empty: []i32 = &[_]i32{};

    // forEach on empty
    par_iter(empty).forEach(struct {
        fn process(_: *i32) void {
            unreachable;
        }
    }.process);

    // sum on empty returns identity (0)
    const sum = par_iter(empty).sum();
    try testing.expectEqual(@as(i32, 0), sum);

    // any on empty returns false
    const has_any = par_iter(empty).any(struct {
        fn always(_: i32) bool {
            return true;
        }
    }.always);
    try testing.expect(!has_any);

    // all on empty returns true (vacuous truth)
    const has_all = par_iter(empty).all(struct {
        fn never(_: i32) bool {
            return false;
        }
    }.never);
    try testing.expect(has_all);
}

// ============================================================================
// withAlloc Tests
// ============================================================================

test "parallel_iter: withAlloc for filter" {
    const pool = try ThreadPool.init(testing.allocator, .{ .num_threads = 2 });
    defer pool.deinit();

    var data = [_]i32{ 1, 2, 3, 4, 5, 6, 7, 8 };

    // Use withAlloc - pass null to filter
    const result = try par_iter(&data).withPool(pool).withAlloc(testing.allocator).filter(struct {
        fn isEven(x: i32) bool {
            return @mod(x, 2) == 0;
        }
    }.isEven, null);
    defer testing.allocator.free(result);

    try testing.expectEqual(@as(usize, 4), result.len);
}

test "parallel_iter: withAlloc override" {
    const pool = try ThreadPool.init(testing.allocator, .{ .num_threads = 2 });
    defer pool.deinit();

    var data = [_]i32{ 1, 2, 3, 4, 5, 6 };

    // Set allocator via withAlloc, then override with explicit allocator
    const iter = par_iter(&data).withPool(pool).withAlloc(testing.allocator);

    // Override - explicit allocator takes precedence
    const result = try iter.filter(struct {
        fn greaterThan3(x: i32) bool {
            return x > 3;
        }
    }.greaterThan3, testing.allocator);
    defer testing.allocator.free(result);

    try testing.expectEqual(@as(usize, 3), result.len);
}

test "parallel_iter: withAlloc for sort" {
    const pool = try ThreadPool.init(testing.allocator, .{ .num_threads = 2 });
    defer pool.deinit();

    // Need larger array to trigger parallel sort (threshold is 1024)
    var data: [2000]i32 = undefined;
    for (&data, 0..) |*item, i| {
        item.* = @intCast(2000 - i);
    }

    // Use withAlloc - pass null to sort
    try par_iter(&data).withPool(pool).withAlloc(testing.allocator).sort(struct {
        fn lessThan(a: i32, b: i32) bool {
            return a < b;
        }
    }.lessThan, null);

    // Verify sorted
    try testing.expectEqual(@as(i32, 1), data[0]);
    try testing.expectEqual(@as(i32, 2000), data[1999]);
}

test "parallel_iter: withAlloc for map" {
    const pool = try ThreadPool.init(testing.allocator, .{ .num_threads = 2 });
    defer pool.deinit();

    var data = [_]i32{ 1, 2, 3, 4, 5 };

    // Use withAlloc - pass null to map
    const result = try par_iter(&data).withPool(pool).withAlloc(testing.allocator).map(i64, struct {
        fn square(x: i32) i64 {
            return @as(i64, x) * @as(i64, x);
        }
    }.square, null);
    defer testing.allocator.free(result);

    try testing.expectEqualSlices(i64, &[_]i64{ 1, 4, 9, 16, 25 }, result);
}

test "parallel_iter: no allocator returns error" {
    var data = [_]i32{ 1, 2, 3, 4 };

    // No withAlloc and pass null - should return error
    const result = par_iter(&data).filter(struct {
        fn isEven(x: i32) bool {
            return @mod(x, 2) == 0;
        }
    }.isEven, null);

    try testing.expectError(error.NoAllocatorProvided, result);
}

test "parallel_iter: withAlloc chained operations" {
    const pool = try ThreadPool.init(testing.allocator, .{ .num_threads = 2 });
    defer pool.deinit();

    var data = [_]i32{ 1, 2, 3, 4, 5, 6, 7, 8 };

    // Create iterator with allocator stored
    const iter = par_iter(&data).withPool(pool).withAlloc(testing.allocator);

    // Multiple operations reusing stored allocator
    const filtered = try iter.filter(struct {
        fn isEven(x: i32) bool {
            return @mod(x, 2) == 0;
        }
    }.isEven, null);
    defer testing.allocator.free(filtered);

    const mapped = try iter.map(i64, struct {
        fn triple(x: i32) i64 {
            return @as(i64, x) * 3;
        }
    }.triple, null);
    defer testing.allocator.free(mapped);

    try testing.expectEqual(@as(usize, 4), filtered.len);
    try testing.expectEqual(@as(usize, 8), mapped.len);
    try testing.expectEqual(@as(i64, 3), mapped[0]);
    try testing.expectEqual(@as(i64, 24), mapped[7]);
}

test "parallel_iter: no allocator for map returns error" {
    var data = [_]i32{ 1, 2, 3 };

    const result = par_iter(&data).map(i64, struct {
        fn double(x: i32) i64 {
            return @as(i64, x) * 2;
        }
    }.double, null);

    try testing.expectError(error.NoAllocatorProvided, result);
}

test "parallel_iter: no allocator for sort returns error" {
    var data = [_]i32{ 3, 1, 4, 1, 5 };

    const result = par_iter(&data).sort(struct {
        fn lessThan(a: i32, b: i32) bool {
            return a < b;
        }
    }.lessThan, null);

    try testing.expectError(error.NoAllocatorProvided, result);
}

test "parallel_iter: withAlloc preserves other config" {
    const pool = try ThreadPool.init(testing.allocator, .{ .num_threads = 2 });
    defer pool.deinit();

    var data = [_]i32{ 1, 2, 3, 4, 5 };

    // Chain all configuration options
    const iter = par_iter(&data)
        .withPool(pool)
        .withSplitter(Splitter.fixed(2))
        .withAlloc(testing.allocator);

    // All config should be preserved
    try testing.expect(iter.pool != null);
    try testing.expectEqual(@as(usize, 2), iter.splitter.min_chunk_size);
    try testing.expect(iter.allocator != null);
}
