// Factorial - Parallel Range Multiplication
//
// Demonstrates parallel factorial computation using divide-and-conquer.
// Splits the multiplication range and combines results.
//
// Key concepts:
// - Parallel range multiplication
// - Uses fork-join pattern
// - Big number demonstration (u128)
//
// Usage: zig build sample-factorial

const std = @import("std");
const zigparallel = @import("loom");
const joinOnPool = zigparallel.joinOnPool;
const ThreadPool = zigparallel.ThreadPool;

const SEQUENTIAL_THRESHOLD = 100;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("╔═══════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║           Parallel Factorial Computation                  ║\n", .{});
    std.debug.print("╚═══════════════════════════════════════════════════════════╝\n\n", .{});

    const pool = try ThreadPool.init(allocator, .{ .num_threads = 8 });
    defer pool.deinit();
    std.debug.print("Thread pool: 8 workers\n\n", .{});

    // ========================================================================
    // Verification
    // ========================================================================
    std.debug.print("--- Verification (Small Factorials) ---\n", .{});
    const test_values = [_]u64{ 0, 1, 5, 10, 15, 20 };
    const expected = [_]u128{ 1, 1, 120, 3628800, 1307674368000, 2432902008176640000 };

    for (test_values, expected) |n, exp| {
        const result = parallelFactorial(pool, n);
        const match = result == exp;
        std.debug.print("  {d}! = {d} {s}\n", .{ n, result, if (match) "✓" else "✗" });
    }

    // ========================================================================
    // Performance benchmark
    // ========================================================================
    std.debug.print("\n--- Performance Benchmark ---\n", .{});
    const bench_values = [_]u64{ 1000, 5000, 10000 };

    for (bench_values) |n| {
        std.debug.print("\n{d}! computation:\n", .{n});

        // Parallel
        const par_start = std.time.nanoTimestamp();
        const par_result = parallelFactorial(pool, n);
        const par_end = std.time.nanoTimestamp();
        const par_ms = @as(f64, @floatFromInt(par_end - par_start)) / 1_000_000.0;

        // Sequential
        const seq_start = std.time.nanoTimestamp();
        const seq_result = sequentialFactorial(n);
        const seq_end = std.time.nanoTimestamp();
        const seq_ms = @as(f64, @floatFromInt(seq_end - seq_start)) / 1_000_000.0;

        const speedup = seq_ms / par_ms;

        std.debug.print("  Parallel:   {d:.3}ms\n", .{par_ms});
        std.debug.print("  Sequential: {d:.3}ms\n", .{seq_ms});
        std.debug.print("  Speedup:    {d:.2}x\n", .{speedup});
        std.debug.print("  Match:      {}\n", .{par_result == seq_result});

        // Show last digits (mod 10^18 to fit in u64 for display)
        const display_mod: u128 = 1_000_000_000_000_000_000;
        std.debug.print("  Last 18 digits: {d}\n", .{@as(u64, @intCast(par_result % display_mod))});
    }

    // ========================================================================
    // Explanation
    // ========================================================================
    std.debug.print("\n--- Algorithm ---\n", .{});
    std.debug.print("n! = 1 × 2 × 3 × ... × n\n\n", .{});
    std.debug.print("Parallel strategy:\n", .{});
    std.debug.print("  - Split range [1, n] into two halves\n", .{});
    std.debug.print("  - Compute product of each half in parallel\n", .{});
    std.debug.print("  - Multiply the two partial products\n", .{});
    std.debug.print("  - Recursively apply to sub-ranges\n", .{});

    std.debug.print("\n╔═══════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║                    Sample Complete                         ║\n", .{});
    std.debug.print("╚═══════════════════════════════════════════════════════════╝\n", .{});
}

/// Parallel factorial using fork-join divide-and-conquer
fn parallelFactorial(pool: *ThreadPool, n: u64) u128 {
    if (n <= 1) return 1;
    return parallelRangeProduct(pool, 1, n);
}

fn parallelRangeProduct(pool: *ThreadPool, lo: u64, hi: u64) u128 {
    if (hi < lo) return 1;
    if (hi == lo) return lo;
    if (hi - lo < SEQUENTIAL_THRESHOLD) {
        return sequentialRangeProduct(lo, hi);
    }

    const mid = lo + (hi - lo) / 2;

    // Fork-join: compute products of both halves in parallel
    const left_product, const right_product = joinOnPool(
        pool,
        struct {
            fn computeLeft(p: *ThreadPool, l: u64, m: u64) u128 {
                return parallelRangeProduct(p, l, m);
            }
        }.computeLeft,
        .{ pool, lo, mid },
        struct {
            fn computeRight(p: *ThreadPool, m: u64, h: u64) u128 {
                return parallelRangeProduct(p, m + 1, h);
            }
        }.computeRight,
        .{ pool, mid, hi },
    );

    return left_product *% right_product; // Wrapping multiply for overflow
}

fn sequentialFactorial(n: u64) u128 {
    if (n <= 1) return 1;
    return sequentialRangeProduct(1, n);
}

fn sequentialRangeProduct(lo: u64, hi: u64) u128 {
    var result: u128 = 1;
    var i = lo;
    while (i <= hi) : (i += 1) {
        result *%= i; // Wrapping multiply
    }
    return result;
}
