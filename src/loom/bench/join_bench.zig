// Join Benchmark
//
// Measures fork-join overhead and performance for:
// - Empty tasks (pure scheduling overhead)
// - CPU-bound tasks (actual parallel speedup)
// - Recursive patterns (parallel quicksort)

const std = @import("std");
const zigparallel = @import("loom");
const ThreadPool = zigparallel.ThreadPool;
const joinOnPool = zigparallel.joinOnPool;

const NUM_ITERATIONS = 100;
const CPU_WORK_ITERATIONS = 10_000;

pub fn main() !void {
    std.debug.print("=== Join Benchmark ===\n\n", .{});

    const allocator = std.heap.page_allocator;

    // Create pool with 8 workers
    const pool = try ThreadPool.init(allocator, .{ .num_threads = 8 });
    defer pool.deinit();

    // Benchmark 1: Empty task overhead
    {
        std.debug.print("Benchmark 1: Empty task join overhead\n", .{});

        const start = std.time.nanoTimestamp();

        for (0..NUM_ITERATIONS) |_| {
            _ = joinOnPool(
                pool,
                struct {
                    fn left() void {}
                }.left,
                .{},
                struct {
                    fn right() void {}
                }.right,
                .{},
            );
        }

        const elapsed_ns = std.time.nanoTimestamp() - start;
        const avg_ns = @as(f64, @floatFromInt(elapsed_ns)) / NUM_ITERATIONS;
        std.debug.print("  Iterations: {d}\n", .{NUM_ITERATIONS});
        std.debug.print("  Total time: {d:.2}ms\n", .{@as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0});
        std.debug.print("  Avg per join: {d:.0}ns\n\n", .{avg_ns});
    }

    // Benchmark 2: CPU-bound tasks
    {
        std.debug.print("Benchmark 2: CPU-bound task join (speedup measurement)\n", .{});

        const cpuWork = struct {
            fn work(iterations: usize) u64 {
                var sum: u64 = 0;
                for (0..iterations) |i| {
                    sum +%= i * i;
                }
                std.mem.doNotOptimizeAway(sum);
                return sum;
            }
        }.work;

        // Sequential baseline
        const seq_start = std.time.nanoTimestamp();
        for (0..NUM_ITERATIONS) |_| {
            _ = cpuWork(CPU_WORK_ITERATIONS);
            _ = cpuWork(CPU_WORK_ITERATIONS);
        }
        const seq_elapsed = std.time.nanoTimestamp() - seq_start;

        // Parallel with join
        const par_start = std.time.nanoTimestamp();
        for (0..NUM_ITERATIONS) |_| {
            _ = joinOnPool(pool, cpuWork, .{CPU_WORK_ITERATIONS}, cpuWork, .{CPU_WORK_ITERATIONS});
        }
        const par_elapsed = std.time.nanoTimestamp() - par_start;

        const seq_ms = @as(f64, @floatFromInt(seq_elapsed)) / 1_000_000.0;
        const par_ms = @as(f64, @floatFromInt(par_elapsed)) / 1_000_000.0;
        const speedup = seq_ms / par_ms;

        std.debug.print("  Work iterations: {d}\n", .{CPU_WORK_ITERATIONS});
        std.debug.print("  Sequential: {d:.2}ms\n", .{seq_ms});
        std.debug.print("  Parallel:   {d:.2}ms\n", .{par_ms});
        std.debug.print("  Speedup:    {d:.2}x\n\n", .{speedup});
    }

    // Benchmark 3: Recursive join (simulating divide-and-conquer)
    {
        std.debug.print("Benchmark 3: Recursive join (parallel sum)\n", .{});

        const data = try allocator.alloc(u64, 100_000);
        defer allocator.free(data);

        for (data, 0..) |*item, i| {
            item.* = i;
        }

        // Sequential sum
        const seq_start = std.time.nanoTimestamp();
        var seq_sum: u64 = 0;
        for (data) |item| {
            seq_sum +%= item;
        }
        const seq_elapsed = std.time.nanoTimestamp() - seq_start;

        // Parallel sum using recursive join
        const par_start = std.time.nanoTimestamp();
        const par_sum = parallelSum(pool, data);
        const par_elapsed = std.time.nanoTimestamp() - par_start;

        const seq_ms = @as(f64, @floatFromInt(seq_elapsed)) / 1_000_000.0;
        const par_ms = @as(f64, @floatFromInt(par_elapsed)) / 1_000_000.0;
        const speedup = seq_ms / par_ms;

        std.debug.print("  Array size: 100,000\n", .{});
        std.debug.print("  Sequential: {d:.2}ms (sum={d})\n", .{ seq_ms, seq_sum });
        std.debug.print("  Parallel:   {d:.2}ms (sum={d})\n", .{ par_ms, par_sum });
        std.debug.print("  Speedup:    {d:.2}x\n", .{speedup});
        std.debug.print("  Correct:    {s}\n\n", .{if (seq_sum == par_sum) "YES" else "NO"});
    }

    std.debug.print("=== Benchmark Complete ===\n", .{});
}

/// Parallel sum using recursive binary join
fn parallelSum(pool: *ThreadPool, data: []const u64) u64 {
    const THRESHOLD = 1000;

    if (data.len <= THRESHOLD) {
        // Sequential sum for small arrays
        var sum: u64 = 0;
        for (data) |item| {
            sum +%= item;
        }
        return sum;
    }

    const mid = data.len / 2;
    const left = data[0..mid];
    const right = data[mid..];

    const left_sum, const right_sum = joinOnPool(
        pool,
        struct {
            fn sumLeft(p: *ThreadPool, d: []const u64) u64 {
                return parallelSum(p, d);
            }
        }.sumLeft,
        .{ pool, left },
        struct {
            fn sumRight(p: *ThreadPool, d: []const u64) u64 {
                return parallelSum(p, d);
            }
        }.sumRight,
        .{ pool, right },
    );

    return left_sum +% right_sum;
}
