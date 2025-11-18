const std = @import("std");
const testing = std.testing;
const DVyukovMPMCQueue = @import("dvyukov_mpmc_queue.zig").DVyukovMPMCQueue;

// =============================================================================
// Fuzz Tests - Edge cases and randomized testing
// =============================================================================

/// Generate a pseudo-random seed for fuzz tests based on timestamp
/// Each test gets a unique seed by adding an offset to ensure different coverage
inline fn generateSeed(comptime offset: u64) u64 {
    const timestamp = std.time.nanoTimestamp();
    return @as(u64, @truncate(@as(u128, @bitCast(timestamp)))) +% offset;
}

test "fuzz - random enqueue/dequeue operations" {
    var prng = std.Random.DefaultPrng.init(generateSeed(1));
    const random = prng.random();

    var queue = try DVyukovMPMCQueue(u64, 64).init(testing.allocator);
    defer queue.deinit();

    var expected: std.ArrayListUnmanaged(u64) = .{};
    defer expected.deinit(testing.allocator);
    var head: usize = 0; // Track front of queue without shifting

    const iterations = 10000;
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const op = random.intRangeAtMost(u8, 0, 2);

        switch (op) {
            0 => {
                // Enqueue
                if (!queue.isFull()) {
                    const value = random.int(u64);
                    queue.enqueue(value) catch |err| {
                        std.debug.panic("Fuzz test enqueue failed: {}", .{err});
                    };
                    try expected.append(testing.allocator, value);
                }
            },
            1 => {
                // Dequeue
                if (queue.dequeue()) |value| {
                    try testing.expectEqual(expected.items[head], value);
                    head += 1;
                }
            },
            2 => {
                // Verify size
                try testing.expectEqual(expected.items.len - head, queue.size());
            },
            else => std.debug.panic("Invalid operation: {}", .{op}),
        }
    }

    // Drain and verify
    while (head < expected.items.len) : (head += 1) {
        const val = queue.dequeue().?;
        try testing.expectEqual(expected.items[head], val);
    }
}

test "fuzz - burst patterns" {
    var prng = std.Random.DefaultPrng.init(generateSeed(2));
    const random = prng.random();

    var queue = try DVyukovMPMCQueue(usize, 128).init(testing.allocator);
    defer queue.deinit();

    // Track expected values in queue
    var expected: std.ArrayListUnmanaged(usize) = .{};
    defer expected.deinit(testing.allocator);
    var head: usize = 0; // Track front of queue without shifting

    const rounds = 100;
    var round: usize = 0;
    while (round < rounds) : (round += 1) {
        // Random burst size
        const burst_size = random.intRangeAtMost(usize, 1, 100);

        // Enqueue burst
        var i: usize = 0;
        while (i < burst_size) : (i += 1) {
            const value = round * 1000 + i;
            queue.enqueue(value) catch break;
            try expected.append(testing.allocator, value);
        }

        // Random drain amount (use local counter instead of calling size())
        const queued_count = expected.items.len - head;
        const drain_amount = random.intRangeAtMost(usize, 0, queued_count);
        i = 0;
        while (i < drain_amount) : (i += 1) {
            const val = queue.dequeue().?;
            try testing.expectEqual(expected.items[head], val);
            head += 1;
        }
    }

    // Final drain and verify
    while (head < expected.items.len) : (head += 1) {
        const val = queue.dequeue().?;
        try testing.expectEqual(expected.items[head], val);
    }
    try testing.expect(queue.isEmpty());
}

test "fuzz - capacity boundary conditions" {
    var prng = std.Random.DefaultPrng.init(generateSeed(3));
    const random = prng.random();

    var queue = try DVyukovMPMCQueue(u32, 8).init(testing.allocator);
    defer queue.deinit();

    const iterations = 1000;
    var i: usize = 0;
    var count: usize = 0; // Track queue size locally
    while (i < iterations) : (i += 1) {
        // Fill to random level
        const target = random.intRangeAtMost(usize, 0, 8);
        while (count < target) : (count += 1) {
            queue.enqueue(random.int(u32)) catch unreachable;
        }

        // Drain to random level
        const new_target = random.intRangeAtMost(usize, 0, count);
        while (count > new_target) : (count -= 1) {
            _ = queue.dequeue();
        }

        try testing.expectEqual(new_target, queue.size());
    }
}

test "fuzz - alternating fill and drain patterns" {
    var queue = try DVyukovMPMCQueue(usize, 32).init(testing.allocator);
    defer queue.deinit();

    var base: usize = 0;
    var queued: usize = 0; // Track queue size locally
    const patterns = 50;
    var p: usize = 0;
    while (p < patterns) : (p += 1) {
        // Fill with pattern: 1, 2, 3, ... , n
        const fill_count = (p % 20) + 1;
        var i: usize = 0;
        while (i < fill_count) : (i += 1) {
            queue.enqueue(base + i) catch break;
            queued += 1;
        }

        // Drain with pattern: every other, or all, or none
        const drain_pattern = p % 3;
        switch (drain_pattern) {
            0 => {
                // Drain all
                while (queue.dequeue()) |_| {
                    queued -= 1;
                }
            },
            1 => {
                // Drain half (use local counter instead of size() call)
                const half = queued / 2;
                i = 0;
                while (i < half) : (i += 1) {
                    _ = queue.dequeue();
                    queued -= 1;
                }
            },
            2 => {
                // Drain none
            },
            else => std.debug.panic("Invalid drain pattern: {}", .{drain_pattern}),
        }

        base += fill_count;
    }
}

test "fuzz - wraparound stress" {
    var prng = std.Random.DefaultPrng.init(generateSeed(4));
    const random = prng.random();

    var queue = try DVyukovMPMCQueue(u64, 16).init(testing.allocator);
    defer queue.deinit();

    // Force many wraparounds
    const cycles = 1000;
    var cycle: usize = 0;
    while (cycle < cycles) : (cycle += 1) {
        // Random operations
        const ops = random.intRangeAtMost(usize, 5, 30);
        var i: usize = 0;
        while (i < ops) : (i += 1) {
            if (random.boolean()) {
                queue.enqueue(random.int(u64)) catch {};
            } else {
                _ = queue.dequeue();
            }
        }
    }

    // Final drain
    while (queue.dequeue()) |_| {}
    try testing.expect(queue.isEmpty());
}

test "fuzz - producer consumer ratio variations" {
    var prng = std.Random.DefaultPrng.init(generateSeed(5));
    const random = prng.random();

    var queue = try DVyukovMPMCQueue(u32, 128).init(testing.allocator);
    defer queue.deinit();

    var stop = std.atomic.Value(bool).init(false);

    const Ctx = struct {
        queue: *DVyukovMPMCQueue(u32, 128),
        stop: *std.atomic.Value(bool),
    };

    const producer = struct {
        fn run(ctx: Ctx) void {
            var local_prng = std.Random.DefaultPrng.init(0x2222);
            const local_random = local_prng.random();

            while (!ctx.stop.load(.monotonic)) {
                const value = local_random.int(u32);
                ctx.queue.enqueue(value) catch {
                    std.Thread.yield() catch {};
                };
            }
        }
    }.run;

    const consumer = struct {
        fn run(ctx: Ctx) void {
            while (!ctx.stop.load(.monotonic)) {
                if (ctx.queue.dequeue()) |_| {
                    // Consumed
                } else {
                    std.Thread.yield() catch {};
                }
            }
        }
    }.run;

    // Spawn variable number of threads
    const num_producers = random.intRangeAtMost(usize, 1, 4);
    const num_consumers = random.intRangeAtMost(usize, 1, 4);

    var producers: std.ArrayListUnmanaged(std.Thread) = .{};
    defer producers.deinit(testing.allocator);
    var consumers: std.ArrayListUnmanaged(std.Thread) = .{};
    defer consumers.deinit(testing.allocator);

    var i: usize = 0;
    while (i < num_producers) : (i += 1) {
        try producers.append(testing.allocator, try std.Thread.spawn(.{}, producer, .{Ctx{
            .queue = &queue,
            .stop = &stop,
        }}));
    }

    i = 0;
    while (i < num_consumers) : (i += 1) {
        try consumers.append(testing.allocator, try std.Thread.spawn(.{}, consumer, .{Ctx{
            .queue = &queue,
            .stop = &stop,
        }}));
    }

    // Run for a bit
    std.Thread.sleep(100 * std.time.ns_per_ms);
    stop.store(true, .release);

    for (producers.items) |t| t.join();
    for (consumers.items) |t| t.join();
}

test "fuzz - tryEnqueue with random attempts" {
    var prng = std.Random.DefaultPrng.init(generateSeed(6));
    const random = prng.random();

    var queue = try DVyukovMPMCQueue(u64, 16).init(testing.allocator);
    defer queue.deinit();

    const iterations = 500;
    var i: usize = 0;
    var queued: usize = 0; // Track queue size locally
    while (i < iterations) : (i += 1) {
        const max_attempts = random.intRangeAtMost(usize, 1, 100);
        const value = random.int(u64);

        queue.tryEnqueue(value, max_attempts) catch {
            // Full or contended, drain some (use local counter)
            if (queued > 0) {
                const drain_count = random.intRangeAtMost(usize, 1, queued);
                var d: usize = 0;
                while (d < drain_count) : (d += 1) {
                    _ = queue.dequeue();
                    queued -= 1;
                }
            }
            continue;
        };
        queued += 1;
    }
}

test "fuzz - concurrent random operations" {
    var prng = std.Random.DefaultPrng.init(generateSeed(7));
    const random = prng.random();

    var queue = try DVyukovMPMCQueue(usize, 256).init(testing.allocator);
    defer queue.deinit();

    var stop = std.atomic.Value(bool).init(false);
    var ops_count = std.atomic.Value(usize).init(0);

    const Ctx = struct {
        queue: *DVyukovMPMCQueue(usize, 256),
        stop: *std.atomic.Value(bool),
        ops: *std.atomic.Value(usize),
    };

    const worker = struct {
        fn run(ctx: Ctx) void {
            var local_prng = std.Random.DefaultPrng.init(@intCast(std.time.milliTimestamp()));
            const local_random = local_prng.random();

            while (!ctx.stop.load(.monotonic)) {
                if (local_random.boolean()) {
                    ctx.queue.enqueue(local_random.int(usize)) catch {
                        std.Thread.yield() catch {};
                    };
                } else {
                    _ = ctx.queue.dequeue();
                }
                _ = ctx.ops.fetchAdd(1, .monotonic);
            }
        }
    }.run;

    // Random number of workers
    const num_workers = random.intRangeAtMost(usize, 2, 8);
    var workers: std.ArrayListUnmanaged(std.Thread) = .{};
    defer workers.deinit(testing.allocator);

    var i: usize = 0;
    while (i < num_workers) : (i += 1) {
        try workers.append(testing.allocator, try std.Thread.spawn(.{}, worker, .{Ctx{
            .queue = &queue,
            .stop = &stop,
            .ops = &ops_count,
        }}));
    }

    // Run for duration
    std.Thread.sleep(200 * std.time.ns_per_ms);
    stop.store(true, .release);

    for (workers.items) |t| t.join();

    std.debug.print("Fuzz concurrent: {} ops with {} workers\n", .{
        ops_count.load(.monotonic),
        num_workers,
    });
}

test "fuzz - queue saturation cycles" {
    var prng = std.Random.DefaultPrng.init(generateSeed(8));
    const random = prng.random();

    var queue = try DVyukovMPMCQueue(u64, 32).init(testing.allocator);
    defer queue.deinit();

    // Rapidly fill and drain the queue
    const iterations = 200;
    var i: usize = 0;
    var queued: usize = 0; // Track queue size locally
    while (i < iterations) : (i += 1) {
        // Fill to random level
        const fill_count = random.intRangeAtMost(usize, 0, 32);
        var filled: usize = 0;
        while (filled < fill_count) : (filled += 1) {
            const value = random.int(u64);
            queue.enqueue(value) catch break;
            queued += 1;
        }

        // Drain to random level (use local counter)
        const drain_count = random.intRangeAtMost(usize, 0, queued);
        var drained: usize = 0;
        while (drained < drain_count) : (drained += 1) {
            _ = queue.dequeue();
            queued -= 1;
        }
    }
}

test "fuzz - extreme capacity boundaries" {
    // Test minimum capacity (2)
    {
        var prng = std.Random.DefaultPrng.init(generateSeed(9));
        const random = prng.random();

        var queue = try DVyukovMPMCQueue(u32, 2).init(testing.allocator);
        defer queue.deinit();

        var i: usize = 0;
        while (i < 1000) : (i += 1) {
            const op = random.intRangeAtMost(u8, 0, 1);
            if (op == 0) {
                _ = queue.enqueue(random.int(u32)) catch {};
            } else {
                _ = queue.dequeue();
            }
        }
    }

    // Test large capacity (2048)
    {
        var prng = std.Random.DefaultPrng.init(generateSeed(10));
        const random = prng.random();

        var queue = try DVyukovMPMCQueue(u32, 2048).init(testing.allocator);
        defer queue.deinit();

        // Fill partially
        var i: usize = 0;
        while (i < 1000) : (i += 1) {
            queue.enqueue(random.int(u32)) catch unreachable;
        }

        // Random ops
        i = 0;
        while (i < 5000) : (i += 1) {
            const op = random.intRangeAtMost(u8, 0, 1);
            if (op == 0 and !queue.isFull()) {
                queue.enqueue(random.int(u32)) catch unreachable;
            } else if (!queue.isEmpty()) {
                _ = queue.dequeue();
            }
        }
    }
}

test "fuzz - tryEnqueue attempts variation" {
    var prng = std.Random.DefaultPrng.init(generateSeed(11));
    const random = prng.random();

    var queue = try DVyukovMPMCQueue(u32, 16).init(testing.allocator);
    defer queue.deinit();

    const iterations = 500;
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const attempts = random.intRangeAtMost(usize, 1, 20);
        const value = random.int(u32);

        _ = queue.tryEnqueue(value, attempts) catch {};

        // Randomly dequeue
        if (random.intRangeAtMost(u8, 0, 2) == 0) {
            _ = queue.dequeue();
        }
    }
}

test "fuzz - mixed operations stress" {
    var prng = std.Random.DefaultPrng.init(generateSeed(12));
    const random = prng.random();

    var queue = try DVyukovMPMCQueue(usize, 64).init(testing.allocator);
    defer queue.deinit();

    var enqueued: usize = 0;
    var dequeued: usize = 0;

    const iterations = 10000;
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const op = random.intRangeAtMost(u8, 0, 4);

        switch (op) {
            0, 1 => {
                // Enqueue (higher probability)
                queue.enqueue(enqueued) catch continue;
                enqueued += 1;
            },
            2 => {
                // Dequeue
                if (queue.dequeue()) |_| {
                    dequeued += 1;
                }
            },
            3 => {
                // tryEnqueue
                const attempts = random.intRangeAtMost(usize, 1, 10);
                queue.tryEnqueue(enqueued, attempts) catch continue;
                enqueued += 1;
            },
            4 => {
                // Check state
                const s = queue.size();
                try testing.expect(s <= 64);
                try testing.expectEqual(queue.isEmpty(), s == 0);
                try testing.expectEqual(queue.isFull(), s == 64);
            },
            else => std.debug.panic("Invalid operation: {}", .{op}),
        }
    }

    // Drain remaining
    while (queue.dequeue()) |_| {
        dequeued += 1;
    }

    try testing.expectEqual(enqueued, dequeued);
}

test "fuzz - alternating patterns" {
    var prng = std.Random.DefaultPrng.init(generateSeed(13));
    const random = prng.random();

    var queue = try DVyukovMPMCQueue(u64, 128).init(testing.allocator);
    defer queue.deinit();

    // Random patterns: enqueue N, dequeue M
    const patterns = 100;
    var p: usize = 0;
    var queued: usize = 0; // Track queue size locally
    while (p < patterns) : (p += 1) {
        // Random enqueue count
        const enq_count = random.intRangeAtMost(usize, 1, 50);
        var e: usize = 0;
        while (e < enq_count) : (e += 1) {
            const value = random.int(u64);
            queue.enqueue(value) catch break;
            queued += 1;
        }

        // Random dequeue count (use local counter)
        if (queued > 0) {
            const deq_count = random.intRangeAtMost(usize, 1, queued);
            var d: usize = 0;
            while (d < deq_count) : (d += 1) {
                _ = queue.dequeue();
                queued -= 1;
            }
        }
    }
}

test "fuzz - large struct operations via pointers" {
    // NOTE: DVyukov queue enforces T <= 128 bytes for optimal cache performance.
    // For large structs, use pointers as recommended by the compile-time error.
    var prng = std.Random.DefaultPrng.init(generateSeed(14));
    const random = prng.random();

    const LargeItem = struct {
        data: [128]u8,
        id: u64,

        fn initRandom(rng: std.Random) @This() {
            var result: @This() = undefined;
            result.id = rng.int(u64);
            for (&result.data) |*byte| {
                byte.* = rng.int(u8);
            }
            return result;
        }
    };

    // Use pointers instead of large structs directly
    var queue = try DVyukovMPMCQueue(*LargeItem, 32).init(testing.allocator);
    defer queue.deinit();

    // Use ArrayListUnmanaged for Zig 0.15.x compatibility
    var allocated_items: std.ArrayListUnmanaged(*LargeItem) = .{};
    defer {
        for (allocated_items.items) |item| {
            testing.allocator.destroy(item);
        }
        allocated_items.deinit(testing.allocator);
    }

    const iterations = 500;
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const op = random.intRangeAtMost(u8, 0, 1);
        if (op == 0) {
            const item = try testing.allocator.create(LargeItem);
            item.* = LargeItem.initRandom(random);
            try allocated_items.append(testing.allocator, item);
            _ = queue.enqueue(item) catch {};
        } else {
            _ = queue.dequeue();
        }
    }
}

test "fuzz - full queue operations" {
    var prng = std.Random.DefaultPrng.init(generateSeed(15));
    const random = prng.random();

    var queue = try DVyukovMPMCQueue(u32, 16).init(testing.allocator);
    defer queue.deinit();

    // Fill queue completely
    var i: u32 = 0;
    while (i < 16) : (i += 1) {
        try queue.enqueue(i);
    }

    try testing.expect(queue.isFull());

    // Fuzz operations on full queue
    const iterations = 200;
    i = 0;
    while (i < iterations) : (i += 1) {
        const op = random.intRangeAtMost(u8, 0, 2);

        switch (op) {
            0 => {
                // Try to enqueue (should fail)
                try testing.expectError(error.QueueFull, queue.enqueue(random.int(u32)));
            },
            1 => {
                // Dequeue one and immediately enqueue
                _ = queue.dequeue();
                try queue.enqueue(random.int(u32));
            },
            2 => {
                // tryEnqueue
                const attempts = random.intRangeAtMost(usize, 1, 5);
                _ = queue.dequeue();
                try queue.tryEnqueue(random.int(u32), attempts);
            },
            else => std.debug.panic("Invalid operation: {}", .{op}),
        }

        // Queue should remain full
        try testing.expect(queue.isFull());
    }
}

test "fuzz - empty queue operations" {
    var prng = std.Random.DefaultPrng.init(generateSeed(16));
    const random = prng.random();

    var queue = try DVyukovMPMCQueue(u32, 16).init(testing.allocator);
    defer queue.deinit();

    const iterations = 200;
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        try testing.expect(queue.isEmpty());

        // Dequeue should return null
        try testing.expectEqual(@as(?u32, null), queue.dequeue());

        // Enqueue one
        try queue.enqueue(random.int(u32));

        // Dequeue immediately
        try testing.expect(queue.dequeue() != null);

        // Should be empty again
        try testing.expect(queue.isEmpty());
    }
}
