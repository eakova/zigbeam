// Parallel Sort Sample
//
// Demonstrates parallel sorting using work-stealing quicksort.
// Shows performance comparison between parallel and sequential sorting.
//
// This sample shows:
// - Basic parallel sort usage
// - Custom comparators for different orderings
// - Performance comparison with std.sort

const std = @import("std");
const zigparallel = @import("loom");
const par_iter = zigparallel.par_iter;
const ThreadPool = zigparallel.ThreadPool;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("=== Parallel Sort Sample ===\n\n", .{});

    // Create a thread pool
    const pool = try ThreadPool.init(allocator, .{ .num_threads = 4 });
    defer pool.deinit();

    // ========================================================================
    // Example 1: Basic parallel sort
    // ========================================================================
    std.debug.print("--- Example 1: Basic Parallel Sort ---\n", .{});
    {
        var data = [_]i32{ 64, 34, 25, 12, 22, 11, 90, 5, 77, 42 };
        std.debug.print("Before: ", .{});
        printArray(i32, &data);

        try par_iter(&data).withPool(pool).sort(struct {
            fn lessThan(a: i32, b: i32) bool {
                return a < b;
            }
        }.lessThan, allocator);

        std.debug.print("After:  ", .{});
        printArray(i32, &data);
        std.debug.print("\n", .{});
    }

    // ========================================================================
    // Example 2: Descending order
    // ========================================================================
    std.debug.print("--- Example 2: Descending Order ---\n", .{});
    {
        var data = [_]i32{ 3, 1, 4, 1, 5, 9, 2, 6, 5, 3, 5 };
        std.debug.print("Before: ", .{});
        printArray(i32, &data);

        try par_iter(&data).withPool(pool).sort(struct {
            fn greaterThan(a: i32, b: i32) bool {
                return a > b;
            }
        }.greaterThan, allocator);

        std.debug.print("After:  ", .{});
        printArray(i32, &data);
        std.debug.print("\n", .{});
    }

    // ========================================================================
    // Example 3: Performance comparison
    // ========================================================================
    std.debug.print("--- Example 3: Performance Comparison ---\n", .{});
    {
        const N: usize = 100_000;
        std.debug.print("Array size: {d} elements\n\n", .{N});

        // Prepare two identical arrays
        const data1 = try allocator.alloc(i32, N);
        defer allocator.free(data1);
        const data2 = try allocator.alloc(i32, N);
        defer allocator.free(data2);

        // Fill with random-like data (deterministic for reproducibility)
        var prng = std.Random.DefaultPrng.init(12345);
        const random = prng.random();
        for (data1, data2) |*d1, *d2| {
            const val = random.int(i32);
            d1.* = val;
            d2.* = val;
        }

        // Parallel sort
        const start_par = std.time.nanoTimestamp();
        try par_iter(data1).withPool(pool).sort(struct {
            fn lessThan(a: i32, b: i32) bool {
                return a < b;
            }
        }.lessThan, allocator);
        const end_par = std.time.nanoTimestamp();

        const par_time = @as(f64, @floatFromInt(end_par - start_par)) / 1_000_000.0;
        std.debug.print("Parallel sort:   {d:.2}ms\n", .{par_time});

        // Sequential sort
        const start_seq = std.time.nanoTimestamp();
        std.mem.sort(i32, data2, {}, struct {
            fn lessThan(_: void, a: i32, b: i32) bool {
                return a < b;
            }
        }.lessThan);
        const end_seq = std.time.nanoTimestamp();

        const seq_time = @as(f64, @floatFromInt(end_seq - start_seq)) / 1_000_000.0;
        std.debug.print("Sequential sort: {d:.2}ms\n", .{seq_time});

        if (seq_time > 0) {
            const speedup = seq_time / par_time;
            std.debug.print("Speedup: {d:.2}x\n", .{speedup});
        }

        // Verify results match
        var match = true;
        for (data1, data2) |d1, d2| {
            if (d1 != d2) {
                match = false;
                break;
            }
        }
        std.debug.print("Results match: {}\n\n", .{match});
    }

    // ========================================================================
    // Example 4: Sorting structs by field
    // ========================================================================
    std.debug.print("--- Example 4: Sorting Structs ---\n", .{});
    {
        const Person = struct {
            name: []const u8,
            age: u32,
        };

        var people = [_]Person{
            .{ .name = "Alice", .age = 30 },
            .{ .name = "Bob", .age = 25 },
            .{ .name = "Charlie", .age = 35 },
            .{ .name = "Diana", .age = 28 },
        };

        std.debug.print("Before (by age): ", .{});
        for (people) |p| {
            std.debug.print("{s}({d}) ", .{ p.name, p.age });
        }
        std.debug.print("\n", .{});

        try par_iter(&people).withPool(pool).sort(struct {
            fn byAge(a: Person, b: Person) bool {
                return a.age < b.age;
            }
        }.byAge, allocator);

        std.debug.print("After:           ", .{});
        for (people) |p| {
            std.debug.print("{s}({d}) ", .{ p.name, p.age });
        }
        std.debug.print("\n", .{});
    }

    std.debug.print("\n=== Sample Complete ===\n", .{});
}

fn printArray(comptime T: type, arr: []const T) void {
    std.debug.print("[", .{});
    for (arr, 0..) |val, i| {
        std.debug.print("{d}", .{val});
        if (i < arr.len - 1) std.debug.print(", ", .{});
    }
    std.debug.print("]\n", .{});
}
