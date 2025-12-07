//! Pin/Unpin Latency Benchmark
//!
//! Measures the latency of pin/unpin operations to validate the
//! <5ns p99 latency target from the constitution.

const std = @import("std");
const ebr = @import("ebr");

const Collector = ebr.Collector;

/// Number of iterations for the benchmark.
const ITERATIONS: usize = 10_000_000;

/// Number of warmup iterations.
const WARMUP: usize = 100_000;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var collector = try Collector.init(allocator);
    defer collector.deinit();

    const handle = try collector.registerThread();
    defer collector.unregisterThread(handle);

    // Warmup
    std.debug.print("Warming up ({} iterations)...\n", .{WARMUP});
    for (0..WARMUP) |_| {
        const guard = collector.pin();
        guard.unpin();
    }

    // Collect latency samples
    std.debug.print("Running benchmark ({} iterations)...\n", .{ITERATIONS});

    var latencies = try allocator.alloc(u64, ITERATIONS);
    defer allocator.free(latencies);

    for (0..ITERATIONS) |i| {
        const start = std.time.nanoTimestamp();
        const guard = collector.pin();
        guard.unpin();
        const end = std.time.nanoTimestamp();
        latencies[i] = @intCast(end - start);
    }

    // Sort for percentile calculation
    std.mem.sort(u64, latencies, {}, std.sort.asc(u64));

    // Calculate statistics
    var sum: u128 = 0;
    for (latencies) |lat| {
        sum += lat;
    }
    const avg = @as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(ITERATIONS));

    const p50_idx = ITERATIONS * 50 / 100;
    const p90_idx = ITERATIONS * 90 / 100;
    const p99_idx = ITERATIONS * 99 / 100;
    const p999_idx = ITERATIONS * 999 / 1000;

    const p50 = latencies[p50_idx];
    const p90 = latencies[p90_idx];
    const p99 = latencies[p99_idx];
    const p999 = latencies[p999_idx];
    const min_lat = latencies[0];
    const max_lat = latencies[ITERATIONS - 1];

    std.debug.print("\n=== Pin/Unpin Latency Results ===\n", .{});
    std.debug.print("Iterations: {}\n", .{ITERATIONS});
    std.debug.print("Min:     {} ns\n", .{min_lat});
    std.debug.print("Avg:     {d:.2} ns\n", .{avg});
    std.debug.print("p50:     {} ns\n", .{p50});
    std.debug.print("p90:     {} ns\n", .{p90});
    std.debug.print("p99:     {} ns  (target: <5ns)\n", .{p99});
    std.debug.print("p99.9:   {} ns\n", .{p999});
    std.debug.print("Max:     {} ns\n", .{max_lat});
    std.debug.print("\n", .{});

    // Validate against target
    if (p99 <= 5) {
        std.debug.print("✓ PASS: p99 latency {} ns <= 5ns target\n", .{p99});
    } else {
        std.debug.print("✗ FAIL: p99 latency {} ns > 5ns target\n", .{p99});
        std.debug.print("  Note: Target may not be achievable on all hardware\n", .{});
    }

    // Calculate throughput
    const total_ns: u128 = sum;
    const throughput_ops_per_sec = @as(f64, @floatFromInt(ITERATIONS)) * 1_000_000_000.0 / @as(f64, @floatFromInt(total_ns));
    std.debug.print("\nThroughput: {d:.2} Mops/sec\n", .{throughput_ops_per_sec / 1_000_000.0});
}
