const std = @import("std");
const testing = std.testing;
const Thread = std.Thread;
const Rng = std.rand.DefaultRng;

// Adjust import paths based on your project structure.
const Arc = @import("arc.zig").Arc;
const ArcWeak = @import("arc_weak.zig").ArcWeak;

// Configuration for the fuzz test.
const NUM_THREADS = 8; // The more, the better to induce contention.
const NUM_OPERATIONS_PER_THREAD = 10_000;
const NUM_INITIAL_ARCS = 4; // The central "target" Arcs that threads will contend over.

// Defines the set of operations a worker thread can perform.
const Operation = enum {
    Clone,
    Release,
    Downgrade,
    Upgrade,
};
const all_ops = @typeInfo(Operation).Enum.fields;

// A struct to hold the local state for each worker thread.
const ThreadState = struct {
    rng: Rng,
    owned_arcs: std.ArrayList(Arc(u64)),
    owned_weaks: std.ArrayList(ArcWeak(u64)),
    thread_id: usize,

    /// Releases all owned references to ensure no leaks from this thread's state.
    fn deinit(self: *ThreadState) void {
        for (self.owned_arcs.items) |arc| arc.release();
        for (self.owned_weaks.items) |weak| weak.release();
        self.owned_arcs.deinit();
        self.owned_weaks.deinit();
    }
};

/// The main worker function for a single thread in the fuzz test.
/// It performs a series of random operations on a shared set of Arcs.
fn fuzzWorker(
    allocator: std.mem.Allocator,
    thread_id: usize,
    shared_arcs: []const Arc(u64),
) !void {
    var state = ThreadState{
        .rng = Rng.init(0), // Can use a unique seed per thread for more randomness.
        .owned_arcs = std.ArrayList(Arc(u64)).init(allocator),
        .owned_weaks = std.ArrayList(ArcWeak(u64)).init(allocator),
        .thread_id = thread_id,
    };
    defer state.deinit();

    for (0..NUM_OPERATIONS_PER_THREAD) |_| {
        // 1. Select a random operation to perform.
        const op_index = state.rng.random().uintLessThan(u32, all_ops.len);
        const op = all_ops[op_index].value;

        switch (op) {
            .Clone => {
                // Randomly choose to clone one of the globally shared Arcs or one
                // of our locally owned ones. This creates more complex ownership chains.
                if (state.rng.random().boolean() and state.owned_arcs.items.len > 0) {
                    const idx = state.rng.random().uintLessThan(usize, state.owned_arcs.items.len);
                    try state.owned_arcs.append(state.owned_arcs.items[idx].clone());
                } else {
                    const idx = state.rng.random().uintLessThan(usize, shared_arcs.len);
                    try state.owned_arcs.append(shared_arcs[idx].clone());
                }
            },
            .Release => {
                // If we own any Arcs, randomly pick one and release it.
                if (state.owned_arcs.items.len > 0) {
                    const idx = state.rng.random().uintLessThan(usize, state.owned_arcs.items.len);
                    const arc = state.owned_arcs.swapRemove(idx);
                    arc.release();
                }
            },
            .Downgrade => {
                // Randomly pick an Arc to create a weak reference from.
                const arc_to_downgrade = if (state.owned_arcs.items.len > 0 and state.rng.random().boolean())
                    state.owned_arcs.items[state.rng.random().uintLessThan(usize, state.owned_arcs.items.len)]
                else
                    shared_arcs[state.rng.random().uintLessThan(usize, shared_arcs.len)];

                if (arc_to_downgrade.downgrade()) |weak| {
                    try state.owned_weaks.append(weak);
                }
            },
            .Upgrade => {
                // If we own any weak references, randomly pick one, consume it,
                // and attempt to upgrade it back to a strong Arc.
                if (state.owned_weaks.items.len > 0) {
                    const idx = state.rng.random().uintLessThan(usize, state.owned_weaks.items.len);
                    const weak = state.owned_weaks.swapRemove(idx);

                    if (weak.upgrade()) |arc| {
                        // Success! Add the new strong reference to our owned list.
                        try state.owned_arcs.append(arc);
                    } else {
                        // Upgrade failed, meaning the original Arc was destroyed.
                        // We must still release the weak reference itself.
                        weak.release();
                    }
                }
            },
        }

        // Introduce random, short sleeps to desynchronize threads and increase
        // the likelihood of hitting rare race conditions.
        if (state.rng.random().uintLessThan(u32, 100) < 5) { // 5% chance to sleep
            std.time.sleep(state.rng.random().uintLessThan(u64, 10_000)); // 0-10 microseconds
        }
    }
}

test "Arc concurrency fuzz test" {
    const allocator = testing.allocator;

    // 1. Create the set of shared Arcs that all threads will contend over.
    var shared_arcs: [NUM_INITIAL_ARCS]Arc(u64) = undefined;
    for (&shared_arcs, 0..) |*arc, i| {
        arc.* = try Arc(u64).init(allocator, @intCast(i));
    }
    // The main test function now owns one reference to each shared Arc.
    // This will be released by the defer at the end of the test.
    defer {
        for (shared_arcs) |arc| arc.release();
    }

    // Sanity check: verify initial state.
    for (shared_arcs) |arc| {
        try testing.expectEqual(@as(usize, 1), arc.strongCount());
    }

    // 2. Spawn worker threads.
    var threads: [NUM_THREADS]Thread = undefined;
    for (&threads, 0..) |*t, i| {
        t.* = try Thread.spawn(.{}, fuzzWorker, .{ allocator, i, &shared_arcs });
    }

    // 3. Wait for all worker threads to complete their operations.
    for (threads) |t| {
        t.join();
    }

    // 4. FINAL VERIFICATION
    // At this point, all worker threads have terminated and their `defer state.deinit()`
    // should have released all the references they acquired.
    // The only remaining strong references should be the ones held by this main
    // test function.
    for (shared_arcs, 0..) |arc, i| {
        try testing.expectEqual(@as(usize, 1), arc.strongCount());
        // This print helps in debugging if a test fails.
        std.debug.print("Final strong count for arc[{}]: {}\n", .{ i, arc.strongCount() });
    }

    // The most important check: `std.testing.allocator` will automatically verify
    // for leaks at the end of the test scope. If `defer` runs and releases the
    // final reference, and all memory is freed, this test passes. If any `Inner`
    // block is leaked, the test will fail here.
}
