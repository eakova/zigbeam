const std = @import("std");
const testing = std.testing;
const DVyukovMPMCQueue = @import("dvyukov_mpmc_queue.zig").DVyukovMPMCQueue;

// =============================================================================
// Integration Tests - Multi-threaded correctness and stress testing
// =============================================================================

test "MPMC - 2 producers 2 consumers" {
    var queue = try DVyukovMPMCQueue(usize, 256).init(testing.allocator);
    defer queue.deinit();

    const num_items = 1000;
    const num_producers = 2;
    const num_consumers = 2;

    var produced = std.atomic.Value(usize).init(0);
    var consumed = std.atomic.Value(usize).init(0);

    const ProducerCtx = struct {
        queue: *DVyukovMPMCQueue(usize, 256),
        id: usize,
        count: *std.atomic.Value(usize),
    };

    const ConsumerCtx = struct {
        queue: *DVyukovMPMCQueue(usize, 256),
        count: *std.atomic.Value(usize),
        expected: usize,
    };

    const producer = struct {
        fn run(ctx: ProducerCtx) void {
            var i: usize = 0;
            while (i < num_items) : (i += 1) {
                const value = ctx.id * 10000 + i;
                while (true) {
                    ctx.queue.enqueue(value) catch {
                        std.Thread.yield() catch {};
                        continue;
                    };
                    break;
                }
                _ = ctx.count.fetchAdd(1, .monotonic);
            }
        }
    }.run;

    const consumer = struct {
        fn run(ctx: ConsumerCtx) void {
            var local: usize = 0;
            while (local < ctx.expected) {
                if (ctx.queue.dequeue()) |_| {
                    local += 1;
                    _ = ctx.count.fetchAdd(1, .monotonic);
                } else {
                    std.Thread.yield() catch {};
                }
            }
        }
    }.run;

    // Spawn threads
    var producers: [num_producers]std.Thread = undefined;
    for (&producers, 0..) |*t, id| {
        t.* = try std.Thread.spawn(.{}, producer, .{ProducerCtx{
            .queue = &queue,
            .id = id,
            .count = &produced,
        }});
    }

    var consumers: [num_consumers]std.Thread = undefined;
    for (&consumers) |*t| {
        t.* = try std.Thread.spawn(.{}, consumer, .{ConsumerCtx{
            .queue = &queue,
            .count = &consumed,
            .expected = num_items,
        }});
    }

    // Join all
    for (producers) |t| t.join();
    for (consumers) |t| t.join();

    try testing.expectEqual(num_producers * num_items, produced.load(.monotonic));
    try testing.expectEqual(num_producers * num_items, consumed.load(.monotonic));
    try testing.expect(queue.isEmpty());
}

test "high contention - many producers many consumers" {
    var queue = try DVyukovMPMCQueue(usize, 512).init(testing.allocator);
    defer queue.deinit();

    const num_items_per_thread = 500;
    const num_producers = 4;
    const num_consumers = 4;

    var produced = std.atomic.Value(usize).init(0);
    var consumed = std.atomic.Value(usize).init(0);

    const Ctx = struct {
        queue: *DVyukovMPMCQueue(usize, 512),
        count: *std.atomic.Value(usize),
    };

    const producer = struct {
        fn run(ctx: Ctx) void {
            var i: usize = 0;
            while (i < num_items_per_thread) : (i += 1) {
                while (true) {
                    ctx.queue.enqueue(i) catch {
                        std.atomic.spinLoopHint();
                        continue;
                    };
                    break;
                }
                _ = ctx.count.fetchAdd(1, .monotonic);
            }
        }
    }.run;

    const consumer = struct {
        fn run(ctx: Ctx) void {
            var local: usize = 0;
            while (local < num_items_per_thread) {
                if (ctx.queue.dequeue()) |_| {
                    local += 1;
                    _ = ctx.count.fetchAdd(1, .monotonic);
                } else {
                    std.atomic.spinLoopHint();
                }
            }
        }
    }.run;

    var producers: [num_producers]std.Thread = undefined;
    for (&producers) |*t| {
        t.* = try std.Thread.spawn(.{}, producer, .{Ctx{
            .queue = &queue,
            .count = &produced,
        }});
    }

    var consumers: [num_consumers]std.Thread = undefined;
    for (&consumers) |*t| {
        t.* = try std.Thread.spawn(.{}, consumer, .{Ctx{
            .queue = &queue,
            .count = &consumed,
        }});
    }

    for (producers) |t| t.join();
    for (consumers) |t| t.join();

    const expected = num_producers * num_items_per_thread;
    try testing.expectEqual(expected, produced.load(.monotonic));
    try testing.expectEqual(expected, consumed.load(.monotonic));
}

test "correctness - all items consumed exactly once" {
    var queue = try DVyukovMPMCQueue(usize, 128).init(testing.allocator);
    defer queue.deinit();

    const total_items = 5000;
    const seen = try testing.allocator.alloc(std.atomic.Value(u8), total_items);
    defer testing.allocator.free(seen);

    for (seen) |*s| {
        s.* = std.atomic.Value(u8).init(0);
    }

    const ProducerCtx = struct {
        queue: *DVyukovMPMCQueue(usize, 128),
        start: usize,
        count: usize,
    };

    const ConsumerCtx = struct {
        queue: *DVyukovMPMCQueue(usize, 128),
        seen: []std.atomic.Value(u8),
        total: usize,
    };

    const producer = struct {
        fn run(ctx: ProducerCtx) void {
            var i: usize = 0;
            while (i < ctx.count) : (i += 1) {
                const value = ctx.start + i;
                while (true) {
                    ctx.queue.enqueue(value) catch {
                        std.Thread.yield() catch {};
                        continue;
                    };
                    break;
                }
            }
        }
    }.run;

    const consumer = struct {
        fn run(ctx: ConsumerCtx) void {
            var count: usize = 0;
            while (count < ctx.total) {
                if (ctx.queue.dequeue()) |value| {
                    _ = ctx.seen[value].fetchAdd(1, .monotonic);
                    count += 1;
                } else {
                    std.Thread.yield() catch {};
                }
            }
        }
    }.run;

    // 2 producers split the work
    const items_per_producer = total_items / 2;
    var p1 = try std.Thread.spawn(.{}, producer, .{ProducerCtx{
        .queue = &queue,
        .start = 0,
        .count = items_per_producer,
    }});
    var p2 = try std.Thread.spawn(.{}, producer, .{ProducerCtx{
        .queue = &queue,
        .start = items_per_producer,
        .count = items_per_producer,
    }});

    // 3 consumers
    var c1 = try std.Thread.spawn(.{}, consumer, .{ConsumerCtx{
        .queue = &queue,
        .seen = seen,
        .total = 1666,
    }});
    var c2 = try std.Thread.spawn(.{}, consumer, .{ConsumerCtx{
        .queue = &queue,
        .seen = seen,
        .total = 1667,
    }});
    var c3 = try std.Thread.spawn(.{}, consumer, .{ConsumerCtx{
        .queue = &queue,
        .seen = seen,
        .total = 1667,
    }});

    p1.join();
    p2.join();
    c1.join();
    c2.join();
    c3.join();

    // Verify each item was consumed exactly once
    for (seen, 0..) |*s, idx| {
        const count = s.load(.monotonic);
        if (count != 1) {
            std.debug.print("Item {} consumed {} times\n", .{ idx, count });
        }
        try testing.expectEqual(@as(u8, 1), count);
    }
}

test "stress test - sustained load" {
    var queue = try DVyukovMPMCQueue(u64, 256).init(testing.allocator);
    defer queue.deinit();

    const duration_ms = 1000; // 1 second
    var stop = std.atomic.Value(bool).init(false);
    var ops_count = std.atomic.Value(usize).init(0);

    const Ctx = struct {
        queue: *DVyukovMPMCQueue(u64, 256),
        stop: *std.atomic.Value(bool),
        ops: *std.atomic.Value(usize),
    };

    const producer = struct {
        fn run(ctx: Ctx) void {
            var value: u64 = 0;
            while (!ctx.stop.load(.monotonic)) {
                ctx.queue.enqueue(value) catch {
                    std.atomic.spinLoopHint();
                    continue;
                };
                value +%= 1;
                _ = ctx.ops.fetchAdd(1, .monotonic);
            }
        }
    }.run;

    const consumer = struct {
        fn run(ctx: Ctx) void {
            while (!ctx.stop.load(.monotonic)) {
                if (ctx.queue.dequeue()) |_| {
                    _ = ctx.ops.fetchAdd(1, .monotonic);
                } else {
                    std.atomic.spinLoopHint();
                }
            }
        }
    }.run;

    // Spawn workers
    var p1 = try std.Thread.spawn(.{}, producer, .{Ctx{
        .queue = &queue,
        .stop = &stop,
        .ops = &ops_count,
    }});
    var p2 = try std.Thread.spawn(.{}, producer, .{Ctx{
        .queue = &queue,
        .stop = &stop,
        .ops = &ops_count,
    }});
    var c1 = try std.Thread.spawn(.{}, consumer, .{Ctx{
        .queue = &queue,
        .stop = &stop,
        .ops = &ops_count,
    }});
    var c2 = try std.Thread.spawn(.{}, consumer, .{Ctx{
        .queue = &queue,
        .stop = &stop,
        .ops = &ops_count,
    }});

    // Run for duration
    std.Thread.sleep(duration_ms * std.time.ns_per_ms);
    stop.store(true, .release);

    p1.join();
    p2.join();
    c1.join();
    c2.join();

    const total_ops = ops_count.load(.monotonic);
    const ops_per_sec = @as(f64, @floatFromInt(total_ops)) / (@as(f64, @floatFromInt(duration_ms)) / 1000.0);
    std.debug.print("Stress test: {} ops in {}ms = {d:.2} ops/sec\n", .{
        total_ops,
        duration_ms,
        ops_per_sec,
    });

    // Verify we got significant throughput
    // Conservative threshold: expect at least 10K ops/sec (works on slow/busy systems)
    const min_ops_per_sec = 10_000;
    const min_ops = (min_ops_per_sec * duration_ms) / 1000;
    try testing.expect(total_ops > min_ops); // Much more conservative than 100K
}

test "overflow wraparound safety" {
    var queue = try DVyukovMPMCQueue(u32, 64).init(testing.allocator);
    defer queue.deinit();

    // Simulate many cycles to test wraparound
    const cycles = 1000;
    var cycle: usize = 0;
    while (cycle < cycles) : (cycle += 1) {
        // Fill
        var i: u32 = 0;
        while (i < 32) : (i += 1) {
            try queue.enqueue(@intCast(cycle * 100 + i));
        }

        // Drain
        i = 0;
        while (i < 32) : (i += 1) {
            const val = queue.dequeue().?;
            try testing.expectEqual(@as(u32, @intCast(cycle * 100 + i)), val);
        }
    }

    try testing.expect(queue.isEmpty());
}

test "SPSC - single producer single consumer" {
    var queue = try DVyukovMPMCQueue(u64, 512).init(testing.allocator);
    defer queue.deinit();

    const num_items = 10000;

    const Ctx = struct {
        queue: *DVyukovMPMCQueue(u64, 512),
        count: usize,
    };

    const producer = struct {
        fn run(ctx: Ctx) void {
            var i: u64 = 0;
            while (i < ctx.count) : (i += 1) {
                while (true) {
                    ctx.queue.enqueue(i) catch {
                        std.Thread.yield() catch {};
                        continue;
                    };
                    break;
                }
            }
        }
    }.run;

    const consumer = struct {
        fn run(ctx: Ctx) void {
            var expected: u64 = 0;
            while (expected < ctx.count) {
                if (ctx.queue.dequeue()) |val| {
                    std.debug.assert(val == expected);
                    expected += 1;
                } else {
                    std.Thread.yield() catch {};
                }
            }
        }
    }.run;

    var p = try std.Thread.spawn(.{}, producer, .{Ctx{
        .queue = &queue,
        .count = num_items,
    }});
    var c = try std.Thread.spawn(.{}, consumer, .{Ctx{
        .queue = &queue,
        .count = num_items,
    }});

    p.join();
    c.join();

    try testing.expect(queue.isEmpty());
}

test "producer heavy - 4P/1C" {
    var queue = try DVyukovMPMCQueue(usize, 1024).init(testing.allocator);
    defer queue.deinit();

    const items_per_producer = 500;
    const num_producers = 4;
    var produced = std.atomic.Value(usize).init(0);
    var consumed = std.atomic.Value(usize).init(0);

    const ProducerCtx = struct {
        queue: *DVyukovMPMCQueue(usize, 1024),
        count: *std.atomic.Value(usize),
        items: usize,
    };

    const ConsumerCtx = struct {
        queue: *DVyukovMPMCQueue(usize, 1024),
        count: *std.atomic.Value(usize),
        target: usize,
    };

    const producer = struct {
        fn run(ctx: ProducerCtx) void {
            var i: usize = 0;
            while (i < ctx.items) : (i += 1) {
                while (true) {
                    ctx.queue.enqueue(i) catch {
                        std.atomic.spinLoopHint();
                        continue;
                    };
                    break;
                }
                _ = ctx.count.fetchAdd(1, .monotonic);
            }
        }
    }.run;

    const consumer = struct {
        fn run(ctx: ConsumerCtx) void {
            var local: usize = 0;
            while (local < ctx.target) {
                if (ctx.queue.dequeue()) |_| {
                    local += 1;
                    _ = ctx.count.fetchAdd(1, .monotonic);
                } else {
                    std.atomic.spinLoopHint();
                }
            }
        }
    }.run;

    var producers: [num_producers]std.Thread = undefined;
    for (&producers) |*t| {
        t.* = try std.Thread.spawn(.{}, producer, .{ProducerCtx{
            .queue = &queue,
            .count = &produced,
            .items = items_per_producer,
        }});
    }

    var c = try std.Thread.spawn(.{}, consumer, .{ConsumerCtx{
        .queue = &queue,
        .count = &consumed,
        .target = num_producers * items_per_producer,
    }});

    for (producers) |t| t.join();
    c.join();

    const expected = num_producers * items_per_producer;
    try testing.expectEqual(expected, produced.load(.monotonic));
    try testing.expectEqual(expected, consumed.load(.monotonic));
}

test "consumer heavy - 1P/4C" {
    var queue = try DVyukovMPMCQueue(usize, 1024).init(testing.allocator);
    defer queue.deinit();

    const total_items = 2000;
    const num_consumers = 4;
    const items_per_consumer = total_items / num_consumers;

    var produced = std.atomic.Value(usize).init(0);
    var consumed = std.atomic.Value(usize).init(0);

    const ProducerCtx = struct {
        queue: *DVyukovMPMCQueue(usize, 1024),
        count: *std.atomic.Value(usize),
        items: usize,
    };

    const ConsumerCtx = struct {
        queue: *DVyukovMPMCQueue(usize, 1024),
        count: *std.atomic.Value(usize),
        items: usize,
    };

    const producer = struct {
        fn run(ctx: ProducerCtx) void {
            var i: usize = 0;
            while (i < ctx.items) : (i += 1) {
                while (true) {
                    ctx.queue.enqueue(i) catch {
                        std.Thread.yield() catch {};
                        continue;
                    };
                    break;
                }
                _ = ctx.count.fetchAdd(1, .monotonic);
            }
        }
    }.run;

    const consumer = struct {
        fn run(ctx: ConsumerCtx) void {
            var local: usize = 0;
            while (local < ctx.items) {
                if (ctx.queue.dequeue()) |_| {
                    local += 1;
                    _ = ctx.count.fetchAdd(1, .monotonic);
                } else {
                    std.Thread.yield() catch {};
                }
            }
        }
    }.run;

    var p = try std.Thread.spawn(.{}, producer, .{ProducerCtx{
        .queue = &queue,
        .count = &produced,
        .items = total_items,
    }});

    var consumers: [num_consumers]std.Thread = undefined;
    for (&consumers) |*t| {
        t.* = try std.Thread.spawn(.{}, consumer, .{ConsumerCtx{
            .queue = &queue,
            .count = &consumed,
            .items = items_per_consumer,
        }});
    }

    p.join();
    for (consumers) |t| t.join();

    try testing.expectEqual(total_items, produced.load(.monotonic));
    try testing.expectEqual(total_items, consumed.load(.monotonic));
}

test "tryEnqueue under contention" {
    var queue = try DVyukovMPMCQueue(usize, 64).init(testing.allocator);
    defer queue.deinit();

    var successful = std.atomic.Value(usize).init(0);
    var failed = std.atomic.Value(usize).init(0);

    const Ctx = struct {
        queue: *DVyukovMPMCQueue(usize, 64),
        success: *std.atomic.Value(usize),
        fail: *std.atomic.Value(usize),
    };

    const worker = struct {
        fn run(ctx: Ctx) void {
            var i: usize = 0;
            while (i < 1000) : (i += 1) {
                ctx.queue.tryEnqueue(i, 10) catch {
                    _ = ctx.fail.fetchAdd(1, .monotonic);
                    continue;
                };
                _ = ctx.success.fetchAdd(1, .monotonic);
            }
        }
    }.run;

    var threads: [8]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, worker, .{Ctx{
            .queue = &queue,
            .success = &successful,
            .fail = &failed,
        }});
    }

    for (threads) |t| t.join();

    const total_attempts = 8 * 1000;
    const success_count = successful.load(.monotonic);
    const fail_count = failed.load(.monotonic);

    try testing.expectEqual(total_attempts, success_count + fail_count);
    std.debug.print("tryEnqueue contention: {} successful, {} failed\n", .{
        success_count,
        fail_count,
    });
}

test "small queue high contention" {
    // Very small queue (capacity=8) with many threads (separate producers/consumers)
    // This is a realistic test - not the pathological lockstep enqueue-dequeue pattern
    var queue = try DVyukovMPMCQueue(usize, 8).init(testing.allocator);
    defer queue.deinit();

    const num_producers = 8;
    const num_consumers = 8;
    const items_per_producer = 100;

    var produced = std.atomic.Value(usize).init(0);
    var consumed = std.atomic.Value(usize).init(0);

    const ProducerCtx = struct {
        queue: *DVyukovMPMCQueue(usize, 8),
        count: *std.atomic.Value(usize),
        id: usize,
    };

    const ConsumerCtx = struct {
        queue: *DVyukovMPMCQueue(usize, 8),
        count: *std.atomic.Value(usize),
        expected: usize,
    };

    const producer = struct {
        fn run(ctx: ProducerCtx) void {
            var i: usize = 0;
            while (i < items_per_producer) : (i += 1) {
                const value = ctx.id * 10000 + i;
                while (true) {
                    ctx.queue.enqueue(value) catch {
                        std.Thread.yield() catch {};
                        continue;
                    };
                    break;
                }
                _ = ctx.count.fetchAdd(1, .monotonic);
            }
        }
    }.run;

    const consumer = struct {
        fn run(ctx: ConsumerCtx) void {
            var local: usize = 0;
            while (local < ctx.expected) {
                if (ctx.queue.dequeue()) |_| {
                    local += 1;
                    _ = ctx.count.fetchAdd(1, .monotonic);
                } else {
                    std.Thread.yield() catch {};
                }
            }
        }
    }.run;

    // Spawn producers
    var producers: [num_producers]std.Thread = undefined;
    for (&producers, 0..) |*t, id| {
        t.* = try std.Thread.spawn(.{}, producer, .{ProducerCtx{
            .queue = &queue,
            .count = &produced,
            .id = id,
        }});
    }

    // Spawn consumers
    var consumers: [num_consumers]std.Thread = undefined;
    for (&consumers) |*t| {
        t.* = try std.Thread.spawn(.{}, consumer, .{ConsumerCtx{
            .queue = &queue,
            .count = &consumed,
            .expected = items_per_producer,
        }});
    }

    // Join all
    for (producers) |t| t.join();
    for (consumers) |t| t.join();

    const expected = num_producers * items_per_producer;
    try testing.expectEqual(expected, produced.load(.monotonic));
    try testing.expectEqual(expected, consumed.load(.monotonic));
    try testing.expect(queue.isEmpty());
}

test "max capacity queue" {
    // Test with very large capacity
    const cap = 8192;
    var queue = try DVyukovMPMCQueue(u64, cap).init(testing.allocator);
    defer queue.deinit();

    const num_producers = 4;
    const num_consumers = 4;
    const items_per_thread = 2000;

    var produced = std.atomic.Value(usize).init(0);
    var consumed = std.atomic.Value(usize).init(0);

    const ProducerCtx = struct {
        queue: *DVyukovMPMCQueue(u64, cap),
        count: *std.atomic.Value(usize),
        id: usize,
    };

    const ConsumerCtx = struct {
        queue: *DVyukovMPMCQueue(u64, cap),
        count: *std.atomic.Value(usize),
        items: usize,
    };

    const producer = struct {
        fn run(ctx: ProducerCtx) void {
            var i: usize = 0;
            while (i < items_per_thread) : (i += 1) {
                const value = @as(u64, ctx.id) * 10000 + i;
                ctx.queue.enqueue(value) catch |err| {
                    std.debug.panic("Integration test enqueue failed: {}", .{err});
                };
                _ = ctx.count.fetchAdd(1, .monotonic);
            }
        }
    }.run;

    const consumer = struct {
        fn run(ctx: ConsumerCtx) void {
            var local: usize = 0;
            while (local < ctx.items) {
                if (ctx.queue.dequeue()) |_| {
                    local += 1;
                    _ = ctx.count.fetchAdd(1, .monotonic);
                } else {
                    std.Thread.yield() catch {};
                }
            }
        }
    }.run;

    var producers: [num_producers]std.Thread = undefined;
    for (&producers, 0..) |*t, id| {
        t.* = try std.Thread.spawn(.{}, producer, .{ProducerCtx{
            .queue = &queue,
            .count = &produced,
            .id = id,
        }});
    }

    var consumers: [num_consumers]std.Thread = undefined;
    for (&consumers) |*t| {
        t.* = try std.Thread.spawn(.{}, consumer, .{ConsumerCtx{
            .queue = &queue,
            .count = &consumed,
            .items = items_per_thread,
        }});
    }

    for (producers) |t| t.join();
    for (consumers) |t| t.join();

    const expected = num_producers * items_per_thread;
    try testing.expectEqual(expected, produced.load(.monotonic));
    try testing.expectEqual(expected, consumed.load(.monotonic));
}
