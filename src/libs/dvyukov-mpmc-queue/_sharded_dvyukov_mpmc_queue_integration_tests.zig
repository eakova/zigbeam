const std = @import("std");
const testing = std.testing;
const Thread = std.Thread;
const Atomic = std.atomic.Value;
const ShardedDVyukovMPMCQueue = @import("sharded_dvyukov_mpmc_queue.zig").ShardedDVyukovMPMCQueue;

// ============================================================================
// Multi-threaded Integration Tests
// ============================================================================

test "ShardedDVyukovMPMCQueue: 4P/4C with perfect sharding" {
    const num_producers = 4;
    const num_consumers = 4;
    const num_shards = 4; // 1P+1C per shard (optimal)
    const items_per_producer = 1_000; // Reduced: tight 1P+1C pairing creates ping-pong

    var queue = try ShardedDVyukovMPMCQueue(u64, num_shards, 256).init(testing.allocator);
    defer queue.deinit();

    const WorkerCtx = struct {
        queue: *ShardedDVyukovMPMCQueue(u64, num_shards, 256),
        shard_id: usize,
        iterations: usize,
        start_flag: *Atomic(u8),
        is_producer: bool,
        errors: *Atomic(usize),

        fn run(ctx: *@This()) void {
            while (ctx.start_flag.load(.seq_cst) == 0) {
                Thread.yield() catch {};
            }

            if (ctx.is_producer) {
                var i: u64 = 0;
                while (i < ctx.iterations) : (i += 1) {
                    while (true) {
                        ctx.queue.enqueueToShard(ctx.shard_id, i) catch {
                            Thread.yield() catch {};
                            continue;
                        };
                        break;
                    }
                }
            } else {
                var count: usize = 0;
                while (count < ctx.iterations) {
                    if (ctx.queue.dequeueFromShard(ctx.shard_id)) |_| {
                        count += 1;
                    } else {
                        Thread.yield() catch {};
                    }
                }
            }
        }
    };

    var start_flag = Atomic(u8).init(0);
    var errors = Atomic(usize).init(0);
    const handles = try testing.allocator.alloc(Thread, num_producers + num_consumers);
    defer testing.allocator.free(handles);
    const contexts = try testing.allocator.alloc(WorkerCtx, num_producers + num_consumers);
    defer testing.allocator.free(contexts);

    // Spawn producers
    var idx: usize = 0;
    while (idx < num_producers) : (idx += 1) {
        contexts[idx] = .{
            .queue = &queue,
            .shard_id = idx % num_shards,
            .iterations = items_per_producer,
            .start_flag = &start_flag,
            .is_producer = true,
            .errors = &errors,
        };
        handles[idx] = try Thread.spawn(.{}, WorkerCtx.run, .{&contexts[idx]});
    }

    // Spawn consumers
    while (idx < num_producers + num_consumers) : (idx += 1) {
        contexts[idx] = .{
            .queue = &queue,
            .shard_id = (idx - num_producers) % num_shards,
            .iterations = items_per_producer,
            .start_flag = &start_flag,
            .is_producer = false,
            .errors = &errors,
        };
        handles[idx] = try Thread.spawn(.{}, WorkerCtx.run, .{&contexts[idx]});
    }

    start_flag.store(1, .seq_cst);
    for (handles) |h| h.join();

    // Verify no errors and queue is empty
    try testing.expectEqual(@as(usize, 0), errors.load(.seq_cst));
    try testing.expectEqual(@as(usize, 0), queue.totalSize());
}

test "ShardedDVyukovMPMCQueue: 2P/2C with 2 shards" {
    const num_producers = 2;
    const num_consumers = 2;
    const num_shards = 2; // 1P+1C per shard
    const items_per_producer = 1_000; // Reduced for test performance

    var queue = try ShardedDVyukovMPMCQueue(usize, num_shards, 128).init(testing.allocator);
    defer queue.deinit();

    const WorkerCtx = struct {
        queue: *ShardedDVyukovMPMCQueue(usize, num_shards, 128),
        shard_id: usize,
        iterations: usize,
        start_flag: *Atomic(u8),
        is_producer: bool,

        fn run(ctx: *@This()) void {
            while (ctx.start_flag.load(.seq_cst) == 0) {
                Thread.yield() catch {};
            }

            if (ctx.is_producer) {
                var i: usize = 0;
                while (i < ctx.iterations) : (i += 1) {
                    while (true) {
                        ctx.queue.enqueueToShard(ctx.shard_id, i) catch {
                            Thread.yield() catch {};
                            continue;
                        };
                        break;
                    }
                }
            } else {
                var count: usize = 0;
                while (count < ctx.iterations) {
                    if (ctx.queue.dequeueFromShard(ctx.shard_id)) |_| {
                        count += 1;
                    } else {
                        Thread.yield() catch {};
                    }
                }
            }
        }
    };

    var start_flag = Atomic(u8).init(0);
    const handles = try testing.allocator.alloc(Thread, num_producers + num_consumers);
    defer testing.allocator.free(handles);
    const contexts = try testing.allocator.alloc(WorkerCtx, num_producers + num_consumers);
    defer testing.allocator.free(contexts);

    var idx: usize = 0;
    while (idx < num_producers) : (idx += 1) {
        contexts[idx] = .{
            .queue = &queue,
            .shard_id = idx % num_shards,
            .iterations = items_per_producer,
            .start_flag = &start_flag,
            .is_producer = true,
        };
        handles[idx] = try Thread.spawn(.{}, WorkerCtx.run, .{&contexts[idx]});
    }

    while (idx < num_producers + num_consumers) : (idx += 1) {
        contexts[idx] = .{
            .queue = &queue,
            .shard_id = (idx - num_producers) % num_shards,
            .iterations = items_per_producer,
            .start_flag = &start_flag,
            .is_producer = false,
        };
        handles[idx] = try Thread.spawn(.{}, WorkerCtx.run, .{&contexts[idx]});
    }

    start_flag.store(1, .seq_cst);
    for (handles) |h| h.join();

    // All items should be consumed
    try testing.expectEqual(@as(usize, 0), queue.totalSize());
}

test "ShardedDVyukovMPMCQueue: imbalanced load (8P/8C, 4 shards)" {
    const num_producers = 8;
    const num_consumers = 8;
    const num_shards = 4; // 2P+2C per shard
    const items_per_producer = 1_000; // Reduced for test performance

    var queue = try ShardedDVyukovMPMCQueue(u64, num_shards, 256).init(testing.allocator);
    defer queue.deinit();

    const WorkerCtx = struct {
        queue: *ShardedDVyukovMPMCQueue(u64, num_shards, 256),
        shard_id: usize,
        iterations: usize,
        start_flag: *Atomic(u8),
        is_producer: bool,

        fn run(ctx: *@This()) void {
            while (ctx.start_flag.load(.seq_cst) == 0) {
                Thread.yield() catch {};
            }

            if (ctx.is_producer) {
                var i: u64 = 0;
                while (i < ctx.iterations) : (i += 1) {
                    while (true) {
                        ctx.queue.enqueueToShard(ctx.shard_id, i) catch {
                            Thread.yield() catch {};
                            continue;
                        };
                        break;
                    }
                }
            } else {
                var count: u64 = 0;
                while (count < ctx.iterations) {
                    if (ctx.queue.dequeueFromShard(ctx.shard_id)) |_| {
                        count += 1;
                    } else {
                        Thread.yield() catch {};
                    }
                }
            }
        }
    };

    var start_flag = Atomic(u8).init(0);
    const handles = try testing.allocator.alloc(Thread, num_producers + num_consumers);
    defer testing.allocator.free(handles);
    const contexts = try testing.allocator.alloc(WorkerCtx, num_producers + num_consumers);
    defer testing.allocator.free(contexts);

    var idx: usize = 0;
    while (idx < num_producers) : (idx += 1) {
        contexts[idx] = .{
            .queue = &queue,
            .shard_id = idx % num_shards,
            .iterations = items_per_producer,
            .start_flag = &start_flag,
            .is_producer = true,
        };
        handles[idx] = try Thread.spawn(.{}, WorkerCtx.run, .{&contexts[idx]});
    }

    while (idx < num_producers + num_consumers) : (idx += 1) {
        contexts[idx] = .{
            .queue = &queue,
            .shard_id = (idx - num_producers) % num_shards,
            .iterations = items_per_producer,
            .start_flag = &start_flag,
            .is_producer = false,
        };
        handles[idx] = try Thread.spawn(.{}, WorkerCtx.run, .{&contexts[idx]});
    }

    start_flag.store(1, .seq_cst);
    for (handles) |h| h.join();

    try testing.expectEqual(@as(usize, 0), queue.totalSize());
}

test "ShardedDVyukovMPMCQueue: stress test with many small operations" {
    const num_threads = 8;
    const num_shards = 8;
    const operations_per_thread = 100; // Reduced to avoid pathological contention

    var queue = try ShardedDVyukovMPMCQueue(usize, num_shards, 256).init(testing.allocator);
    defer queue.deinit();

    const WorkerCtx = struct {
        queue: *ShardedDVyukovMPMCQueue(usize, num_shards, 256),
        thread_id: usize,
        start_flag: *Atomic(u8),

        fn run(ctx: *@This()) void {
            while (ctx.start_flag.load(.seq_cst) == 0) {
                Thread.yield() catch {};
            }

            const my_shard = ctx.thread_id % num_shards;

            // Mix of enqueue and dequeue operations
            var i: usize = 0;
            while (i < operations_per_thread) : (i += 1) {
                // Enqueue
                while (true) {
                    ctx.queue.enqueueToShard(my_shard, i) catch {
                        Thread.yield() catch {};
                        continue;
                    };
                    break;
                }

                // Immediately dequeue
                if (i % 2 == 0) {
                    _ = ctx.queue.dequeueFromShard(my_shard);
                }
            }
        }
    };

    var start_flag = Atomic(u8).init(0);
    const handles = try testing.allocator.alloc(Thread, num_threads);
    defer testing.allocator.free(handles);
    const contexts = try testing.allocator.alloc(WorkerCtx, num_threads);
    defer testing.allocator.free(contexts);

    var idx: usize = 0;
    while (idx < num_threads) : (idx += 1) {
        contexts[idx] = .{
            .queue = &queue,
            .thread_id = idx,
            .start_flag = &start_flag,
        };
        handles[idx] = try Thread.spawn(.{}, WorkerCtx.run, .{&contexts[idx]});
    }

    start_flag.store(1, .seq_cst);
    for (handles) |h| h.join();

    // Queue should have approximately half the items (those not dequeued)
    const approx_remaining = queue.totalSize();
    const expected_approx = (num_threads * operations_per_thread) / 2;

    // Allow 10% variance due to timing
    const lower_bound = expected_approx - (expected_approx / 10);
    const upper_bound = expected_approx + (expected_approx / 10);

    try testing.expect(approx_remaining >= lower_bound);
    try testing.expect(approx_remaining <= upper_bound);
}

test "ShardedDVyukovMPMCQueue: correctness of data values" {
    const num_producers = 4;
    const num_shards = 4;
    const items_per_producer = 100; // Reduced to avoid excessive yields when queue fills

    var queue = try ShardedDVyukovMPMCQueue(u64, num_shards, 256).init(testing.allocator);
    defer queue.deinit();

    const ProducerCtx = struct {
        queue: *ShardedDVyukovMPMCQueue(u64, num_shards, 256),
        shard_id: usize,
        start_value: u64,
        count: usize,
        start_flag: *Atomic(u8),

        fn run(ctx: *@This()) void {
            while (ctx.start_flag.load(.seq_cst) == 0) {
                Thread.yield() catch {};
            }

            var i: u64 = 0;
            while (i < ctx.count) : (i += 1) {
                const value = ctx.start_value + i;
                while (true) {
                    ctx.queue.enqueueToShard(ctx.shard_id, value) catch {
                        Thread.yield() catch {};
                        continue;
                    };
                    break;
                }
            }
        }
    };

    var start_flag = Atomic(u8).init(0);
    const handles = try testing.allocator.alloc(Thread, num_producers);
    defer testing.allocator.free(handles);
    const contexts = try testing.allocator.alloc(ProducerCtx, num_producers);
    defer testing.allocator.free(contexts);

    // Each producer writes to its own shard with unique values
    var idx: usize = 0;
    while (idx < num_producers) : (idx += 1) {
        contexts[idx] = .{
            .queue = &queue,
            .shard_id = idx,
            .start_value = @as(u64, @intCast(idx)) * 1_000_000,
            .count = items_per_producer,
            .start_flag = &start_flag,
        };
        handles[idx] = try Thread.spawn(.{}, ProducerCtx.run, .{&contexts[idx]});
    }

    start_flag.store(1, .seq_cst);
    for (handles) |h| h.join();

    // Verify total count
    try testing.expectEqual(@as(usize, num_producers * items_per_producer), queue.totalSize());

    // Verify each shard has correct count
    idx = 0;
    while (idx < num_shards) : (idx += 1) {
        try testing.expectEqual(@as(usize, items_per_producer), queue.shardSize(idx));
    }

    // Verify FIFO ordering within each shard
    idx = 0;
    while (idx < num_shards) : (idx += 1) {
        const start_value = @as(u64, @intCast(idx)) * 1_000_000;
        var i: u64 = 0;
        while (i < items_per_producer) : (i += 1) {
            const expected = start_value + i;
            const actual = queue.dequeueFromShard(idx);
            try testing.expectEqual(@as(?u64, expected), actual);
        }
    }

    // All shards should now be empty
    try testing.expectEqual(@as(usize, 0), queue.totalSize());
}
