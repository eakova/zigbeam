//! ArcCycleDetector unit tests.
//! Focus: minimal graph patterns and correctness of leak detection.
//! How to run:
//! - `cd utils && zig test src/arc/cycle-detector/_arc_cycle_detector_unit_tests.zig -OReleaseFast`
//! - or: `cd utils && zig build -Doptimize=ReleaseFast test`

const std = @import("std");
const testing = std.testing;
const ArcModule = @import("arc");
const DetectorModule = @import("arc-cycle");

const Node = struct {
    label: u8,
    next: ?ArcModule.Arc(@This()) = null,
};

const NodeArc = ArcModule.Arc(Node);
const Detector = DetectorModule.ArcCycleDetector(Node);

fn traceNode(_: ?*anyopaque, allocator: std.mem.Allocator, data: *const Node, children: *Detector.ChildList) void {
    if (data.next) |child| {
        if (!child.isInline()) {
            children.append(allocator, child.asPtr()) catch unreachable;
        }
    }
}

fn noTrace(_: ?*anyopaque, _: std.mem.Allocator, _: *const u8, _: *DetectorModule.ArcCycleDetector(u8).ChildList) void {}

test "ArcCycleDetector finds a simple two-node cycle" {
    var detector = Detector.init(testing.allocator, traceNode, null);
    defer detector.deinit();

    var node_a = try NodeArc.init(testing.allocator, .{ .label = 'A', .next = null });
    var node_b = try NodeArc.init(testing.allocator, .{ .label = 'B', .next = null });

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
    defer leaks.deinit(); // This releases all Arc items automatically
    // Break cycles by releasing .next children (leaks.deinit() releases the arcs themselves)
    for (leaks.list.items) |arc| {
        if (arc.asPtr().data.next) |child| {
            child.release();
            arc.asPtr().data.next = null;
        }
    }
    try testing.expectEqual(@as(usize, 2), leaks.list.items.len);
}

test "ArcCycleDetector ignores inline arcs" {
    const InlineArc = ArcModule.Arc(u8);
    const InlineDetector = DetectorModule.ArcCycleDetector(u8);

    var detector = InlineDetector.init(testing.allocator, noTrace, null);
    defer detector.deinit();

    const arc = try InlineArc.init(testing.allocator, 1);
    try detector.track(&arc);
    var leaks = try detector.detectCycles();
    defer leaks.deinit();
    try testing.expectEqual(@as(usize, 0), leaks.list.items.len);
}

test "ArcCycleDetector survives partially traced graphs" {
    var detector = Detector.init(testing.allocator, traceNode, null);
    defer detector.deinit();

    var node_a = try NodeArc.init(testing.allocator, .{ .label = 'A', .next = null });
    // Note: node_a is released explicitly below, not via defer
    var node_b = try NodeArc.init(testing.allocator, .{ .label = 'B', .next = null });
    // Note: node_b is released explicitly below, not via defer
    var node_c = try NodeArc.init(testing.allocator, .{ .label = 'C', .next = null });
    // Cleanup node_c.next before releasing node_c (it holds a clone of node_a)
    defer {
        if (node_c.asPtr().data.next) |child| {
            child.release();
            node_c.asPtr().data.next = null;
        }
        node_c.release();
    }

    node_a.asPtr().data.next = node_b.clone();
    node_b.asPtr().data.next = node_c.clone();
    node_c.asPtr().data.next = node_a.clone();

    try detector.track(&node_a);
    try detector.track(&node_b);

    var weak_a = node_a.downgrade().?;
    var weak_b = node_b.downgrade().?;
    defer weak_a.release();
    defer weak_b.release();

    node_a.release();
    node_b.release();

    var leaks = try detector.detectCycles();
    defer leaks.deinit(); // This releases all Arc items automatically
    // Break cycles by releasing .next children (leaks.deinit() releases the arcs themselves)
    for (leaks.list.items) |arc| {
        if (arc.asPtr().data.next) |child| {
            child.release();
            arc.asPtr().data.next = null;
        }
    }
    try testing.expectEqual(@as(usize, 2), leaks.list.items.len);
}
