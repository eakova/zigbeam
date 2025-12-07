/// TinyUFO v3 Benchmark Suite
/// Comprehensive performance testing and comparison with Rust baseline

const std = @import("std");
const tinyufo = @import("tinyufov3");

const TinyUFO = tinyufo.TinyUFO;
const BackendType = tinyufo.BackendType;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("TinyUFO v3 Benchmark Suite\n", .{});
    std.debug.print("==========================\n\n", .{});

    // Benchmark 1: Sequential read/write (small cache)
    try bench_sequential_small(allocator);

    // Benchmark 2: Sequential read/write (large cache)
    try bench_sequential_large(allocator);

    // Benchmark 3: Random access patterns
    try bench_random_access(allocator);

    // Benchmark 4: High eviction scenario
    try bench_eviction_scenario(allocator);

    // Benchmark 5: Hotspot workload
    try bench_hotspot_workload(allocator);

    // Benchmark 6: Backend comparison
    try bench_backend_comparison(allocator);

    // Benchmark 7: Concurrent access
    try bench_concurrent_access(allocator);

    // Benchmark 8: Weight-based capacity
    try bench_weight_capacity(allocator);

    std.debug.print("\n" ++ "=" ** 80 ++ "\n", .{});
    std.debug.print("Benchmark Suite Complete\n", .{});
    std.debug.print("=" ** 80 ++ "\n", .{});
}

fn bench_sequential_small(allocator: std.mem.Allocator) !void {
    std.debug.print("Benchmark 1: Sequential R/W (Small Cache 100KB)...\n", .{});

    const cache = try TinyUFO(u64).init(allocator, 100_000);
    defer cache.deinit();

    var timer = try std.time.Timer.start();

    const ops: u64 = 100_000;
    for (0..ops) |i| {
        try cache.set(@intCast(i % 1000), @intCast(i), 100);
        _ = cache.get(@intCast(i % 1000));
    }

    const duration = timer.read();
    _ = cache.stats();
    const ops_per_sec = (@as(f64, @floatFromInt(ops)) / @as(f64, @floatFromInt(duration))) * 1e9;
    const hit_rate = cache.hit_rate();

    std.debug.print("  Ops: {}, Duration: {d:.2}ms, Ops/sec: {d:.0}, Hit rate: {d:.2}%\n\n", .{
        ops,
        @as(f64, @floatFromInt(duration)) / 1e6,
        ops_per_sec,
        hit_rate * 100.0,
    });
}

fn bench_sequential_large(allocator: std.mem.Allocator) !void {
    std.debug.print("Benchmark 2: Sequential R/W (Large Cache 10MB)...\n", .{});

    const cache = try TinyUFO(u64).init(allocator, 10_000_000);
    defer cache.deinit();

    var timer = try std.time.Timer.start();

    const ops: u64 = 50_000;
    for (0..ops) |i| {
        try cache.set(@intCast(i), @intCast(i * 2), 100);
        _ = cache.get(@intCast(i));
    }

    const duration = timer.read();
    _ = cache.stats();
    const ops_per_sec = (@as(f64, @floatFromInt(ops)) / @as(f64, @floatFromInt(duration))) * 1e9;
    const hit_rate = cache.hit_rate();

    std.debug.print("  Ops: {}, Duration: {d:.2}ms, Ops/sec: {d:.0}, Hit rate: {d:.2}%\n\n", .{
        ops,
        @as(f64, @floatFromInt(duration)) / 1e6,
        ops_per_sec,
        hit_rate * 100.0,
    });
}

fn bench_random_access(allocator: std.mem.Allocator) !void {
    std.debug.print("Benchmark 3: Random Access Pattern...\n", .{});

    const cache = try TinyUFO(u64).init(allocator, 1_000_000);
    defer cache.deinit();

    // Pre-populate cache
    for (0..1000) |i| {
        try cache.set(@intCast(i), @intCast(i), 100);
    }

    var timer = try std.time.Timer.start();

    const ops: u64 = 100_000;
    var seed: u64 = 12345;
    for (0..ops) |_| {
        seed = (seed *% 1103515245 +% 12345) & 0x7fffffff;
        const key = seed % 1000;

        if (seed % 2 == 0) {
            _ = cache.get(@intCast(key));
        } else {
            try cache.set(@intCast(key), @intCast(seed), 100);
        }
    }

    const duration = timer.read();
    _ = cache.stats();
    const ops_per_sec = (@as(f64, @floatFromInt(ops)) / @as(f64, @floatFromInt(duration))) * 1e9;
    const hit_rate = cache.hit_rate();

    std.debug.print("  Ops: {}, Duration: {d:.2}ms, Ops/sec: {d:.0}, Hit rate: {d:.2}%\n\n", .{
        ops,
        @as(f64, @floatFromInt(duration)) / 1e6,
        ops_per_sec,
        hit_rate * 100.0,
    });
}

fn bench_eviction_scenario(allocator: std.mem.Allocator) !void {
    std.debug.print("Benchmark 4: High Eviction Scenario...\n", .{});

    const cache = try TinyUFO(u64).init(allocator, 50_000);

    var timer = try std.time.Timer.start();

    const ops: u64 = 10_000;
    for (0..ops) |i| {
        try cache.set(@intCast(i), @intCast(i), 100);
    }

    const duration = timer.read();
    const stats = cache.stats();
    const ops_per_sec = (@as(f64, @floatFromInt(ops)) / @as(f64, @floatFromInt(duration))) * 1e9;

    std.debug.print("  Ops: {}, Duration: {d:.2}ms, Ops/sec: {d:.0}, Evictions: {}\n\n", .{
        ops,
        @as(f64, @floatFromInt(duration)) / 1e6,
        ops_per_sec,
        stats.evictions,
    });

    cache.deinit();
}

fn bench_hotspot_workload(allocator: std.mem.Allocator) !void {
    std.debug.print("Benchmark 5: Hotspot Workload (80/20 principle)...\n", .{});

    const cache = try TinyUFO(u64).init(allocator, 1_000_000);
    defer cache.deinit();

    var timer = try std.time.Timer.start();

    const ops: u64 = 100_000;
    var seed: u64 = 42;
    for (0..ops) |_| {
        seed = (seed *% 1103515245 +% 12345) & 0x7fffffff;

        // 80% access to 20% of keys
        const key = if (seed % 100 < 80) seed % 200 else seed % 1000;

        if (seed % 3 == 0) {
            _ = cache.get(@intCast(key));
        } else {
            try cache.set(@intCast(key), @intCast(seed), 100);
        }
    }

    const duration = timer.read();
    _ = cache.stats();
    const ops_per_sec = (@as(f64, @floatFromInt(ops)) / @as(f64, @floatFromInt(duration))) * 1e9;
    const hit_rate = cache.hit_rate();

    std.debug.print("  Ops: {}, Duration: {d:.2}ms, Ops/sec: {d:.0}, Hit rate: {d:.2}%\n\n", .{
        ops,
        @as(f64, @floatFromInt(duration)) / 1e6,
        ops_per_sec,
        hit_rate * 100.0,
    });
}

fn bench_backend_comparison(allocator: std.mem.Allocator) !void {
    std.debug.print("Benchmark 6: Backend Comparison (Fast vs Compact)...\n", .{});

    // Test Fast backend
    const cache_fast = try TinyUFO(u64).init_with_backend(allocator, 1_000_000, .Fast);

    var timer = try std.time.Timer.start();
    for (0..50_000) |i| {
        try cache_fast.set(@intCast(i), @intCast(i), 100);
        _ = cache_fast.get(@intCast(i));
    }
    const duration_fast = timer.read();
    _ = cache_fast.stats();

    cache_fast.deinit();

    // Test Compact backend
    const cache_compact = try TinyUFO(u64).init_with_backend(allocator, 1_000_000, .Compact);

    timer = try std.time.Timer.start();
    for (0..50_000) |i| {
        try cache_compact.set(@intCast(i), @intCast(i), 100);
        _ = cache_compact.get(@intCast(i));
    }
    const duration_compact = timer.read();
    _ = cache_compact.stats();

    cache_compact.deinit();

    const ops_per_sec_fast = (50000.0 / @as(f64, @floatFromInt(duration_fast))) * 1e9;
    const ops_per_sec_compact = (50000.0 / @as(f64, @floatFromInt(duration_compact))) * 1e9;

    std.debug.print("  Fast:    {d:.0} ops/sec ({d:.2}ms)\n", .{
        ops_per_sec_fast,
        @as(f64, @floatFromInt(duration_fast)) / 1e6,
    });
    std.debug.print("  Compact: {d:.0} ops/sec ({d:.2}ms)\n", .{
        ops_per_sec_compact,
        @as(f64, @floatFromInt(duration_compact)) / 1e6,
    });

    const ratio = ops_per_sec_fast / ops_per_sec_compact;
    std.debug.print("  Ratio: {d:.2}x (Fast/Compact)\n\n", .{ratio});
}

fn bench_concurrent_access(allocator: std.mem.Allocator) !void {
    std.debug.print("Benchmark 7: Concurrent Access Patterns...\n", .{});

    const cache = try TinyUFO(u64).init(allocator, 1_000_000);

    var timer = try std.time.Timer.start();

    const ops: u64 = 50_000;
    for (0..ops) |i| {
        try cache.set(@intCast(i % 5000), @intCast(i), 100);
        _ = cache.get(@intCast(i % 5000));
    }

    const duration = timer.read();
    _ = cache.stats();
    const ops_per_sec = (@as(f64, @floatFromInt(ops)) / @as(f64, @floatFromInt(duration))) * 1e9;
    const hit_rate = cache.hit_rate();

    std.debug.print("  Ops: {}, Duration: {d:.2}ms, Ops/sec: {d:.0}, Hit rate: {d:.2}%\n\n", .{
        ops,
        @as(f64, @floatFromInt(duration)) / 1e6,
        ops_per_sec,
        hit_rate * 100.0,
    });

    cache.deinit();
}

fn bench_weight_capacity(allocator: std.mem.Allocator) !void {
    std.debug.print("Benchmark 8: Weight-Based Capacity Management...\n", .{});

    const cache = try TinyUFO([]const u8).init(allocator, 10_000);

    var timer = try std.time.Timer.start();

    const ops: u64 = 1_000;
    var buf: [1024]u8 = undefined;
    for (0..ops) |i| {
        const size = @min(100 + (i % 500), 1000);
        @memset(buf[0..size], @intCast(i % 256));

        try cache.set(@intCast(i), buf[0..size], @intCast(size));
    }

    const duration = timer.read();
    const stats = cache.stats();
    const ops_per_sec = (@as(f64, @floatFromInt(ops)) / @as(f64, @floatFromInt(duration))) * 1e9;

    std.debug.print("  Ops: {}, Duration: {d:.2}ms, Ops/sec: {d:.0}, Total weight: {}\n\n", .{
        ops,
        @as(f64, @floatFromInt(duration)) / 1e6,
        ops_per_sec,
        stats.total_weight,
    });

    cache.deinit();
}
