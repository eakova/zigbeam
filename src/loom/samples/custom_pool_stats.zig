// Custom Pool Configuration Sample
//
// Demonstrates custom ThreadPool configuration with compile-time options.
// Shows how to configure queue capacities and enable statistics.
//
// This sample shows:
// - Creating custom pool types with ThreadPoolFn
// - Different queue capacity configurations
// - Stats configuration (enable_stats)
// - Accessing pool configuration at runtime

const std = @import("std");
const zigparallel = @import("loom");
const ThreadPoolFn = zigparallel.ThreadPoolFn;
const ThreadPool = zigparallel.ThreadPool;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("=== Custom Pool Configuration Sample ===\n\n", .{});

    // ========================================================================
    // Example 1: Default pool (stats disabled)
    // ========================================================================
    std.debug.print("--- Example 1: Default Pool (stats disabled) ---\n", .{});
    {
        const pool = try ThreadPool.init(allocator, .{ .num_threads = 4 });
        defer pool.deinit();

        std.debug.print("Pool workers: {d}\n", .{pool.numWorkers()});
        std.debug.print("Stats enabled: false (default)\n", .{});

        // getWorkerStats returns null when stats are disabled
        const stats = pool.getWorkerStats(0);
        std.debug.print("getWorkerStats(0): {?}\n", .{stats});

        const total = pool.getTotalStats();
        std.debug.print("getTotalStats(): {?}\n\n", .{total});
    }

    // ========================================================================
    // Example 2: Pool with stats enabled
    // ========================================================================
    std.debug.print("--- Example 2: Stats-Enabled Pool ---\n", .{});
    {
        // Create a custom pool type with stats enabled at compile time
        const StatsPool = ThreadPoolFn(.{
            .enable_stats = true,
        });

        const pool = try StatsPool.init(allocator, .{ .num_threads = 4 });
        defer pool.deinit();

        std.debug.print("Pool workers: {d}\n", .{pool.numWorkers()});
        std.debug.print("Stats enabled: true\n", .{});

        // Spawn some tasks directly to test stats
        var counter = std.atomic.Value(usize).init(0);

        const Context = struct {
            counter: *std.atomic.Value(usize),
        };

        const wrapper = struct {
            fn execute(ctx: *anyopaque) void {
                const context: *Context = @ptrCast(@alignCast(ctx));
                _ = context.counter.fetchAdd(1, .acq_rel);
            }
        };

        var context = Context{ .counter = &counter };
        var tasks: [10]zigparallel.Task = undefined;
        for (&tasks) |*task| {
            task.* = zigparallel.Task{
                .execute = wrapper.execute,
                .context = @ptrCast(&context),
                .scope = null,
            };
            try pool.spawn(task);
        }

        // Wait for tasks to complete
        var attempts: usize = 0;
        while (counter.load(.acquire) < 10 and attempts < 1000) : (attempts += 1) {
            std.Thread.sleep(1_000_000); // 1ms
        }

        std.debug.print("Tasks completed: {d}\n", .{counter.load(.acquire)});

        // Read per-worker stats
        std.debug.print("\nPer-worker statistics:\n", .{});
        for (0..pool.numWorkers()) |i| {
            if (pool.getWorkerStats(i)) |ws| {
                std.debug.print("  Worker {d}: {d} tasks executed\n", .{ i, ws.tasks_executed });
            }
        }

        // Read aggregate stats
        if (pool.getTotalStats()) |total| {
            std.debug.print("\nAggregate: {d} total tasks executed\n", .{total.tasks_executed});
        }
        std.debug.print("\n", .{});
    }

    // ========================================================================
    // Example 3: Custom queue capacities
    // ========================================================================
    std.debug.print("--- Example 3: Custom Queue Capacities ---\n", .{});
    {
        // Pool with larger local queues for fine-grained tasks
        const LargeLocalPool = ThreadPoolFn(.{
            .local_capacity = 512, // Default is 256
            .global_capacity = 8192, // Default is 4096
        });

        const pool = try LargeLocalPool.init(allocator, .{ .num_threads = 2 });
        defer pool.deinit();

        std.debug.print("Custom pool configuration:\n", .{});
        std.debug.print("  local_capacity: {d}\n", .{LargeLocalPool.pool_config.local_capacity});
        std.debug.print("  global_capacity: {d}\n", .{LargeLocalPool.pool_config.global_capacity});
        std.debug.print("  enable_stats: {}\n\n", .{LargeLocalPool.pool_config.enable_stats});
    }

    // ========================================================================
    // Example 4: Comparing configurations
    // ========================================================================
    std.debug.print("--- Example 4: Configuration Comparison ---\n", .{});
    {
        // Default configuration
        std.debug.print("Default ThreadPool config:\n", .{});
        std.debug.print("  local_capacity: {d}\n", .{ThreadPool.pool_config.local_capacity});
        std.debug.print("  global_capacity: {d}\n", .{ThreadPool.pool_config.global_capacity});
        std.debug.print("  enable_stats: {}\n\n", .{ThreadPool.pool_config.enable_stats});

        // High-throughput configuration
        const HighThroughputPool = ThreadPoolFn(.{
            .local_capacity = 1024,
            .global_capacity = 16384,
            .enable_stats = false,
        });
        std.debug.print("High-throughput config:\n", .{});
        std.debug.print("  local_capacity: {d}\n", .{HighThroughputPool.pool_config.local_capacity});
        std.debug.print("  global_capacity: {d}\n", .{HighThroughputPool.pool_config.global_capacity});
        std.debug.print("  enable_stats: {}\n\n", .{HighThroughputPool.pool_config.enable_stats});

        // Debug/analytics configuration
        const DebugPool = ThreadPoolFn(.{
            .local_capacity = 64,
            .global_capacity = 512,
            .enable_stats = true,
        });
        std.debug.print("Debug/analytics config:\n", .{});
        std.debug.print("  local_capacity: {d}\n", .{DebugPool.pool_config.local_capacity});
        std.debug.print("  global_capacity: {d}\n", .{DebugPool.pool_config.global_capacity});
        std.debug.print("  enable_stats: {}\n", .{DebugPool.pool_config.enable_stats});
    }

    std.debug.print("\n=== Sample Complete ===\n", .{});
}
