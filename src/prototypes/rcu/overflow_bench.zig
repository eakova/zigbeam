const std = @import("std");
const Rcu = @import("rcu.zig").Rcu;
const Thread = std.Thread;

const TestData = struct {
    value: u64,
    generation: u64,
    padding: [48]u8 = undefined, // Cache line alignment
};

/// Special benchmark to test 3-level queue and bag overflow
fn benchmarkOverflow() !void {
    const allocator = std.heap.c_allocator;

    // Create initial data
    const initial = try allocator.create(TestData);
    initial.* = .{ .value = 0, .generation = 0 };

    const RcuTest = Rcu(TestData);

    // Use VERY small sizes to force overflow quickly
    const config = RcuTest.Config{
        .queue_size = 16,      // Minimum size to force overflow
        .bag_capacity = 32,     // Minimum size to force batch overflow
        .reclaim_interval_ns = 10 * std.time.ns_per_ms,  // Faster reclaim for more batch activity
        .use_expanded_queues_on_overflow = true,
    };

    const rcu = try RcuTest.init(allocator, initial, destroyTestData, config);
    defer rcu.deinit();

    // Stats tracking
    const Stats = struct {
        primary_queue_fulls: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        secondary_created: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        tertiary_created: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        updates_succeeded: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        updates_failed: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        reads_performed: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    };

    var stats = Stats{};
    var stop = std.atomic.Value(bool).init(false);
    const duration_ms = 5000; // 5 second stress test

    // Writer context - generates massive update pressure
    const WriterCtx = struct {
        rcu: *RcuTest,
        id: u32,
        stats: *Stats,
        stop: *const std.atomic.Value(bool),

        fn run(self: *@This()) void {
            var generation: u64 = 0;
            while (!self.stop.load(.acquire)) {
                var ctx = UpdateCtx{
                    .writer_id = self.id,
                    .generation = generation,
                };

                // Try update, track if we hit overflow
                self.rcu.update(&ctx, UpdateCtx.update) catch |err| {
                    if (err == error.QueueFull) {
                        _ = self.stats.primary_queue_fulls.fetchAdd(1, .monotonic);
                    }
                    _ = self.stats.updates_failed.fetchAdd(1, .monotonic);
                    // Tiny sleep to reduce contention slightly
                    Thread.sleep(100 * std.time.ns_per_us);
                    continue;
                };

                _ = self.stats.updates_succeeded.fetchAdd(1, .monotonic);
                generation += 1;

                // Check if secondary/tertiary queues exist (this is a hack for testing)
                if (self.rcu.secondary_mod_queue != null and
                    !self.stats.secondary_created.load(.acquire)) {
                    self.stats.secondary_created.store(true, .release);
                    std.debug.print("  🔸 Secondary queue created!\n", .{});
                }
                if (self.rcu.tertiary_mod_queue != null and
                    !self.stats.tertiary_created.load(.acquire)) {
                    self.stats.tertiary_created.store(true, .release);
                    std.debug.print("  🔹 Tertiary queue created!\n", .{});
                }
            }
        }

        const UpdateCtx = struct {
            writer_id: u32,
            generation: u64,

            fn update(ctx: *anyopaque, alloc: std.mem.Allocator, current: ?*const TestData) !*TestData {
                const self: *UpdateCtx = @ptrCast(@alignCast(ctx));
                const new = try alloc.create(TestData);
                new.* = .{
                    .value = if (current) |c| c.value + 1 else 0,
                    .generation = self.generation,
                };
                return new;
            }
        };
    };

    // Reader context - creates epoch pressure
    const ReaderCtx = struct {
        rcu: *const RcuTest,
        stats: *Stats,
        stop: *const std.atomic.Value(bool),

        fn run(self: *@This()) void {
            while (!self.stop.load(.acquire)) {
                const guard = self.rcu.read() catch return;
                defer guard.release();

                const data = guard.get();
                _ = data.value; // Touch the data

                _ = self.stats.reads_performed.fetchAdd(1, .monotonic);

                // Vary read duration to create different epoch advancement patterns
                if (self.stats.reads_performed.load(.monotonic) % 100 == 0) {
                    Thread.sleep(std.time.ns_per_us); // Fast read
                } else {
                    Thread.sleep(10 * std.time.ns_per_us); // Slower read
                }
            }
        }
    };

    std.debug.print("\n╔═══════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║         OVERFLOW STRESS TEST                      ║\n", .{});
    std.debug.print("╠═══════════════════════════════════════════════════╣\n", .{});
    std.debug.print("║ Primary Queue:    16 slots (minimum)             ║\n", .{});
    std.debug.print("║ Primary Bag:      32 objects (minimum)           ║\n", .{});
    std.debug.print("║ Writers:          16 threads (high pressure)     ║\n", .{});
    std.debug.print("║ Readers:          16 threads                     ║\n", .{});
    std.debug.print("╚═══════════════════════════════════════════════════╝\n", .{});

    var timer = try std.time.Timer.start();

    // Launch many writers to create queue pressure
    var writer_threads: [16]Thread = undefined;  // Reduced from 32 to allow some draining
    for (&writer_threads, 0..) |*t, i| {
        const ctx = try allocator.create(WriterCtx);
        ctx.* = .{
            .rcu = rcu,
            .id = @intCast(i),
            .stats = &stats,
            .stop = &stop,
        };
        t.* = try Thread.spawn(.{}, WriterCtx.run, .{ctx});
    }

    // Launch readers to create epoch advancement
    var reader_threads: [16]Thread = undefined;
    for (&reader_threads) |*t| {
        const ctx = try allocator.create(ReaderCtx);
        ctx.* = .{
            .rcu = rcu,
            .stats = &stats,
            .stop = &stop,
        };
        t.* = try Thread.spawn(.{}, ReaderCtx.run, .{ctx});
    }

    // Monitor progress
    var last_updates: u64 = 0;
    var last_reads: u64 = 0;
    const monitor_interval = 1000 * std.time.ns_per_ms; // 1 second

    while (timer.read() < duration_ms * std.time.ns_per_ms) {
        Thread.sleep(monitor_interval);

        const updates = stats.updates_succeeded.load(.monotonic);
        const reads = stats.reads_performed.load(.monotonic);
        const failures = stats.updates_failed.load(.monotonic);

        const update_rate = updates - last_updates;
        const read_rate = reads - last_reads;

        std.debug.print("  [{d:>2}s] Updates: {d: >6}/s, Reads: {d: >6}/s, Failures: {d: >6}\n",
            .{ timer.read() / std.time.ns_per_s, update_rate, read_rate, failures });

        last_updates = updates;
        last_reads = reads;
    }

    stop.store(true, .release);

    // Give threads time to see the stop signal
    Thread.sleep(100 * std.time.ns_per_ms);

    for (writer_threads) |t| t.join();
    for (reader_threads) |t| t.join();

    const elapsed_ns = timer.read();
    const elapsed_s = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, std.time.ns_per_s);

    // Final statistics
    std.debug.print("\n📊 Final Results:\n", .{});
    std.debug.print("  ├─ Duration:           {d:.2}s\n", .{elapsed_s});
    std.debug.print("  ├─ Updates Succeeded:  {d: >10} ({d:.2} K/sec)\n",
        .{ stats.updates_succeeded.load(.monotonic),
           @as(f64, @floatFromInt(stats.updates_succeeded.load(.monotonic))) / elapsed_s / 1000.0 });
    std.debug.print("  ├─ Updates Failed:     {d: >10}\n", .{stats.updates_failed.load(.monotonic)});
    std.debug.print("  ├─ Reads Performed:    {d: >10} ({d:.2} M/sec)\n",
        .{ stats.reads_performed.load(.monotonic),
           @as(f64, @floatFromInt(stats.reads_performed.load(.monotonic))) / elapsed_s / 1_000_000.0 });
    std.debug.print("  ├─ Primary Queue Fulls:{d: >10}\n", .{stats.primary_queue_fulls.load(.monotonic)});
    std.debug.print("  ├─ Secondary Queue:    {s}\n",
        .{if (stats.secondary_created.load(.monotonic)) "✅ Created" else "❌ Not needed"});
    std.debug.print("  └─ Tertiary Queue:     {s}\n",
        .{if (stats.tertiary_created.load(.monotonic)) "✅ Created" else "❌ Not needed"});

    // Note: Bag overflow status would require access to internals
    std.debug.print("\n  Note: Bag overflow tracking requires RCU internals access\n", .{});
}

fn destroyTestData(self: *TestData, alloc: std.mem.Allocator) void {
    alloc.destroy(self);
}

pub fn main() !void {
    std.debug.print("\n╔═══════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║      3-LEVEL OVERFLOW BENCHMARK                   ║\n", .{});
    std.debug.print("║   Testing Secondary & Tertiary Queue/Bag Usage    ║\n", .{});
    std.debug.print("╚═══════════════════════════════════════════════════╝\n", .{});

    try benchmarkOverflow();

    std.debug.print("\n╔═══════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║           OVERFLOW TEST COMPLETE                  ║\n", .{});
    std.debug.print("╚═══════════════════════════════════════════════════╝\n\n", .{});
}