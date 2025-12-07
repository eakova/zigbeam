// Scope and Join Sample
//
// Demonstrates structured concurrency patterns in ZigParallel.
// Shows join() for binary fork-join parallelism.
//
// This sample shows:
// - Binary parallelism with join()
// - Recursive parallel algorithms
// - Different return types from parallel branches

const std = @import("std");
const zigparallel = @import("loom");
const join = zigparallel.join;

pub fn main() !void {
    std.debug.print("=== ZigParallel Scope/Join Sample ===\n\n", .{});

    // join() automatically uses the global thread pool

    // ========================================================================
    // Example 1: Binary fork-join with join()
    // ========================================================================
    std.debug.print("--- Example 1: Binary Fork-Join ---\n", .{});
    {
        const sumLeft = struct {
            fn compute() u64 {
                var sum: u64 = 0;
                for (0..500_000) |i| {
                    sum +%= i;
                }
                return sum;
            }
        }.compute;

        const sumRight = struct {
            fn compute() u64 {
                var sum: u64 = 0;
                for (500_000..1_000_000) |i| {
                    sum +%= i;
                }
                return sum;
            }
        }.compute;

        const left, const right = join(sumLeft, .{}, sumRight, .{});
        const total = left + right;

        std.debug.print("Left sum (0..500K):   {d}\n", .{left});
        std.debug.print("Right sum (500K..1M): {d}\n", .{right});
        std.debug.print("Total sum:            {d}\n\n", .{total});
    }

    // ========================================================================
    // Example 2: Different return types
    // ========================================================================
    std.debug.print("--- Example 2: Different Return Types ---\n", .{});
    {
        const countEven = struct {
            fn compute() i32 {
                var count: i32 = 0;
                for (0..1000) |i| {
                    if (i % 2 == 0) count += 1;
                }
                return count;
            }
        }.compute;

        const computeAverage = struct {
            fn compute() f64 {
                var sum: f64 = 0;
                for (0..100) |i| {
                    sum += @as(f64, @floatFromInt(i));
                }
                return sum / 100.0;
            }
        }.compute;

        const even_count, const average = join(countEven, .{}, computeAverage, .{});

        std.debug.print("Even count (0..1000): {d}\n", .{even_count});
        std.debug.print("Average (0..100):     {d:.2}\n\n", .{average});
    }

    // ========================================================================
    // Example 3: Join with arguments
    // ========================================================================
    std.debug.print("--- Example 3: Functions with Arguments ---\n", .{});
    {
        const multiply = struct {
            fn compute(a: i32, b: i32) i32 {
                return a * b;
            }
        }.compute;

        const sumRange = struct {
            fn compute(start: u64, end: u64) u64 {
                var sum: u64 = 0;
                for (start..end) |i| {
                    sum += i;
                }
                return sum;
            }
        }.compute;

        const product, const range_sum = join(
            multiply,
            .{ 7, 8 },
            sumRange,
            .{ @as(u64, 1), @as(u64, 101) },
        );

        std.debug.print("7 * 8 = {d}\n", .{product});
        std.debug.print("sum(1..100) = {d}\n\n", .{range_sum});
    }

    // ========================================================================
    // Example 4: Recursive parallelism - Parallel Fibonacci
    // ========================================================================
    std.debug.print("--- Example 4: Recursive Fibonacci ---\n", .{});
    {
        const n: u32 = 20;
        const result = parallelFib(n);
        std.debug.print("Parallel fib({d}) = {d}\n\n", .{ n, result });
    }

    // ========================================================================
    // Example 5: Parallel array processing
    // ========================================================================
    std.debug.print("--- Example 5: Parallel Array Sum ---\n", .{});
    {
        var data: [10000]i64 = undefined;
        for (&data, 0..) |*item, i| {
            item.* = @intCast(i + 1);
        }

        // Split array and sum each half in parallel
        const half = data.len / 2;
        const first_half: []const i64 = data[0..half];
        const second_half: []const i64 = data[half..];

        const sumSlice = struct {
            fn compute(slice: []const i64) i64 {
                var sum: i64 = 0;
                for (slice) |v| {
                    sum += v;
                }
                return sum;
            }
        }.compute;

        const left_sum, const right_sum = join(
            sumSlice,
            .{first_half},
            sumSlice,
            .{second_half},
        );

        const total = left_sum + right_sum;
        const n: i64 = @intCast(data.len);
        const expected = @divExact(n * (n + 1), 2);

        std.debug.print("Left half sum:  {d}\n", .{left_sum});
        std.debug.print("Right half sum: {d}\n", .{right_sum});
        std.debug.print("Total: {d} (expected: {d})\n\n", .{ total, expected });
    }

    std.debug.print("=== All examples completed ===\n", .{});
}

fn parallelFib(n: u32) u64 {
    if (n <= 1) return n;

    // For small n, compute sequentially
    if (n < 15) {
        return sequentialFib(n);
    }

    // For larger n, use parallel join
    const left, const right = join(
        struct {
            fn compute(m: u32) u64 {
                return parallelFib(m);
            }
        }.compute,
        .{n - 1},
        struct {
            fn compute(m: u32) u64 {
                return parallelFib(m);
            }
        }.compute,
        .{n - 2},
    );

    return left + right;
}

fn sequentialFib(n: u32) u64 {
    if (n <= 1) return n;
    var a: u64 = 0;
    var b: u64 = 1;
    for (2..n + 1) |_| {
        const c = a + b;
        a = b;
        b = c;
    }
    return b;
}
