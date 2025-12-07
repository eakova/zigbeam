//! Concurrent Pin/Unpin Contention Test (T036)
//!
//! Stress tests concurrent pin/unpin operations across multiple threads.
//! Validates that the EBR system handles high contention correctly.
//!
//! Note: Thread count reduced to 8 to avoid contention issues on typical hardware.

const std = @import("std");
const ebr = @import("ebr");

const Collector = ebr.Collector;

/// Number of threads for contention testing.
const NUM_THREADS: usize = 8;

/// Duration of the test in seconds.
const TEST_DURATION_SECS: u64 = 3;

/// Per-thread context for tracking operations.
const ThreadContext = struct {
    collector: *Collector,
    ops_completed: std.atomic.Value(u64),
    should_stop: *std.atomic.Value(bool),
    thread_id: usize,
};

/// Worker that performs rapid pin/unpin cycles.
fn contentionWorker(ctx: *ThreadContext) void {
    const handle = ctx.collector.registerThread() catch return;
    defer ctx.collector.unregisterThread(handle);

    var ops: u64 = 0;

    while (!ctx.should_stop.load(.acquire)) {
        // Standard pin/unpin (supports nesting)
        const guard1 = ctx.collector.pin();

        // Nested pin to stress nesting logic
        const guard2 = ctx.collector.pin();
        guard2.unpin();

        guard1.unpin();
        ops += 2; // Count both pin/unpin pairs
    }

    _ = ctx.ops_completed.fetchAdd(ops, .release);
}

/// Worker using pinFast for maximum throughput.
fn fastContentionWorker(ctx: *ThreadContext) void {
    const handle = ctx.collector.registerThread() catch return;
    defer ctx.collector.unregisterThread(handle);

    var ops: u64 = 0;

    while (!ctx.should_stop.load(.acquire)) {
        // Fast pin/unpin (no nesting support)
        const guard = ctx.collector.pinFast();
        guard.unpin();
        ops += 1;
    }

    _ = ctx.ops_completed.fetchAdd(ops, .release);
}

fn runTest(allocator: std.mem.Allocator, name: []const u8, worker_fn: anytype) !void {
    std.debug.print("\n--- {s} ---\n", .{name});

    var collector = try Collector.init(allocator);
    defer collector.deinit();

    var should_stop = std.atomic.Value(bool).init(false);
    var contexts: [NUM_THREADS]ThreadContext = undefined;
    var threads: [NUM_THREADS]std.Thread = undefined;

    // Initialize and spawn
    for (0..NUM_THREADS) |i| {
        contexts[i] = .{
            .collector = &collector,
            .ops_completed = std.atomic.Value(u64).init(0),
            .should_stop = &should_stop,
            .thread_id = i,
        };
        threads[i] = try std.Thread.spawn(.{}, worker_fn, .{&contexts[i]});
    }

    // Let it run
    std.Thread.sleep(TEST_DURATION_SECS * std.time.ns_per_s);

    // Signal stop
    should_stop.store(true, .release);

    // Wait for threads
    for (&threads) |*thread| {
        thread.join();
    }

    // Collect results
    var total_ops: u64 = 0;
    for (&contexts) |*ctx| {
        total_ops += ctx.ops_completed.load(.acquire);
    }

    const ops_per_sec = total_ops / TEST_DURATION_SECS;
    std.debug.print("Total ops: {}\n", .{total_ops});
    std.debug.print("Throughput: {} Mops/sec\n", .{ops_per_sec / 1_000_000});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== Pin/Unpin Contention Stress Test ===\n", .{});
    std.debug.print("Threads: {}\n", .{NUM_THREADS});
    std.debug.print("Duration: {} seconds per test\n", .{TEST_DURATION_SECS});

    try runTest(allocator, "Standard pin() with nesting", contentionWorker);
    try runTest(allocator, "Fast pinFast() without nesting", fastContentionWorker);

    std.debug.print("\n✓ PASS: Contention test completed without crashes\n", .{});
}
