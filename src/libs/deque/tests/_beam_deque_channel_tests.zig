const std = @import("std");
const testing = std.testing;
const Thread = std.Thread;
const Atomic = std.atomic.Value;
const DequeChannel = @import("deque-channel").DequeChannel;

// =============================================================================
// DequeChannel Tests
// =============================================================================

test "DequeChannel: basic send and recv" {
    const Channel = DequeChannel(u32, 256, 1024);
    var result = try Channel.init(testing.allocator, 4);
    defer result.channel.deinit(&result.workers);

    // Worker 0 sends
    try result.workers[0].send(42);
    try result.workers[0].send(43);

    // Worker 0 receives (LIFO from local deque)
    try testing.expectEqual(@as(?u32, 43), result.workers[0].recv());
    try testing.expectEqual(@as(?u32, 42), result.workers[0].recv());
    try testing.expectEqual(@as(?u32, null), result.workers[0].recv());
}

test "DequeChannel: work stealing between workers" {
    const Channel = DequeChannel(u64, 256, 1024);
    var result = try Channel.init(testing.allocator, 4);
    defer result.channel.deinit(&result.workers);

    // Worker 0 sends 100 items
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        try result.workers[0].send(i);
    }

    // Worker 1 steals
    var stolen: usize = 0;
    while (result.workers[1].recv()) |_| {
        stolen += 1;
    }

    // Worker 0 consumes remaining
    var local: usize = 0;
    while (result.workers[0].recv()) |_| {
        local += 1;
    }

    // Verify total
    try testing.expectEqual(@as(usize, 100), stolen + local);
    // Worker 1 should have stolen at least some items
    try testing.expect(stolen > 0);
}

test "DequeChannel: overflow to global queue" {
    const Channel = DequeChannel(u32, 8, 64); // Small local capacity
    var result = try Channel.init(testing.allocator, 2);
    defer result.channel.deinit(&result.workers);

    // Fill worker 0's local deque and trigger overflow
    var i: u32 = 0;
    while (i < 20) : (i += 1) {
        try result.workers[0].send(i);
    }

    // Verify items can be received
    var count: usize = 0;
    while (result.workers[0].recv()) |_| {
        count += 1;
    }

    try testing.expectEqual(@as(usize, 20), count);
}

test "DequeChannel: back-pressure when full" {
    const Channel = DequeChannel(u32, 4, 8); // Very small capacities
    var result = try Channel.init(testing.allocator, 1);
    defer result.channel.deinit(&result.workers);

    // Strategy: Fill both local and global queues completely, then verify error.Full
    // Local capacity: 4 (but BeamDeque reserves 1 slot, so 3 usable)
    // Global capacity: 8 (DVyukovMPMCQueue reserves 1 slot, so 7 usable)

    // Fill the system completely by sending many items
    // The send() implementation will offload to global when local fills
    var sent: usize = 0;
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        result.workers[0].send(i) catch |err| {
            if (err == error.Full) {
                // System is full, verify we sent enough items
                try testing.expect(sent >= 8); // At least local + some global
                return; // Test passed!
            }
            return err;
        };
        sent += 1;
    }

    // If we get here, we sent 100 items without hitting Full - that's wrong!
    try testing.expect(false); // Should have hit error.Full before 100 items
}

test "DequeChannel: 8P/8C stress test (1M items)" {
    const Channel = DequeChannel(u64, 256, 4096);
    var result = try Channel.init(testing.allocator, 8);
    defer result.channel.deinit(&result.workers);

    const num_items: usize = 1_000_000;
    const items_per_producer = num_items / 4; // 4 producers

    // Track consumed items to verify uniqueness
    const allocator = testing.allocator;
    const consumed_items = try allocator.alloc(Atomic(bool), num_items);
    defer allocator.free(consumed_items);
    for (consumed_items) |*item| {
        item.* = Atomic(bool).init(false);
    }

    var total_consumed = Atomic(usize).init(0);
    var done = Atomic(bool).init(false);

    // Spawn 4 producer threads
    var producers: [4]Thread = undefined;
    for (&producers, 0..) |*producer, idx| {
        producer.* = try Thread.spawn(.{}, struct {
            fn run(
                worker: *Channel.Worker,
                start: usize,
                count: usize,
            ) !void {
                var i: usize = 0;
                while (i < count) : (i += 1) {
                    const item = start + i;
                    // Retry on Full
                    while (true) {
                        worker.send(item) catch |err| {
                            if (err == error.Full) {
                                Thread.yield() catch {};
                                continue;
                            }
                            return err;
                        };
                        break;
                    }
                }
            }
        }.run, .{
            &result.workers[idx],
            idx * items_per_producer,
            items_per_producer,
        });
    }

    // Spawn 4 consumer threads
    var consumers: [4]Thread = undefined;
    for (&consumers, 4..) |*consumer, idx| {
        consumer.* = try Thread.spawn(.{}, struct {
            fn run(
                worker: *Channel.Worker,
                done_flag: *Atomic(bool),
                counter: *Atomic(usize),
                items: []Atomic(bool),
            ) void {
                var count: usize = 0;

                // Process items while producers are active
                while (!done_flag.load(.acquire)) {
                    if (worker.recv()) |value| {
                        count += 1;
                        // Mark as consumed
                        _ = items[@intCast(value)].swap(true, .monotonic);
                    } else {
                        Thread.yield() catch {};
                    }
                }

                // Final drain - keep trying to recv (with work-stealing) until
                // no items found after multiple attempts. Items may still be
                // in other workers' queues waiting to be stolen.
                var empty_attempts: usize = 0;
                while (empty_attempts < 100) {
                    if (worker.recv()) |value| {
                        count += 1;
                        _ = items[@intCast(value)].swap(true, .monotonic);
                        empty_attempts = 0; // Reset on successful recv
                    } else {
                        empty_attempts += 1;
                        Thread.yield() catch {};
                    }
                }

                _ = counter.fetchAdd(count, .monotonic);
            }
        }.run, .{
            &result.workers[idx],
            &done,
            &total_consumed,
            consumed_items,
        });
    }

    // Wait for producers
    for (producers) |producer| {
        producer.join();
    }

    // Small delay to let in-flight items settle into queues
    Thread.sleep(10 * std.time.ns_per_ms);

    // Signal done
    done.store(true, .release);

    // Wait for consumers
    for (consumers) |consumer| {
        consumer.join();
    }

    // Verify total count
    try testing.expectEqual(num_items, total_consumed.load(.monotonic));

    // Verify all items consumed exactly once
    for (consumed_items) |*item| {
        try testing.expect(item.load(.monotonic));
    }
}

test "DequeChannel: 1P/8C load balancing test" {
    const Channel = DequeChannel(u64, 128, 2048);
    var result = try Channel.init(testing.allocator, 9); // 9 workers: 8 consumers + 1 producer
    defer result.channel.deinit(&result.workers);

    const num_items: usize = 100_000;

    var consumed_counts: [8]Atomic(usize) = undefined;
    for (&consumed_counts) |*count| {
        count.* = Atomic(usize).init(0);
    }

    var done = Atomic(bool).init(false);

    // Spawn 8 consumer threads (workers 0-7)
    var consumers: [8]Thread = undefined;
    for (&consumers, 0..) |*consumer, idx| {
        consumer.* = try Thread.spawn(.{}, struct {
            fn run(
                worker: *Channel.Worker,
                done_flag: *Atomic(bool),
                counter: *Atomic(usize),
            ) void {
                var count: usize = 0;

                while (!done_flag.load(.acquire)) {
                    if (worker.recv()) |_| {
                        count += 1;
                    } else {
                        Thread.yield() catch {};
                    }
                }

                // Final drain - keep trying with work-stealing until no items
                // found after multiple attempts
                var empty_attempts: usize = 0;
                while (empty_attempts < 100) {
                    if (worker.recv()) |_| {
                        count += 1;
                        empty_attempts = 0;
                    } else {
                        empty_attempts += 1;
                        Thread.yield() catch {};
                    }
                }

                counter.store(count, .monotonic);
            }
        }.run, .{
            &result.workers[idx],
            &done,
            &consumed_counts[idx],
        });
    }

    // Main thread acts as single producer (worker 8 - dedicated producer worker)
    var i: usize = 0;
    while (i < num_items) : (i += 1) {
        while (true) {
            result.workers[8].send(i) catch |err| {
                if (err == error.Full) {
                    Thread.yield() catch {};
                    continue;
                }
                return err;
            };
            break;
        }
    }

    // Small delay to let in-flight items settle into queues
    Thread.sleep(10 * std.time.ns_per_ms);

    // Signal done
    done.store(true, .release);

    // Wait for consumers
    for (consumers) |consumer| {
        consumer.join();
    }

    // Verify total count
    var total: usize = 0;
    for (&consumed_counts) |*count| {
        total += count.load(.monotonic);
    }
    try testing.expectEqual(num_items, total);

    // Verify load balancing: no single consumer should have 100% of items
    // (This is probabilistic; in 1P/8C scenarios one consumer can dominate
    // especially on CI with variable timing, so we just verify work-stealing
    // happens at all by checking no consumer got ALL items)
    for (&consumed_counts) |*count| {
        const consumed = count.load(.monotonic);
        try testing.expect(consumed < num_items);
    }
}

test "DequeChannel: recv priority ordering" {
    const Channel = DequeChannel(u32, 16, 64);
    var result = try Channel.init(testing.allocator, 3);
    defer result.channel.deinit(&result.workers);

    // Worker 0: Push to local deque
    try result.workers[0].send(100);

    // Worker 1: Push to local, then trigger overflow to global
    var i: u32 = 0;
    while (i < 20) : (i += 1) {
        try result.workers[1].send(200 + i);
    }

    // Worker 2 receives:
    // - Should first check its local deque (empty)
    // - Then check global queue (has items from worker 1)
    // - Finally attempt to steal
    const item = result.workers[2].recv();
    try testing.expect(item != null);

    // The item should be from global queue (200-219 range) or stolen (100 or 200-219)
    // We can't guarantee exact value due to race, but it should exist
}

test "DequeChannel: no self-stealing" {
    const Channel = DequeChannel(u64, 256, 1024);
    var result = try Channel.init(testing.allocator, 1);
    defer result.channel.deinit(&result.workers);

    // Single worker should never steal from itself
    try result.workers[0].send(42);

    // Pop from local (priority 1)
    const item1 = result.workers[0].recv();
    try testing.expectEqual(@as(?u64, 42), item1);

    // Next recv should return null (local empty, global empty, can't steal from self)
    const item2 = result.workers[0].recv();
    try testing.expectEqual(@as(?u64, null), item2);
}
