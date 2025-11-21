const std = @import("std");
const Backoff = @import("beam-backoff").Backoff;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    std.debug.print("Backoff samples\n", .{});

    try demoSpinLoop();
    try demoSnoozeWait();
    try demoIsCompletedHint();
    try demoCustomLimits();
}

fn demoSpinLoop() !void {
    var counter = std.atomic.Value(usize).init(1);

    var backoff = Backoff.init(.{});
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        const old = counter.load(.seq_cst);
        if (counter.cmpxchgStrong(old, old * 2, .seq_cst, .seq_cst) == null) {
            std.debug.print("spin demo: updated counter from {d} to {d}\n", .{ old, old * 2 });
        } else {
            backoff.spin();
        }
    }
}

fn demoSnoozeWait() !void {
    var ready = std.atomic.Value(bool).init(false);

    var backoff = Backoff.init(.{});
    var spins: usize = 0;
    while (!ready.load(.seq_cst)) {
        // Simulate another thread setting the flag after a few iterations.
        if (spins == 10) {
            ready.store(true, .seq_cst);
        } else {
            backoff.snooze();
            spins += 1;
        }
    }

    std.debug.print("snooze demo: flag observed after {d} iterations\n", .{spins});
}

fn demoIsCompletedHint() !void {
    var backoff = Backoff.init(.{});
    var iterations: usize = 0;
    while (!backoff.isCompleted()) : (iterations += 1) {
        backoff.snooze();
    }

    std.debug.print("isCompleted demo: backoff.completed() after {d} snoozes\n", .{iterations});
}

fn demoCustomLimits() !void {
    // Create a backoff with custom limits for more aggressive spinning
    var aggressive_backoff = Backoff.init(.{
        .spin_limit = 8,  // Spin up to 2^8 = 256 times (default: 2^6 = 64)
        .yield_limit = 15, // More yielding steps before completion (default: 10)
    });

    // Create a backoff with conservative limits for light spinning
    var conservative_backoff = Backoff.init(.{
        .spin_limit = 4,  // Spin up to 2^4 = 16 times (less aggressive)
        .yield_limit = 6,  // Complete sooner (default: 10)
    });

    // Demonstrate that they behave differently
    var aggressive_steps: usize = 0;
    while (!aggressive_backoff.isCompleted()) : (aggressive_steps += 1) {
        aggressive_backoff.snooze();
    }

    var conservative_steps: usize = 0;
    while (!conservative_backoff.isCompleted()) : (conservative_steps += 1) {
        conservative_backoff.snooze();
    }

    std.debug.print("custom limits demo:\n", .{});
    std.debug.print("  aggressive (spin=8, yield=15): completed after {d} steps\n", .{aggressive_steps});
    std.debug.print("  conservative (spin=4, yield=6): completed after {d} steps\n", .{conservative_steps});
}
