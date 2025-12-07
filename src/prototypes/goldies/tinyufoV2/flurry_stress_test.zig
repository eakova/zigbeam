const std = @import("std");
const flurry = @import("flurry.zig");
const ebr = @import("ebr.zig");

// Simple hash function for u64 keys
fn hashU64(key: u64) u64 {
    return key;
}

// Simple equality for u64 keys
fn eqlU64(a: u64, b: u64) bool {
    return a == b;
}

const TestHashMap = flurry.HashMap(u64, u64, hashU64, eqlU64);

const ThreadContext = struct {
    map: *TestHashMap,
    collector: *ebr.Collector,
    thread_id: usize,
    num_operations: usize,
    allocator: std.mem.Allocator,
};

fn workerThread(ctx: *ThreadContext) !void {
    const guard = try ctx.collector.pin();
    defer ctx.collector.unpinGuard(guard);

    var prng = std.Random.DefaultPrng.init(@intCast(ctx.thread_id + std.time.nanoTimestamp()));
    const random = prng.random();

    var i: usize = 0;
    while (i < ctx.num_operations) : (i += 1) {
        const op = random.int(u8) % 100;

        if (op < 50) {
            // 50% inserts/updates
            const key = random.int(u64) % 1000; // Keys in range [0, 999]
            const value_ptr = try ctx.allocator.create(u64);
            value_ptr.* = ctx.thread_id * 1000000 + i;

            // Try to insert - might replace existing value
            const old_value = try ctx.map.put(key, value_ptr, guard);
            if (old_value) |_| {
                // Value was replaced - in production, EBR would retire it
                // For now, we leak it (test focus is on correctness, not memory)
            }
        } else {
            // 50% reads
            const key = random.int(u64) % 1000;
            const value = ctx.map.get(key, guard);

            // Verify we got something reasonable (if exists)
            if (value) |v| {
                _ = v.*; // Just access it to ensure it's valid
            }
        }

        // Continue without yielding - let OS scheduler handle contention
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const num_threads = 16;
    const operations_per_thread = 10000;

    std.debug.print("=== Flurry HashMap Stress Test ===\n", .{});
    std.debug.print("Threads: {}\n", .{num_threads});
    std.debug.print("Operations per thread: {}\n", .{operations_per_thread});
    std.debug.print("Total operations: {}\n\n", .{num_threads * operations_per_thread});

    // Initialize EBR collector
    var collector = try ebr.Collector.init(allocator);
    defer collector.deinit();

    // Create HashMap with larger initial capacity to reduce resizing
    var map = try TestHashMap.init(allocator, collector, 256);
    defer map.deinit();

    std.debug.print("HashMap initialized\n", .{});

    // Create thread contexts
    var contexts = try allocator.alloc(ThreadContext, num_threads);
    defer allocator.free(contexts);

    for (contexts, 0..) |*ctx, i| {
        ctx.* = .{
            .map = map,
            .collector = collector,
            .thread_id = i,
            .num_operations = operations_per_thread,
            .allocator = allocator,
        };
    }

    // Spawn threads
    const threads = try allocator.alloc(std.Thread, num_threads);
    defer allocator.free(threads);

    std.debug.print("Starting {} threads...\n", .{num_threads});
    const start_time = std.time.nanoTimestamp();

    for (threads, 0..) |*thread, i| {
        thread.* = try std.Thread.spawn(.{}, workerThread, .{&contexts[i]});
    }

    // Wait for all threads to complete
    for (threads) |thread| {
        thread.join();
    }

    const end_time = std.time.nanoTimestamp();
    const duration_ns = end_time - start_time;
    const duration_ms = @as(f64, @floatFromInt(duration_ns)) / 1_000_000.0;

    std.debug.print("\n=== Results ===\n", .{});
    std.debug.print("Duration: {d:.2} ms\n", .{duration_ms});
    std.debug.print("Final map size: {}\n", .{map.len()});

    const total_ops = num_threads * operations_per_thread;
    const ops_per_sec = @as(f64, @floatFromInt(total_ops)) / (duration_ms / 1000.0);
    std.debug.print("Throughput: {d:.0} ops/sec\n", .{ops_per_sec});

    std.debug.print("\n=== Stress Test Completed Successfully! ===\n", .{});
}
