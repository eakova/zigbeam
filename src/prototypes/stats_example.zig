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

/// Monitor thread that periodically reports stats
fn monitorStats(rcu: *const Rcu(TestData), stop: *const std.atomic.Value(bool)) void {
    while (!stop.load(.acquire)) {
        Thread.sleep(1000 * std.time.ns_per_ms); // Report every second

        const stats = rcu.stats_collector.getStats();

        std.debug.print("\n╔════════════════════ RCU STATISTICS ════════════════════╗\n", .{});

        // Read/Write operations
        std.debug.print("║ Operations:                                            ║\n", .{});
        std.debug.print("║   Read Acquisitions:    {d: >15}                 ║\n", .{stats.read_acquisitions});
        std.debug.print("║   Update Attempts:      {d: >15}                 ║\n", .{stats.update_attempts});
        std.debug.print("║   Update Successes:     {d: >15}                 ║\n", .{stats.update_successes});
        std.debug.print("║   Read/Write Ratio:     {d: >14.1}:1                ║\n", .{stats.getReadWriteRatio()});

        // Queue statistics
        std.debug.print("║                                                        ║\n", .{});
        std.debug.print("║ Queue Performance:                                     ║\n", .{});
        std.debug.print("║   Primary Pushes:       {d: >15}                 ║\n", .{stats.primary_queue_pushes});
        std.debug.print("║   Secondary Pushes:     {d: >15}                 ║\n", .{stats.secondary_queue_pushes});
        std.debug.print("║   Tertiary Pushes:      {d: >15}                 ║\n", .{stats.tertiary_queue_pushes});
        std.debug.print("║   Queue Full Rate:      {d: >14.2}%                 ║\n", .{stats.getQueueFullRate()});

        // Overflow status
        std.debug.print("║                                                        ║\n", .{});
        std.debug.print("║ Overflow Status:                                       ║\n", .{});
        std.debug.print("║   Secondary Queue:      {s: >15}                 ║\n",
            .{if (stats.secondary_queue_created) "Created" else "Not Created"});
        std.debug.print("║   Tertiary Queue:       {s: >15}                 ║\n",
            .{if (stats.tertiary_queue_created) "Created" else "Not Created"});

        // Memory reclamation
        std.debug.print("║                                                        ║\n", .{});
        std.debug.print("║ Memory Management:                                     ║\n", .{});
        std.debug.print("║   Objects Retired:      {d: >15}                 ║\n", .{stats.objects_retired});
        std.debug.print("║   Objects Reclaimed:    {d: >15}                 ║\n", .{stats.objects_reclaimed});
        std.debug.print("║   Epochs Advanced:      {d: >15}                 ║\n", .{stats.epochs_advanced});

        std.debug.print("╚════════════════════════════════════════════════════════╝\n", .{});
    }
}

/// Reader thread that performs continuous reads
fn readerThread(rcu: *const Rcu(TestData), stop: *const std.atomic.Value(bool)) void {
    while (!stop.load(.acquire)) {
        const guard = rcu.read() catch return;
        defer guard.release();

        const data = guard.get();
        _ = data.value; // Touch the data

        Thread.sleep(std.time.ns_per_us); // Very fast reads
    }
}

/// Writer thread that performs updates
fn writerThread(rcu: *Rcu(TestData), id: u32, stop: *const std.atomic.Value(bool)) void {
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
            // Queue full, back off
            Thread.sleep(10 * std.time.ns_per_us);
            continue;
        };

        generation += 1;
        Thread.sleep(100 * std.time.ns_per_us); // Writers are slower than readers
    }
}

pub fn main() !void {
    std.debug.print("\n╔════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║         RCU RUNTIME STATISTICS MONITORING             ║\n", .{});
    std.debug.print("╚════════════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\nStarting workload with real-time statistics reporting...\n", .{});

    const allocator = std.heap.c_allocator;

    // Create initial data
    const initial = try allocator.create(TestData);
    initial.* = .{ .value = 0, .generation = 0 };

    const RcuTest = Rcu(TestData);

    // Use small queue to demonstrate overflow
    const config = RcuTest.Config{
        .queue_size = 256,
        .bag_capacity = 128,
        .reclaim_interval_ns = 10 * std.time.ns_per_ms,
        .use_expanded_queues_on_overflow = true,
    };

    const rcu = try RcuTest.init(allocator, initial, TestData.destroy, config);
    defer rcu.deinit();

    // Start monitoring
    try rcu.stats_collector.startMonitoring();

    var stop = std.atomic.Value(bool).init(false);
    const duration_ms = 10000; // Run for 10 seconds

    // Start monitor thread
    const monitor = try Thread.spawn(.{}, monitorStats, .{rcu, &stop});

    // Start reader threads
    var readers: [8]Thread = undefined;
    for (&readers) |*t| {
        t.* = try Thread.spawn(.{}, readerThread, .{rcu, &stop});
    }

    // Start writer threads
    var writers: [4]Thread = undefined;
    for (&writers, 0..) |*t, i| {
        t.* = try Thread.spawn(.{}, writerThread, .{rcu, @as(u32, @intCast(i)), &stop});
    }

    // Let it run
    Thread.sleep(duration_ms * std.time.ns_per_ms);

    // Stop all threads
    stop.store(true, .release);

    // Wait for threads to finish
    monitor.join();
    for (readers) |t| t.join();
    for (writers) |t| t.join();

    // Print final stats
    const final_stats = rcu.stats_collector.getStats();

    std.debug.print("\n╔════════════════════ FINAL STATISTICS ═════════════════╗\n", .{});
    std.debug.print("║                                                        ║\n", .{});
    std.debug.print("║ Total Operations:                                      ║\n", .{});
    std.debug.print("║   Reads:                {d: >15}                 ║\n", .{final_stats.read_acquisitions});
    std.debug.print("║   Successful Updates:   {d: >15}                 ║\n", .{final_stats.update_successes});
    std.debug.print("║   Failed Updates:       {d: >15}                 ║\n",
        .{if (final_stats.update_attempts >= final_stats.update_successes) final_stats.update_attempts - final_stats.update_successes else 0});
    std.debug.print("║                                                        ║\n", .{});
    std.debug.print("║ Queue Utilization:                                     ║\n", .{});
    std.debug.print("║   Total Capacity:       {d: >15} slots       ║\n",
        .{final_stats.getTotalQueueCapacity(config)});
    std.debug.print("║   Overflow Used:        {s: >15}                 ║\n",
        .{if (final_stats.secondary_queue_created or final_stats.tertiary_queue_created) "Yes" else "No"});
    std.debug.print("║                                                        ║\n", .{});
    std.debug.print("║ Performance Metrics:                                   ║\n", .{});
    std.debug.print("║   Read/Write Ratio:     {d: >14.1}:1                ║\n", .{final_stats.getReadWriteRatio()});
    std.debug.print("║   Queue Full Rate:      {d: >14.2}%                 ║\n", .{final_stats.getQueueFullRate()});
    std.debug.print("╚════════════════════════════════════════════════════════╝\n\n", .{});
}