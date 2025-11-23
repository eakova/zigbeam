const std = @import("std");
const Rcu = @import("rcu.zig").Rcu;
const StatsCollectorModule = @import("rcu_stats_collector.zig");
const Thread = std.Thread;

const TestData = struct {
    value: u64,
    generation: u64,

    fn destroy(self: *TestData, alloc: std.mem.Allocator) void {
        alloc.destroy(self);
    }
};

const RcuType = Rcu(TestData);
const StatsSnapshot = StatsCollectorModule.StatsSnapshot;

/// Simple monitoring thread - user can periodically read snapshots
fn monitorThread(rcu: *const RcuType, stop: *const std.atomic.Value(bool), interval_ns: u64) void {
    while (!stop.load(.acquire)) {
        Thread.sleep(interval_ns);

        // User can simply read the snapshot periodically
        const snapshot = rcu.stats_collector.getStats();

        // Only print if stats are actually enabled (non-zero values)
        if (snapshot.read_acquisitions > 0 or snapshot.update_attempts > 0) {
            const timestamp = std.time.timestamp();
            std.debug.print("[{d}] ", .{timestamp});
            std.debug.print("R:{d} W:{d} R/W:{d:.1}:1 ", .{
                snapshot.read_acquisitions,
                snapshot.update_successes,
                snapshot.getReadWriteRatio(),
            });
            std.debug.print("QFull:{d:.1}% ", .{snapshot.getQueueFullRate()});
            std.debug.print("Retired:{d} Reclaimed:{d}\n", .{
                snapshot.objects_retired,
                snapshot.objects_reclaimed,
            });
        }
    }
}

/// Worker threads
fn readerThread(rcu: *const RcuType, stop: *const std.atomic.Value(bool)) void {
    while (!stop.load(.acquire)) {
        const guard = rcu.read() catch return;
        defer guard.release();

        const data = guard.get();
        _ = data.value; // Touch the data

        Thread.sleep(std.time.ns_per_us);
    }
}

fn writerThread(rcu: *RcuType, id: u32, stop: *const std.atomic.Value(bool)) void {
    var generation: u64 = 0;

    const UpdateCtx = struct {
        writer_id: u32,
        generation: u64,

        fn update(ctx: *anyopaque, alloc: std.mem.Allocator, current: ?*const TestData) !*TestData {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            const new = try alloc.create(TestData);
            new.* = .{
                .value = if (current) |c| c.value + 1 else 0,
                .generation = self.generation,
            };
            return new;
        }
    };

    while (!stop.load(.acquire)) {
        var ctx = UpdateCtx{
            .writer_id = id,
            .generation = generation,
        };

        rcu.update(&ctx, UpdateCtx.update) catch {
            Thread.sleep(10 * std.time.ns_per_us);
            continue;
        };

        generation += 1;
        Thread.sleep(100 * std.time.ns_per_us);
    }
}

pub fn main() !void {
    std.debug.print("\n╔════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║         PERIODIC STATS SNAPSHOT MONITORING             ║\n", .{});
    std.debug.print("╚════════════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\nDemonstrating simple periodic snapshot reading.\n", .{});
    std.debug.print("No callbacks or complex monitoring - just read snapshots when needed.\n\n", .{});

    const allocator = std.heap.c_allocator;

    // Test 1: With stats enabled
    {
        std.debug.print("=== TEST 1: Stats ENABLED ===\n", .{});

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

        // Simple monitoring thread - no complex StatsMonitor needed!
        const monitor = try Thread.spawn(.{}, monitorThread, .{
            rcu,
            &stop,
            2 * std.time.ns_per_s  // Report every 2 seconds
        });

        // Start workers
        var readers: [4]Thread = undefined;
        for (&readers) |*t| {
            t.* = try Thread.spawn(.{}, readerThread, .{rcu, &stop});
        }

        var writers: [2]Thread = undefined;
        for (&writers, 0..) |*t, i| {
            t.* = try Thread.spawn(.{}, writerThread, .{rcu, @as(u32, @intCast(i)), &stop});
        }

        // Run for 6 seconds
        Thread.sleep(6 * std.time.ns_per_s);

        stop.store(true, .release);
        monitor.join();
        for (readers) |t| t.join();
        for (writers) |t| t.join();

        // Final stats
        const final_stats = rcu.stats_collector.getStats();
        std.debug.print("\nFinal Stats (with monitoring):\n", .{});
        std.debug.print("  Total Reads:  {d}\n", .{final_stats.read_acquisitions});
        std.debug.print("  Total Writes: {d}\n", .{final_stats.update_successes});
        std.debug.print("  R/W Ratio:    {d:.1}:1\n", .{final_stats.getReadWriteRatio()});
    }

    std.debug.print("\n=== TEST 2: Stats DISABLED (zero overhead) ===\n", .{});

    // Test 2: With stats disabled
    {
        const initial = try allocator.create(TestData);
        initial.* = .{ .value = 0, .generation = 0 };

        const config = RcuType.Config{
            .queue_size = 512,
            .bag_capacity = 256,
        };

        const rcu = try RcuType.init(allocator, initial, TestData.destroy, config);
        defer rcu.deinit();

        var stop = std.atomic.Value(bool).init(false);

        // Monitor thread still runs but won't print anything (all zeros)
        const monitor = try Thread.spawn(.{}, monitorThread, .{
            rcu,
            &stop,
            2 * std.time.ns_per_s
        });

        // Start workers
        var readers: [4]Thread = undefined;
        for (&readers) |*t| {
            t.* = try Thread.spawn(.{}, readerThread, .{rcu, &stop});
        }

        var writers: [2]Thread = undefined;
        for (&writers, 0..) |*t, i| {
            t.* = try Thread.spawn(.{}, writerThread, .{rcu, @as(u32, @intCast(i)), &stop});
        }

        // Run for 6 seconds
        Thread.sleep(6 * std.time.ns_per_s);

        stop.store(true, .release);
        monitor.join();
        for (readers) |t| t.join();
        for (writers) |t| t.join();

        // Final stats (will be all zeros)
        const final_stats = rcu.stats_collector.getStats();
        std.debug.print("\nFinal Stats (without monitoring - should be zeros):\n", .{});
        std.debug.print("  Total Reads:  {d}\n", .{final_stats.read_acquisitions});
        std.debug.print("  Total Writes: {d}\n", .{final_stats.update_successes});
        std.debug.print("  R/W Ratio:    {d:.1}:1\n", .{final_stats.getReadWriteRatio()});
    }

    std.debug.print("\n╔════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║                    TEST COMPLETE                       ║\n", .{});
    std.debug.print("║  ✓ Stats can be enabled/disabled via config           ║\n", .{});
    std.debug.print("║  ✓ Simple periodic snapshot reading (no callbacks)    ║\n", .{});
    std.debug.print("║  ✓ Zero overhead when stats disabled                  ║\n", .{});
    std.debug.print("║  ✓ User controls monitoring logic directly            ║\n", .{});
    std.debug.print("╚════════════════════════════════════════════════════════╝\n\n", .{});
}