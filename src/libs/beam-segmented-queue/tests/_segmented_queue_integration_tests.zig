const std = @import("std");
const SegmentedQueue = @import("beam-segmented-queue").SegmentedQueue;
const ebr = @import("beam-ebr");

test "segmented queue basic enqueue/dequeue with EBR" {
    const allocator = std.testing.allocator;
    const Queue = SegmentedQueue(u64, 4);

    var queue = try Queue.init(allocator);
    defer queue.deinit();

    const participant = try queue.createParticipant();
    defer queue.destroyParticipant(participant);

    try queue.enqueue(1);
    try queue.enqueue(2);

    var guard1 = ebr.pin();
    defer guard1.deinit();
    try std.testing.expectEqual(@as(?u64, 1), queue.dequeue(&guard1));

    var guard2 = ebr.pin();
    defer guard2.deinit();
    try std.testing.expectEqual(@as(?u64, 2), queue.dequeue(&guard2));

    var guard3 = ebr.pin();
    defer guard3.deinit();
    try std.testing.expectEqual(@as(?u64, null), queue.dequeue(&guard3));
}

