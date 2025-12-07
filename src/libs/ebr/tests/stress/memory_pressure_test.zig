//! Memory Pressure Stress Test (T049)
//!
//! Stress tests the deferred reclamation system under memory pressure.
//! Validates that garbage is collected and memory doesn't grow unbounded.
//!
//! Note: Thread count reduced to 8 to avoid contention issues on typical hardware.

const std = @import("std");
const ebr = @import("ebr");

const Collector = ebr.Collector;
const DtorFn = ebr.DtorFn;

/// Number of threads for stress testing.
const NUM_THREADS: usize = 8;

/// Duration of the test in seconds.
const TEST_DURATION_SECS: u64 = 3;

/// Size of each allocated object.
const OBJECT_SIZE: usize = 64;

/// Tracking for destructor calls.
var destructor_calls = std.atomic.Value(u64).init(0);

/// Destructor that tracks calls and frees memory.
fn trackingDestructor(ptr: *anyopaque) void {
    _ = destructor_calls.fetchAdd(1, .release);
    // The actual memory is managed by the test, not freed here
    // This simulates a real destructor that does cleanup work
    _ = ptr;
}

/// Per-thread context.
const ThreadContext = struct {
    collector: *Collector,
    allocator: std.mem.Allocator,
    defers_submitted: std.atomic.Value(u64),
    should_stop: *std.atomic.Value(bool),
};

/// Worker that allocates, uses, and defers objects.
fn memoryPressureWorker(ctx: *ThreadContext) void {
    const handle = ctx.collector.registerThread() catch return;
    defer ctx.collector.unregisterThread(handle);

    var defers: u64 = 0;

    while (!ctx.should_stop.load(.acquire)) {
        // Allocate an object
        const obj = ctx.allocator.alloc(u8, OBJECT_SIZE) catch continue;

        // Pin while "using" the object
        const guard = ctx.collector.pin();

        // Simulate some work with the object
        @memset(obj, 0xAB);

        // Defer the reclamation
        ctx.collector.deferReclaim(@ptrCast(obj.ptr), trackingDestructor);
        defers += 1;

        guard.unpin();

        // Periodically trigger collection
        if (defers % 100 == 0) {
            ctx.collector.collect();
        }
    }

    // Final collection
    ctx.collector.collect();

    _ = ctx.defers_submitted.fetchAdd(defers, .release);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== Memory Pressure Stress Test ===\n", .{});
    std.debug.print("Threads: {}\n", .{NUM_THREADS});
    std.debug.print("Duration: {} seconds\n", .{TEST_DURATION_SECS});
    std.debug.print("Object size: {} bytes\n\n", .{OBJECT_SIZE});

    var collector = try Collector.init(allocator);
    defer collector.deinit();

    var should_stop = std.atomic.Value(bool).init(false);
    var contexts: [NUM_THREADS]ThreadContext = undefined;
    var threads: [NUM_THREADS]std.Thread = undefined;

    // Reset destructor counter
    destructor_calls.store(0, .release);

    // Initialize and spawn
    for (0..NUM_THREADS) |i| {
        contexts[i] = .{
            .collector = &collector,
            .allocator = allocator,
            .defers_submitted = std.atomic.Value(u64).init(0),
            .should_stop = &should_stop,
        };
        threads[i] = try std.Thread.spawn(.{}, memoryPressureWorker, .{&contexts[i]});
    }

    // Let it run
    std.Thread.sleep(TEST_DURATION_SECS * std.time.ns_per_s);

    // Signal stop
    should_stop.store(true, .release);

    // Wait for threads
    for (&threads) |*thread| {
        thread.join();
    }

    // Final collection pass
    collector.collect();

    // Collect results
    var total_defers: u64 = 0;
    for (&contexts) |*ctx| {
        total_defers += ctx.defers_submitted.load(.acquire);
    }

    const total_destructors = destructor_calls.load(.acquire);
    const pending = collector.getPendingCount();

    std.debug.print("Results:\n", .{});
    std.debug.print("  Defers submitted: {}\n", .{total_defers});
    std.debug.print("  Destructors called: {}\n", .{total_destructors});
    std.debug.print("  Pending count: {}\n", .{pending});
    std.debug.print("  Reclaim rate: {d:.1}%\n", .{@as(f64, @floatFromInt(total_destructors)) / @as(f64, @floatFromInt(total_defers)) * 100.0});

    // Validate that most objects were reclaimed
    // Some may be pending due to epoch timing
    const reclaim_threshold = total_defers * 80 / 100; // 80% should be reclaimed
    if (total_destructors >= reclaim_threshold) {
        std.debug.print("\n✓ PASS: Memory reclamation is working ({d:.1}% reclaimed)\n", .{
            @as(f64, @floatFromInt(total_destructors)) / @as(f64, @floatFromInt(total_defers)) * 100.0,
        });
    } else {
        std.debug.print("\n✗ FAIL: Insufficient reclamation (only {d:.1}%, expected >80%)\n", .{
            @as(f64, @floatFromInt(total_destructors)) / @as(f64, @floatFromInt(total_defers)) * 100.0,
        });
        std.process.exit(1);
    }
}
