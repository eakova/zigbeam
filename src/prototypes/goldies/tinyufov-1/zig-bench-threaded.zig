/// Multi-threaded TinyUFO v3 Benchmark Suite
/// Tests performance across 1, 2, 4, 8, and 16 threads

const std = @import("std");
const tinyufo = @import("tinyufov3");

const TinyUFO = tinyufo.TinyUFO;

// Shared cache and metrics
var cache: ?*TinyUFO(u64) = null;
var allocator: std.mem.Allocator = undefined;

const BenchResult = struct {
    ops: u64,
    duration_ns: u64,
    ops_per_sec: f64,
    hit_rate: f64,
    evictions: u64,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    allocator = gpa.allocator();

    std.debug.print("\n╔════════════════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║     TinyUFO v3 MULTI-THREADED BENCHMARK (1, 2, 4, 8, 16 threads)   ║\n", .{});
    std.debug.print("╚════════════════════════════════════════════════════════════════════╝\n\n", .{});

    // Test configurations
    const thread_counts = [_]u32{ 1, 2, 4, 8, 16 };
    const workloads = [_][]const u8{ "random_access", "sequential", "hotspot", "mixed" };

    for (thread_counts) |threads| {
        std.debug.print("\n================================================================================\n", .{});
        std.debug.print("THREAD COUNT: {} threads\n", .{threads});
        std.debug.print("================================================================================\n", .{});

        for (workloads) |workload| {
            try run_workload_threaded(threads, workload);
        }
    }

    std.debug.print("\n================================================================================\n", .{});
    std.debug.print("Multi-Threaded Benchmark Complete\n", .{});
    std.debug.print("================================================================================\n\n", .{});
}

fn run_workload_threaded(thread_count: u32, workload: []const u8) !void {
    const c = try TinyUFO(u64).init(allocator, 1_000_000);
    cache = c;
    defer c.deinit();

    std.debug.print("\n{s} ({} threads): ", .{ workload, thread_count });

    var threads_array: [16]std.Thread = undefined;
    var thread_count_actual: u32 = 0;

    var timer = try std.time.Timer.start();

    // Create and spawn threads
    if (std.mem.eql(u8, workload, "random_access")) {
        for (0..thread_count) |i| {
            threads_array[i] = try std.Thread.spawn(.{}, thread_random_access, .{@as(u64, @intCast(i))});
            thread_count_actual += 1;
        }
    } else if (std.mem.eql(u8, workload, "sequential")) {
        for (0..thread_count) |i| {
            threads_array[i] = try std.Thread.spawn(.{}, thread_sequential, .{@as(u64, @intCast(i)), thread_count});
            thread_count_actual += 1;
        }
    } else if (std.mem.eql(u8, workload, "hotspot")) {
        for (0..thread_count) |i| {
            threads_array[i] = try std.Thread.spawn(.{}, thread_hotspot, .{@as(u64, @intCast(i))});
            thread_count_actual += 1;
        }
    } else if (std.mem.eql(u8, workload, "mixed")) {
        for (0..thread_count) |i| {
            threads_array[i] = try std.Thread.spawn(.{}, thread_mixed, .{@as(u64, @intCast(i))});
            thread_count_actual += 1;
        }
    }

    // Wait for all threads
    for (0..thread_count_actual) |i| {
        threads_array[i].join();
    }

    const duration = timer.read();

    const hit_rate = c.hit_rate();
    const ops_per_sec = (100_000.0 / @as(f64, @floatFromInt(duration))) * 1e9;

    std.debug.print("Ops/sec: {d:.0}, Hit rate: {d:.2}%\n", .{ ops_per_sec, hit_rate * 100.0 });
}

fn thread_random_access(thread_id: u64) void {
    if (cache) |c| {
        for (0..100_000) |i| {
            const key = (thread_id * 100_000 + i) % 10_000;
            c.set(@intCast(key), @intCast(i), 100) catch {};
            _ = c.get(@intCast(key));
        }
    }
}

fn thread_sequential(thread_id: u64, total_threads: u32) void {
    if (cache) |c| {
        const per_thread = 100_000 / @as(u64, @intCast(total_threads));
        const start = thread_id * per_thread;
        const end = if (thread_id == @as(u64, @intCast(total_threads - 1))) 100_000 else start + per_thread;

        for (start..end) |i| {
            c.set(@intCast(i), @intCast(i * 2), 100) catch {};
            _ = c.get(@intCast(i));
        }
    }
}

fn thread_hotspot(thread_id: u64) void {
    if (cache) |c| {
        for (0..100_000) |i| {
            // 80% of accesses to 20% of data (200 hot keys)
            const key = if (i % 100 < 80) @as(u64, @intCast(i % 200)) else @as(u64, @intCast(200 + (i % 4800)));
            c.set(key, thread_id * 100_000 + i, 100) catch {};
            _ = c.get(key);
        }
    }
}

fn thread_mixed(thread_id: u64) void {
    if (cache) |c| {
        for (0..100_000) |i| {
            // 50% reads, 50% writes
            if (i % 2 == 0) {
                // Write
                const key = (thread_id * 50_000 + i / 2) % 1000;
                c.set(key, @intCast(i), 100) catch {};
            } else {
                // Read
                const key = (thread_id * 50_000 + i / 2) % 1000;
                _ = c.get(key);
            }
        }
    }
}
