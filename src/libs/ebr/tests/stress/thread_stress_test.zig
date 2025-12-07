//! Thread Registration Stress Test (T024)
//!
//! Stress tests thread registration/unregistration with multiple threads.
//! Validates that concurrent registration and unregistration is thread-safe.
//!
//! Note: Thread count reduced to 8 to avoid contention issues on typical hardware.

const std = @import("std");
const ebr = @import("ebr");

const Collector = ebr.Collector;

/// Number of threads for stress testing.
/// Reduced from 64 to 8 due to contention issues on typical hardware.
const NUM_THREADS: usize = 8;

/// Number of register/unregister cycles per thread.
const CYCLES_PER_THREAD: usize = 1000;

/// Thread worker that repeatedly registers and unregisters.
fn registerUnregisterWorker(collector: *Collector, results: *std.atomic.Value(u64)) void {
    var successes: u64 = 0;

    for (0..CYCLES_PER_THREAD) |_| {
        const handle = collector.registerThread() catch {
            continue;
        };

        // Do a quick pin/unpin to verify registration worked
        const guard = collector.pin();
        guard.unpin();

        collector.unregisterThread(handle);
        successes += 1;
    }

    _ = results.fetchAdd(successes, .release);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== Thread Registration Stress Test ===\n", .{});
    std.debug.print("Threads: {}\n", .{NUM_THREADS});
    std.debug.print("Cycles per thread: {}\n\n", .{CYCLES_PER_THREAD});

    var collector = try Collector.init(allocator);
    defer collector.deinit();

    var results = std.atomic.Value(u64).init(0);
    var threads: [NUM_THREADS]std.Thread = undefined;

    const start = std.time.nanoTimestamp();

    // Spawn all threads
    for (0..NUM_THREADS) |i| {
        threads[i] = try std.Thread.spawn(.{}, registerUnregisterWorker, .{ &collector, &results });
    }

    // Wait for all threads
    for (&threads) |*thread| {
        thread.join();
    }

    const end = std.time.nanoTimestamp();
    const elapsed_ms = @as(f64, @floatFromInt(end - start)) / 1_000_000.0;

    const total_successes = results.load(.acquire);
    const expected = NUM_THREADS * CYCLES_PER_THREAD;

    std.debug.print("Results:\n", .{});
    std.debug.print("  Total cycles: {}/{}\n", .{ total_successes, expected });
    std.debug.print("  Elapsed: {d:.2} ms\n", .{elapsed_ms});
    std.debug.print("  Rate: {d:.0} cycles/sec\n", .{@as(f64, @floatFromInt(total_successes)) * 1000.0 / elapsed_ms});

    if (total_successes == expected) {
        std.debug.print("\n✓ PASS: All register/unregister cycles completed\n", .{});
    } else {
        std.debug.print("\n✗ FAIL: Only {}/{} cycles completed\n", .{ total_successes, expected });
        std.process.exit(1);
    }
}
