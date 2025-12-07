const std = @import("std");
const TinyUFO = @import("tinyufo.zig").TinyUFO;

const ThreadContext = struct {
    cache: *TinyUFO(u64, u64),
    thread_id: usize,
    ops_per_thread: usize,
};

fn workerThread(ctx: ThreadContext) void {
    const collector = ctx.cache.getCollector();
    const guard = collector.pin() catch {
        std.debug.print("Thread {}: Failed to pin\n", .{ctx.thread_id});
        return;
    };
    defer collector.unpinGuard(guard);

    std.debug.print("Thread {} started\n", .{ctx.thread_id});

    var i: usize = 0;
    while (i < ctx.ops_per_thread) : (i += 1) {
        // HIGH CONTENTION: All threads access the SAME 100 hot keys!
        // This mimics zipf distribution where many threads hit same keys
        const key = i % 100;  // Only 100 keys, all threads fighting for same keys

        // Mix of puts and gets (same as before)
        if (i % 2 == 0) {
            ctx.cache.putWithGuard(key, key, guard) catch {};
        } else {
            _ = ctx.cache.getWithGuard(key, guard);
        }

        // Print progress every 10000 ops
        if (i % 10000 == 0 and i > 0) {
            std.debug.print("Thread {}: {} ops done\n", .{ ctx.thread_id, i });
        }
    }

    std.debug.print("Thread {} completed {} ops\n", .{ ctx.thread_id, ctx.ops_per_thread });
}

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    const num_threads = 16;
    const ops_per_thread = 562_500; // Match benchmark: 9M / 16
    const cache_size = 10_000; // Match benchmark

    std.debug.print("Creating cache (size={})\n", .{cache_size});
    var cache = try TinyUFO(u64, u64).init(allocator, cache_size);
    defer cache.deinit();

    std.debug.print("Starting {} threads with HIGH CONTENTION (100 shared keys), {} ops each\n", .{ num_threads, ops_per_thread });

    var threads = try allocator.alloc(std.Thread, num_threads);
    defer allocator.free(threads);

    // Spawn threads
    for (0..num_threads) |i| {
        const ctx = ThreadContext{
            .cache = &cache,
            .thread_id = i,
            .ops_per_thread = ops_per_thread,
        };
        threads[i] = try std.Thread.spawn(.{}, workerThread, .{ctx});
        std.debug.print("Spawned thread {}\n", .{i});
    }

    // Wait for all threads
    std.debug.print("Waiting for threads to complete...\n", .{});
    for (threads, 0..) |thread, i| {
        thread.join();
        std.debug.print("Thread {} joined\n", .{i});
    }

    const stats = cache.stats();
    std.debug.print("\n=== Final Stats ===\n", .{});
    std.debug.print("Hits: {}, Misses: {}, Evictions: {}\n", .{ stats.hits, stats.misses, stats.evictions });
    std.debug.print("Hit Rate: {d:.2}%\n", .{stats.hit_rate * 100.0});
    std.debug.print("\n✓ Test completed successfully!\n", .{});
}
