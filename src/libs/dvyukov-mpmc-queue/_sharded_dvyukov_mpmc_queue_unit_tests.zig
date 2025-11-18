const std = @import("std");
const testing = std.testing;
const ShardedDVyukovMPMCQueue = @import("sharded_dvyukov_mpmc_queue.zig").ShardedDVyukovMPMCQueue;

// ============================================================================
// Basic Functionality Tests
// ============================================================================

test "ShardedDVyukovMPMCQueue: init/deinit" {
    const Queue = ShardedDVyukovMPMCQueue(u64, 4, 16);
    var queue = try Queue.init(testing.allocator);
    defer queue.deinit();

    try testing.expectEqual(@as(usize, 4), queue.shardCount());
    try testing.expectEqual(@as(usize, 16), queue.capacityPerShard());
    try testing.expectEqual(@as(usize, 64), queue.totalCapacity());
}

test "ShardedDVyukovMPMCQueue: enqueue/dequeue single items" {
    const Queue = ShardedDVyukovMPMCQueue(usize, 4, 16);
    var queue = try Queue.init(testing.allocator);
    defer queue.deinit();

    // Enqueue to different shards
    try queue.enqueueToShard(0, 100);
    try queue.enqueueToShard(1, 200);
    try queue.enqueueToShard(2, 300);
    try queue.enqueueToShard(3, 400);

    // Dequeue from corresponding shards
    try testing.expectEqual(@as(?usize, 100), queue.dequeueFromShard(0));
    try testing.expectEqual(@as(?usize, 200), queue.dequeueFromShard(1));
    try testing.expectEqual(@as(?usize, 300), queue.dequeueFromShard(2));
    try testing.expectEqual(@as(?usize, 400), queue.dequeueFromShard(3));

    // All shards should be empty
    try testing.expectEqual(@as(?usize, null), queue.dequeueFromShard(0));
    try testing.expectEqual(@as(?usize, null), queue.dequeueFromShard(1));
    try testing.expectEqual(@as(?usize, null), queue.dequeueFromShard(2));
    try testing.expectEqual(@as(?usize, null), queue.dequeueFromShard(3));
}

test "ShardedDVyukovMPMCQueue: shard isolation" {
    const Queue = ShardedDVyukovMPMCQueue(u64, 2, 4);
    var queue = try Queue.init(testing.allocator);
    defer queue.deinit();

    // Fill shard 0 completely
    try queue.enqueueToShard(0, 1);
    try queue.enqueueToShard(0, 2);
    try queue.enqueueToShard(0, 3);
    try queue.enqueueToShard(0, 4);

    // Shard 0 should be full
    try testing.expectError(error.QueueFull, queue.enqueueToShard(0, 5));

    // But shard 1 should still be empty
    try testing.expect(queue.isShardEmpty(1));
    try queue.enqueueToShard(1, 10);
    try testing.expectEqual(@as(?u64, 10), queue.dequeueFromShard(1));

    // Drain shard 0
    try testing.expectEqual(@as(?u64, 1), queue.dequeueFromShard(0));
    try testing.expectEqual(@as(?u64, 2), queue.dequeueFromShard(0));
    try testing.expectEqual(@as(?u64, 3), queue.dequeueFromShard(0));
    try testing.expectEqual(@as(?u64, 4), queue.dequeueFromShard(0));
    try testing.expectEqual(@as(?u64, null), queue.dequeueFromShard(0));
}

test "ShardedDVyukovMPMCQueue: FIFO ordering within shard" {
    const Queue = ShardedDVyukovMPMCQueue(u32, 2, 8);
    var queue = try Queue.init(testing.allocator);
    defer queue.deinit();

    // Enqueue sequence to shard 0
    try queue.enqueueToShard(0, 10);
    try queue.enqueueToShard(0, 20);
    try queue.enqueueToShard(0, 30);
    try queue.enqueueToShard(0, 40);

    // Should dequeue in same order
    try testing.expectEqual(@as(?u32, 10), queue.dequeueFromShard(0));
    try testing.expectEqual(@as(?u32, 20), queue.dequeueFromShard(0));
    try testing.expectEqual(@as(?u32, 30), queue.dequeueFromShard(0));
    try testing.expectEqual(@as(?u32, 40), queue.dequeueFromShard(0));
}

test "ShardedDVyukovMPMCQueue: drainAll" {
    const Queue = ShardedDVyukovMPMCQueue(u64, 2, 8);
    var queue = try Queue.init(testing.allocator);
    defer queue.deinit();

    // Add items to both shards
    try queue.enqueueToShard(0, 1);
    try queue.enqueueToShard(0, 2);
    try queue.enqueueToShard(1, 10);
    try queue.enqueueToShard(1, 20);

    try testing.expectEqual(@as(usize, 4), queue.totalSize());

    // Drain all shards
    queue.drainAll(null);

    // Verify all shards are empty
    try testing.expect(queue.isShardEmpty(0));
    try testing.expect(queue.isShardEmpty(1));
    try testing.expectEqual(@as(usize, 0), queue.totalSize());
}

// ============================================================================
// Monitoring/Telemetry Tests
// ============================================================================

test "ShardedDVyukovMPMCQueue: shardSize" {
    const Queue = ShardedDVyukovMPMCQueue(u64, 3, 8);
    var queue = try Queue.init(testing.allocator);
    defer queue.deinit();

    try testing.expectEqual(@as(usize, 0), queue.shardSize(0));
    try testing.expectEqual(@as(usize, 0), queue.shardSize(1));
    try testing.expectEqual(@as(usize, 0), queue.shardSize(2));

    try queue.enqueueToShard(0, 1);
    try queue.enqueueToShard(0, 2);
    try queue.enqueueToShard(1, 10);

    try testing.expectEqual(@as(usize, 2), queue.shardSize(0));
    try testing.expectEqual(@as(usize, 1), queue.shardSize(1));
    try testing.expectEqual(@as(usize, 0), queue.shardSize(2));
}

test "ShardedDVyukovMPMCQueue: totalSize" {
    const Queue = ShardedDVyukovMPMCQueue(u64, 4, 8);
    var queue = try Queue.init(testing.allocator);
    defer queue.deinit();

    try testing.expectEqual(@as(usize, 0), queue.totalSize());

    try queue.enqueueToShard(0, 1);
    try queue.enqueueToShard(1, 2);
    try queue.enqueueToShard(2, 3);
    try queue.enqueueToShard(3, 4);

    try testing.expectEqual(@as(usize, 4), queue.totalSize());

    _ = queue.dequeueFromShard(0);
    _ = queue.dequeueFromShard(1);

    try testing.expectEqual(@as(usize, 2), queue.totalSize());
}

test "ShardedDVyukovMPMCQueue: isEmpty/isFull per shard" {
    const Queue = ShardedDVyukovMPMCQueue(u64, 2, 4);
    var queue = try Queue.init(testing.allocator);
    defer queue.deinit();

    // Both shards start empty
    try testing.expect(queue.isShardEmpty(0));
    try testing.expect(queue.isShardEmpty(1));
    try testing.expect(!queue.isShardFull(0));
    try testing.expect(!queue.isShardFull(1));

    // Fill shard 0
    try queue.enqueueToShard(0, 1);
    try queue.enqueueToShard(0, 2);
    try queue.enqueueToShard(0, 3);
    try queue.enqueueToShard(0, 4);

    // Shard 0 is full, shard 1 still empty
    try testing.expect(!queue.isShardEmpty(0));
    try testing.expect(queue.isShardFull(0));
    try testing.expect(queue.isShardEmpty(1));
    try testing.expect(!queue.isShardFull(1));
}

// ============================================================================
// Edge Cases
// ============================================================================

test "ShardedDVyukovMPMCQueue: alternating enqueue/dequeue" {
    const Queue = ShardedDVyukovMPMCQueue(usize, 2, 8);
    var queue = try Queue.init(testing.allocator);
    defer queue.deinit();

    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const shard = i % 2;
        try queue.enqueueToShard(shard, i);
        try testing.expectEqual(@as(?usize, i), queue.dequeueFromShard(shard));
    }

    try testing.expect(queue.isShardEmpty(0));
    try testing.expect(queue.isShardEmpty(1));
}

test "ShardedDVyukovMPMCQueue: tryEnqueueToShard with retry limit" {
    const Queue = ShardedDVyukovMPMCQueue(u64, 2, 4);
    var queue = try Queue.init(testing.allocator);
    defer queue.deinit();

    // Fill shard 0
    try queue.tryEnqueueToShard(0, 1, 10);
    try queue.tryEnqueueToShard(0, 2, 10);
    try queue.tryEnqueueToShard(0, 3, 10);
    try queue.tryEnqueueToShard(0, 4, 10);

    // Should fail even with retries
    try testing.expectError(error.QueueFull, queue.tryEnqueueToShard(0, 5, 10));

    // But shard 1 should work
    try queue.tryEnqueueToShard(1, 100, 10);
    try testing.expectEqual(@as(?u64, 100), queue.dequeueFromShard(1));
}

test "ShardedDVyukovMPMCQueue: wraparound in individual shard" {
    const Queue = ShardedDVyukovMPMCQueue(u64, 2, 4);
    var queue = try Queue.init(testing.allocator);
    defer queue.deinit();

    // Test wraparound in shard 0
    var i: u64 = 0;
    while (i < 20) : (i += 1) {
        try queue.enqueueToShard(0, i);
        try testing.expectEqual(@as(?u64, i), queue.dequeueFromShard(0));
    }

    try testing.expect(queue.isShardEmpty(0));
}
