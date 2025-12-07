// Merge Sort - Parallel Divide-and-Conquer
//
// Demonstrates parallel merge sort using fork-join pattern.
// Each recursive level splits work between threads.
//
// Key concepts:
// - Divide-and-conquer parallelism
// - Parallel merge phase
// - Stable sorting (preserves equal element order)
//
// Usage: zig build sample-mergesort

const std = @import("std");
const zigparallel = @import("loom");
const joinOnPool = zigparallel.joinOnPool;
const ThreadPool = zigparallel.ThreadPool;

const SEQUENTIAL_THRESHOLD = 4096;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("╔═══════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║           Parallel Merge Sort (Stable)                    ║\n", .{});
    std.debug.print("╚═══════════════════════════════════════════════════════════╝\n\n", .{});

    const pool = try ThreadPool.init(allocator, .{ .num_threads = 8 });
    defer pool.deinit();
    std.debug.print("Thread pool: 8 workers\n", .{});
    std.debug.print("Sequential threshold: {d} elements\n\n", .{SEQUENTIAL_THRESHOLD});

    // ========================================================================
    // Verification test
    // ========================================================================
    std.debug.print("--- Verification Test ---\n", .{});
    {
        var data = [_]i32{ 38, 27, 43, 3, 9, 82, 10 };
        const temp = try allocator.alloc(i32, data.len);
        defer allocator.free(temp);

        std.debug.print("Before: ", .{});
        printSlice(&data);

        parallelMergeSort(pool, i32, &data, temp);

        std.debug.print("After:  ", .{});
        printSlice(&data);

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

            const data_parallel = try allocator.alloc(i32, n);
            defer allocator.free(data_parallel);
            const data_seq = try allocator.alloc(i32, n);
            defer allocator.free(data_seq);
            const temp = try allocator.alloc(i32, n);
            defer allocator.free(temp);

            // Initialize with random data
            var rng = std.Random.DefaultPrng.init(12345);
            for (data_parallel, data_seq) |*dp, *ds| {
                const val = rng.random().int(i32);
                dp.* = val;
                ds.* = val;
            }

            // Parallel merge sort
            const par_start = std.time.nanoTimestamp();
            parallelMergeSort(pool, i32, data_parallel, temp);
            const par_end = std.time.nanoTimestamp();
            const par_ms = @as(f64, @floatFromInt(par_end - par_start)) / 1_000_000.0;

            // Sequential sort (std.mem.sort)
            const seq_start = std.time.nanoTimestamp();
            std.mem.sort(i32, data_seq, {}, std.sort.asc(i32));
            const seq_end = std.time.nanoTimestamp();
            const seq_ms = @as(f64, @floatFromInt(seq_end - seq_start)) / 1_000_000.0;

            const speedup = seq_ms / par_ms;

            std.debug.print("  Parallel:   {d:.3}ms\n", .{par_ms});
            std.debug.print("  Sequential: {d:.3}ms\n", .{seq_ms});
            std.debug.print("  Speedup:    {d:.2}x\n", .{speedup});

            const match = std.mem.eql(i32, data_parallel, data_seq);
            std.debug.print("  Correct:    {}\n", .{match});
        }
    }

    std.debug.print("\n╔═══════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║                    Sample Complete                         ║\n", .{});
    std.debug.print("╚═══════════════════════════════════════════════════════════╝\n", .{});
}

fn parallelMergeSort(pool: *ThreadPool, comptime T: type, data: []T, temp: []T) void {
    if (data.len <= 1) return;

    if (data.len <= SEQUENTIAL_THRESHOLD) {
        sequentialMergeSort(T, data, temp);
        return;
    }

    const mid = data.len / 2;
    const left = data[0..mid];
    const right = data[mid..];
    const temp_left = temp[0..mid];
    const temp_right = temp[mid..];

    // Fork: sort both halves in parallel
    _ = joinOnPool(
        pool,
        struct {
            fn sortLeft(p: *ThreadPool, d: []T, t: []T) void {
                parallelMergeSort(p, T, d, t);
            }
        }.sortLeft,
        .{ pool, left, temp_left },
        struct {
            fn sortRight(p: *ThreadPool, d: []T, t: []T) void {
                parallelMergeSort(p, T, d, t);
            }
        }.sortRight,
        .{ pool, right, temp_right },
    );

    // Join: merge the sorted halves
    merge(T, data, mid, temp);
}

fn sequentialMergeSort(comptime T: type, data: []T, temp: []T) void {
    if (data.len <= 1) return;

    const mid = data.len / 2;
    sequentialMergeSort(T, data[0..mid], temp[0..mid]);
    sequentialMergeSort(T, data[mid..], temp[mid..]);
    merge(T, data, mid, temp);
}

fn merge(comptime T: type, data: []T, mid: usize, temp: []T) void {
    // Copy to temp
    @memcpy(temp[0..data.len], data);

    var i: usize = 0;
    var j: usize = mid;
    var k: usize = 0;

    while (i < mid and j < data.len) : (k += 1) {
        if (temp[i] <= temp[j]) {
            data[k] = temp[i];
            i += 1;
        } else {
            data[k] = temp[j];
            j += 1;
        }
    }

    while (i < mid) : ({
        i += 1;
        k += 1;
    }) {
        data[k] = temp[i];
    }

    while (j < data.len) : ({
        j += 1;
        k += 1;
    }) {
        data[k] = temp[j];
    }
}

fn printSlice(slice: []const i32) void {
    std.debug.print("[", .{});
    for (slice, 0..) |val, i| {
        std.debug.print("{d}", .{val});
        if (i < slice.len - 1) std.debug.print(", ", .{});
    }
    std.debug.print("]\n", .{});
}
