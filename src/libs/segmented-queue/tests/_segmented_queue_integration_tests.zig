const std = @import("std");
const SegmentedQueue = @import("segmented-queue").SegmentedQueue;
const ebr = @import("ebr");

test "segmented queue basic enqueue/dequeue with EBR" {
    const allocator = std.testing.allocator;

    // Initialize EBR collector
    var collector = try ebr.Collector.init(allocator);
    defer collector.deinit();

    // Register thread with collector
    const handle = try collector.registerThread();
    defer collector.unregisterThread(handle);

    // Create queue with collector
    const Queue = SegmentedQueue(u64, 4);
    var queue = try Queue.init(allocator, &collector);
    defer queue.deinit();

    // Enqueue items (uses internal guard)
    try queue.enqueueWithAutoGuard(1);
    try queue.enqueueWithAutoGuard(2);

    // Dequeue with auto guard
    try std.testing.expectEqual(@as(?u64, 1), queue.dequeueWithAutoGuard());
    try std.testing.expectEqual(@as(?u64, 2), queue.dequeueWithAutoGuard());
    try std.testing.expectEqual(@as(?u64, null), queue.dequeueWithAutoGuard());
}

test "segmented queue manual guard management" {
    const allocator = std.testing.allocator;

    var collector = try ebr.Collector.init(allocator);
    defer collector.deinit();

    const handle = try collector.registerThread();
    defer collector.unregisterThread(handle);

    const Queue = SegmentedQueue(u64, 4);
    var queue = try Queue.init(allocator, &collector);
    defer queue.deinit();

    // Use manual guard for batch operations
    {
        const guard = collector.pin();
        defer guard.unpin();

        try queue.enqueue(10);
        try queue.enqueue(20);
        try queue.enqueue(30);
    }

    {
        const guard = collector.pin();
        defer guard.unpin();

        try std.testing.expectEqual(@as(?u64, 10), queue.dequeue());
        try std.testing.expectEqual(@as(?u64, 20), queue.dequeue());
        try std.testing.expectEqual(@as(?u64, 30), queue.dequeue());
        try std.testing.expectEqual(@as(?u64, null), queue.dequeue());
    }
}

test "segmented queue batch operations" {
    const allocator = std.testing.allocator;

    var collector = try ebr.Collector.init(allocator);
    defer collector.deinit();

    const handle = try collector.registerThread();
    defer collector.unregisterThread(handle);

    const Queue = SegmentedQueue(u64, 4);
    var queue = try Queue.init(allocator, &collector);
    defer queue.deinit();

    // Batch enqueue
    const items = [_]u64{ 1, 2, 3, 4, 5 };
    try queue.enqueueMany(&items);

    // Batch dequeue
    var buffer: [5]u64 = undefined;
    const count = queue.dequeueMany(&buffer);

    try std.testing.expectEqual(@as(usize, 5), count);
    try std.testing.expectEqual(@as(u64, 1), buffer[0]);
    try std.testing.expectEqual(@as(u64, 5), buffer[4]);
}

test "segmented queue segment growth" {
    const allocator = std.testing.allocator;

    var collector = try ebr.Collector.init(allocator);
    defer collector.deinit();

    const handle = try collector.registerThread();
    defer collector.unregisterThread(handle);

    // Small segment capacity to force segment allocation
    const Queue = SegmentedQueue(u64, 4);
    var queue = try Queue.init(allocator, &collector);
    defer queue.deinit();

    // Enqueue more items than segment capacity
    for (0..20) |i| {
        try queue.enqueueWithAutoGuard(@intCast(i));
    }

    // Dequeue all items
    for (0..20) |i| {
        const item = queue.dequeueWithAutoGuard();
        try std.testing.expectEqual(@as(?u64, @intCast(i)), item);
    }

    try std.testing.expectEqual(@as(?u64, null), queue.dequeueWithAutoGuard());
}
