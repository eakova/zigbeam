// Parallel Map Sample
//
// Demonstrates parallel map transformation over arrays.
// Shows forEach, forEachIndexed, map, and filter operations.

const std = @import("std");
const zigparallel = @import("loom");
const par_iter = zigparallel.par_iter;
const ThreadPool = zigparallel.ThreadPool;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("=== Parallel Map Sample ===\n\n", .{});

    // Create a thread pool
    const pool = try ThreadPool.init(allocator, .{ .num_threads = 4 });
    defer pool.deinit();

    // ========================================================================
    // forEach - In-place modification
    // ========================================================================
    std.debug.print("--- forEach (in-place double) ---\n", .{});

    var data1 = [_]i32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
    std.debug.print("Before: ", .{});
    printArray(&data1);

    par_iter(&data1).withPool(pool).forEach(struct {
        fn double(x: *i32) void {
            x.* *= 2;
        }
    }.double);

    std.debug.print("After:  ", .{});
    printArray(&data1);

    // ========================================================================
    // forEachIndexed - Access index during modification
    // ========================================================================
    std.debug.print("\n--- forEachIndexed (set to index * 10) ---\n", .{});

    var data2 = [_]i32{ 0, 0, 0, 0, 0 };
    std.debug.print("Before: ", .{});
    printArray(&data2);

    par_iter(&data2).withPool(pool).forEachIndexed(struct {
        fn setFromIndex(i: usize, x: *i32) void {
            x.* = @intCast(i * 10);
        }
    }.setFromIndex);

    std.debug.print("After:  ", .{});
    printArray(&data2);

    // ========================================================================
    // map - Transform to new array
    // ========================================================================
    std.debug.print("\n--- map (square each element) ---\n", .{});

    var data3 = [_]i32{ 1, 2, 3, 4, 5 };
    std.debug.print("Input:  ", .{});
    printArray(&data3);

    const squares = try par_iter(&data3).withPool(pool).map(i64, struct {
        fn square(x: i32) i64 {
            return @as(i64, x) * @as(i64, x);
        }
    }.square, allocator);
    defer allocator.free(squares);

    std.debug.print("Output: ", .{});
    for (squares, 0..) |val, i| {
        std.debug.print("{d}", .{val});
        if (i < squares.len - 1) std.debug.print(", ", .{});
    }
    std.debug.print("\n", .{});

    // ========================================================================
    // filter - Select matching elements
    // ========================================================================
    std.debug.print("\n--- filter (select even numbers) ---\n", .{});

    var data4 = [_]i32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
    std.debug.print("Input:  ", .{});
    printArray(&data4);

    const evens = try par_iter(&data4).filter(struct {
        fn isEven(x: i32) bool {
            return @mod(x, 2) == 0;
        }
    }.isEven, allocator);
    defer allocator.free(evens);

    std.debug.print("Output: ", .{});
    for (evens, 0..) |val, i| {
        std.debug.print("{d}", .{val});
        if (i < evens.len - 1) std.debug.print(", ", .{});
    }
    std.debug.print("\n", .{});

    // ========================================================================
    // Predicates: any, all, find, count
    // ========================================================================
    std.debug.print("\n--- Predicates ---\n", .{});

    var data5 = [_]i32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };

    const has_even = par_iter(&data5).any(struct {
        fn isEven(x: i32) bool {
            return @mod(x, 2) == 0;
        }
    }.isEven);
    std.debug.print("any(isEven): {}\n", .{has_even});

    const all_positive = par_iter(&data5).all(struct {
        fn isPositive(x: i32) bool {
            return x > 0;
        }
    }.isPositive);
    std.debug.print("all(isPositive): {}\n", .{all_positive});

    const first_gt5 = par_iter(&data5).find(struct {
        fn greaterThan5(x: i32) bool {
            return x > 5;
        }
    }.greaterThan5);
    std.debug.print("find(>5): {?}\n", .{first_gt5});

    const even_count = par_iter(&data5).count(struct {
        fn isEven(x: i32) bool {
            return @mod(x, 2) == 0;
        }
    }.isEven);
    std.debug.print("count(isEven): {d}\n", .{even_count});

    // ========================================================================
    // withAlloc - Store allocator once, use for multiple operations
    // ========================================================================
    std.debug.print("\n--- withAlloc (set allocator once) ---\n", .{});

    var data6 = [_]i32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 };
    std.debug.print("Input: ", .{});
    printArray(&data6);

    // Create iterator with stored allocator - no need to pass allocator to each operation
    const iter = par_iter(&data6).withPool(pool).withAlloc(allocator);

    // filter uses stored allocator (pass null)
    const evens2 = try iter.filter(struct {
        fn isEven(x: i32) bool {
            return @mod(x, 2) == 0;
        }
    }.isEven, null);
    defer allocator.free(evens2);

    std.debug.print("Filtered evens: ", .{});
    for (evens2, 0..) |val, i| {
        std.debug.print("{d}", .{val});
        if (i < evens2.len - 1) std.debug.print(", ", .{});
    }
    std.debug.print("\n", .{});

    // map uses stored allocator (pass null)
    const cubed = try iter.map(i64, struct {
        fn cube(x: i32) i64 {
            const v: i64 = @intCast(x);
            return v * v * v;
        }
    }.cube, null);
    defer allocator.free(cubed);

    std.debug.print("Cubed values: ", .{});
    for (cubed[0..6], 0..) |val, i| {
        std.debug.print("{d}", .{val});
        if (i < 5) std.debug.print(", ", .{});
    }
    std.debug.print("...\n", .{});

    std.debug.print("\n=== Sample Complete ===\n", .{});
}

fn printArray(arr: []const i32) void {
    for (arr, 0..) |val, i| {
        std.debug.print("{d}", .{val});
        if (i < arr.len - 1) std.debug.print(", ", .{});
    }
    std.debug.print("\n", .{});
}
