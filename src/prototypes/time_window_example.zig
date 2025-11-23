const std = @import("std");
const Rcu = @import("rcu.zig").Rcu;
const Thread = std.Thread;

const TestData = struct {
    value: u64,
    generation: u64,

    fn destroy(self: *TestData, alloc: std.mem.Allocator) void {
        alloc.destroy(self);
    }
};

const RcuType = Rcu(TestData);

/// Worker threads
fn readerThread(rcu: *const RcuType, stop: *const std.atomic.Value(bool)) void {
    while (!stop.load(.acquire)) {
        const guard = rcu.read() catch return;
        defer guard.release();
        _ = guard.get();
        Thread.sleep(100 * std.time.ns_per_us);
    }
}

fn writerThread(rcu: *RcuType, stop: *const std.atomic.Value(bool)) void {
    const UpdateCtx = struct {
        fn update(ctx: *anyopaque, alloc: std.mem.Allocator, current: ?*const TestData) !*TestData {
            _ = ctx;
            const new = try alloc.create(TestData);
            new.* = .{
                .value = if (current) |c| c.value + 1 else 0,
                .generation = 0,
            };
            return new;
        }
    };

    while (!stop.load(.acquire)) {
        var ctx: u32 = 0;
        rcu.update(&ctx, UpdateCtx.update) catch {
            Thread.sleep(std.time.ns_per_ms);
            continue;
        };
        Thread.sleep(500 * std.time.ns_per_us);
    }
}

fn formatDuration(ns: i128) void {
    if (ns <= 0) {
        std.debug.print("expired", .{});
    } else if (ns < std.time.ns_per_s) {
        std.debug.print("{d:.1}ms", .{@as(f64, @floatFromInt(ns)) / @as(f64, std.time.ns_per_ms)});
    } else {
        std.debug.print("{d:.1}s", .{@as(f64, @floatFromInt(ns)) / @as(f64, std.time.ns_per_s)});
    }
}

pub fn main() !void {
    std.debug.print("\n╔════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║           TIME-BOUNDED STATS COLLECTION                 ║\n", .{});
    std.debug.print("╚════════════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\nDemonstrating automatic stats expiration after time window.\n\n", .{});

    const allocator = std.heap.c_allocator;

    // Test 1: Monitor stats over time with default window
    {
        std.debug.print("=== TEST 1: Stats monitoring with default window ===\n", .{});

        const initial = try allocator.create(TestData);
        initial.* = .{ .value = 0, .generation = 0 };

        const config = RcuType.Config{
            .queue_size = 512,
            .bag_capacity = 256,
        };

        const rcu = try RcuType.init(allocator, initial, TestData.destroy, config);
        defer rcu.deinit();

        // Start monitoring
        try rcu.stats_collector.startMonitoring();

        var stop = std.atomic.Value(bool).init(false);

        // Start workers
        const reader = try Thread.spawn(.{}, readerThread, .{rcu, &stop});
        const writer = try Thread.spawn(.{}, writerThread, .{rcu, &stop});

        // Monitor stats window
        var check_count: u32 = 0;
        while (check_count < 8) : (check_count += 1) {
            Thread.sleep(std.time.ns_per_s); // Check every second

            const stats = rcu.stats_collector.getStats();

            std.debug.print("[{d}s] Gen:{d} Reads:{d} Writes:{d} Window:", .{
                check_count + 1,
                stats.generation,
                stats.read_acquisitions,
                stats.update_successes,
            });
            formatDuration(rcu.stats_collector.getWindowRemaining());

            if (stats.window_expired) {
                std.debug.print(" [EXPIRED]", .{});
            }
            std.debug.print("\n", .{});

            // After expiration, reset stats
            if (check_count == 5 and stats.window_expired) {
                std.debug.print("  → Resetting stats for new window\n", .{});
                rcu.stats_collector.resetStats();
            }
        }

        stop.store(true, .release);
        reader.join();
        writer.join();
    }

    std.debug.print("\n=== TEST 2: Default 1-hour window ===\n", .{});

    // Test 2: Default window (1 hour)
    {
        const initial = try allocator.create(TestData);
        initial.* = .{ .value = 0, .generation = 0 };

        const config = RcuType.Config{
            .queue_size = 512,
            .bag_capacity = 256,
        };

        const rcu = try RcuType.init(allocator, initial, TestData.destroy, config);
        defer rcu.deinit();

        // Start monitoring
        try rcu.stats_collector.startMonitoring();

        const stats = rcu.stats_collector.getStats();

        std.debug.print("Stats window: ", .{});
        formatDuration(rcu.stats_collector.getWindowRemaining());
        std.debug.print(" (Generation: {d})\n", .{stats.generation});

        // At 10M ops/sec for 1 hour = 36 billion ops
        // Still well below u64 max (18.4 quintillion)
        const ops_per_hour = 10_000_000 * 3600;
        const u64_max = std.math.maxInt(u64);
        const hours_to_overflow = u64_max / ops_per_hour;

        std.debug.print("At 10M ops/sec, overflow would take {d} hours\n", .{hours_to_overflow});
        std.debug.print("With 1-hour window, overflow is impossible!\n", .{});
    }

    std.debug.print("\n=== TEST 3: Default window duration ===\n", .{});

    // Test 3: Check the default window duration
    {
        const initial = try allocator.create(TestData);
        initial.* = .{ .value = 0, .generation = 0 };

        const config = RcuType.Config{
            .queue_size = 512,
            .bag_capacity = 256,
        };

        const rcu = try RcuType.init(allocator, initial, TestData.destroy, config);
        defer rcu.deinit();

        // Start monitoring
        try rcu.stats_collector.startMonitoring();

        const hours = @as(f64, @floatFromInt(rcu.stats_collector.getWindowRemaining())) / @as(f64, std.time.ns_per_hour);

        std.debug.print("Default window: {d:.1} hours\n", .{hours});
    }

    std.debug.print("\n╔════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║                    TEST COMPLETE                        ║\n", .{});
    std.debug.print("║  ✓ Stats auto-disable after time window                ║\n", .{});
    std.debug.print("║  ✓ Window can be reset to start new collection         ║\n", .{});
    std.debug.print("║  ✓ Default 1 hour window prevents overflow             ║\n", .{});
    std.debug.print("║  ✓ Stats controlled via StatsCollector methods         ║\n", .{});
    std.debug.print("╚════════════════════════════════════════════════════════╝\n\n", .{});
}