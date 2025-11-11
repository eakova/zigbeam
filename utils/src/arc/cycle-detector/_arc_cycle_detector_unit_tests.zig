const std = @import("std");
const testing = std.testing;
const ArcModule = @import("arc_core");
const DetectorModule = @import("arc_cycle_detector.zig");

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

    try detector.track(node_a.clone());
    try detector.track(node_b.clone());

    var weak_a = node_a.downgrade().?;
    var weak_b = node_b.downgrade().?;
    defer weak_a.release();
    defer weak_b.release();

    node_a.release();
    node_b.release();

    var leaks = try detector.detectCycles();
    defer {
        for (leaks.list.items) |arc| {
            if (arc.asPtr().data.next) |child| {
                child.release();
                arc.asPtr().data.next = null;
            }
            arc.release();
        }
        leaks.deinit();
    }
    try testing.expectEqual(@as(usize, 2), leaks.list.items.len);
}

test "ArcCycleDetector ignores inline arcs" {
    const InlineArc = ArcModule.Arc(u8);
    const InlineDetector = DetectorModule.ArcCycleDetector(u8);

    var detector = InlineDetector.init(testing.allocator, noTrace, null);
    defer detector.deinit();

    const arc = try InlineArc.init(testing.allocator, 1);
    try detector.track(arc);
    var leaks = try detector.detectCycles();
    defer leaks.deinit();
    try testing.expectEqual(@as(usize, 0), leaks.list.items.len);
}
