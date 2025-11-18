//! ArcCycleDetector integration tests.
//! Focus: larger graphs, pool churn, and realistic release orders.
//! How to run:
//! - `cd utils && zig test src/arc/cycle-detector/_arc_cycle_detector_integration_tests.zig -OReleaseFast`
//! - or: `cd utils && zig build -Doptimize=ReleaseFast test`

const std = @import("std");
const testing = std.testing;
const ArcModule = @import("arc_core");
const DetectorModule = @import("arc_cycle_detector.zig");
const ArcPoolModule = @import("arc_pool");

const Node = struct {
    label: u8,
    next: ?ArcModule.Arc(@This()) = null,
};

const NodeArc = ArcModule.Arc(Node);
const Detector = DetectorModule.ArcCycleDetector(Node);
const Pool = ArcPoolModule.ArcPool(Node, false);

fn traceNode(_: ?*anyopaque, allocator: std.mem.Allocator, data: *const Node, children: *Detector.ChildList) void {
    if (data.next) |child| {
        if (!child.isInline()) {
            children.append(allocator, child.asPtr()) catch unreachable;
        }
    }
}

fn releaseNext(node: *NodeArc) void {
    if (node.asPtr().data.next) |child| {
        child.release();
        node.asPtr().data.next = null;
    }
}

const WorkerCtx = struct {
    pool: *Pool,
    iterations: usize,
};

fn workerChurn(ctx: *WorkerCtx) void {
    defer ctx.pool.drainThreadCache();
    var i: usize = 0;
    while (i < ctx.iterations) : (i += 1) {
        const label: u8 = @intCast(i % 26);
        const arc = ctx.pool.create(.{ .label = label, .next = null }) catch unreachable;
        ctx.pool.recycle(arc);
    }
}

test "ArcCycleDetector detects cycles built from pooled arcs" {
    var pool = Pool.init(testing.allocator, .{});
    defer pool.deinit();

    var detector = Detector.init(testing.allocator, traceNode, null);
    defer detector.deinit();

    var node_a = try pool.create(.{ .label = 'A', .next = null });
    var node_b = try pool.create(.{ .label = 'B', .next = null });

    node_a.asPtr().data.next = node_b.clone();
    node_b.asPtr().data.next = node_a.clone();

    try detector.track(&node_a);
    try detector.track(&node_b);

    var weak_a = node_a.downgrade().?;
    var weak_b = node_b.downgrade().?;
    defer weak_a.release();
    defer weak_b.release();

    node_a.release();
    node_b.release();

    var leaks = try detector.detectCycles();
    defer leaks.deinit();

    for (leaks.list.items) |*arc_ptr| {
        releaseNext(arc_ptr);
        arc_ptr.release();
    }
    pool.drainThreadCache();

    try testing.expectEqual(@as(usize, 2), leaks.list.items.len);
}

test "ArcCycleDetector prunes pooled nodes once references are cleared" {
    var pool = Pool.init(testing.allocator, .{});
    defer pool.deinit();

    var detector = Detector.init(testing.allocator, traceNode, null);
    defer detector.deinit();

    var node_a = try pool.create(.{ .label = 'A', .next = null });
    var node_b = try pool.create(.{ .label = 'B', .next = null });

    node_a.asPtr().data.next = node_b.clone();
    node_b.asPtr().data.next = node_a.clone();

    try detector.track(&node_a);
    try detector.track(&node_b);

    var weak_a = node_a.downgrade().?;
    var weak_b = node_b.downgrade().?;
    defer weak_a.release();
    defer weak_b.release();

    releaseNext(&node_a);
    releaseNext(&node_b);
    node_a.release();
    node_b.release();

    var leaks = try detector.detectCycles();
    defer leaks.deinit();
    pool.drainThreadCache();
    try testing.expectEqual(@as(usize, 0), leaks.list.items.len);
}

test "ArcCycleDetector handles mixed multi-node graphs" {
    var detector = Detector.init(testing.allocator, traceNode, null);
    defer detector.deinit();

    var node_a = try NodeArc.init(testing.allocator, .{ .label = 'A', .next = null });
    var node_b = try NodeArc.init(testing.allocator, .{ .label = 'B', .next = null });
    var node_c = try NodeArc.init(testing.allocator, .{ .label = 'C', .next = null });

    node_a.asPtr().data.next = node_b.clone();
    node_b.asPtr().data.next = node_c.clone();
    node_c.asPtr().data.next = node_a.clone();

    try detector.track(&node_a);
    try detector.track(&node_b);
    try detector.track(&node_c);

    var weak_a = node_a.downgrade().?;
    var weak_b = node_b.downgrade().?;
    var weak_c = node_c.downgrade().?;
    defer weak_a.release();
    defer weak_b.release();
    defer weak_c.release();

    // Break C -> A edge, rewire B -> A to keep a simple cycle.
    releaseNext(&node_c);
    releaseNext(&node_b);
    node_b.asPtr().data.next = node_a.clone();

    node_c.release();
    node_a.release();
    node_b.release();

    var leaks = try detector.detectCycles();
    defer leaks.deinit();

    for (leaks.list.items) |*arc_ptr| {
        releaseNext(arc_ptr);
        arc_ptr.release();
    }

    try testing.expectEqual(@as(usize, 2), leaks.list.items.len);
}

test "ArcCycleDetector survives pool churn with thread-local caches" {
    var pool = Pool.init(testing.allocator, .{});
    defer pool.deinit();

    var detector = Detector.init(testing.allocator, traceNode, null);
    defer detector.deinit();

    var node_a = try pool.create(.{ .label = 'A', .next = null });
    var node_b = try pool.create(.{ .label = 'B', .next = null });
    node_a.asPtr().data.next = node_b.clone();
    node_b.asPtr().data.next = node_a.clone();

    try detector.track(&node_a);
    try detector.track(&node_b);

    var weak_a = node_a.downgrade().?;
    var weak_b = node_b.downgrade().?;

    var threads: [4]std.Thread = undefined;
    var contexts: [4]WorkerCtx = undefined;
    for (&threads, 0..) |*t, idx| {
        contexts[idx] = .{ .pool = &pool, .iterations = 2000 + idx * 101 };
        t.* = try std.Thread.spawn(.{}, workerChurn, .{&contexts[idx]});
    }
    for (threads) |t| t.join();

    node_a.release();
    node_b.release();

    var leaks = try detector.detectCycles();
    defer leaks.deinit();

    for (leaks.list.items) |*arc_ptr| {
        releaseNext(arc_ptr);
        arc_ptr.release();
    }
    pool.drainThreadCache();

    weak_a.release();
    weak_b.release();

    try testing.expectEqual(@as(usize, 2), leaks.list.items.len);
}

const PoolCtx = struct {
    pool: *Pool,
    detector: *Detector,
    iterations: usize,
};

fn workerTrack(ctx: *PoolCtx) void {
    defer ctx.pool.drainThreadCache();
    var i: usize = 0;
    while (i < ctx.iterations) : (i += 1) {
        const label: u8 = @intCast((i % 26) + 'A');
        var arc = ctx.pool.create(.{ .label = label, .next = null }) catch unreachable;
        ctx.detector.track(&arc) catch unreachable;
        ctx.pool.recycle(arc);
    }
}

test "ArcCycleDetector scales with pooled tracking across threads" {
    var pool = Pool.init(testing.allocator, .{});
    defer pool.deinit();

    var detector = Detector.init(testing.allocator, traceNode, null);
    defer detector.deinit();

    var node_a = try pool.create(.{ .label = 'A', .next = null });
    var node_b = try pool.create(.{ .label = 'B', .next = null });
    node_a.asPtr().data.next = node_b.clone();
    node_b.asPtr().data.next = node_a.clone();

    try detector.track(&node_a);
    try detector.track(&node_b);

    var weak_a = node_a.downgrade().?;
    var weak_b = node_b.downgrade().?;

    var threads: [4]std.Thread = undefined;
    var contexts: [4]PoolCtx = undefined;
    for (&threads, 0..) |*t, idx| {
        contexts[idx] = .{
            .pool = &pool,
            .detector = &detector,
            .iterations = 500 + idx * 137,
        };
        t.* = try std.Thread.spawn(.{}, workerTrack, .{&contexts[idx]});
    }
    for (threads) |t| t.join();

    node_a.release();
    node_b.release();

    var leaks = try detector.detectCycles();
    defer leaks.deinit();
    for (leaks.list.items) |*arc_ptr| {
        releaseNext(arc_ptr);
        arc_ptr.release();
    }
    pool.drainThreadCache();

    weak_a.release();
    weak_b.release();

    try testing.expectEqual(@as(usize, 2), leaks.list.items.len);
}

// newCyclic: self-weak tek başına güçlü döngü oluşturmaz; dedektör sızıntı bulmamalı.
const NodeC_New = struct {
    weak_self: ArcModule.ArcWeak(@This()),
    pad: [64]u8 = [_]u8{0} ** 64,
};
const ArcNodeC_New = ArcModule.Arc(NodeC_New);
const DetectorC_New = DetectorModule.ArcCycleDetector(NodeC_New);
fn traceC_New(_: ?*anyopaque, allocator: std.mem.Allocator, data: *const NodeC_New, children: *DetectorC_New.ChildList) void {
    _ = allocator;
    _ = children;
    _ = data;
}
test "ArcCycleDetector ignores self-weak from Arc.newCyclic" {
    var detector = DetectorC_New.init(testing.allocator, traceC_New, null);
    defer detector.deinit();

    var arc = try ArcNodeC_New.newCyclic(testing.allocator, struct {
        fn ctor(w: ArcModule.ArcWeak(NodeC_New)) anyerror!NodeC_New { return NodeC_New{ .weak_self = w, }; }
    }.ctor);
    try detector.track(&arc);
    arc.release();

    var leaks = try detector.detectCycles();
    defer leaks.deinit();
    try testing.expectEqual(@as(usize, 0), leaks.list.items.len);
}

// createCyclic: pool üstünden self-weak oluşturulur; güçlü döngü yoksa dedektör sızıntı görmez.
const NodeC_Pool = struct {
    weak_self: ArcModule.ArcWeak(@This()),
    pad: [64]u8 = [_]u8{0} ** 64,
};
const PoolC_Pool = ArcPoolModule.ArcPool(NodeC_Pool, false);
const DetectorC_Pool = DetectorModule.ArcCycleDetector(NodeC_Pool);
fn traceC_Pool(_: ?*anyopaque, allocator: std.mem.Allocator, data: *const NodeC_Pool, children: *DetectorC_Pool.ChildList) void {
    _ = allocator;
    _ = children;
    _ = data;
}
test "ArcCycleDetector ignores self-weak from ArcPool.createCyclic" {
    var detector = DetectorC_Pool.init(testing.allocator, traceC_Pool, null);
    defer detector.deinit();

    var pool = PoolC_Pool.init(testing.allocator, .{});
    defer pool.deinit();

    const ctor = struct { fn f(w: ArcModule.ArcWeak(NodeC_Pool)) anyerror!NodeC_Pool { return NodeC_Pool{ .weak_self = w, }; } }.f;
    var arc = try pool.createCyclic(ctor);
    try detector.track(&arc);
    pool.recycle(arc);
    pool.drainThreadCache();

    var leaks = try detector.detectCycles();
    defer leaks.deinit();
    try testing.expectEqual(@as(usize, 0), leaks.list.items.len);
}
