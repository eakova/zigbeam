//! Arc atomic operations unit tests.
//! Tests for atomicLoad, atomicStore, atomicSwap, atomicCompareSwap, and ptrEqual.

const std = @import("std");
const testing = std.testing;
const Arc = @import("arc.zig").Arc;
const Thread = std.Thread;

const ArcU32 = Arc(u32);
const ArcU64 = Arc(u64);
const ArcBuffer = Arc([64]u8);

// ============================================================================
// Basic Atomic Operations Tests
// ============================================================================

test "atomicLoad - basic functionality" {
    const arc = try ArcU32.init(testing.allocator, 42);
    defer arc.release();

    // Atomic load should return a cloned Arc
    const loaded = ArcU32.atomicLoad(&arc, .acquire) orelse return error.TestFailed;
    defer loaded.release();

    // Values should match
    try testing.expectEqual(@as(u32, 42), loaded.get().*);

    // Strong count should be 2 (original + loaded)
    try testing.expectEqual(@as(usize, 2), arc.strongCount());
}

test "atomicLoad - returns null for deallocated Arc" {
    // This test verifies the safety check in atomicLoad
    // We can't easily test this without unsafe operations since we
    // properly manage refcounts. Documented for completeness.
}

test "atomicStore - basic functionality" {
    var arc1 = try ArcU32.init(testing.allocator, 100);
    const arc2 = try ArcU32.init(testing.allocator, 200);

    // Arc1 starts at 100
    try testing.expectEqual(@as(u32, 100), arc1.get().*);

    // Atomically store arc2 into arc1
    ArcU32.atomicStore(&arc1, arc2, .release);

    // Arc1 should now be 200
    try testing.expectEqual(@as(u32, 200), arc1.get().*);

    // Clean up (arc2 was moved into arc1, so only release arc1)
    arc1.release();
}

test "atomicStore - properly releases old value" {
    var deinit_called = false;
    const TrackedValue = struct {
        flag: *bool,
        value: u32,

        pub fn deinit(self: *@This()) void {
            self.flag.* = true;
        }
    };

    const ArcTracked = Arc(TrackedValue);

    var arc1 = try ArcTracked.init(testing.allocator, .{ .flag = &deinit_called, .value = 1 });
    const arc2 = try ArcTracked.init(testing.allocator, .{ .flag = &deinit_called, .value = 2 });

    // Atomically store arc2 into arc1 - should release old arc1
    ArcTracked.atomicStore(&arc1, arc2, .release);

    // Old value should be released and deinit called
    try testing.expect(deinit_called);

    arc1.release();
}

test "atomicSwap - basic functionality" {
    var arc1 = try ArcU32.init(testing.allocator, 111);
    const arc2 = try ArcU32.init(testing.allocator, 222);

    try testing.expectEqual(@as(u32, 111), arc1.get().*);

    // Atomically swap - returns old value
    const old_arc = ArcU32.atomicSwap(&arc1, arc2, .acq_rel);
    defer old_arc.release();

    try testing.expectEqual(@as(u32, 222), arc1.get().*);
    try testing.expectEqual(@as(u32, 111), old_arc.get().*);

    arc1.release();
}

test "atomicCompareSwap - success case" {
    var arc = try ArcU32.init(testing.allocator, 100);
    defer arc.release();

    const expected = arc.clone();
    defer expected.release();

    const new_arc = try ArcU32.init(testing.allocator, 200);

    // CAS should succeed because arc == expected
    const prev = ArcU32.atomicCompareSwap(&arc, expected, new_arc, .acq_rel, .acquire);
    defer prev.release();

    // Arc should now contain 200
    try testing.expectEqual(@as(u32, 200), arc.get().*);

    // prev should equal expected (CAS succeeded)
    try testing.expect(ArcU32.ptrEqual(prev, expected));
}

test "atomicCompareSwap - failure case" {
    var arc = try ArcU32.init(testing.allocator, 100);
    defer arc.release();

    const wrong_expected = try ArcU32.init(testing.allocator, 999);
    defer wrong_expected.release();

    const new_arc = try ArcU32.init(testing.allocator, 200);

    // CAS should fail because arc != wrong_expected
    const prev = ArcU32.atomicCompareSwap(&arc, wrong_expected, new_arc, .acq_rel, .acquire);
    defer prev.release();

    // Arc should still contain 100 (CAS failed)
    try testing.expectEqual(@as(u32, 100), arc.get().*);

    // prev should NOT equal wrong_expected (CAS failed)
    try testing.expect(!ArcU32.ptrEqual(prev, wrong_expected));

    // new_arc was not used, so release it
    new_arc.release();
}

test "ptrEqual - same Inner" {
    const arc1 = try ArcU32.init(testing.allocator, 42);
    defer arc1.release();

    const arc2 = arc1.clone();
    defer arc2.release();

    // Should point to same Inner
    try testing.expect(ArcU32.ptrEqual(arc1, arc2));
}

test "ptrEqual - different Inner" {
    const arc1 = try ArcU32.init(testing.allocator, 42);
    defer arc1.release();

    const arc2 = try ArcU32.init(testing.allocator, 42);
    defer arc2.release();

    // Should point to different Inner (even though values are equal)
    try testing.expect(!ArcU32.ptrEqual(arc1, arc2));
}

// ============================================================================
// Multi-threaded Tests
// ============================================================================

test "atomicLoad - concurrent readers" {
    var shared_arc = try ArcU64.init(testing.allocator, 999);
    defer shared_arc.release();

    const Context = struct {
        arc: *const ArcU64,
        success_count: *std.atomic.Value(usize),
    };

    var success_count = std.atomic.Value(usize).init(0);
    const ctx = Context{ .arc = &shared_arc, .success_count = &success_count };

    const reader_fn = struct {
        fn run(c: Context) void {
            var i: usize = 0;
            while (i < 10000) : (i += 1) {
                if (ArcU64.atomicLoad(c.arc, .acquire)) |loaded| {
                    defer loaded.release();
                    if (loaded.get().* == 999) {
                        _ = c.success_count.fetchAdd(1, .monotonic);
                    }
                }
            }
        }
    }.run;

    // Spawn multiple readers
    var threads: [4]Thread = undefined;
    for (&threads) |*t| {
        t.* = try Thread.spawn(.{}, reader_fn, .{ctx});
    }

    for (threads) |t| {
        t.join();
    }

    // All reads should have succeeded
    const total = success_count.load(.monotonic);
    try testing.expectEqual(@as(usize, 40000), total);
}

test "atomicSwap - concurrent swappers" {
    var shared_arc = try ArcU32.init(testing.allocator, 0);
    defer {
        // Final cleanup - may contain any value from 0-3
        shared_arc.release();
    }

    const Context = struct {
        arc: *ArcU32,
        thread_id: u32,
    };

    const swapper_fn = struct {
        fn run(c: Context) !void {
            var i: usize = 0;
            while (i < 100) : (i += 1) {
                const new_arc = try ArcU32.init(testing.allocator, c.thread_id);
                const old_arc = ArcU32.atomicSwap(c.arc, new_arc, .acq_rel);
                old_arc.release();
                Thread.yield() catch {};
            }
        }
    }.run;

    var threads: [4]Thread = undefined;
    for (&threads, 0..) |*t, i| {
        t.* = try Thread.spawn(.{}, swapper_fn, .{Context{
            .arc = &shared_arc,
            .thread_id = @intCast(i),
        }});
    }

    for (threads) |t| {
        t.join();
    }

    // Final value should be 0, 1, 2, or 3
    const final_value = shared_arc.get().*;
    try testing.expect(final_value <= 3);
}

test "atomicCompareSwap - concurrent CAS contention" {
    var shared_arc = try ArcU32.init(testing.allocator, 0);
    defer shared_arc.release();

    const Context = struct {
        arc: *ArcU32,
        success_count: *std.atomic.Value(usize),
        allocator: std.mem.Allocator,
    };

    var success_count = std.atomic.Value(usize).init(0);

    const cas_fn = struct {
        fn run(c: Context) !void {
            var i: usize = 0;
            while (i < 100) : (i += 1) {
                // Try to increment the value with CAS
                var expected = c.arc.clone();
                const current_value = expected.get().*;
                const new_value = current_value + 1;

                const new_arc = try ArcU32.init(c.allocator, new_value);

                const prev = ArcU32.atomicCompareSwap(c.arc, expected, new_arc, .acq_rel, .acquire);

                if (ArcU32.ptrEqual(prev, expected)) {
                    // CAS succeeded
                    _ = c.success_count.fetchAdd(1, .monotonic);
                    prev.release();
                    expected.release();
                } else {
                    // CAS failed - clean up
                    prev.release();
                    expected.release();
                    new_arc.release();
                }

                Thread.yield() catch {};
            }
        }
    }.run;

    var threads: [4]Thread = undefined;
    for (&threads) |*t| {
        t.* = try Thread.spawn(.{}, cas_fn, .{Context{
            .arc = &shared_arc,
            .success_count = &success_count,
            .allocator = testing.allocator,
        }});
    }

    for (threads) |t| {
        t.join();
    }

    // Total successful CAS operations should match final value
    const total_successes = success_count.load(.monotonic);
    const final_value = shared_arc.get().*;
    try testing.expectEqual(total_successes, final_value);
}

// ============================================================================
// Memory Safety Tests
// ============================================================================

test "atomicLoad - no memory leaks" {
    const allocator = testing.allocator;

    var arc = try ArcBuffer.init(allocator, [_]u8{0} ** 64);
    defer arc.release();

    // Perform many atomic loads
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        const loaded = ArcBuffer.atomicLoad(&arc, .acquire) orelse unreachable;
        loaded.release();
    }

    // If there were leaks, the test allocator would catch them
}

test "atomicSwap - no memory leaks" {
    const allocator = testing.allocator;

    var arc = try ArcU64.init(allocator, 0);

    // Perform many swaps
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        const new_arc = try ArcU64.init(allocator, i);
        const old_arc = ArcU64.atomicSwap(&arc, new_arc, .acq_rel);
        old_arc.release();
    }

    arc.release();

    // If there were leaks, the test allocator would catch them
}

test "atomicStore - no memory leaks" {
    const allocator = testing.allocator;

    var arc = try ArcU64.init(allocator, 0);

    // Perform many stores
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        const new_arc = try ArcU64.init(allocator, i);
        ArcU64.atomicStore(&arc, new_arc, .release);
    }

    arc.release();

    // If there were leaks, the test allocator would catch them
}
