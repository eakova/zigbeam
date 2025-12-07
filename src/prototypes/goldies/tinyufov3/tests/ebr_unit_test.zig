const std = @import("std");
const ebr = @import("../ebr.zig");

test "ebr: pin/unpin basic" {
    const gpa = std.testing.allocator;
    const collector = try ebr.Collector.init(gpa);
    defer collector.deinit();

    const guard1 = try collector.pin();
    collector.unpinGuard(guard1);

    const guard2 = try collector.pin();
    const guard3 = try collector.pin();
    collector.unpinGuard(guard3);
    collector.unpinGuard(guard2);
}

fn reclaim_box(ptr: *anyopaque, _: *ebr.Collector) void {
    const p: *usize = @ptrCast(@alignCast(ptr));
    std.testing.allocator.destroy(p);
}

test "ebr: retire and reclaim" {
    const gpa = std.testing.allocator;
    const collector = try ebr.Collector.init(gpa);
    defer collector.deinit();

    // Pin a guard (so retired object won't be reclaimed yet)
    const guard = try collector.pin();

    // Allocate and retire an object
    const p = try gpa.create(usize);
    p.* = 1234;
    try collector.retire(@ptrCast(p), reclaim_box);

    // Still pinned: object should not be reclaimed yet
    collector.unpinGuard(guard);

    // After unpin, reclamation proceeds; there is no direct assertion,
    // but double-destroy would cause test failures when allocator checks.
}

test "ebr: DROP mode immediate reclaim" {
    const gpa = std.testing.allocator;
    const collector = try ebr.Collector.init(gpa);
    defer collector.deinit();

    collector.enableDropMode();

    const reclaim_inc = struct {
        fn reclaim(ptr: *anyopaque, _: *ebr.Collector) void {
            const p: *usize = @ptrCast(@alignCast(ptr));
            p.* += 1;
        }
    };
    const p = try gpa.create(usize);
    p.* = 0;
    try collector.retire(@ptrCast(p), reclaim_inc.reclaim);
    // In DROP mode, reclaim runs immediately; value incremented to 1
    try std.testing.expectEqual(@as(usize, 1), p.*);
    gpa.destroy(p);
}

test "ebr: LocalGuard reentrancy" {
    const gpa = std.testing.allocator;
    const collector = try ebr.Collector.init(gpa);
    defer collector.deinit();

    var g1 = try ebr.Collector.LocalGuard.enter(collector);
    var g2 = try ebr.Collector.LocalGuard.enter(collector);
    g2.deinit();
    g1.deinit();
}

test "ebr: OwnedGuard basic" {
    const gpa = std.testing.allocator;
    const collector = try ebr.Collector.init(gpa);
    defer collector.deinit();
    var og = try ebr.Collector.OwnedGuard.enter(collector);
    og.lockGuard();
    og.unlockGuard();
    og.deinit();
}
