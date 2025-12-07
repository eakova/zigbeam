// Iterator Parity Tests - Phase 9 methods
//
// Tests for Rayon-inspired iterator parity methods:
// find_first, find_last, find_map, min_by, max_by, min_by_key, max_by_key,
// step_by, rev, filter_map, partition, inspect

const std = @import("std");
const testing = std.testing;
const zigparallel = @import("loom");
const par_iter = zigparallel.par_iter;
const SteppedIterator = zigparallel.SteppedIterator;
const ThreadPool = zigparallel.ThreadPool;

// ============================================================================
// find_first / find_last tests
// ============================================================================

test "find_first returns first matching element" {
    const data = [_]i32{ 1, 2, 3, 4, 5, 2, 6 };
    const result = par_iter(&data).find_first(struct {
        fn pred(x: i32) bool {
            return x == 2;
        }
    }.pred);
    try testing.expect(result != null);
    try testing.expectEqual(@as(i32, 2), result.?);
}

test "find_last returns last matching element" {
    const data = [_]i32{ 1, 2, 3, 4, 5, 2, 6 };
    const result = par_iter(&data).find_last(struct {
        fn pred(x: i32) bool {
            return x == 2;
        }
    }.pred);
    try testing.expect(result != null);
    try testing.expectEqual(@as(i32, 2), result.?);
}

test "find_first empty slice returns null" {
    const data: []const i32 = &[_]i32{};
    const result = par_iter(data).find_first(struct {
        fn pred(_: i32) bool {
            return true;
        }
    }.pred);
    try testing.expect(result == null);
}

test "find_first no match returns null" {
    const data = [_]i32{ 1, 2, 3 };
    const result = par_iter(&data).find_first(struct {
        fn pred(x: i32) bool {
            return x > 10;
        }
    }.pred);
    try testing.expect(result == null);
}

// ============================================================================
// find_map tests
// ============================================================================

test "find_map transforms first match" {
    const data = [_]i32{ 1, 2, 3, 4, 5 };
    const result = par_iter(&data).find_map(i64, struct {
        fn func(x: i32) ?i64 {
            if (x > 3) return @as(i64, x) * 10;
            return null;
        }
    }.func);
    try testing.expect(result != null);
    try testing.expectEqual(@as(i64, 40), result.?);
}

test "find_map no match returns null" {
    const data = [_]i32{ 1, 2, 3 };
    const result = par_iter(&data).find_map(i64, struct {
        fn func(x: i32) ?i64 {
            if (x > 10) return @as(i64, x);
            return null;
        }
    }.func);
    try testing.expect(result == null);
}

// ============================================================================
// min_by / max_by tests
// ============================================================================

test "min_by with custom comparator" {
    const data = [_]i32{ 3, 1, 4, 1, 5, 9, 2 };
    const result = par_iter(&data).min_by(struct {
        fn less(a: i32, b: i32) bool {
            return a < b;
        }
    }.less);
    try testing.expect(result != null);
    try testing.expectEqual(@as(i32, 1), result.?);
}

test "max_by with custom comparator" {
    const data = [_]i32{ 3, 1, 4, 1, 5, 9, 2 };
    // max_by uses comparator(a, b) = "a < b" semantics
    // When comparator(result, item) is true, result < item, so item becomes new result
    const result = par_iter(&data).max_by(struct {
        fn less(a: i32, b: i32) bool {
            return a < b;
        }
    }.less);
    try testing.expect(result != null);
    try testing.expectEqual(@as(i32, 9), result.?);
}

test "min_by empty slice returns null" {
    const data: []const i32 = &[_]i32{};
    const result = par_iter(data).min_by(struct {
        fn less(a: i32, b: i32) bool {
            return a < b;
        }
    }.less);
    try testing.expect(result == null);
}

// ============================================================================
// min_by_key / max_by_key tests
// ============================================================================

const Person = struct {
    name: []const u8,
    age: u32,
};

test "min_by_key extracts key for comparison" {
    const people = [_]Person{
        .{ .name = "Alice", .age = 30 },
        .{ .name = "Bob", .age = 25 },
        .{ .name = "Carol", .age = 35 },
    };
    const result = par_iter(&people).min_by_key(u32, struct {
        fn getAge(p: Person) u32 {
            return p.age;
        }
    }.getAge);
    try testing.expect(result != null);
    try testing.expectEqual(@as(u32, 25), result.?.age);
}

test "max_by_key extracts key for comparison" {
    const people = [_]Person{
        .{ .name = "Alice", .age = 30 },
        .{ .name = "Bob", .age = 25 },
        .{ .name = "Carol", .age = 35 },
    };
    const result = par_iter(&people).max_by_key(u32, struct {
        fn getAge(p: Person) u32 {
            return p.age;
        }
    }.getAge);
    try testing.expect(result != null);
    try testing.expectEqual(@as(u32, 35), result.?.age);
}

// ============================================================================
// step_by tests
// ============================================================================

test "step_by yields every Nth element" {
    var data = [_]i32{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 };
    var iter = par_iter(&data).step_by(3);

    try testing.expectEqual(@as(?i32, 0), iter.next());
    try testing.expectEqual(@as(?i32, 3), iter.next());
    try testing.expectEqual(@as(?i32, 6), iter.next());
    try testing.expectEqual(@as(?i32, 9), iter.next());
    try testing.expectEqual(@as(?i32, null), iter.next());
}

test "step_by with step=1 yields all elements" {
    var data = [_]i32{ 1, 2, 3 };
    var iter = par_iter(&data).step_by(1);

    try testing.expectEqual(@as(?i32, 1), iter.next());
    try testing.expectEqual(@as(?i32, 2), iter.next());
    try testing.expectEqual(@as(?i32, 3), iter.next());
    try testing.expectEqual(@as(?i32, null), iter.next());
}

test "step_by with step=0 defaults to step=1" {
    var data = [_]i32{ 1, 2, 3 };
    var iter = par_iter(&data).step_by(0);

    try testing.expectEqual(@as(?i32, 1), iter.next());
    try testing.expectEqual(@as(?i32, 2), iter.next());
    try testing.expectEqual(@as(?i32, 3), iter.next());
    try testing.expectEqual(@as(?i32, null), iter.next());
}

test "step_by reset restarts iteration" {
    var data = [_]i32{ 0, 1, 2, 3, 4 };
    var iter = par_iter(&data).step_by(2);

    _ = iter.next();
    _ = iter.next();
    iter.reset();

    try testing.expectEqual(@as(?i32, 0), iter.next());
}

test "step_by collect gathers stepped elements" {
    var data = [_]i32{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 };
    var iter = par_iter(&data).step_by(2);

    const allocator = testing.allocator;
    const collected = try iter.collect(allocator);
    defer allocator.free(collected);

    try testing.expectEqual(@as(usize, 5), collected.len);
    try testing.expectEqualSlices(i32, &[_]i32{ 0, 2, 4, 6, 8 }, collected);
}

// ============================================================================
// rev tests
// ============================================================================

test "rev reverses slice in-place" {
    var data = [_]i32{ 1, 2, 3, 4, 5 };
    _ = par_iter(&data).rev();

    try testing.expectEqualSlices(i32, &[_]i32{ 5, 4, 3, 2, 1 }, &data);
}

test "rev empty slice is no-op" {
    var data: [0]i32 = .{};
    _ = par_iter(&data).rev();
    // No crash
}

test "rev single element is no-op" {
    var data = [_]i32{42};
    _ = par_iter(&data).rev();
    try testing.expectEqual(@as(i32, 42), data[0]);
}

// ============================================================================
// filter_map tests
// ============================================================================

test "filter_map combines filter and transform" {
    const data = [_]i32{ 1, 2, 3, 4, 5, 6 };
    const allocator = testing.allocator;

    const result = try par_iter(&data).withAlloc(allocator).filter_map(i64, struct {
        fn func(x: i32) ?i64 {
            if (@mod(x, 2) == 0) return @as(i64, x) * 10;
            return null;
        }
    }.func, null);
    defer allocator.free(result);

    try testing.expectEqual(@as(usize, 3), result.len);
    try testing.expectEqualSlices(i64, &[_]i64{ 20, 40, 60 }, result);
}

test "filter_map all filtered returns empty" {
    const data = [_]i32{ 1, 3, 5 };
    const allocator = testing.allocator;

    const result = try par_iter(&data).withAlloc(allocator).filter_map(i64, struct {
        fn func(x: i32) ?i64 {
            if (@mod(x, 2) == 0) return @as(i64, x);
            return null;
        }
    }.func, null);
    defer allocator.free(result);

    try testing.expectEqual(@as(usize, 0), result.len);
}

// ============================================================================
// partition tests
// ============================================================================

test "partition splits by predicate" {
    const data = [_]i32{ 1, 2, 3, 4, 5, 6 };
    const allocator = testing.allocator;

    const result = try par_iter(&data).withAlloc(allocator).partition(struct {
        fn isEven(x: i32) bool {
            return @mod(x, 2) == 0;
        }
    }.isEven, null);
    defer allocator.free(result.matching);
    defer allocator.free(result.non_matching);

    try testing.expectEqual(@as(usize, 3), result.matching.len);
    try testing.expectEqual(@as(usize, 3), result.non_matching.len);
    try testing.expectEqualSlices(i32, &[_]i32{ 2, 4, 6 }, result.matching);
    try testing.expectEqualSlices(i32, &[_]i32{ 1, 3, 5 }, result.non_matching);
}

test "partition all match" {
    const data = [_]i32{ 2, 4, 6 };
    const allocator = testing.allocator;

    const result = try par_iter(&data).withAlloc(allocator).partition(struct {
        fn always(_: i32) bool {
            return true;
        }
    }.always, null);
    defer allocator.free(result.matching);
    defer allocator.free(result.non_matching);

    try testing.expectEqual(@as(usize, 3), result.matching.len);
    try testing.expectEqual(@as(usize, 0), result.non_matching.len);
}

test "partition none match" {
    const data = [_]i32{ 1, 3, 5 };
    const allocator = testing.allocator;

    const result = try par_iter(&data).withAlloc(allocator).partition(struct {
        fn never(_: i32) bool {
            return false;
        }
    }.never, null);
    defer allocator.free(result.matching);
    defer allocator.free(result.non_matching);

    try testing.expectEqual(@as(usize, 0), result.matching.len);
    try testing.expectEqual(@as(usize, 3), result.non_matching.len);
}

// ============================================================================
// inspect tests
// ============================================================================

test "inspect calls function on each element" {
    const data = [_]i32{ 1, 2, 3 };

    // Note: inspect is for side effects, typically debugging
    _ = par_iter(&data).inspect(struct {
        fn countOp(_: i32) void {
            // Can't capture external state here in Zig, so this test is limited
            // In real use, this would be for debugging prints
        }
    }.countOp);

    // Test passes if no crash - inspect is mainly for side-effect debugging
}

// ============================================================================
// Combined operations tests
// ============================================================================

test "chained operations: filter then map" {
    var data = [_]i32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
    const allocator = testing.allocator;

    // Filter evens, then map (done with filter_map)
    const result = try par_iter(&data).withAlloc(allocator).filter_map(i32, struct {
        fn doubleEvens(x: i32) ?i32 {
            if (@mod(x, 2) == 0) return x * 2;
            return null;
        }
    }.doubleEvens, null);
    defer allocator.free(result);

    try testing.expectEqualSlices(i32, &[_]i32{ 4, 8, 12, 16, 20 }, result);
}

test "step_by with forEach" {
    var data = [_]i32{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    var iter = par_iter(&data).step_by(2);

    iter.forEach(struct {
        fn setTo99(x: *i32) void {
            x.* = 99;
        }
    }.setTo99);

    // Elements at indices 0, 2, 4, 6, 8 should be 99
    try testing.expectEqualSlices(i32, &[_]i32{ 99, 0, 99, 0, 99, 0, 99, 0, 99, 0 }, &data);
}

// ============================================================================
// Thread pool integration tests
// ============================================================================

test "find_first with thread pool" {
    const allocator = testing.allocator;
    const pool = try ThreadPool.init(allocator, .{ .num_threads = 4 });
    defer pool.deinit();

    var data: [1000]i32 = undefined;
    for (&data, 0..) |*v, i| {
        v.* = @intCast(i);
    }

    const result = par_iter(&data).withPool(pool).find_first(struct {
        fn pred(x: i32) bool {
            return x == 500;
        }
    }.pred);

    try testing.expect(result != null);
    try testing.expectEqual(@as(i32, 500), result.?);
}

test "partition with thread pool" {
    const allocator = testing.allocator;
    const pool = try ThreadPool.init(allocator, .{ .num_threads = 4 });
    defer pool.deinit();

    var data: [100]i32 = undefined;
    for (&data, 0..) |*v, i| {
        v.* = @intCast(i);
    }

    const result = try par_iter(&data).withPool(pool).withAlloc(allocator).partition(struct {
        fn isEven(x: i32) bool {
            return @mod(x, 2) == 0;
        }
    }.isEven, null);
    defer allocator.free(result.matching);
    defer allocator.free(result.non_matching);

    try testing.expectEqual(@as(usize, 50), result.matching.len);
    try testing.expectEqual(@as(usize, 50), result.non_matching.len);
}

// ============================================================================
// try_fold / try_reduce tests
// ============================================================================

test "try_fold success" {
    const data = [_]i32{ 1, 2, 3, 4, 5 };
    const result = try par_iter(&data).try_fold(error{Overflow}, 0, struct {
        fn add(acc: i32, x: i32) error{Overflow}!i32 {
            return acc + x;
        }
    }.add);
    try testing.expectEqual(@as(i32, 15), result);
}

test "try_fold error propagation" {
    const data = [_]i32{ 1, 2, 3, 4, 5 };
    const result = par_iter(&data).try_fold(error{TooBig}, 0, struct {
        fn addWithLimit(acc: i32, x: i32) error{TooBig}!i32 {
            if (acc + x > 5) return error.TooBig;
            return acc + x;
        }
    }.addWithLimit);
    try testing.expectError(error.TooBig, result);
}

test "try_reduce success" {
    const data = [_]i32{ 1, 2, 3, 4, 5 };
    const result = try par_iter(&data).try_reduce(error{Overflow}, struct {
        fn add(a: i32, b: i32) error{Overflow}!i32 {
            return a + b;
        }
    }.add);
    try testing.expect(result != null);
    try testing.expectEqual(@as(i32, 15), result.?);
}

test "try_reduce empty returns null" {
    const data: []const i32 = &[_]i32{};
    const result = try par_iter(data).try_reduce(error{Overflow}, struct {
        fn add(a: i32, b: i32) error{Overflow}!i32 {
            return a + b;
        }
    }.add);
    try testing.expect(result == null);
}

// ============================================================================
// enumerate tests
// ============================================================================

test "enumerate adds indices" {
    const data = [_]i32{ 10, 20, 30 };
    const allocator = testing.allocator;

    const result = try par_iter(&data).withAlloc(allocator).enumerate(null);
    defer allocator.free(result);

    try testing.expectEqual(@as(usize, 3), result.len);
    try testing.expectEqual(@as(usize, 0), result[0].index);
    try testing.expectEqual(@as(i32, 10), result[0].value);
    try testing.expectEqual(@as(usize, 1), result[1].index);
    try testing.expectEqual(@as(i32, 20), result[1].value);
    try testing.expectEqual(@as(usize, 2), result[2].index);
    try testing.expectEqual(@as(i32, 30), result[2].value);
}

test "enumerate empty slice" {
    const data: []const i32 = &[_]i32{};
    const allocator = testing.allocator;

    const result = try par_iter(data).withAlloc(allocator).enumerate(null);
    defer allocator.free(result);

    try testing.expectEqual(@as(usize, 0), result.len);
}

// ============================================================================
// cloned tests
// ============================================================================

test "cloned creates copy" {
    const data = [_]i32{ 1, 2, 3, 4, 5 };
    const allocator = testing.allocator;

    const result = try par_iter(&data).withAlloc(allocator).cloned(null);
    defer allocator.free(result);

    try testing.expectEqual(@as(usize, 5), result.len);
    try testing.expectEqualSlices(i32, &data, result);
}

test "cloned is independent copy" {
    var data = [_]i32{ 1, 2, 3 };
    const allocator = testing.allocator;

    const result = try par_iter(&data).withAlloc(allocator).cloned(null);
    defer allocator.free(result);

    // Modify original
    data[0] = 99;

    // Cloned should be unchanged
    try testing.expectEqual(@as(i32, 1), result[0]);
}

// ============================================================================
// zip tests
// ============================================================================

test "zip combines two slices" {
    const a = [_]i32{ 1, 2, 3 };
    const b = [_]i64{ 10, 20, 30 };
    const allocator = testing.allocator;

    const result = try par_iter(&a).withAlloc(allocator).zip(i64, &b, null);
    defer allocator.free(result);

    try testing.expectEqual(@as(usize, 3), result.len);
    try testing.expectEqual(@as(i32, 1), result[0].first);
    try testing.expectEqual(@as(i64, 10), result[0].second);
    try testing.expectEqual(@as(i32, 2), result[1].first);
    try testing.expectEqual(@as(i64, 20), result[1].second);
    try testing.expectEqual(@as(i32, 3), result[2].first);
    try testing.expectEqual(@as(i64, 30), result[2].second);
}

test "zip truncates to shorter length" {
    const a = [_]i32{ 1, 2, 3, 4, 5 };
    const b = [_]i64{ 10, 20 };
    const allocator = testing.allocator;

    const result = try par_iter(&a).withAlloc(allocator).zip(i64, &b, null);
    defer allocator.free(result);

    try testing.expectEqual(@as(usize, 2), result.len);
}

// ============================================================================
// chain tests
// ============================================================================

test "chain concatenates slices" {
    const a = [_]i32{ 1, 2, 3 };
    const b = [_]i32{ 4, 5, 6 };
    const allocator = testing.allocator;

    const result = try par_iter(&a).withAlloc(allocator).chain(&b, null);
    defer allocator.free(result);

    try testing.expectEqual(@as(usize, 6), result.len);
    try testing.expectEqualSlices(i32, &[_]i32{ 1, 2, 3, 4, 5, 6 }, result);
}

test "chain with empty first" {
    const a: []const i32 = &[_]i32{};
    const b = [_]i32{ 1, 2, 3 };
    const allocator = testing.allocator;

    const result = try par_iter(a).withAlloc(allocator).chain(&b, null);
    defer allocator.free(result);

    try testing.expectEqual(@as(usize, 3), result.len);
    try testing.expectEqualSlices(i32, &[_]i32{ 1, 2, 3 }, result);
}

test "chain with empty second" {
    const a = [_]i32{ 1, 2, 3 };
    const b: []const i32 = &[_]i32{};
    const allocator = testing.allocator;

    const result = try par_iter(&a).withAlloc(allocator).chain(b, null);
    defer allocator.free(result);

    try testing.expectEqual(@as(usize, 3), result.len);
    try testing.expectEqualSlices(i32, &[_]i32{ 1, 2, 3 }, result);
}

// ============================================================================
// flat_map tests
// ============================================================================

test "flat_map expands and flattens" {
    const data = [_]i32{ 1, 2, 3 };
    const allocator = testing.allocator;

    // Each element expands to [x, x]
    const pairs = [3][2]i32{ .{ 1, 1 }, .{ 2, 2 }, .{ 3, 3 } };

    const result = try par_iter(&data).withAlloc(allocator).flat_map(i32, struct {
        const p = &pairs;
        fn expand(x: i32) []const i32 {
            return &p.*[@as(usize, @intCast(x - 1))];
        }
    }.expand, null);
    defer allocator.free(result);

    try testing.expectEqual(@as(usize, 6), result.len);
    try testing.expectEqualSlices(i32, &[_]i32{ 1, 1, 2, 2, 3, 3 }, result);
}
