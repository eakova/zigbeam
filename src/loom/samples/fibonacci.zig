// Fibonacci Sample - Classic Fork-Join Recursion
//
// Demonstrates the fundamental fork-join pattern with Fibonacci computation.
// This is the classic example of parallel recursion showing:
// - How join() enables parallel recursive computation
// - The importance of sequential cutoff for efficiency
// - Work-stealing for load balancing
//
// Note: This is for demonstration purposes. For production Fibonacci,
// use the closed-form formula or matrix exponentiation.
//
// Usage: zig build sample-fibonacci

const std = @import("std");
const zigparallel = @import("loom");
const joinOnPool = zigparallel.joinOnPool;
const ThreadPool = zigparallel.ThreadPool;

const SEQUENTIAL_CUTOFF = 20;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("╔═══════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║           Parallel Fibonacci - Fork-Join Demo             ║\n", .{});
    std.debug.print("╚═══════════════════════════════════════════════════════════╝\n\n", .{});

    // Create thread pool
    const pool = try ThreadPool.init(allocator, .{ .num_threads = 8 });
    defer pool.deinit();
    std.debug.print("Thread pool: 8 workers\n", .{});
    std.debug.print("Sequential cutoff: n <= {d}\n\n", .{SEQUENTIAL_CUTOFF});

    // ========================================================================
    // Small values verification
    // ========================================================================
    std.debug.print("--- Verification (First 10 Fibonacci numbers) ---\n", .{});
    std.debug.print("Expected: 0, 1, 1, 2, 3, 5, 8, 13, 21, 34\n", .{});
    std.debug.print("Computed: ", .{});
    for (0..10) |i| {
        const n: u64 = @intCast(i);
        std.debug.print("{d}", .{parallelFib(pool, n)});
        if (i < 9) std.debug.print(", ", .{});
    }
    std.debug.print("\n\n", .{});

    // ========================================================================
    // Performance comparison
    // ========================================================================
    std.debug.print("--- Performance Comparison ---\n", .{});
    const test_values = [_]u64{ 30, 35, 40, 42 };

    for (test_values) |n| {
        std.debug.print("\nFib({d}):\n", .{n});

        // Parallel computation
        const par_start = std.time.nanoTimestamp();
        const par_result = parallelFib(pool, n);
        const par_end = std.time.nanoTimestamp();
        const par_ms = @as(f64, @floatFromInt(par_end - par_start)) / 1_000_000.0;

        // Sequential computation
        const seq_start = std.time.nanoTimestamp();
        const seq_result = sequentialFib(n);
        const seq_end = std.time.nanoTimestamp();
        const seq_ms = @as(f64, @floatFromInt(seq_end - seq_start)) / 1_000_000.0;

        const speedup = if (par_ms > 0) seq_ms / par_ms else 0;

        std.debug.print("  Result:     {d}\n", .{par_result});
        std.debug.print("  Parallel:   {d:.3}ms\n", .{par_ms});
        std.debug.print("  Sequential: {d:.3}ms\n", .{seq_ms});
        std.debug.print("  Speedup:    {d:.2}x\n", .{speedup});
        std.debug.print("  Match:      {}\n", .{par_result == seq_result});
    }

    // ========================================================================
    // Explanation
    // ========================================================================
    std.debug.print("\n--- How It Works ---\n", .{});
    std.debug.print("Fib(n) = Fib(n-1) + Fib(n-2)\n\n", .{});
    std.debug.print("Fork-join structure:\n", .{});
    std.debug.print("  fib(40)\n", .{});
    std.debug.print("    ├── fib(39) ─┬─ fib(38) + fib(37)\n", .{});
    std.debug.print("    │            └── ...\n", .{});
    std.debug.print("    └── fib(38) ─┬─ fib(37) + fib(36)\n", .{});
    std.debug.print("                 └── ...\n", .{});
    std.debug.print("\nWith cutoff at n={d}:\n", .{SEQUENTIAL_CUTOFF});
    std.debug.print("  - Creates ~2^(n-cutoff) parallel tasks\n", .{});
    std.debug.print("  - Work-stealing balances the tree\n", .{});
    std.debug.print("  - Small subtrees run sequentially\n", .{});

    std.debug.print("\n╔═══════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║                    Sample Complete                         ║\n", .{});
    std.debug.print("╚═══════════════════════════════════════════════════════════╝\n", .{});
}

/// Parallel Fibonacci using fork-join
fn parallelFib(pool: *ThreadPool, n: u64) u64 {
    if (n <= 1) return n;

    // Below cutoff, use sequential to avoid overhead
    if (n <= SEQUENTIAL_CUTOFF) {
        return sequentialFib(n);
    }

    // Fork: compute fib(n-1) and fib(n-2) in parallel
    const fib_n1, const fib_n2 = joinOnPool(
        pool,
        struct {
            fn left(p: *ThreadPool, m: u64) u64 {
                return parallelFib(p, m);
            }
        }.left,
        .{ pool, n - 1 },
        struct {
            fn right(p: *ThreadPool, m: u64) u64 {
                return parallelFib(p, m);
            }
        }.right,
        .{ pool, n - 2 },
    );

    // Join: combine results
    return fib_n1 + fib_n2;
}

/// Sequential Fibonacci (for cutoff and comparison)
fn sequentialFib(n: u64) u64 {
    if (n <= 1) return n;

    var a: u64 = 0;
    var b: u64 = 1;

    for (2..n + 1) |_| {
        const temp = a + b;
        a = b;
        b = temp;
    }

    return b;
}
