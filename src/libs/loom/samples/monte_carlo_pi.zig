// Monte Carlo Pi Estimation
//
// Demonstrates parallel random sampling with reduction.
// Uses the classic Monte Carlo method: throw darts at a square,
// count how many land inside the inscribed circle.
//
// pi/4 = (points in circle) / (total points)
// pi = 4 * (points in circle) / (total points)
//
// Key concepts:
// - Parallel RNG (separate seed per chunk)
// - Parallel reduction to sum results
// - Statistical convergence with more samples
//
// Usage: zig build sample-monte-carlo-pi

const std = @import("std");
const zigparallel = @import("loom");
const par_iter = zigparallel.par_iter;
const scopeOnPool = zigparallel.scopeOnPool;
const Scope = zigparallel.Scope;
const ThreadPool = zigparallel.ThreadPool;
const Splitter = zigparallel.Splitter;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("╔═══════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║           Monte Carlo Pi Estimation (Parallel)            ║\n", .{});
    std.debug.print("╚═══════════════════════════════════════════════════════════╝\n\n", .{});

    // Create thread pool
    const pool = try ThreadPool.init(allocator, .{ .num_threads = 8 });
    defer pool.deinit();
    std.debug.print("Thread pool: 8 workers\n", .{});
    std.debug.print("True value:  π = 3.14159265358979...\n\n", .{});

    // ========================================================================
    // Run with increasing sample sizes
    // ========================================================================
    std.debug.print("--- Convergence with Sample Size ---\n", .{});
    std.debug.print("{s: <15} {s: <15} {s: <12} {s: <10}\n", .{ "Samples", "Estimate", "Error", "Time" });
    std.debug.print("{s:-<15} {s:-<15} {s:-<12} {s:-<10}\n", .{ "", "", "", "" });

    const sample_sizes = [_]u64{
        10_000,
        100_000,
        1_000_000,
        10_000_000,
        100_000_000,
    };

    const pi_true: f64 = 3.14159265358979323846;

    for (sample_sizes) |samples| {
        const start = std.time.nanoTimestamp();
        const estimate = estimatePiParallel(pool, samples, allocator);
        const end = std.time.nanoTimestamp();

        const time_ms = @as(f64, @floatFromInt(end - start)) / 1_000_000.0;
        const error_pct = @abs(estimate - pi_true) / pi_true * 100.0;

        std.debug.print("{d: <15} {d:.10} {d:.6}% {d:.2}ms\n", .{ samples, estimate, error_pct, time_ms });
    }

    // ========================================================================
    // Comparison: Parallel vs Sequential
    // ========================================================================
    std.debug.print("\n--- Parallel vs Sequential (10M samples) ---\n", .{});
    const n: u64 = 10_000_000;

    // Parallel
    const par_start = std.time.nanoTimestamp();
    const par_result = estimatePiParallel(pool, n, allocator);
    const par_end = std.time.nanoTimestamp();
    const par_ms = @as(f64, @floatFromInt(par_end - par_start)) / 1_000_000.0;

    // Sequential
    const seq_start = std.time.nanoTimestamp();
    const seq_result = estimatePiSequential(n);
    const seq_end = std.time.nanoTimestamp();
    const seq_ms = @as(f64, @floatFromInt(seq_end - seq_start)) / 1_000_000.0;

    const speedup = seq_ms / par_ms;

    std.debug.print("Parallel:   π ≈ {d:.10} ({d:.2}ms)\n", .{ par_result, par_ms });
    std.debug.print("Sequential: π ≈ {d:.10} ({d:.2}ms)\n", .{ seq_result, seq_ms });
    std.debug.print("Speedup:    {d:.2}x\n", .{speedup});

    // ========================================================================
    // Explanation
    // ========================================================================
    std.debug.print("\n--- How It Works ---\n", .{});
    std.debug.print("1. Generate random (x, y) points in unit square [0,1]×[0,1]\n", .{});
    std.debug.print("2. Check if x² + y² ≤ 1 (inside quarter circle)\n", .{});
    std.debug.print("3. π = 4 × (points inside) / (total points)\n", .{});
    std.debug.print("\nParallel strategy:\n", .{});
    std.debug.print("  - Each worker gets a chunk of samples\n", .{});
    std.debug.print("  - Each worker uses its own RNG seed\n", .{});
    std.debug.print("  - Results are summed using atomic add\n", .{});
    std.debug.print("  - Embarrassingly parallel - linear speedup\n", .{});

    std.debug.print("\n╔═══════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║                    Sample Complete                         ║\n", .{});
    std.debug.print("╚═══════════════════════════════════════════════════════════╝\n", .{});
}

/// Parallel Monte Carlo Pi estimation
fn estimatePiParallel(pool: *ThreadPool, total_samples: u64, allocator: std.mem.Allocator) f64 {
    const num_chunks: u64 = 64; // More chunks = better load balancing
    const samples_per_chunk = total_samples / num_chunks;

    // Create array of chunk seeds (0..num_chunks)
    const seeds = allocator.alloc(u64, num_chunks) catch return 0;
    defer allocator.free(seeds);

    for (seeds, 0..) |*s, i| {
        s.* = i;
    }

    // Atomic counter for inside points
    var inside_count = std.atomic.Value(u64).init(0);

    // Static state for the parallel computation
    const WorkerState = struct {
        var samples: u64 = 0;
        var inside: *std.atomic.Value(u64) = undefined;

        fn countInside(seed: *u64) void {
            var rng = std.Random.DefaultPrng.init(seed.* * 12345 + 67890);
            const random = rng.random();

            var local_inside: u64 = 0;
            for (0..samples) |_| {
                const x = random.float(f64);
                const y = random.float(f64);
                if (x * x + y * y <= 1.0) {
                    local_inside += 1;
                }
            }

            // Add to global counter
            _ = inside.fetchAdd(local_inside, .acq_rel);
        }
    };

    WorkerState.samples = samples_per_chunk;
    WorkerState.inside = &inside_count;

    // Process chunks in parallel
    par_iter(seeds).withPool(pool).withSplitter(Splitter.fixed(1)).forEach(WorkerState.countInside);

    const inside = inside_count.load(.acquire);
    return 4.0 * @as(f64, @floatFromInt(inside)) / @as(f64, @floatFromInt(num_chunks * samples_per_chunk));
}

/// Sequential Monte Carlo Pi estimation
fn estimatePiSequential(total_samples: u64) f64 {
    var rng = std.Random.DefaultPrng.init(12345);
    const random = rng.random();

    var inside: u64 = 0;
    for (0..total_samples) |_| {
        const x = random.float(f64);
        const y = random.float(f64);
        if (x * x + y * y <= 1.0) {
            inside += 1;
        }
    }

    return 4.0 * @as(f64, @floatFromInt(inside)) / @as(f64, @floatFromInt(total_samples));
}
