// FILE: _arc_fuzz_tests.zig
//! Concurrency fuzz test for Arc/ArcWeak.
//!
//! Goal:
//! - Exercise clone/release/downgrade/upgrade interleavings across many threads.
//! - Shake out use-after-free and leak bugs under random operation mixes.
//!
//! How to run:
//! - `cd utils && zig test src/arc/_arc_fuzz_tests.zig -OReleaseFast`
//! - Optional: override counts via build options (see `std.options`).

const std = @import("std");
const testing = std.testing;
const Thread = std.Thread;
const Rng = std.rand.DefaultRng;

const ArcModule = @import("arc");
const Arc = ArcModule.Arc;
const ArcWeak = ArcModule.ArcWeak;

// Configuration for the fuzz test. Can be overridden via build options for CI.
const NUM_THREADS = std.options.fuzz_threads orelse 8;
const NUM_OPERATIONS_PER_THREAD = std.options.fuzz_ops orelse 10_000;
const NUM_INITIAL_ARCS = 4;

const Operation = enum(u2) { // Explicit tag type for @enumFromInt
    Clone,
    Release,
    Downgrade,
    Upgrade,
};
const all_ops = @typeInfo(Operation).Enum.fields;

const ThreadState = struct {
    rng: Rng,
    owned_arcs: std.ArrayList(Arc(u64)),
    owned_weaks: std.ArrayList(ArcWeak(u64)),
    thread_id: usize,

    fn deinit(self: *ThreadState) void {
        for (self.owned_arcs.items) |arc| arc.release();
        for (self.owned_weaks.items) |weak| weak.release();
        self.owned_arcs.deinit();
        self.owned_weaks.deinit();
    }
};

fn fuzzWorker(
    allocator: std.mem.Allocator,
    thread_id: usize,
    shared_arcs: []const Arc(u64),
) !void {
    // CORRECTED (Suggestion 3): Seed RNG with a per-thread value for better randomness.
    // Using a prime number multiplication for a simple hash.
    var state = ThreadState{
        .rng = Rng.init(@as(u64, @intCast(thread_id)) * 0x9E3779B97F4A7C15),
        .owned_arcs = std.ArrayList(Arc(u64)).init(allocator),
        .owned_weaks = std.ArrayList(ArcWeak(u64)).init(allocator),
        .thread_id = thread_id,
    };
    defer state.deinit();

    for (0..NUM_OPERATIONS_PER_THREAD) |_| {
        const op_index = state.rng.random().uintLessThan(u32, all_ops.len);

        // CORRECTED (Bug 1): Use @enumFromInt to correctly convert the integer value to an enum tag.
        const op: Operation = @enumFromInt(op_index);

        switch (op) {
            .Clone => {
                if (state.rng.random().boolean() and state.owned_arcs.items.len > 0) {
                    const idx = state.rng.random().uintLessThan(usize, state.owned_arcs.items.len);
                    try state.owned_arcs.append(state.owned_arcs.items[idx].clone());
                } else {
                    const idx = state.rng.random().uintLessThan(usize, shared_arcs.len);
                    try state.owned_arcs.append(shared_arcs[idx].clone());
                }
            },
            .Release => {
                if (state.owned_arcs.items.len > 0) {
                    const idx = state.rng.random().uintLessThan(usize, state.owned_arcs.items.len);
                    const arc = state.owned_arcs.swapRemove(idx);
                    arc.release();
                }
            },
            .Downgrade => {
                const arc_to_downgrade = if (state.owned_arcs.items.len > 0 and state.rng.random().boolean())
                    state.owned_arcs.items[state.rng.random().uintLessThan(usize, state.owned_arcs.items.len)]
                else
                    shared_arcs[state.rng.random().uintLessThan(usize, shared_arcs.len)];

                if (arc_to_downgrade.downgrade()) |weak| {
                    try state.owned_weaks.append(weak);
                }
            },
            .Upgrade => {
                if (state.owned_weaks.items.len > 0) {
                    const idx = state.rng.random().uintLessThan(usize, state.owned_weaks.items.len);
                    const weak = state.owned_weaks.swapRemove(idx);

                    if (weak.upgrade()) |arc| {
                        try state.owned_arcs.append(arc);
                        // CORRECTED (Bug 2): The weak reference is now redundant. Release it to prevent a leak.
                        weak.release();
                    } else {
                        // Upgrade failed. The weak reference must still be released.
                        weak.release();
                    }
                }
            },
        }

        if (state.rng.random().uintLessThan(u32, 100) < 5) {
            // Comment corrected for clarity. 10_000 ns = 10 µs.
            std.time.sleep(state.rng.random().uintLessThan(u64, 10_000)); // 0-10 microseconds
        }
    }
}

test "Arc concurrency fuzz test" {
    const allocator = testing.allocator;

    var shared_arcs: [NUM_INITIAL_ARCS]Arc(u64) = undefined;
    for (&shared_arcs, 0..) |*arc, i| {
        arc.* = try Arc(u64).init(allocator, @intCast(i));
    }
    defer {
        for (shared_arcs) |arc| arc.release();
    }

    var threads: [NUM_THREADS]Thread = undefined;
    for (&threads, 0..) |*t, i| {
        t.* = try Thread.spawn(.{}, fuzzWorker, .{ allocator, i, &shared_arcs });
    }

    for (threads) |t| {
        t.join();
    }

    // Final verification remains the same. If the test passes `expectNoLeaks`
    // at the end, it means our fixes for the leaks were successful.
    for (shared_arcs) |arc| {
        try testing.expectEqual(@as(usize, 1), arc.strongCount());
    }
}
