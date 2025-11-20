//! Comprehensive test suite for BoundedSPSCQueue
//!
//! This file contains:
//! 1. Single-threaded correctness tests (FIFO order, full/empty conditions)
//! 2. Two-thread correctness tests (concurrent producer/consumer)
//! 3. Stress tests (high-throughput verification)

const std = @import("std");
const testing = std.testing;
const Thread = std.Thread;
const BoundedSPSCQueue = @import("spsc_queue.zig").BoundedSPSCQueue;

// ============================================================================
// Single-Threaded Correctness Tests
// ============================================================================

test "SPSC: single-threaded FIFO order" {
    const Queue = BoundedSPSCQueue(u64);
    var result = try Queue.init(testing.allocator, 16);
    defer result.producer.deinit();

    const N = 10;

    // Enqueue N items
    var i: u64 = 0;
    while (i < N) : (i += 1) {
        try result.producer.enqueue(i);
    }

    // Dequeue and verify FIFO order
    i = 0;
    while (i < N) : (i += 1) {
        const item = result.consumer.dequeue() orelse {
            std.debug.print("Expected item {}, got null\n", .{i});
            return error.TestUnexpectedResult;
        };
        try testing.expectEqual(i, item);
    }

    // Queue should be empty
    try testing.expectEqual(@as(?u64, null), result.consumer.dequeue());
}

test "SPSC: single-threaded full queue behavior" {
    const Queue = BoundedSPSCQueue(u64);
    const capacity = 8;
    var result = try Queue.init(testing.allocator, capacity);
    defer result.producer.deinit();

    // Fill the queue completely
    var i: u64 = 0;
    while (i < capacity) : (i += 1) {
        try result.producer.enqueue(i);
    }

    // Next enqueue should fail
    const err = result.producer.enqueue(999);
    try testing.expectError(error.Full, err);

    // Dequeue one item
    const item = result.consumer.dequeue().?;
    try testing.expectEqual(@as(u64, 0), item);

    // Now we should be able to enqueue again
    try result.producer.enqueue(capacity);

    // Verify remaining items are correct
    i = 1;
    while (i <= capacity) : (i += 1) {
        const dequeued = result.consumer.dequeue().?;
        try testing.expectEqual(i, dequeued);
    }

    try testing.expectEqual(@as(?u64, null), result.consumer.dequeue());
}

test "SPSC: single-threaded interleaved enqueue/dequeue" {
    const Queue = BoundedSPSCQueue(u64);
    var result = try Queue.init(testing.allocator, 2048);
    defer result.producer.deinit();

    var next_enqueue: u64 = 0;
    var next_dequeue: u64 = 0;
    const total_ops = 1000;

    var i: usize = 0;
    while (i < total_ops) : (i += 1) {
        // Enqueue a few
        var j: usize = 0;
        while (j < 3) : (j += 1) {
            try result.producer.enqueue(next_enqueue);
            next_enqueue += 1;
        }

        // Dequeue a few
        j = 0;
        while (j < 2) : (j += 1) {
            const item = result.consumer.dequeue().?;
            try testing.expectEqual(next_dequeue, item);
            next_dequeue += 1;
        }
    }

    // Drain remaining items
    while (result.consumer.dequeue()) |item| {
        try testing.expectEqual(next_dequeue, item);
        next_dequeue += 1;
    }

    try testing.expectEqual(next_enqueue, next_dequeue);
}

test "SPSC: single-threaded wrap-around" {
    const Queue = BoundedSPSCQueue(u64);
    const capacity = 4;
    var result = try Queue.init(testing.allocator, capacity);
    defer result.producer.deinit();

    // This test ensures the ring buffer wraps around correctly
    const iterations = 100;
    var i: u64 = 0;
    while (i < iterations) : (i += 1) {
        // Fill queue
        var j: u64 = 0;
        while (j < capacity) : (j += 1) {
            try result.producer.enqueue(i * capacity + j);
        }

        // Empty queue and verify order
        j = 0;
        while (j < capacity) : (j += 1) {
            const item = result.consumer.dequeue().?;
            try testing.expectEqual(i * capacity + j, item);
        }
    }
}

// ============================================================================
// Multi-Threaded Correctness Tests
// ============================================================================

test "SPSC: two-thread correctness - sequential items" {
    const Queue = BoundedSPSCQueue(u64);
    const capacity = 256;
    const N = 1_000_000;

    var result = try Queue.init(testing.allocator, capacity);
    defer result.producer.deinit();

    const TestContext = struct {
        producer: *Queue.Producer,
        consumer: *Queue.Consumer,
        count: u64,
        received: []u64,
        allocator: std.mem.Allocator,
    };

    const received = try testing.allocator.alloc(u64, N);
    defer testing.allocator.free(received);

    var ctx = TestContext{
        .producer = @constCast(&result.producer),
        .consumer = @constCast(&result.consumer),
        .count = N,
        .received = received,
        .allocator = testing.allocator,
    };

    const ProducerFn = struct {
        fn run(context: *TestContext) void {
            var i: u64 = 0;
            while (i < context.count) {
                context.producer.enqueue(i) catch {
                    // Queue full, spin and retry
                    std.atomic.spinLoopHint();
                    continue;
                };
                i += 1;
            }
        }
    };

    const ConsumerFn = struct {
        fn run(context: *TestContext) void {
            var i: usize = 0;
            while (i < context.count) {
                if (context.consumer.dequeue()) |item| {
                    context.received[i] = item;
                    i += 1;
                } else {
                    // Queue empty, spin and retry
                    std.atomic.spinLoopHint();
                }
            }
        }
    };

    // Spawn producer and consumer threads
    const producer_thread = try Thread.spawn(.{}, ProducerFn.run, .{&ctx});
    const consumer_thread = try Thread.spawn(.{}, ConsumerFn.run, .{&ctx});

    producer_thread.join();
    consumer_thread.join();

    // Verify all items received in correct order
    var i: u64 = 0;
    while (i < N) : (i += 1) {
        if (received[i] != i) {
            std.debug.print("Mismatch at index {}: expected {}, got {}\n", .{ i, i, received[i] });
            return error.TestUnexpectedResult;
        }
    }

    // Queue should be empty
    try testing.expectEqual(@as(?u64, null), result.consumer.dequeue());
}

test "SPSC: two-thread correctness - random delays" {
    const Queue = BoundedSPSCQueue(u64);
    const capacity = 64;
    const N = 100_000;

    var result = try Queue.init(testing.allocator, capacity);
    defer result.producer.deinit();

    const TestContext = struct {
        producer: *Queue.Producer,
        consumer: *Queue.Consumer,
        count: u64,
        received: []u64,
        seed: u64,
    };

    const received = try testing.allocator.alloc(u64, N);
    defer testing.allocator.free(received);

    var ctx = TestContext{
        .producer = @constCast(&result.producer),
        .consumer = @constCast(&result.consumer),
        .count = N,
        .received = received,
        .seed = 12345,
    };

    const ProducerFn = struct {
        fn run(context: *TestContext) void {
            var prng = std.Random.DefaultPrng.init(context.seed);
            var random = prng.random();
            var i: u64 = 0;
            while (i < context.count) {
                context.producer.enqueue(i) catch {
                    std.atomic.spinLoopHint();
                    continue;
                };
                i += 1;

                // Random small delay
                if (random.int(u8) < 10) {
                    var spin: usize = 0;
                    while (spin < random.uintLessThan(usize, 100)) : (spin += 1) {
                        std.atomic.spinLoopHint();
                    }
                }
            }
        }
    };

    const ConsumerFn = struct {
        fn run(context: *TestContext) void {
            var prng = std.Random.DefaultPrng.init(context.seed + 1);
            var random = prng.random();
            var i: usize = 0;
            while (i < context.count) {
                if (context.consumer.dequeue()) |item| {
                    context.received[i] = item;
                    i += 1;

                    // Random small delay
                    if (random.int(u8) < 10) {
                        var spin: usize = 0;
                        while (spin < random.uintLessThan(usize, 100)) : (spin += 1) {
                            std.atomic.spinLoopHint();
                        }
                    }
                } else {
                    std.atomic.spinLoopHint();
                }
            }
        }
    };

    const producer_thread = try Thread.spawn(.{}, ProducerFn.run, .{&ctx});
    const consumer_thread = try Thread.spawn(.{}, ConsumerFn.run, .{&ctx});

    producer_thread.join();
    consumer_thread.join();

    // Verify FIFO order
    var i: u64 = 0;
    while (i < N) : (i += 1) {
        try testing.expectEqual(i, received[i]);
    }
}

test "SPSC: two-thread stress test - high throughput" {
    const Queue = BoundedSPSCQueue(u64);
    const capacity = 1024;
    const N = 10_000_000;

    var result = try Queue.init(testing.allocator, capacity);
    defer result.producer.deinit();

    const TestContext = struct {
        producer: *Queue.Producer,
        consumer: *Queue.Consumer,
        count: u64,
        checksum: std.atomic.Value(u64),
    };

    var ctx = TestContext{
        .producer = @constCast(&result.producer),
        .consumer = @constCast(&result.consumer),
        .count = N,
        .checksum = std.atomic.Value(u64).init(0),
    };

    const ProducerFn = struct {
        fn run(context: *TestContext) void {
            var i: u64 = 0;
            while (i < context.count) {
                context.producer.enqueue(i) catch {
                    std.atomic.spinLoopHint();
                    continue;
                };
                i += 1;
            }
        }
    };

    const ConsumerFn = struct {
        fn run(context: *TestContext) void {
            var i: usize = 0;
            var sum: u64 = 0;
            while (i < context.count) {
                if (context.consumer.dequeue()) |item| {
                    sum +%= item;
                    i += 1;
                } else {
                    std.atomic.spinLoopHint();
                }
            }
            context.checksum.store(sum, .monotonic);
        }
    };

    const start = std.time.nanoTimestamp();

    const producer_thread = try Thread.spawn(.{}, ProducerFn.run, .{&ctx});
    const consumer_thread = try Thread.spawn(.{}, ConsumerFn.run, .{&ctx});

    producer_thread.join();
    consumer_thread.join();

    const end = std.time.nanoTimestamp();
    const duration_ns = @as(u64, @intCast(end - start));
    const ops_per_sec = (@as(u128, N) * 1_000_000_000) / duration_ns;

    // Verify checksum (sum of 0..N-1)
    const expected_sum = (N * (N - 1)) / 2;
    const actual_sum = ctx.checksum.load(.monotonic);
    try testing.expectEqual(expected_sum, actual_sum);

    std.debug.print("\nSPSC Stress Test: {} items in {} ns ({} M ops/sec)\n", .{
        N,
        duration_ns,
        ops_per_sec / 1_000_000,
    });
}

// ============================================================================
// Edge Case Tests
// ============================================================================

test "SPSC: minimum capacity (2)" {
    const Queue = BoundedSPSCQueue(u64);
    var result = try Queue.init(testing.allocator, 2);
    defer result.producer.deinit();

    try result.producer.enqueue(1);
    try result.producer.enqueue(2);
    try testing.expectError(error.Full, result.producer.enqueue(3));

    try testing.expectEqual(@as(u64, 1), result.consumer.dequeue().?);
    try result.producer.enqueue(3);
    try testing.expectEqual(@as(u64, 2), result.consumer.dequeue().?);
    try testing.expectEqual(@as(u64, 3), result.consumer.dequeue().?);
    try testing.expectEqual(@as(?u64, null), result.consumer.dequeue());
}

test "SPSC: large capacity" {
    const Queue = BoundedSPSCQueue(u64);
    const capacity = 65536;
    var result = try Queue.init(testing.allocator, capacity);
    defer result.producer.deinit();

    // Fill to capacity
    var i: u64 = 0;
    while (i < capacity) : (i += 1) {
        try result.producer.enqueue(i);
    }

    // Verify full
    try testing.expectError(error.Full, result.producer.enqueue(capacity));

    // Drain and verify
    i = 0;
    while (i < capacity) : (i += 1) {
        try testing.expectEqual(i, result.consumer.dequeue().?);
    }
    try testing.expectEqual(@as(?u64, null), result.consumer.dequeue());
}

test "SPSC: pointer types" {
    const Payload = struct {
        value: u64,
    };

    const Queue = BoundedSPSCQueue(*Payload);
    var result = try Queue.init(testing.allocator, 8);
    defer result.producer.deinit();

    var p1 = Payload{ .value = 42 };
    var p2 = Payload{ .value = 99 };

    try result.producer.enqueue(&p1);
    try result.producer.enqueue(&p2);

    const r1 = result.consumer.dequeue().?;
    const r2 = result.consumer.dequeue().?;

    try testing.expectEqual(@as(u64, 42), r1.value);
    try testing.expectEqual(@as(u64, 99), r2.value);
    try testing.expectEqual(&p1, r1);
    try testing.expectEqual(&p2, r2);
}
