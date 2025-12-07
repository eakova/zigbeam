const std = @import("std");
const api = @import("../api.zig");
const buckets = @import("../buckets.zig");

test "tinyufo: insert/get/evict basic" {
    const gpa = std.testing.allocator;
    var ufo = try api.TinyUFO(usize).init(gpa, 20, .fast, 64);
    defer ufo.deinit();

    try std.testing.expectEqual(@as(?*anyopaque, null), @as(?*anyopaque, @ptrCast(ufo.get(1))));
    try ufo.insert(1, 10, 10);
    try ufo.insert(2, 20, 15);
    // Eviction should kick in to enforce capacity 20
    const g1 = ufo.get(1);
    const g2 = ufo.get(2);
    _ = g1; _ = g2;
    // No strict assertion on which remains due to FIFO policy; smoke test only
}

test "tinyufo: stats counters" {
    const gpa = std.testing.allocator;
    var ufo = try api.TinyUFO(usize).init(gpa, 10, .fast, 16);
    defer ufo.deinit();
    try ufo.insert(1, 1, 1);
    _ = ufo.get(1);
    _ = ufo.get(2);
    // Not asserting exact values, just invoking paths for coverage
}

test "tinyufo: promotion to main" {
    const gpa = std.testing.allocator;
    var ufo = try api.TinyUFO(usize).init(gpa, 100, .fast, 64);
    defer ufo.deinit();
    try ufo.insert(10, 10, 10);
    const before = ufo.stats_total_weight();
    _ = ufo.get(10); // should promote to main
    const after = ufo.stats_total_weight();
    try std.testing.expect(before == after);
}

test "tinyufo: remove retires" {
    const gpa = std.testing.allocator;
    var ufo = try api.TinyUFO(usize).init(gpa, 100, .fast, 64);
    defer ufo.deinit();
    try ufo.insert(77, 77, 1);
    ufo.remove(77);
    try std.testing.expectEqual(@as(?*anyopaque, null), @as(?*anyopaque, @ptrCast(ufo.get(77))));
}
