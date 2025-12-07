// Basic Join Sample
//
// Demonstrates the join() function for binary fork-join parallelism.
//
// This sample shows:
// - Simple parallel computation
// - How join() executes two functions in parallel
// - Return values from both branches

const std = @import("std");
const zigparallel = @import("loom");
const join = zigparallel.join;

pub fn main() !void {
    std.debug.print("=== ZigParallel Basic Join Sample ===\n\n", .{});

    // Example 1: Simple parallel computation
    std.debug.print("Example 1: Parallel sum computation\n", .{});
    {
        const sumLeft = struct {
            fn compute() u64 {
                var sum: u64 = 0;
                for (0..1_000_000) |i| {
                    sum +%= i;
                }
                return sum;
            }
        }.compute;

        const sumRight = struct {
            fn compute() u64 {
                var sum: u64 = 0;
                for (1_000_000..2_000_000) |i| {
                    sum +%= i;
                }
                return sum;
            }
        }.compute;

        const left, const right = join(sumLeft, .{}, sumRight, .{});
        const total = left + right;

        std.debug.print("  Left sum (0..1M):   {d}\n", .{left});
        std.debug.print("  Right sum (1M..2M): {d}\n", .{right});
        std.debug.print("  Total sum:          {d}\n\n", .{total});
    }

    // Example 2: Different return types
    std.debug.print("Example 2: Different return types\n", .{});
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

        std.debug.print("  Even numbers (0..1000): {d}\n", .{even_count});
        std.debug.print("  Average (0..100):       {d:.2}\n\n", .{average});
    }

    // Example 3: With arguments
    std.debug.print("Example 3: Functions with arguments\n", .{});
    {
        const multiply = struct {
            fn compute(a: i32, b: i32) i32 {
                return a * b;
            }
        }.compute;

        const divide = struct {
            fn compute(a: f64, b: f64) f64 {
                return a / b;
            }
        }.compute;

        const product, const quotient = join(
            multiply,
            .{ 7, 8 },
            divide,
            .{ 100.0, 4.0 },
        );

        std.debug.print("  7 * 8 = {d}\n", .{product});
        std.debug.print("  100 / 4 = {d:.2}\n\n", .{quotient});
    }

    std.debug.print("✓ All examples completed successfully!\n", .{});
}
