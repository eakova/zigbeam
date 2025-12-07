// Join Stress Test - Recursive Quicksort
//
// Stress tests for the join() fork-join primitive.
// Tests:
// - Recursive divide-and-conquer (parallel quicksort)
// - Many join points (thousands of joins)
// - Deep recursion without stack overflow
// - Correct results

const std = @import("std");
const zigparallel = @import("loom");
const ThreadPool = zigparallel.ThreadPool;
const joinOnPool = zigparallel.joinOnPool;

const ARRAY_SIZE = 100_000;
const THRESHOLD = 1000; // Sequential threshold
const NUM_WORKERS = 8;

pub fn main() !void {
    std.debug.print("=== Join Stress Test (Parallel Quicksort) ===\n", .{});
    std.debug.print("Array size: {d}, Threshold: {d}, Workers: {d}\n\n", .{ ARRAY_SIZE, THRESHOLD, NUM_WORKERS });

    const allocator = std.heap.page_allocator;

    // Initialize pool
    std.debug.print("Initializing thread pool...\n", .{});
    const pool = try ThreadPool.init(allocator, .{ .num_threads = NUM_WORKERS });
    defer {
        std.debug.print("Shutting down thread pool...\n", .{});
        pool.deinit();
        std.debug.print("Shutdown complete.\n", .{});
    }

    // Create array with random data
    std.debug.print("Generating random array...\n", .{});
    const data = try allocator.alloc(i32, ARRAY_SIZE);
    defer allocator.free(data);

    var rng = std.Random.DefaultPrng.init(12345);
    for (data) |*item| {
        item.* = rng.random().int(i32);
    }

    // Copy for verification
    const data_copy = try allocator.alloc(i32, ARRAY_SIZE);
    defer allocator.free(data_copy);
    @memcpy(data_copy, data);

    // Parallel quicksort
    std.debug.print("Running parallel quicksort...\n", .{});
    const start_time = std.time.nanoTimestamp();

    parallelQuicksort(pool, data);

    const parallel_time = std.time.nanoTimestamp();
    const parallel_duration_ms = @as(f64, @floatFromInt(parallel_time - start_time)) / 1_000_000.0;
    std.debug.print("Parallel sort complete in {d:.2}ms\n", .{parallel_duration_ms});

    // Sequential sort for comparison
    std.debug.print("Running sequential quicksort for comparison...\n", .{});
    const seq_start = std.time.nanoTimestamp();

    std.mem.sort(i32, data_copy, {}, std.sort.asc(i32));

    const seq_time = std.time.nanoTimestamp();
    const seq_duration_ms = @as(f64, @floatFromInt(seq_time - seq_start)) / 1_000_000.0;
    std.debug.print("Sequential sort complete in {d:.2}ms\n", .{seq_duration_ms});

    // Verify correctness
    std.debug.print("\nVerifying results...\n", .{});
    var is_sorted = true;
    var matches_expected = true;

    for (0..data.len - 1) |i| {
        if (data[i] > data[i + 1]) {
            is_sorted = false;
            break;
        }
    }

    for (0..data.len) |i| {
        if (data[i] != data_copy[i]) {
            matches_expected = false;
            break;
        }
    }

    // Results
    std.debug.print("\n=== Results ===\n", .{});
    std.debug.print("Array sorted: {s}\n", .{if (is_sorted) "YES" else "NO"});
    std.debug.print("Matches sequential: {s}\n", .{if (matches_expected) "YES" else "NO"});
    std.debug.print("Parallel time: {d:.2}ms\n", .{parallel_duration_ms});
    std.debug.print("Sequential time: {d:.2}ms\n", .{seq_duration_ms});

    const speedup = seq_duration_ms / parallel_duration_ms;
    std.debug.print("Speedup: {d:.2}x\n", .{speedup});

    if (is_sorted and matches_expected) {
        std.debug.print("\n✓ JOIN STRESS TEST PASSED\n", .{});
    } else {
        std.debug.print("\n✗ JOIN STRESS TEST FAILED\n", .{});
        return error.TestFailed;
    }
}

/// Parallel quicksort using join()
fn parallelQuicksort(pool: *ThreadPool, data: []i32) void {
    if (data.len <= 1) return;

    if (data.len <= THRESHOLD) {
        // Below threshold, use sequential sort
        std.mem.sort(i32, data, {}, std.sort.asc(i32));
        return;
    }

    // Partition using Hoare scheme
    const pivot_idx = partition(data);

    // Get the left and right slices
    // Hoare partition: elements [0..pivot_idx] are <= pivot, [pivot_idx+1..] are >= pivot
    // pivot_idx is included in left partition
    const left = data[0 .. pivot_idx + 1];
    const right = if (pivot_idx + 1 < data.len) data[pivot_idx + 1 ..] else data[0..0];

    // Sort in parallel using join
    _ = joinOnPool(
        pool,
        struct {
            fn sortLeft(p: *ThreadPool, d: []i32) void {
                parallelQuicksort(p, d);
            }
        }.sortLeft,
        .{ pool, left },
        struct {
            fn sortRight(p: *ThreadPool, d: []i32) void {
                parallelQuicksort(p, d);
            }
        }.sortRight,
        .{ pool, right },
    );
}

/// Partition using Hoare partition scheme
fn partition(data: []i32) usize {
    if (data.len <= 1) return 0;

    // Use median-of-three pivot selection
    const mid = data.len / 2;
    const pivot = medianOfThree(data[0], data[mid], data[data.len - 1]);

    var i: usize = 0;
    var j: usize = data.len - 1;

    while (true) {
        while (data[i] < pivot) : (i += 1) {}
        while (data[j] > pivot) : (j -= 1) {}

        if (i >= j) return j;

        // Swap
        const tmp = data[i];
        data[i] = data[j];
        data[j] = tmp;

        i += 1;
        if (j > 0) j -= 1;
    }
}

fn medianOfThree(a: i32, b: i32, c: i32) i32 {
    if ((a <= b and b <= c) or (c <= b and b <= a)) return b;
    if ((b <= a and a <= c) or (c <= a and a <= b)) return a;
    return c;
}
