const std = @import("std");
const Rcu = @import("rcu.zig").Rcu;
const Thread = std.Thread;
const Timer = std.time.Timer;

const Config = struct {
    value: u64,
    fn destroy(self: *Config, alloc: std.mem.Allocator) void {
        alloc.destroy(self);
    }
};

fn benchmark(
    name: []const u8,
    readers: usize,
    writers: usize,
    duration_ms: u64,
) !void {
    std.debug.print("\n╔═══════════════════════════════════════╗\n", .{});
    std.debug.print("║ {s: <37} ║\n", .{name});
    std.debug.print("╠═══════════════════════════════════════╣\n", .{});
    std.debug.print("║ Readers: {d: >4} | Writers: {d: >4}       ║\n", .{ readers, writers });
    std.debug.print("║ Queue: 64K | Bag: 8K (no expand)   ║\n", .{});
    std.debug.print("╚═══════════════════════════════════════╝\n", .{});

    const allocator = std.heap.c_allocator;

    const initial = try allocator.create(Config);
    initial.* = .{ .value = 0 };

    const RcuConfig = Rcu(Config);
    // Use 64K primary queue, 8K bag with auto-expand disabled
    const queue_size: usize = 65536;
    const bag_size: usize = 8192;
    const rcu = try RcuConfig.init(allocator, initial, Config.destroy, .{
        .queue_size = queue_size,
        .bag_capacity = bag_size,
        .reclaim_interval_ns = 5 * std.time.ns_per_ms,
        .use_expanded_queues_on_overflow = false,
    });
    defer rcu.deinit();

    var stop = std.atomic.Value(bool).init(false);
    var read_ops = std.atomic.Value(u64).init(0);
    var write_ops = std.atomic.Value(u64).init(0);

    const Reader = struct {
        rcu: *const RcuConfig,
        stop_flag: *std.atomic.Value(bool),
        counter: *std.atomic.Value(u64),

        fn run(self: *@This()) void {
            var local: u64 = 0;
            var checksum: u64 = 0; // BUGFIX: Accumulate values to prevent optimizer from removing get()
            while (!self.stop_flag.load(.acquire)) {
                const guard = self.rcu.read() catch break;
                defer guard.release();
                // BUGFIX: Actually USE the value - wrapping add prevents overflow
                checksum +%= guard.get().value;
                local += 1;
            }
            _ = self.counter.fetchAdd(local, .monotonic);
            // BUGFIX: Prevent compiler from optimizing away checksum variable
            std.mem.doNotOptimizeAway(&checksum);
        }
    };

    const Writer = struct {
        rcu: *RcuConfig,
        stop_flag: *std.atomic.Value(bool),
        counter: *std.atomic.Value(u64),

        fn run(self: *@This()) void {
            const Ctx = struct {
                fn update(ctx: *anyopaque, alloc: std.mem.Allocator, curr: ?*const Config) !*Config {
                    _ = ctx;
                    const new = try alloc.create(Config);
                    new.* = curr.?.*;
                    new.value += 1;
                    return new;
                }
            };

            var local: u64 = 0;
            var backoff: u64 = 100; // Start with 100 microseconds
            while (!self.stop_flag.load(.acquire)) {
                var ctx: u8 = 0;
                self.rcu.update(&ctx, Ctx.update) catch {
                    // Exponential backoff for queue full
                    Thread.sleep(backoff * std.time.ns_per_us);
                    backoff = @min(backoff * 2, 10000); // Max 10ms
                    continue;
                };
                backoff = 100; // Reset backoff on success
                local += 1;
            }
            _ = self.counter.fetchAdd(local, .monotonic);
        }
    };

    const reader_threads = try allocator.alloc(Thread, readers);
    defer allocator.free(reader_threads);
    const reader_ctxs = try allocator.alloc(Reader, readers);
    defer allocator.free(reader_ctxs);

    const writer_threads = try allocator.alloc(Thread, writers);
    defer allocator.free(writer_threads);
    const writer_ctxs = try allocator.alloc(Writer, writers);
    defer allocator.free(writer_ctxs);

    var timer = try Timer.start();

    for (reader_threads, reader_ctxs) |*t, *ctx| {
        ctx.* = .{ .rcu = rcu, .stop_flag = &stop, .counter = &read_ops };
        t.* = try Thread.spawn(.{}, Reader.run, .{ctx});
    }

    for (writer_threads, writer_ctxs) |*t, *ctx| {
        ctx.* = .{ .rcu = rcu, .stop_flag = &stop, .counter = &write_ops };
        t.* = try Thread.spawn(.{}, Writer.run, .{ctx});
    }

    Thread.sleep(duration_ms * std.time.ns_per_ms);
    stop.store(true, .release);

    for (reader_threads) |t| t.join();
    for (writer_threads) |t| t.join();

    const elapsed_ns = timer.read();
    const elapsed_s = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, std.time.ns_per_s);

    const reads = read_ops.load(.monotonic);
    const writes = write_ops.load(.monotonic);

    const reads_per_sec = @as(f64, @floatFromInt(reads)) / elapsed_s;
    const writes_per_sec = @as(f64, @floatFromInt(writes)) / elapsed_s;

    std.debug.print("\n📊 Results:\n", .{});
    std.debug.print("  ├─ Reads:    {d: >12} ({d: >7.2} M/sec)\n", .{ reads, reads_per_sec / 1_000_000.0 });
    std.debug.print("  ├─ Writes:   {d: >12} ({d: >7.2} K/sec)\n", .{ writes, writes_per_sec / 1_000.0 });
    const ratio = if (writes > 0) @as(f64, @floatFromInt(reads)) / @as(f64, @floatFromInt(writes)) else 0;
    std.debug.print("  ├─ Ratio:    {d: >12.1}:1\n", .{ratio});
    std.debug.print("  └─ Duration: {d: >12.3}s\n", .{elapsed_s});
}

pub fn main() !void {
    std.debug.print("\n", .{});
    std.debug.print("╔═══════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║           RCU PERFORMANCE BENCHMARK               ║\n", .{});
    std.debug.print("║          Maximum Throughput Edition               ║\n", .{});
    std.debug.print("╚═══════════════════════════════════════════════════╝\n", .{});

    // Standard benchmarks
    try benchmark("Read-Heavy Workload", 16, 2, 2000);
    try benchmark("Balanced Workload", 8, 4, 2000);
    try benchmark("Extreme Read-Heavy", 32, 1, 2000);
    try benchmark("Many Readers", 64, 2, 2000);

    // New intensive benchmarks
    try benchmark("Heavy Contention", 64, 16, 2000);
    try benchmark("Write-Heavy Workload", 4, 64, 2000);
    try benchmark("Maximum Contention", 64, 64, 2000);

    std.debug.print("\n", .{});
    std.debug.print("╔═══════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║               BENCHMARK COMPLETE                  ║\n", .{});
    std.debug.print("╚═══════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\n", .{});
}
