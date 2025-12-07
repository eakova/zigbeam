const std = @import("std");
const TinyUFO = @import("tinyufo.zig").TinyUFO;

const NUM_THREADS = 16; // Test with 16 threads (original crash scenario)
const OPS_PER_THREAD = 10000;
const CACHE_SIZE = 1000;
const KEY_RANGE = 5000; // 5x cache size for evictions

var cache: *TinyUFO(u64, u64) = undefined;
var ready_barrier: std.atomic.Value(usize) = undefined;

fn workerThread(thread_id: usize) void {
    // Wait for all threads to be ready
    _ = ready_barrier.fetchAdd(1, .release);
    while (ready_barrier.load(.acquire) < NUM_THREADS) {
        std.atomic.spinLoopHint();
    }

    var prng = std.Random.DefaultPrng.init(@as(u64, @intCast(thread_id)) * 12345);
    const random = prng.random();

    var local_hits: usize = 0;
    var local_misses: usize = 0;

    for (0..OPS_PER_THREAD) |_| {
        const op = random.int(u8) % 100;
        const key = random.int(u64) % KEY_RANGE;

        if (op < 70) {
            // 70% reads
            if (cache.get(key)) |_| {
                local_hits += 1;
            } else {
                local_misses += 1;
            }
        } else {
            // 30% writes
            const value = key * 1000 + thread_id;
            cache.put(key, value) catch |err| {
                std.debug.print("Put error: {}\n", .{err});
            };
        }
    }

    std.debug.print("Thread {} completed: {} hits, {} misses\n", .{ thread_id, local_hits, local_misses });
}

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    std.debug.print("TinyUFO v2 Stress Test\n", .{});
    std.debug.print("======================\n", .{});
    std.debug.print("Threads: {}\n", .{NUM_THREADS});
    std.debug.print("Operations per thread: {}\n", .{OPS_PER_THREAD});
    std.debug.print("Total operations: {}\n", .{NUM_THREADS * OPS_PER_THREAD});
    std.debug.print("Cache size: {}\n", .{CACHE_SIZE});
    std.debug.print("Key range: {}\n\n", .{KEY_RANGE});

    // Initialize cache
    var cache_instance = try TinyUFO(u64, u64).init(allocator, CACHE_SIZE);
    defer cache_instance.deinit();
    cache = &cache_instance;

    // Initialize barrier
    ready_barrier = std.atomic.Value(usize).init(0);

    // Create threads
    var threads: [NUM_THREADS]std.Thread = undefined;

    const start_time = std.time.milliTimestamp();

    for (0..NUM_THREADS) |i| {
        threads[i] = try std.Thread.spawn(.{}, workerThread, .{i});
    }

    // Wait for all threads
    for (0..NUM_THREADS) |i| {
        threads[i].join();
    }

    const end_time = std.time.milliTimestamp();
    const elapsed_ms = end_time - start_time;

    // Print final statistics
    const stats = cache.stats();
    std.debug.print("\n======================\n", .{});
    std.debug.print("Test completed in {}ms\n", .{elapsed_ms});
    std.debug.print("\nFinal Cache Stats:\n", .{});
    std.debug.print("  Size: {}/{}\n", .{ stats.size, stats.capacity });
    std.debug.print("  Hits: {}\n", .{stats.hits});
    std.debug.print("  Misses: {}\n", .{stats.misses});
    std.debug.print("  Hit rate: {d:.2}%\n", .{stats.hit_rate * 100});
    std.debug.print("  Evictions: {}\n", .{stats.evictions});

    const total_ops = NUM_THREADS * OPS_PER_THREAD;
    const ops_per_ms = @as(f64, @floatFromInt(total_ops)) / @as(f64, @floatFromInt(elapsed_ms));
    const ops_per_sec = ops_per_ms * 1000.0;
    std.debug.print("\nPerformance:\n", .{});
    std.debug.print("  {d:.0} ops/sec\n", .{ops_per_sec});
    std.debug.print("  {d:.2} us/op\n", .{1000000.0 / ops_per_sec});

    // Verify cache integrity
    std.debug.print("\nVerifying cache integrity...\n", .{});
    var integrity_ok = true;

    // Test that we can still read/write
    try cache.put(999999, 123456);
    if (cache.get(999999)) |val| {
        if (val != 123456) {
            std.debug.print("ERROR: Value mismatch after stress test!\n", .{});
            integrity_ok = false;
        }
    } else {
        std.debug.print("ERROR: Could not retrieve just-inserted value!\n", .{});
        integrity_ok = false;
    }

    if (integrity_ok) {
        std.debug.print("Cache integrity: OK\n", .{});
    } else {
        std.debug.print("Cache integrity: FAILED\n", .{});
        return error.IntegrityCheckFailed;
    }

    std.debug.print("\nStress test PASSED!\n", .{});
}
