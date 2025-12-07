// Join Microbenchmark - Fork-Join Overhead Measurement
//
// Measures the raw overhead of fork-join operations.
// Essential for understanding scheduling costs.
//
// Key concepts:
// - Fork-join overhead measurement
// - Empty task baseline
// - Scaling characteristics
//
// Usage: zig build sample-join-microbench

const std = @import("std");
const zigparallel = @import("loom");
const joinOnPool = zigparallel.joinOnPool;
const ThreadPool = zigparallel.ThreadPool;

const WARMUP_ITERATIONS = 100;
const BENCH_ITERATIONS = 1000;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("╔═══════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║          Fork-Join Overhead Microbenchmark                ║\n", .{});
    std.debug.print("╚═══════════════════════════════════════════════════════════╝\n\n", .{});

    const pool = try ThreadPool.init(allocator, .{ .num_threads = 8 });
    defer pool.deinit();
    std.debug.print("Thread pool: 8 workers\n", .{});
    std.debug.print("Warmup: {d} iterations\n", .{WARMUP_ITERATIONS});
    std.debug.print("Bench:  {d} iterations\n\n", .{BENCH_ITERATIONS});

    // ========================================================================
    // Empty join overhead
    // ========================================================================
    std.debug.print("--- Empty Join Overhead ---\n", .{});
    {
        // Warmup
        for (0..WARMUP_ITERATIONS) |_| {
            _ = joinOnPool(pool, emptyTask, .{}, emptyTask, .{});
        }

        // Benchmark
        const start = std.time.nanoTimestamp();
        for (0..BENCH_ITERATIONS) |_| {
            _ = joinOnPool(pool, emptyTask, .{}, emptyTask, .{});
        }
        const end = std.time.nanoTimestamp();

        const total_ns = end - start;
        const avg_ns = @divFloor(total_ns, BENCH_ITERATIONS);
        const avg_us = @as(f64, @floatFromInt(avg_ns)) / 1000.0;

        std.debug.print("  Total time:    {d}ms\n", .{@divFloor(total_ns, 1_000_000)});
        std.debug.print("  Avg per join:  {d}ns ({d:.2}μs)\n\n", .{ avg_ns, avg_us });
    }

    // ========================================================================
    // Join with minimal work
    // ========================================================================
    std.debug.print("--- Join with Minimal Work (increment counter) ---\n", .{});
    {
        var counter: u64 = 0;

        // Warmup
        for (0..WARMUP_ITERATIONS) |_| {
            const l, const r = joinOnPool(pool, incrementTask, .{}, incrementTask, .{});
            counter += l + r;
        }

        // Benchmark
        const start = std.time.nanoTimestamp();
        for (0..BENCH_ITERATIONS) |_| {
            const l, const r = joinOnPool(pool, incrementTask, .{}, incrementTask, .{});
            counter += l + r;
        }
        const end = std.time.nanoTimestamp();

        const total_ns = end - start;
        const avg_ns = @divFloor(total_ns, BENCH_ITERATIONS);

        std.debug.print("  Avg per join: {d}ns\n", .{avg_ns});
        std.debug.print("  Counter:      {d}\n\n", .{counter});
    }

    // ========================================================================
    // Join with actual work
    // ========================================================================
    std.debug.print("--- Join with Work (100K loop iterations each) ---\n", .{});
    {
        const WORK_ITERATIONS = 100_000;

        // Warmup
        for (0..10) |_| {
            _ = joinOnPool(pool, workTask, .{WORK_ITERATIONS}, workTask, .{WORK_ITERATIONS});
        }

        // Parallel
        const par_start = std.time.nanoTimestamp();
        var par_sum: u64 = 0;
        for (0..100) |_| {
            const l, const r = joinOnPool(pool, workTask, .{WORK_ITERATIONS}, workTask, .{WORK_ITERATIONS});
            par_sum += l + r;
        }
        const par_end = std.time.nanoTimestamp();
        const par_ns = par_end - par_start;

        // Sequential
        const seq_start = std.time.nanoTimestamp();
        var seq_sum: u64 = 0;
        for (0..100) |_| {
            seq_sum += doWork(WORK_ITERATIONS);
            seq_sum += doWork(WORK_ITERATIONS);
        }
        const seq_end = std.time.nanoTimestamp();
        const seq_ns = seq_end - seq_start;

        const speedup = @as(f64, @floatFromInt(seq_ns)) / @as(f64, @floatFromInt(par_ns));

        std.debug.print("  Parallel:   {d:.3}ms\n", .{@as(f64, @floatFromInt(par_ns)) / 1_000_000.0});
        std.debug.print("  Sequential: {d:.3}ms\n", .{@as(f64, @floatFromInt(seq_ns)) / 1_000_000.0});
        std.debug.print("  Speedup:    {d:.2}x\n", .{speedup});
        std.debug.print("  Sum match:  {}\n\n", .{par_sum == seq_sum});
    }

    // ========================================================================
    // Nested join
    // ========================================================================
    std.debug.print("--- Nested Join (2 levels deep) ---\n", .{});
    {
        // Warmup
        for (0..10) |_| {
            _ = joinOnPool(pool, nestedJoin, .{pool}, nestedJoin, .{pool});
        }

        // Benchmark
        const start = std.time.nanoTimestamp();
        var result: u64 = 0;
        for (0..100) |_| {
            const l, const r = joinOnPool(pool, nestedJoin, .{pool}, nestedJoin, .{pool});
            result += l + r;
        }
        const end = std.time.nanoTimestamp();

        const total_ms = @as(f64, @floatFromInt(end - start)) / 1_000_000.0;
        const avg_us = @as(f64, @floatFromInt(end - start)) / 100.0 / 1000.0;

        std.debug.print("  Total:       {d:.3}ms\n", .{total_ms});
        std.debug.print("  Avg per:     {d:.2}μs\n", .{avg_us});
        std.debug.print("  Result:      {d}\n\n", .{result});
    }

    std.debug.print("╔═══════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║                    Benchmark Complete                      ║\n", .{});
    std.debug.print("╚═══════════════════════════════════════════════════════════╝\n", .{});
}

fn emptyTask() void {}

fn incrementTask() u64 {
    return 1;
}

fn workTask(iterations: usize) u64 {
    return doWork(iterations);
}

fn doWork(iterations: usize) u64 {
    var sum: u64 = 0;
    for (0..iterations) |i| {
        sum +%= i;
    }
    return sum;
}

fn nestedJoin(pool: *ThreadPool) u64 {
    const l, const r = joinOnPool(pool, incrementTask, .{}, incrementTask, .{});
    return l + r;
}
