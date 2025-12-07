//! Full EBR Stress Test (T061)
//!
//! Comprehensive stress test combining all EBR operations:
//! - Thread registration/unregistration
//! - Pin/unpin (standard and fast)
//! - Deferred reclamation
//! - Epoch advancement
//!
//! Note: Thread count reduced to 8 to avoid contention issues on typical hardware.

const std = @import("std");
const ebr = @import("ebr");

const Collector = ebr.Collector;
const DtorFn = ebr.DtorFn;

/// Number of worker threads.
const NUM_WORKERS: usize = 8;

/// Duration of the test in seconds.
const TEST_DURATION_SECS: u64 = 5;

/// Destructor call counter.
var destructor_calls = std.atomic.Value(u64).init(0);

fn noopDestructor(_: *anyopaque) void {
    _ = destructor_calls.fetchAdd(1, .release);
}

/// Stats for each worker.
const WorkerStats = struct {
    pins: std.atomic.Value(u64),
    fast_pins: std.atomic.Value(u64),
    defers: std.atomic.Value(u64),
    collects: std.atomic.Value(u64),

    fn init() WorkerStats {
        return .{
            .pins = std.atomic.Value(u64).init(0),
            .fast_pins = std.atomic.Value(u64).init(0),
            .defers = std.atomic.Value(u64).init(0),
            .collects = std.atomic.Value(u64).init(0),
        };
    }
};

/// Context for worker threads.
const WorkerContext = struct {
    collector: *Collector,
    stats: *WorkerStats,
    should_stop: *std.atomic.Value(bool),
    worker_id: usize,
};

/// Worker that performs mixed EBR operations.
fn mixedWorker(ctx: *WorkerContext) void {
    const handle = ctx.collector.registerThread() catch return;
    defer ctx.collector.unregisterThread(handle);

    var pins: u64 = 0;
    var fast_pins: u64 = 0;
    var defers: u64 = 0;
    var collects: u64 = 0;
    var dummy: u64 = 0;
    var prng = std.Random.DefaultPrng.init(ctx.worker_id);
    const random = prng.random();

    while (!ctx.should_stop.load(.acquire)) {
        const op = random.intRangeAtMost(u8, 0, 100);

        if (op < 40) {
            // 40%: Standard pin/unpin with potential nesting
            const guard1 = ctx.collector.pin();
            dummy +%= 1;

            if (op < 10) {
                // 10%: Nested pin
                const guard2 = ctx.collector.pin();
                dummy +%= 1;
                guard2.unpin();
            }

            guard1.unpin();
            pins += 1;
        } else if (op < 70) {
            // 30%: Fast pin/unpin
            const guard = ctx.collector.pinFast();
            dummy +%= 1;
            guard.unpin();
            fast_pins += 1;
        } else if (op < 95) {
            // 25%: Pin + defer
            const guard = ctx.collector.pin();
            ctx.collector.deferReclaim(@ptrCast(&dummy), noopDestructor);
            guard.unpin();
            defers += 1;
        } else {
            // 5%: Explicit collect
            ctx.collector.collect();
            collects += 1;
        }
    }

    _ = ctx.stats.pins.fetchAdd(pins, .release);
    _ = ctx.stats.fast_pins.fetchAdd(fast_pins, .release);
    _ = ctx.stats.defers.fetchAdd(defers, .release);
    _ = ctx.stats.collects.fetchAdd(collects, .release);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== Full EBR Stress Test ===\n", .{});
    std.debug.print("Workers: {}\n", .{NUM_WORKERS});
    std.debug.print("Duration: {} seconds\n\n", .{TEST_DURATION_SECS});

    var collector = try Collector.init(allocator);
    defer collector.deinit();

    var should_stop = std.atomic.Value(bool).init(false);
    var stats: [NUM_WORKERS]WorkerStats = undefined;
    var contexts: [NUM_WORKERS]WorkerContext = undefined;
    var threads: [NUM_WORKERS]std.Thread = undefined;

    destructor_calls.store(0, .release);

    const start = std.time.nanoTimestamp();

    // Initialize and spawn workers
    for (0..NUM_WORKERS) |i| {
        stats[i] = WorkerStats.init();
        contexts[i] = .{
            .collector = &collector,
            .stats = &stats[i],
            .should_stop = &should_stop,
            .worker_id = i,
        };
        threads[i] = try std.Thread.spawn(.{}, mixedWorker, .{&contexts[i]});
    }

    // Let it run
    std.Thread.sleep(TEST_DURATION_SECS * std.time.ns_per_s);

    // Signal stop
    should_stop.store(true, .release);

    // Wait for threads
    for (&threads) |*thread| {
        thread.join();
    }

    const end = std.time.nanoTimestamp();
    const elapsed_secs = @as(f64, @floatFromInt(end - start)) / 1_000_000_000.0;

    // Aggregate stats
    var total_pins: u64 = 0;
    var total_fast_pins: u64 = 0;
    var total_defers: u64 = 0;
    var total_collects: u64 = 0;

    for (&stats) |*s| {
        total_pins += s.pins.load(.acquire);
        total_fast_pins += s.fast_pins.load(.acquire);
        total_defers += s.defers.load(.acquire);
        total_collects += s.collects.load(.acquire);
    }

    const total_ops = total_pins + total_fast_pins + total_defers + total_collects;
    const dtors = destructor_calls.load(.acquire);

    std.debug.print("=== Results ===\n", .{});
    std.debug.print("Duration: {d:.2} seconds\n\n", .{elapsed_secs});

    std.debug.print("Operations:\n", .{});
    std.debug.print("  Standard pin/unpin: {}\n", .{total_pins});
    std.debug.print("  Fast pin/unpin:     {}\n", .{total_fast_pins});
    std.debug.print("  Defers:             {}\n", .{total_defers});
    std.debug.print("  Collects:           {}\n", .{total_collects});
    std.debug.print("  Total:              {}\n\n", .{total_ops});

    std.debug.print("Throughput: {d:.2} Mops/sec\n", .{@as(f64, @floatFromInt(total_ops)) / elapsed_secs / 1_000_000.0});
    std.debug.print("Destructors called: {}/{} ({d:.1}%)\n", .{
        dtors,
        total_defers,
        if (total_defers > 0) @as(f64, @floatFromInt(dtors)) / @as(f64, @floatFromInt(total_defers)) * 100.0 else 0.0,
    });
    std.debug.print("Final epoch: {}\n", .{collector.getCurrentEpoch()});
    std.debug.print("Pending count: {}\n", .{collector.getPendingCount()});

    std.debug.print("\n✓ PASS: Full stress test completed without crashes\n", .{});
}
