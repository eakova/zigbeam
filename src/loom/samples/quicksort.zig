// Quicksort Sample - Parallel Quicksort with Work-Stealing
//
// Demonstrates classic recursive parallel quicksort using join().
// This shows the fundamental fork-join pattern for divide-and-conquer algorithms.
//
// Key concepts:
// - Recursive parallel partitioning with join()
// - Sequential threshold for efficient base case
// - Work-stealing enables load balancing
//
// Usage: zig build sample-quicksort

const std = @import("std");
const zigparallel = @import("loom");
const joinOnPool = zigparallel.joinOnPool;
const ThreadPool = zigparallel.ThreadPool;

const SEQUENTIAL_THRESHOLD = 5000; // Larger threshold to reduce recursion depth

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("╔═══════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║        Parallel Quicksort with Work-Stealing              ║\n", .{});
    std.debug.print("╚═══════════════════════════════════════════════════════════╝\n\n", .{});

    // Create thread pool
    const pool = try ThreadPool.init(allocator, .{ .num_threads = 8 });
    defer pool.deinit();
    std.debug.print("Thread pool: 8 workers\n", .{});
    std.debug.print("Sequential threshold: {d} elements\n\n", .{SEQUENTIAL_THRESHOLD});

    // ========================================================================
    // Test with small array (verification)
    // ========================================================================
    std.debug.print("--- Small Array Test (Verification) ---\n", .{});
    {
        var data = [_]i32{ 64, 34, 25, 12, 22, 11, 90, 5, 77, 42 };
        std.debug.print("Before: ", .{});
        printSlice(i32, &data);

        parallelQuicksort(pool, i32, &data);

        std.debug.print("After:  ", .{});
        printSlice(i32, &data);

        // Verify sorted
        var sorted = true;
        for (1..data.len) |i| {
            if (data[i - 1] > data[i]) {
                sorted = false;
                break;
            }
        }
        std.debug.print("Sorted: {}\n\n", .{sorted});
    }

    // ========================================================================
    // Performance benchmark
    // ========================================================================
    std.debug.print("--- Performance Benchmark ---\n", .{});
    {
        const sizes = [_]usize{ 10_000, 50_000, 100_000 };

        for (sizes) |n| {
            std.debug.print("\nArray size: {d} elements\n", .{n});

            // Allocate arrays
            const data_parallel = try allocator.alloc(i32, n);
            defer allocator.free(data_parallel);
            const data_seq = try allocator.alloc(i32, n);
            defer allocator.free(data_seq);

            // Initialize with random data
            var rng = std.Random.DefaultPrng.init(12345);
            for (data_parallel, data_seq) |*dp, *ds| {
                const val = rng.random().int(i32);
                dp.* = val;
                ds.* = val;
            }

            // Parallel quicksort
            const par_start = std.time.nanoTimestamp();
            parallelQuicksort(pool, i32, data_parallel);
            const par_end = std.time.nanoTimestamp();
            const par_ms = @as(f64, @floatFromInt(par_end - par_start)) / 1_000_000.0;

            // Sequential quicksort (std.mem.sort)
            const seq_start = std.time.nanoTimestamp();
            std.mem.sort(i32, data_seq, {}, std.sort.asc(i32));
            const seq_end = std.time.nanoTimestamp();
            const seq_ms = @as(f64, @floatFromInt(seq_end - seq_start)) / 1_000_000.0;

            const speedup = seq_ms / par_ms;

            std.debug.print("  Parallel:   {d:.3}ms\n", .{par_ms});
            std.debug.print("  Sequential: {d:.3}ms\n", .{seq_ms});
            std.debug.print("  Speedup:    {d:.2}x\n", .{speedup});

            // Verify correctness
            const match = std.mem.eql(i32, data_parallel, data_seq);
            std.debug.print("  Correct:    {}\n", .{match});
        }
    }

    // ========================================================================
    // Show recursive structure
    // ========================================================================
    std.debug.print("\n--- Recursive Structure Demo ---\n", .{});
    std.debug.print("For a 1M element array:\n", .{});
    std.debug.print("  - Depth 0: 1 task   (1M elements)\n", .{});
    std.debug.print("  - Depth 1: 2 tasks  (~500K each)\n", .{});
    std.debug.print("  - Depth 2: 4 tasks  (~250K each)\n", .{});
    std.debug.print("  - Depth 3: 8 tasks  (~125K each)\n", .{});
    std.debug.print("  - ...\n", .{});
    std.debug.print("  - At threshold ({d}): switches to sequential\n", .{SEQUENTIAL_THRESHOLD});
    std.debug.print("  - Work-stealing balances uneven partitions\n", .{});

    std.debug.print("\n╔═══════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║                    Sample Complete                         ║\n", .{});
    std.debug.print("╚═══════════════════════════════════════════════════════════╝\n", .{});
}

/// Parallel quicksort using fork-join with join()
fn parallelQuicksort(pool: *ThreadPool, comptime T: type, data: []T) void {
    if (data.len <= 1) return;

    if (data.len <= SEQUENTIAL_THRESHOLD) {
        // Base case: use sequential sort for small arrays
        sequentialQuicksort(T, data);
        return;
    }

    // Partition the array
    const pivot_idx = partition(T, data);

    // Split into two parts (excluding pivot which is in place)
    const left = data[0..pivot_idx];
    const right = if (pivot_idx + 1 < data.len) data[pivot_idx + 1 ..] else data[0..0];

    // Fork-join: sort left and right in parallel
    _ = joinOnPool(
        pool,
        struct {
            fn sortLeft(p: *ThreadPool, d: []T) void {
                parallelQuicksort(p, T, d);
            }
        }.sortLeft,
        .{ pool, left },
        struct {
            fn sortRight(p: *ThreadPool, d: []T) void {
                parallelQuicksort(p, T, d);
            }
        }.sortRight,
        .{ pool, right },
    );
}

/// Lomuto partition scheme
fn partition(comptime T: type, data: []T) usize {
    if (data.len == 0) return 0;

    const pivot_idx = data.len - 1;
    const pivot = data[pivot_idx];

    var i: usize = 0;
    for (0..pivot_idx) |j| {
        if (compare(T, data[j], pivot)) {
            std.mem.swap(T, &data[i], &data[j]);
            i += 1;
        }
    }

    std.mem.swap(T, &data[i], &data[pivot_idx]);
    return i;
}

/// Sequential quicksort for base case
fn sequentialQuicksort(comptime T: type, data: []T) void {
    std.mem.sort(T, data, {}, struct {
        fn lessThan(_: void, a: T, b: T) bool {
            return compare(T, a, b);
        }
    }.lessThan);
}

/// Generic comparison
fn compare(comptime T: type, a: T, b: T) bool {
    return a < b;
}

fn printSlice(comptime T: type, slice: []const T) void {
    std.debug.print("[", .{});
    for (slice, 0..) |val, i| {
        std.debug.print("{d}", .{val});
        if (i < slice.len - 1) std.debug.print(", ", .{});
    }
    std.debug.print("]\n", .{});
}
