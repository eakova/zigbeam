// NoOp Benchmark - Scheduling Overhead Measurement
//
// Measures the raw overhead of parallel task scheduling.
// Uses empty tasks to isolate scheduling costs.
//
// Key concepts:
// - Scheduling overhead measurement
// - Parallel iteration baseline
// - Performance floor analysis
//
// Usage: zig build sample-noop-bench

const std = @import("std");
const zigparallel = @import("loom");
const par_iter = zigparallel.par_iter;
const ThreadPool = zigparallel.ThreadPool;

const WARMUP_ITERATIONS = 10;
const BENCH_ITERATIONS = 100;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("╔═══════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║          Scheduling Overhead Benchmark                    ║\n", .{});
    std.debug.print("╚═══════════════════════════════════════════════════════════╝\n\n", .{});

    const pool = try ThreadPool.init(allocator, .{ .num_threads = 8 });
    defer pool.deinit();
    std.debug.print("Thread pool: 8 workers\n", .{});
    std.debug.print("Warmup: {d} iterations\n", .{WARMUP_ITERATIONS});
    std.debug.print("Bench:  {d} iterations\n\n", .{BENCH_ITERATIONS});

    // ========================================================================
    // Empty forEach overhead
    // ========================================================================
    std.debug.print("--- Empty forEach Overhead ---\n", .{});
    const sizes = [_]usize{ 100, 1_000, 10_000, 100_000, 1_000_000 };

    for (sizes) |size| {
        const data = try allocator.alloc(u8, size);
        defer allocator.free(data);
        @memset(data, 0);

        // Warmup
        for (0..WARMUP_ITERATIONS) |_| {
            par_iter(data).withPool(pool).forEach(struct {
                fn noop(_: *u8) void {}
            }.noop);
        }

        // Benchmark
        const start = std.time.nanoTimestamp();
        for (0..BENCH_ITERATIONS) |_| {
            par_iter(data).withPool(pool).forEach(struct {
                fn noop(_: *u8) void {}
            }.noop);
        }
        const end = std.time.nanoTimestamp();

        const total_ns = end - start;
        const avg_ns = @divFloor(total_ns, BENCH_ITERATIONS);
        const per_element_ns = @as(f64, @floatFromInt(avg_ns)) / @as(f64, @floatFromInt(size));

        std.debug.print("  Size {d:>7}: avg {d:>8}ns total, {d:.2}ns/element\n", .{
            size, avg_ns, per_element_ns,
        });
    }

    // ========================================================================
    // Sum reduction overhead
    // ========================================================================
    std.debug.print("\n--- Sum Reduction Overhead ---\n", .{});

    for (sizes) |size| {
        const data = try allocator.alloc(i32, size);
        defer allocator.free(data);
        for (data, 0..) |*v, i| {
            v.* = @intCast(i);
        }

        // Warmup
        for (0..WARMUP_ITERATIONS) |_| {
            _ = par_iter(data).withPool(pool).sum();
        }

        // Benchmark parallel
        const par_start = std.time.nanoTimestamp();
        var par_sum: i32 = 0;
        for (0..BENCH_ITERATIONS) |_| {
            par_sum +%= par_iter(data).withPool(pool).sum();
        }
        const par_end = std.time.nanoTimestamp();
        const par_avg = @divFloor(par_end - par_start, BENCH_ITERATIONS);

        // Benchmark sequential
        const seq_start = std.time.nanoTimestamp();
        var seq_sum: i64 = 0;
        for (0..BENCH_ITERATIONS) |_| {
            var sum: i64 = 0;
            for (data) |v| sum += v;
            seq_sum +%= sum;
        }
        const seq_end = std.time.nanoTimestamp();
        const seq_avg = @divFloor(seq_end - seq_start, BENCH_ITERATIONS);

        const speedup = @as(f64, @floatFromInt(seq_avg)) / @as(f64, @floatFromInt(par_avg));

        std.debug.print("  Size {d:>7}: par {d:>8}ns, seq {d:>8}ns, speedup {d:.2}x (par_sum={d}, seq_sum={})\n", .{
            size, par_avg, seq_avg, speedup, par_sum, seq_sum != 0,
        });
    }

    // ========================================================================
    // Chunk size impact
    // ========================================================================
    std.debug.print("\n--- Chunk Size Impact (1M elements) ---\n", .{});
    {
        const data = try allocator.alloc(i32, 1_000_000);
        defer allocator.free(data);
        for (data, 0..) |*v, i| {
            v.* = @intCast(i);
        }

        const chunk_sizes = [_]usize{ 100, 1_000, 10_000, 100_000, 500_000 };

        for (chunk_sizes) |chunk_size| {
            // Warmup
            for (0..WARMUP_ITERATIONS) |_| {
                _ = par_iter(data).withPool(pool).withMinChunk(chunk_size).sum();
            }

            // Benchmark
            const start = std.time.nanoTimestamp();
            for (0..BENCH_ITERATIONS) |_| {
                _ = par_iter(data).withPool(pool).withMinChunk(chunk_size).sum();
            }
            const end = std.time.nanoTimestamp();
            const avg_ns = @divFloor(end - start, BENCH_ITERATIONS);

            std.debug.print("  Chunk {d:>6}: avg {d:>8}ns\n", .{ chunk_size, avg_ns });
        }
    }

    // ========================================================================
    // Summary
    // ========================================================================
    std.debug.print("\n--- Analysis ---\n", .{});
    std.debug.print("Per-element overhead decreases as size increases\n", .{});
    std.debug.print("Larger chunks reduce scheduling overhead\n", .{});
    std.debug.print("Parallel speedup requires sufficient work per element\n", .{});

    std.debug.print("\n╔═══════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║                    Benchmark Complete                      ║\n", .{});
    std.debug.print("╚═══════════════════════════════════════════════════════════╝\n", .{});
}
