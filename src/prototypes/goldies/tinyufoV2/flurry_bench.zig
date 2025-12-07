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

const BenchHashMap = flurry.HashMap(u64, u64, hashU64, eqlU64);

const BenchContext = struct {
    map: *BenchHashMap,
    collector: *ebr.Collector,
    thread_id: usize,
    num_operations: usize,
    allocator: std.mem.Allocator,
    workload_type: WorkloadType,
};

const WorkloadType = enum {
    read_heavy,   // 95% reads, 5% writes
    write_heavy,  // 5% reads, 95% writes
    mixed,        // 50% reads, 50% writes
};

fn benchThread(ctx: *BenchContext) !void {
    const guard = try ctx.collector.pin();
    defer ctx.collector.unpinGuard(guard);

    var prng = std.Random.DefaultPrng.init(@intCast(ctx.thread_id * 1000000 + std.time.nanoTimestamp()));
    const random = prng.random();

    const read_threshold: u8 = switch (ctx.workload_type) {
        .read_heavy => 95,
        .write_heavy => 5,
        .mixed => 50,
    };

    var i: usize = 0;
    while (i < ctx.num_operations) : (i += 1) {
        const op = random.int(u8) % 100;

        if (op < read_threshold) {
            // Read operation
            const key = random.int(u64) % 10000;
            _ = ctx.map.get(key, guard);
        } else {
            // Write operation
            const key = random.int(u64) % 10000;
            const value_ptr = try ctx.allocator.create(u64);
            value_ptr.* = ctx.thread_id * 1000000 + i;
            _ = try ctx.map.put(key, value_ptr, guard);
        }
    }
}

fn runBenchmark(
    allocator: std.mem.Allocator,
    num_threads: usize,
    ops_per_thread: usize,
    workload: WorkloadType,
) !void {
    const workload_name = switch (workload) {
        .read_heavy => "Read-Heavy (95% read)",
        .write_heavy => "Write-Heavy (95% write)",
        .mixed => "Mixed (50/50)",
    };

    std.debug.print("\n=== {s} Workload ===\n", .{workload_name});
    std.debug.print("Threads: {}, Ops/thread: {}\n", .{ num_threads, ops_per_thread });

    var collector = try ebr.Collector.init(allocator);
    defer collector.deinit();

    var map = try BenchHashMap.init(allocator, collector, 1024);
    defer map.deinit();

    // Pre-populate with some data
    {
        const guard = try collector.pin();
        defer collector.unpinGuard(guard);

        var i: usize = 0;
        while (i < 5000) : (i += 1) {
            const val = try allocator.create(u64);
            val.* = i;
            _ = try map.put(i, val, guard);
        }
    }

    var contexts = try allocator.alloc(BenchContext, num_threads);
    defer allocator.free(contexts);

    for (contexts, 0..) |*ctx, i| {
        ctx.* = .{
            .map = map,
            .collector = collector,
            .thread_id = i,
            .num_operations = ops_per_thread,
            .allocator = allocator,
            .workload_type = workload,
        };
    }

    const threads = try allocator.alloc(std.Thread, num_threads);
    defer allocator.free(threads);

    const start = std.time.nanoTimestamp();

    for (threads, 0..) |*thread, i| {
        thread.* = try std.Thread.spawn(.{}, benchThread, .{&contexts[i]});
    }

    for (threads) |thread| {
        thread.join();
    }

    const end = std.time.nanoTimestamp();
    const duration_ns = end - start;
    const duration_ms = @as(f64, @floatFromInt(duration_ns)) / 1_000_000.0;
    const total_ops = num_threads * ops_per_thread;
    const ops_per_sec = @as(f64, @floatFromInt(total_ops)) / (duration_ms / 1000.0);

    std.debug.print("Duration: {d:.2}ms\n", .{duration_ms});
    std.debug.print("Throughput: {d:.0} ops/sec\n", .{ops_per_sec});
    std.debug.print("Final map size: {}\n", .{map.len()});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== Flurry HashMap Benchmark (Zig) ===\n", .{});

    // Single-threaded baseline
    std.debug.print("\n--- Single Thread Baseline ---\n", .{});
    try runBenchmark(allocator, 1, 100000, .mixed);

    // Multi-threaded workloads
    const thread_counts = [_]usize{ 2, 4, 8, 16 };

    for (thread_counts) |threads| {
        std.debug.print("\n--- {} Threads ---\n", .{threads});
        try runBenchmark(allocator, threads, 50000, .read_heavy);
        try runBenchmark(allocator, threads, 50000, .mixed);
        try runBenchmark(allocator, threads, 50000, .write_heavy);
    }

    std.debug.print("\n=== Benchmark Complete ===\n", .{});
}
