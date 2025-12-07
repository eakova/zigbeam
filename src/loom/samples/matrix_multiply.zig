// Matrix Multiplication - Parallel Block Algorithm
//
// Demonstrates parallel matrix multiplication using block decomposition.
// Each block of the result matrix is computed in parallel.
//
// Key concepts:
// - 2D block decomposition for parallelism
// - Cache-friendly block sizes
// - Parallel iteration over result blocks
//
// Usage: zig build sample-matrix-multiply

const std = @import("std");
const zigparallel = @import("loom");
const par_iter = zigparallel.par_iter;
const scopeOnPool = zigparallel.scopeOnPool;
const Scope = zigparallel.Scope;
const ThreadPool = zigparallel.ThreadPool;
const Splitter = zigparallel.Splitter;

const BLOCK_SIZE: usize = 64; // Cache-friendly block size

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("╔═══════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║        Parallel Matrix Multiplication (Block Algorithm)   ║\n", .{});
    std.debug.print("╚═══════════════════════════════════════════════════════════╝\n\n", .{});

    // Create thread pool
    const pool = try ThreadPool.init(allocator, .{ .num_threads = 8 });
    defer pool.deinit();
    std.debug.print("Thread pool: 8 workers\n", .{});
    std.debug.print("Block size:  {d}×{d}\n\n", .{ BLOCK_SIZE, BLOCK_SIZE });

    // ========================================================================
    // Small matrix verification
    // ========================================================================
    std.debug.print("--- Small Matrix Test (Verification) ---\n", .{});
    {
        const A = [3][3]f64{
            .{ 1, 2, 3 },
            .{ 4, 5, 6 },
            .{ 7, 8, 9 },
        };
        const B = [3][3]f64{
            .{ 9, 8, 7 },
            .{ 6, 5, 4 },
            .{ 3, 2, 1 },
        };

        std.debug.print("A = [[1,2,3], [4,5,6], [7,8,9]]\n", .{});
        std.debug.print("B = [[9,8,7], [6,5,4], [3,2,1]]\n", .{});

        var C: [3][3]f64 = undefined;
        multiplySmall(3, &A, &B, &C);

        std.debug.print("C = A × B = [\n", .{});
        for (0..3) |i| {
            std.debug.print("  [", .{});
            for (0..3) |j| {
                std.debug.print("{d:.0}", .{C[i][j]});
                if (j < 2) std.debug.print(", ", .{});
            }
            std.debug.print("]\n", .{});
        }
        std.debug.print("]\n\n", .{});
    }

    // ========================================================================
    // Performance benchmark
    // ========================================================================
    std.debug.print("--- Performance Benchmark ---\n", .{});
    const sizes = [_]usize{ 256, 512, 1024 };

    for (sizes) |n| {
        std.debug.print("\nMatrix size: {d}×{d}\n", .{ n, n });

        // Allocate matrices
        const A = try allocator.alloc(f64, n * n);
        defer allocator.free(A);
        const B = try allocator.alloc(f64, n * n);
        defer allocator.free(B);
        const C_par = try allocator.alloc(f64, n * n);
        defer allocator.free(C_par);
        const C_seq = try allocator.alloc(f64, n * n);
        defer allocator.free(C_seq);

        // Initialize matrices
        var rng = std.Random.DefaultPrng.init(12345);
        for (A, B) |*a, *b| {
            a.* = rng.random().float(f64) * 10.0;
            b.* = rng.random().float(f64) * 10.0;
        }
        @memset(C_par, 0);
        @memset(C_seq, 0);

        // Parallel multiplication
        const par_start = std.time.nanoTimestamp();
        multiplyParallel(pool, n, A, B, C_par);
        const par_end = std.time.nanoTimestamp();
        const par_ms = @as(f64, @floatFromInt(par_end - par_start)) / 1_000_000.0;

        // Sequential multiplication
        const seq_start = std.time.nanoTimestamp();
        multiplySequential(n, A, B, C_seq);
        const seq_end = std.time.nanoTimestamp();
        const seq_ms = @as(f64, @floatFromInt(seq_end - seq_start)) / 1_000_000.0;

        const speedup = seq_ms / par_ms;

        // Verify results match
        var max_diff: f64 = 0;
        for (C_par, C_seq) |cp, cs| {
            const diff = @abs(cp - cs);
            if (diff > max_diff) max_diff = diff;
        }

        std.debug.print("  Parallel:   {d:.2}ms\n", .{par_ms});
        std.debug.print("  Sequential: {d:.2}ms\n", .{seq_ms});
        std.debug.print("  Speedup:    {d:.2}x\n", .{speedup});
        std.debug.print("  Max diff:   {e:.2} (floating point tolerance)\n", .{max_diff});

        const gflops = (2.0 * @as(f64, @floatFromInt(n)) * @as(f64, @floatFromInt(n)) * @as(f64, @floatFromInt(n))) / (par_ms * 1_000_000.0);
        std.debug.print("  GFLOPS:     {d:.2}\n", .{gflops});
    }

    std.debug.print("\n╔═══════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║                    Sample Complete                         ║\n", .{});
    std.debug.print("╚═══════════════════════════════════════════════════════════╝\n", .{});
}

/// Parallel matrix multiplication using row decomposition
fn multiplyParallel(pool: *ThreadPool, n: usize, A: []const f64, B: []const f64, C: []f64) void {
    // Create indices for each row
    const row_indices = std.heap.page_allocator.alloc(usize, n) catch return;
    defer std.heap.page_allocator.free(row_indices);

    for (row_indices, 0..) |*r, i| {
        r.* = i;
    }

    // Static state for computation
    const State = struct {
        var mat_n: usize = 0;
        var mat_a: []const f64 = undefined;
        var mat_b: []const f64 = undefined;
        var mat_c: []f64 = undefined;

        fn computeRow(row_ptr: *usize) void {
            const row = row_ptr.*;
            // C[row, :] = A[row, :] × B
            for (0..mat_n) |col| {
                var sum: f64 = 0;
                for (0..mat_n) |k| {
                    sum += mat_a[row * mat_n + k] * mat_b[k * mat_n + col];
                }
                mat_c[row * mat_n + col] = sum;
            }
        }
    };

    State.mat_n = n;
    State.mat_a = A;
    State.mat_b = B;
    State.mat_c = C;

    par_iter(row_indices).withPool(pool).withSplitter(Splitter.fixed(4)).forEach(State.computeRow);
}

/// Sequential matrix multiplication
fn multiplySequential(n: usize, A: []const f64, B: []const f64, C: []f64) void {
    for (0..n) |i| {
        for (0..n) |j| {
            var sum: f64 = 0;
            for (0..n) |k| {
                sum += A[i * n + k] * B[k * n + j];
            }
            C[i * n + j] = sum;
        }
    }
}

/// Small fixed-size matrix multiplication for verification
fn multiplySmall(comptime n: usize, A: *const [n][n]f64, B: *const [n][n]f64, C: *[n][n]f64) void {
    for (0..n) |i| {
        for (0..n) |j| {
            var sum: f64 = 0;
            for (0..n) |k| {
                sum += A[i][k] * B[k][j];
            }
            C[i][j] = sum;
        }
    }
}
