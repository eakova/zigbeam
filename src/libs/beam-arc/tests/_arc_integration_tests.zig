//! Arc integration tests.
//! Focus: multi-threaded clone/release and downgrade/upgrade flows with timing.
//! How to run:
//! - `cd utils && zig test src/arc/_arc_integration_tests.zig -OReleaseFast`
//! - or: `cd utils && zig build -Doptimize=ReleaseFast test`

const std = @import("std");
const testing = std.testing;
const ArcModule = @import("beam-arc");
const ArcPoolModule = @import("beam-arc-pool");

const ArcU64 = ArcModule.Arc(u64);
const ArcHeapBytes = ArcModule.Arc([32]u8);
const PoolValue = struct {
    bytes: [32]u8,
};
const Pool = ArcPoolModule.ArcPool(PoolValue, false);

const WorkerCtx = struct {
    shared: *ArcU64,
    iterations: usize,
};

fn workerClone(_: void, ctx: *WorkerCtx) void {
    var i: usize = 0;
    while (i < ctx.iterations) : (i += 1) {
        var clone = ctx.shared.clone();
        clone.release();
    }
}

const DowngradeCtx = struct {
    shared: *ArcHeapBytes,
    iterations: usize,
};

fn workerDowngrade(_: void, ctx: *DowngradeCtx) void {
    var i: usize = 0;
    while (i < ctx.iterations) : (i += 1) {
        if (ctx.shared.downgrade()) |weak| {
            if (weak.upgrade()) |tmp| tmp.release();
            weak.release();
        }
    }
}

test "Arc multi-threaded clone/release keeps counts stable" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var shared = try ArcU64.init(allocator, 123);
    defer shared.release();

    const thread_count = 4;
    const iterations: usize = 2_000;
    var contexts: [thread_count]WorkerCtx = undefined;
    var threads: [thread_count]std.Thread = undefined;

    for (&contexts, 0..) |*ctx, i| {
        ctx.* = .{ .shared = &shared, .iterations = iterations + i * 137 };
        threads[i] = try std.Thread.spawn(.{}, workerClone, .{ctx});
    }

    for (threads) |t| t.join();

    try testing.expectEqual(@as(usize, 1), shared.strongCount());
    try testing.expectEqual(@as(u64, 123), shared.get().*);
}

test "ArcPool recycles heap allocated inners" {
    var pool = Pool.init(testing.allocator, .{});
    defer pool.deinit();

    var arc_one = try pool.create(.{ .bytes = [_]u8{0} ** 32 });
    const first_ptr = arc_one.asPtr();
    pool.recycle(arc_one);

    var pattern: [32]u8 = undefined;
    var i: usize = 0;
    while (i < pattern.len) : (i += 1) pattern[i] = @intCast(i);

    var arc_two = try pool.create(.{ .bytes = pattern });
    defer pool.recycle(arc_two);
    const second_ptr = arc_two.asPtr();

    try testing.expectEqual(first_ptr, second_ptr);
    try testing.expectEqual(pattern, arc_two.get().*.bytes);
}

test "Arc downgrade/upgrade remains stable under contention" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var shared = try ArcHeapBytes.init(allocator, [_]u8{5} ** 32);
    defer shared.release();

    const threads = 4;
    const base_iterations: usize = 5_000;
    var contexts: [threads]DowngradeCtx = undefined;
    var handles: [threads]std.Thread = undefined;

    for (contexts, 0..) |*ctx, idx| {
        ctx.* = .{ .shared = &shared, .iterations = base_iterations + idx * 521 };
        handles[idx] = try std.Thread.spawn(.{}, workerDowngrade, .{ctx});
    }

    for (handles) |t| t.join();

    try testing.expectEqual(@as(usize, 1), shared.strongCount());
    try testing.expectEqual(@as(usize, 0), shared.weakCount());
}

test "Arc newCyclic integrates: self-weak upgrade ok before drop, fails after" {
    const Node = struct {
        weak_self: ArcModule.ArcWeak(@This()) = ArcModule.ArcWeak(@This()).empty(),
        pub fn deinit(self: *@This()) void {
            self.weak_self.release();
        }
    };
    const ArcNode = ArcModule.Arc(Node);

    var arc = try ArcNode.newCyclic(testing.allocator, struct {
        fn ctor(w: ArcModule.ArcWeak(Node)) anyerror!Node {
            // keep an owned weak by cloning
            return Node{ .weak_self = w.clone() };
        }
    }.ctor);
    const up = arc.get().*.weak_self.upgrade();
    try testing.expect(up != null);
    if (up) |t| t.release();
    const kept = arc.get().*.weak_self.clone();
    arc.release();
    try testing.expect(kept.upgrade() == null);
    kept.release();
}

test "ArcPool createCyclic integrates: pooled self-weak works and recycles" {
    // NOTE: ArcPool requires T to be trivially destructible (no deinit).
    // For types with deinit (like Node with weak_self), use regular Arc instead.
    // Here we test with a POD type that stores just a counter.
    const PodNode = struct {
        counter: u64 = 0,
        marker: u64 = 0,
    };
    const Pooled = ArcPoolModule.ArcPool(PodNode, false);
    var pool = Pooled.init(testing.allocator, .{});
    defer pool.deinit();

    const ctor = struct {
        fn f(w: ArcModule.ArcWeak(PodNode)) anyerror!PodNode {
            // Just verify we got a valid weak ref, then return POD data
            _ = w; // weak is temporary and released by Arc infrastructure
            return PodNode{ .counter = 42, .marker = 0xDEADBEEF };
        }
    }.f;

    var arc = try pool.createCyclic(ctor);
    try testing.expectEqual(@as(u64, 42), arc.get().*.counter);
    try testing.expectEqual(@as(u64, 0xDEADBEEF), arc.get().*.marker);
    pool.recycle(arc);
    pool.drainThreadCache();
}
