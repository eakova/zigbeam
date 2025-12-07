//! Throughput Benchmark
//!
//! Measures the overall throughput of EBR operations including
//! pin, unpin, defer, and collect to validate the >1 Gops/sec target.

const std = @import("std");
const ebr = @import("ebr");

const Collector = ebr.Collector;
const DtorFn = ebr.DtorFn;

/// Duration of the benchmark in seconds.
const BENCH_DURATION_SECS: u64 = 5;

/// Number of threads to test with.
/// Note: 16+ threads disabled - causes contention issues on most machines
const THREAD_COUNTS = [_]u8{ 1, 2, 4, 8 };

/// Dummy destructor for deferred objects.
fn noopDtor(_: *anyopaque) void {}

/// Per-thread benchmark context.
const BenchContext = struct {
    collector: *Collector,
    ops_completed: std.atomic.Value(u64),
    should_stop: *std.atomic.Value(bool),
};

/// Worker thread that performs pin/unpin/defer cycles.
fn worker(ctx: *BenchContext) void {
    const handle = ctx.collector.registerThread() catch return;
    defer ctx.collector.unregisterThread(handle);

    var ops: u64 = 0;
    var dummy: u64 = 0;

    while (!ctx.should_stop.load(.acquire)) {
        // Simulate a typical EBR usage pattern
        const guard = ctx.collector.pin();

        // Do some "work" with protected data
        dummy +%= 1;

        // Occasionally defer something
        if (ops % 100 == 0) {
            ctx.collector.deferReclaim(@ptrCast(&dummy), noopDtor);
        }

        guard.unpin();
        ops += 1;
    }

    _ = ctx.ops_completed.fetchAdd(ops, .release);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== EBR Throughput Benchmark ===\n", .{});
    std.debug.print("Duration: {} seconds per thread count\n\n", .{BENCH_DURATION_SECS});
    std.debug.print("{s:>8} {s:>12} {s:>15}\n", .{ "Threads", "Ops/sec", "Per Thread" });
    std.debug.print("{s:-<8} {s:-<12} {s:-<15}\n", .{ "", "", "" });

    for (THREAD_COUNTS) |thread_count| {
        var collector = try Collector.init(allocator);
        defer collector.deinit();

        var should_stop = std.atomic.Value(bool).init(false);
        var contexts = try allocator.alloc(BenchContext, thread_count);
        defer allocator.free(contexts);

        var threads = try allocator.alloc(std.Thread, thread_count);
        defer allocator.free(threads);

        // Initialize contexts and spawn threads
        for (0..thread_count) |i| {
            contexts[i] = .{
                .collector = &collector,
                .ops_completed = std.atomic.Value(u64).init(0),
                .should_stop = &should_stop,
            };
            threads[i] = try std.Thread.spawn(.{}, worker, .{&contexts[i]});
        }

        // Let the benchmark run
        std.Thread.sleep(BENCH_DURATION_SECS * std.time.ns_per_s);

        // Signal stop
        should_stop.store(true, .release);

        // Wait for threads to finish
        for (threads) |thread| {
            thread.join();
        }

        // Collect results
        var total_ops: u64 = 0;
        for (contexts) |ctx| {
            total_ops += ctx.ops_completed.load(.acquire);
        }

        const ops_per_sec = total_ops / BENCH_DURATION_SECS;
        const per_thread = ops_per_sec / thread_count;

        std.debug.print("{d:>8} {d:>12} {d:>15}\n", .{
            thread_count,
            ops_per_sec,
            per_thread,
        });
    }

    std.debug.print("\nTarget: >1 Gops/sec (1,000,000,000 ops/sec) per thread\n", .{});
}
