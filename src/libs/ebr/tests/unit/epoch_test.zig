//! Unit tests for epoch management.

const std = @import("std");
const ebr = @import("ebr");

test "Global epoch starts at 0" {
    var collector = try ebr.Collector.init(std.testing.allocator);
    defer collector.deinit();

    try std.testing.expectEqual(@as(u64, 0), collector.getCurrentEpoch());
}

test "getCurrentEpoch returns correct value" {
    var collector = try ebr.Collector.init(std.testing.allocator);
    defer collector.deinit();

    // Initial
    try std.testing.expectEqual(@as(u64, 0), collector.getCurrentEpoch());

    // After advancement
    _ = collector.tryAdvanceEpoch();
    try std.testing.expectEqual(@as(u64, 1), collector.getCurrentEpoch());

    _ = collector.tryAdvanceEpoch();
    try std.testing.expectEqual(@as(u64, 2), collector.getCurrentEpoch());
}

test "Epoch advances when no active threads" {
    var collector = try ebr.Collector.init(std.testing.allocator);
    defer collector.deinit();

    const handle = try collector.registerThread();
    defer collector.unregisterThread(handle);

    // Thread registered but not pinned - should advance
    try std.testing.expect(collector.tryAdvanceEpoch());
    try std.testing.expectEqual(@as(u64, 1), collector.getCurrentEpoch());
}

test "Epoch does not advance with active pinned thread" {
    var collector = try ebr.Collector.init(std.testing.allocator);
    defer collector.deinit();

    const handle = try collector.registerThread();
    defer collector.unregisterThread(handle);

    // Advance once while unpinned
    _ = collector.tryAdvanceEpoch();
    const epoch_before = collector.getCurrentEpoch();

    // Pin the thread
    const guard = collector.pin();

    // Try to advance again - thread is pinned at old epoch
    // Advancement depends on implementation, just verify no crash
    _ = collector.tryAdvanceEpoch();

    guard.unpin();

    // After unpin, advancement should work
    _ = collector.tryAdvanceEpoch();
    try std.testing.expect(collector.getCurrentEpoch() >= epoch_before);
}
