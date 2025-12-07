//! Custom Collector Configuration Example
//!
//! Demonstrates how to tune the EBR collector for different workloads:
//! - High-scalability (many threads)
//! - Low-latency (aggressive collection)
//! - High-throughput (batched collection)
//!
//! Run: zig build sample-config

const std = @import("std");
const ebr = @import("ebr");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== Custom Collector Configuration Example ===\n\n", .{});

    // Default configuration
    // - epoch_advance_sample_rate = 4 (25% sampling)
    // - batch_threshold = 64 objects
    {
        std.debug.print("1. Default Configuration\n", .{});
        std.debug.print("   epoch_advance_sample_rate = 4 (25%% sampling)\n", .{});
        std.debug.print("   batch_threshold = 64\n", .{});

        var collector = try ebr.Collector.init(allocator);
        defer collector.deinit();

        const handle = try collector.registerThread();
        defer collector.unregisterThread(handle);

        const guard = collector.pin();
        guard.unpin();

        std.debug.print("   OK\n\n", .{});
    }

    // High-scalability configuration (32+ threads)
    // - Less frequent epoch advancement reduces mutex contention
    // - Larger batches reduce collection overhead
    {
        std.debug.print("2. High-Scalability Configuration (32+ threads)\n", .{});
        std.debug.print("   epoch_advance_sample_rate = 16 (6.25%% sampling)\n", .{});
        std.debug.print("   batch_threshold = 256\n", .{});

        const HighScaleCollector = ebr.CollectorType(.{
            .epoch_advance_sample_rate = 16, // Only 1 in 16 collections try to advance
            .batch_threshold = 256, // Larger batches before collection
        });

        var collector = try HighScaleCollector.init(allocator);
        defer collector.deinit();

        const handle = try collector.registerThread();
        defer collector.unregisterThread(handle);

        const guard = collector.pin();
        guard.unpin();

        std.debug.print("   OK\n\n", .{});
    }

    // Low-latency configuration
    // - More frequent epoch advancement for faster reclamation
    // - Smaller batches to reduce peak memory
    {
        std.debug.print("3. Low-Latency Configuration\n", .{});
        std.debug.print("   epoch_advance_sample_rate = 1 (100%% - every collection)\n", .{});
        std.debug.print("   batch_threshold = 16\n", .{});

        const LowLatencyCollector = ebr.CollectorType(.{
            .epoch_advance_sample_rate = 1, // Every collection tries to advance
            .batch_threshold = 16, // Frequent small collections
        });

        var collector = try LowLatencyCollector.init(allocator);
        defer collector.deinit();

        const handle = try collector.registerThread();
        defer collector.unregisterThread(handle);

        const guard = collector.pin();
        guard.unpin();

        std.debug.print("   OK\n\n", .{});
    }

    // High-throughput configuration
    // - Very large batches to minimize collection frequency
    // - Moderate sampling to balance progress
    {
        std.debug.print("4. High-Throughput Configuration\n", .{});
        std.debug.print("   epoch_advance_sample_rate = 8 (12.5%% sampling)\n", .{});
        std.debug.print("   batch_threshold = 512\n", .{});

        const HighThroughputCollector = ebr.CollectorType(.{
            .epoch_advance_sample_rate = 8,
            .batch_threshold = 512, // Very large batches
        });

        var collector = try HighThroughputCollector.init(allocator);
        defer collector.deinit();

        const handle = try collector.registerThread();
        defer collector.unregisterThread(handle);

        const guard = collector.pin();
        guard.unpin();

        std.debug.print("   OK\n\n", .{});
    }

    std.debug.print("All configurations work correctly!\n", .{});
    std.debug.print("\nTuning Guidelines:\n", .{});
    std.debug.print("  - More threads -> higher epoch_advance_sample_rate\n", .{});
    std.debug.print("  - Memory-constrained -> lower batch_threshold\n", .{});
    std.debug.print("  - Throughput-critical -> higher batch_threshold\n", .{});
    std.debug.print("  - Latency-sensitive -> lower epoch_advance_sample_rate\n", .{});
}
