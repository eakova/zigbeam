//! Unit tests for Collector init/deinit.

const std = @import("std");
const ebr = @import("ebr");

test "Collector init creates valid instance" {
    var collector = try ebr.Collector.init(std.testing.allocator);
    defer collector.deinit();

    // Verify initial state
    try std.testing.expectEqual(@as(u64, 0), collector.getCurrentEpoch());
    try std.testing.expectEqual(@as(usize, 0), collector.getPendingCount());
}

test "Collector deinit cleans up resources" {
    var collector = try ebr.Collector.init(std.testing.allocator);

    // Register and unregister a thread to exercise more code paths
    const handle = try collector.registerThread();
    collector.unregisterThread(handle);

    // Should not leak
    collector.deinit();
}

test "Collector multiple init/deinit cycles" {
    for (0..10) |_| {
        var collector = try ebr.Collector.init(std.testing.allocator);
        defer collector.deinit();

        const handle = try collector.registerThread();
        const guard = collector.pin();
        guard.unpin();
        collector.unregisterThread(handle);
    }
}
