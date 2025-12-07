//! Pure Pin/Unpin Throughput Benchmark
//!
//! Measures ONLY pin/unpin throughput without timer overhead per iteration.
//! Times a batch of operations to get true throughput.
//!
//! Uses pinFast() for maximum throughput (no nested guard support).
//! Target: >1 Gops/sec pairs (1 billion pin+unpin pairs per second).

const std = @import("std");
const ebr = @import("ebr");

const Collector = ebr.Collector;

/// Number of pin+unpin pairs per batch.
const PAIRS_PER_BATCH: usize = 100_000_000;

/// Number of batches to run for averaging.
const NUM_BATCHES: usize = 5;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var collector = try Collector.init(allocator);
    defer collector.deinit();

    const handle = try collector.registerThread();
    defer collector.unregisterThread(handle);

    std.debug.print("=== Pure Pin/Unpin Throughput (pinFast) ===\n", .{});
    std.debug.print("Pairs per batch: {}\n", .{PAIRS_PER_BATCH});
    std.debug.print("Running {} batches...\n\n", .{NUM_BATCHES});

    var total_ns: u64 = 0;
    var best_ns: u64 = std.math.maxInt(u64);

    for (0..NUM_BATCHES) |batch| {
        const start = std.time.nanoTimestamp();

        // Ultra-fast pin/unpin loop using pinFast (no nested support, no extra threadlocal read)
        for (0..PAIRS_PER_BATCH) |_| {
            const guard = collector.pinFast();
            guard.unpin();
        }

        const end = std.time.nanoTimestamp();
        const elapsed: u64 = @intCast(end - start);
        total_ns += elapsed;
        if (elapsed < best_ns) best_ns = elapsed;

        const pairs_per_sec = @as(f64, @floatFromInt(PAIRS_PER_BATCH)) * 1_000_000_000.0 / @as(f64, @floatFromInt(elapsed));
        const ops_per_sec = pairs_per_sec * 2.0; // 1 pair = 2 ops (pin + unpin)
        const ns_per_pair = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(PAIRS_PER_BATCH));
        const ns_per_op = ns_per_pair / 2.0;
        std.debug.print("Batch {}: {d:.2} Gops pairs/s ({d:.2} Gops ops/s) | {d:.2} ns/pair ({d:.2} ns/op)\n", .{
            batch + 1,
            pairs_per_sec / 1_000_000_000.0,
            ops_per_sec / 1_000_000_000.0,
            ns_per_pair,
            ns_per_op,
        });
    }

    std.debug.print("\n=== Results ===\n", .{});

    const avg_ns = total_ns / NUM_BATCHES;
    const avg_pairs = @as(f64, @floatFromInt(PAIRS_PER_BATCH)) * 1_000_000_000.0 / @as(f64, @floatFromInt(avg_ns));
    const best_pairs = @as(f64, @floatFromInt(PAIRS_PER_BATCH)) * 1_000_000_000.0 / @as(f64, @floatFromInt(best_ns));
    const avg_ops = avg_pairs * 2.0;
    const best_ops = best_pairs * 2.0;
    const best_ns_per_pair = @as(f64, @floatFromInt(best_ns)) / @as(f64, @floatFromInt(PAIRS_PER_BATCH));
    const best_ns_per_op = best_ns_per_pair / 2.0;

    std.debug.print("Average: {d:.2} Gops pairs/s ({d:.2} Gops ops/s)\n", .{
        avg_pairs / 1_000_000_000.0,
        avg_ops / 1_000_000_000.0,
    });
    std.debug.print("Best:    {d:.2} Gops pairs/s ({d:.2} Gops ops/s)\n", .{
        best_pairs / 1_000_000_000.0,
        best_ops / 1_000_000_000.0,
    });
    std.debug.print("Latency: {d:.2} ns/pair ({d:.2} ns/op)\n", .{
        best_ns_per_pair,
        best_ns_per_op,
    });

    std.debug.print("\nNote: 1 pair = 1 pin + 1 unpin, ops = individual pin or unpin calls\n", .{});
    std.debug.print("Target: >1 Gops pairs/s (1 billion pin+unpin per second)\n", .{});

    if (best_pairs >= 1_000_000_000.0) {
        std.debug.print("✓ PASS: {d:.2} Gops pairs/s exceeds 1 Gops target\n", .{best_pairs / 1_000_000_000.0});
    } else {
        std.debug.print("✗ FAIL: {d:.2} Gops pairs/s ({d:.1}% of target)\n", .{
            best_pairs / 1_000_000_000.0,
            best_pairs / 1_000_000_000.0 * 100.0,
        });
    }
}
