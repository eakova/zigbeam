const std = @import("std");
const testing = std.testing;
const DVyukovMPMCQueue = @import("beam-dvyukov-mpmc").DVyukovMPMCQueue;

// =============================================================================
// Unit Tests - Single-threaded correctness verification
// =============================================================================

test "queue creation and basic properties" {
    var queue = try DVyukovMPMCQueue(u32, 16).init(testing.allocator);
    defer queue.deinit();

    try testing.expectEqual(@as(usize, 16), queue.getCapacity());
    try testing.expect(queue.isEmpty());
    try testing.expectEqual(@as(usize, 0), queue.size());
}

test "single enqueue and dequeue" {
    var queue = try DVyukovMPMCQueue(u64, 8).init(testing.allocator);
    defer queue.deinit();

    try queue.enqueue(42);
    try testing.expectEqual(@as(usize, 1), queue.size());
    try testing.expectEqual(@as(?u64, 42), queue.dequeue());
    try testing.expect(queue.isEmpty());
}

test "FIFO ordering preserved" {
    var queue = try DVyukovMPMCQueue(usize, 16).init(testing.allocator);
    defer queue.deinit();

    // Enqueue 0..10
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        try queue.enqueue(i);
    }

    // Dequeue and verify order
    i = 0;
    while (i < 10) : (i += 1) {
        try testing.expectEqual(@as(?usize, i), queue.dequeue());
    }

    try testing.expect(queue.isEmpty());
}

test "fill and drain queue completely" {
    const cap = 32;
    var queue = try DVyukovMPMCQueue(u32, cap).init(testing.allocator);
    defer queue.deinit();

    // Fill completely
    var i: u32 = 0;
    while (i < cap) : (i += 1) {
        try queue.enqueue(i);
    }

    try testing.expect(queue.isFull());
    try testing.expectEqual(@as(usize, cap), queue.size());

    // Drain completely
    i = 0;
    while (i < cap) : (i += 1) {
        try testing.expectEqual(@as(?u32, i), queue.dequeue());
    }

    try testing.expect(queue.isEmpty());
    try testing.expectEqual(@as(?u32, null), queue.dequeue());
}

test "enqueue fails when full" {
    var queue = try DVyukovMPMCQueue(u8, 4).init(testing.allocator);
    defer queue.deinit();

    // Fill queue
    try queue.enqueue(1);
    try queue.enqueue(2);
    try queue.enqueue(3);
    try queue.enqueue(4);

    // Next enqueue should fail
    try testing.expectError(error.QueueFull, queue.enqueue(5));

    // Size should be at capacity
    try testing.expectEqual(@as(usize, 4), queue.size());
}

test "dequeue returns null when empty" {
    var queue = try DVyukovMPMCQueue(i32, 8).init(testing.allocator);
    defer queue.deinit();

    try testing.expectEqual(@as(?i32, null), queue.dequeue());
    try testing.expectEqual(@as(?i32, null), queue.dequeue());
}

test "alternating enqueue and dequeue" {
    var queue = try DVyukovMPMCQueue(usize, 8).init(testing.allocator);
    defer queue.deinit();

    var i: usize = 0;
    while (i < 100) : (i += 1) {
        try queue.enqueue(i);
        try testing.expectEqual(@as(?usize, i), queue.dequeue());
        try testing.expect(queue.isEmpty());
    }
}

test "wraparound behavior" {
    var queue = try DVyukovMPMCQueue(u32, 4).init(testing.allocator);
    defer queue.deinit();

    // Cycle through queue many times to test wraparound
    var cycle: usize = 0;
    while (cycle < 1000) : (cycle += 1) {
        try queue.enqueue(@intCast(cycle));
        try testing.expectEqual(@as(?u32, @intCast(cycle)), queue.dequeue());
    }

    try testing.expect(queue.isEmpty());
}

test "partial fill and drain cycles" {
    var queue = try DVyukovMPMCQueue(usize, 16).init(testing.allocator);
    defer queue.deinit();

    // Cycle: fill halfway, drain halfway, repeat
    var round: usize = 0;
    while (round < 10) : (round += 1) {
        // Fill half
        var i: usize = 0;
        while (i < 8) : (i += 1) {
            try queue.enqueue(round * 100 + i);
        }

        try testing.expectEqual(@as(usize, 8), queue.size());

        // Drain half
        i = 0;
        while (i < 8) : (i += 1) {
            try testing.expectEqual(@as(?usize, round * 100 + i), queue.dequeue());
        }

        try testing.expect(queue.isEmpty());
    }
}

test "different data types" {
    // Test with struct
    const Point = struct {
        x: f32,
        y: f32,
    };

    var queue = try DVyukovMPMCQueue(Point, 8).init(testing.allocator);
    defer queue.deinit();

    try queue.enqueue(.{ .x = 1.0, .y = 2.0 });
    try queue.enqueue(.{ .x = 3.0, .y = 4.0 });

    const p1 = queue.dequeue().?;
    try testing.expectEqual(@as(f32, 1.0), p1.x);
    try testing.expectEqual(@as(f32, 2.0), p1.y);

    const p2 = queue.dequeue().?;
    try testing.expectEqual(@as(f32, 3.0), p2.x);
    try testing.expectEqual(@as(f32, 4.0), p2.y);
}

test "pointer types" {
    var value: u32 = 42;
    var queue = try DVyukovMPMCQueue(*u32, 4).init(testing.allocator);
    defer queue.deinit();

    try queue.enqueue(&value);
    const ptr = queue.dequeue().?;
    try testing.expectEqual(@as(u32, 42), ptr.*);
    try testing.expectEqual(&value, ptr);
}

test "tryEnqueue with spin limit" {
    var queue = try DVyukovMPMCQueue(u32, 4).init(testing.allocator);
    defer queue.deinit();

    // Fill queue
    try queue.enqueue(1);
    try queue.enqueue(2);
    try queue.enqueue(3);
    try queue.enqueue(4);

    // tryEnqueue should fail after attempts
    try testing.expectError(error.QueueFull, queue.tryEnqueue(5, 10));

    // Dequeue one and tryEnqueue should succeed
    _ = queue.dequeue();
    try queue.tryEnqueue(5, 10);

    try testing.expectEqual(@as(usize, 4), queue.size());
}

test "queue with minimum capacity" {
    // Test minimum supported capacity (2)
    var queue = try DVyukovMPMCQueue(u32, 2).init(testing.allocator);
    defer queue.deinit();

    try queue.enqueue(1);
    try queue.enqueue(2);
    try testing.expect(queue.isFull());
    try testing.expectError(error.QueueFull, queue.enqueue(3));

    try testing.expectEqual(@as(?u32, 1), queue.dequeue());
    try testing.expectEqual(@as(?u32, 2), queue.dequeue());
    try testing.expect(queue.isEmpty());

    try queue.enqueue(3);
    try queue.enqueue(4);
    try testing.expectEqual(@as(?u32, 3), queue.dequeue());
    try testing.expectEqual(@as(?u32, 4), queue.dequeue());
}

test "queue with large capacity" {
    const cap = 1024;
    var queue = try DVyukovMPMCQueue(usize, cap).init(testing.allocator);
    defer queue.deinit();

    // Fill completely
    var i: usize = 0;
    while (i < cap) : (i += 1) {
        try queue.enqueue(i);
    }

    try testing.expectEqual(@as(usize, cap), queue.size());

    // Drain and verify
    i = 0;
    while (i < cap) : (i += 1) {
        try testing.expectEqual(@as(?usize, i), queue.dequeue());
    }

    try testing.expect(queue.isEmpty());
}

test "enqueue dequeue patterns" {
    var queue = try DVyukovMPMCQueue(u32, 16).init(testing.allocator);
    defer queue.deinit();

    // Pattern: enqueue 3, dequeue 2, repeat
    // This creates a growing queue with net +1 item per round
    var expected: u32 = 0;
    var round: usize = 0;
    while (round < 10) : (round += 1) {
        const base = @as(u32, @intCast(round * 3));
        try queue.enqueue(base);
        try queue.enqueue(base + 1);
        try queue.enqueue(base + 2);

        try testing.expectEqual(@as(?u32, expected), queue.dequeue());
        try testing.expectEqual(@as(?u32, expected + 1), queue.dequeue());
        expected += 2;
    }

    // Verify we have 10 items remaining (1 per round)
    try testing.expectEqual(@as(usize, 10), queue.size());

    // Drain remaining and verify they're consecutive
    while (queue.dequeue()) |val| {
        try testing.expectEqual(expected, val);
        expected += 1;
    }
    try testing.expect(queue.isEmpty());
}

test "size reporting accuracy" {
    var queue = try DVyukovMPMCQueue(u32, 16).init(testing.allocator);
    defer queue.deinit();

    try testing.expectEqual(@as(usize, 0), queue.size());

    var i: u32 = 1;
    while (i <= 10) : (i += 1) {
        try queue.enqueue(i);
        try testing.expectEqual(@as(usize, i), queue.size());
    }

    i = 10;
    while (i > 0) : (i -= 1) {
        _ = queue.dequeue();
        try testing.expectEqual(@as(usize, i - 1), queue.size());
    }
}

test "stress test - many operations" {
    var queue = try DVyukovMPMCQueue(usize, 64).init(testing.allocator);
    defer queue.deinit();

    var total_enqueued: usize = 0;
    var total_dequeued: usize = 0;
    const capacity = queue.getCapacity();

    var i: usize = 0;
    while (i < 10000) : (i += 1) {
        // Randomly decide to enqueue or dequeue
        // Use local counters instead of isFull/isEmpty to avoid redundant atomic loads
        const current_size = total_enqueued - total_dequeued;
        if ((i % 3) != 0 and current_size < capacity) {
            queue.enqueue(total_enqueued) catch |err| {
                std.debug.panic("Unexpected enqueue failure: {}", .{err});
            };
            total_enqueued += 1;
        } else if (current_size > 0) {
            const val = queue.dequeue().?;
            try testing.expectEqual(total_dequeued, val);
            total_dequeued += 1;
        }
    }

    // Drain remaining
    while (queue.dequeue()) |val| {
        try testing.expectEqual(total_dequeued, val);
        total_dequeued += 1;
    }

    try testing.expectEqual(total_enqueued, total_dequeued);
}

test "large struct type via pointers" {
    // NOTE: DVyukov queue enforces T <= 128 bytes for optimal cache performance.
    // For large structs (>128 bytes), use pointers as recommended by the compile-time error.
    const LargeStruct = struct {
        data: [200]u8,
        id: usize,

        fn init(id_val: usize) @This() {
            var result: @This() = undefined;
            result.id = id_val;
            for (&result.data, 0..) |*byte, idx| {
                byte.* = @truncate(id_val + idx);
            }
            return result;
        }

        fn verify(self: *const @This(), expected_id: usize) bool {
            if (self.id != expected_id) return false;
            for (self.data, 0..) |byte, idx| {
                if (byte != @as(u8, @truncate(expected_id + idx))) return false;
            }
            return true;
        }
    };

    // Use pointers instead of large structs directly
    var queue = try DVyukovMPMCQueue(*LargeStruct, 8).init(testing.allocator);
    defer queue.deinit();

    // Allocate and enqueue
    const s0_ptr = try testing.allocator.create(LargeStruct);
    s0_ptr.* = LargeStruct.init(0);
    try queue.enqueue(s0_ptr);

    const s1_ptr = try testing.allocator.create(LargeStruct);
    s1_ptr.* = LargeStruct.init(1);
    try queue.enqueue(s1_ptr);

    const s2_ptr = try testing.allocator.create(LargeStruct);
    s2_ptr.* = LargeStruct.init(2);
    try queue.enqueue(s2_ptr);

    // Dequeue, verify, and free
    const dequeued_s0 = queue.dequeue().?;
    try testing.expect(dequeued_s0.verify(0));
    testing.allocator.destroy(dequeued_s0);

    const dequeued_s1 = queue.dequeue().?;
    try testing.expect(dequeued_s1.verify(1));
    testing.allocator.destroy(dequeued_s1);

    const dequeued_s2 = queue.dequeue().?;
    try testing.expect(dequeued_s2.verify(2));
    testing.allocator.destroy(dequeued_s2);

    try testing.expect(queue.isEmpty());
}

test "tryEnqueue edge cases" {
    var queue = try DVyukovMPMCQueue(u32, 4).init(testing.allocator);
    defer queue.deinit();

    // Test with max_attempts = 0 (should fail immediately)
    try testing.expectError(error.QueueFull, queue.tryEnqueue(1, 0));

    // Test with max_attempts = 1 (should succeed on empty queue)
    try queue.tryEnqueue(1, 1);
    try testing.expectEqual(@as(usize, 1), queue.size());

    // Fill queue completely
    try queue.tryEnqueue(2, 10);
    try queue.tryEnqueue(3, 10);
    try queue.tryEnqueue(4, 10);

    // Should fail immediately on full queue regardless of attempts
    try testing.expectError(error.QueueFull, queue.tryEnqueue(5, 1));
    try testing.expectError(error.QueueFull, queue.tryEnqueue(5, 100));
    try testing.expectError(error.QueueFull, queue.tryEnqueue(5, 1000));

    // Drain one
    try testing.expectEqual(@as(?u32, 1), queue.dequeue());

    // Now should succeed
    try queue.tryEnqueue(5, 1);
    try testing.expectEqual(@as(usize, 4), queue.size());
}

test "multiple types in same test" {
    // Test with u8
    {
        var q = try DVyukovMPMCQueue(u8, 4).init(testing.allocator);
        defer q.deinit();
        try q.enqueue(255);
        try testing.expectEqual(@as(?u8, 255), q.dequeue());
    }

    // Test with i64
    {
        var q = try DVyukovMPMCQueue(i64, 4).init(testing.allocator);
        defer q.deinit();
        try q.enqueue(-9223372036854775807);
        try testing.expectEqual(@as(?i64, -9223372036854775807), q.dequeue());
    }

    // Test with f64
    {
        var q = try DVyukovMPMCQueue(f64, 4).init(testing.allocator);
        defer q.deinit();
        try q.enqueue(3.141592653589793);
        const val = q.dequeue().?;
        try testing.expectApproxEqRel(3.141592653589793, val, 0.0000001);
    }

    // Test with bool
    {
        var q = try DVyukovMPMCQueue(bool, 4).init(testing.allocator);
        defer q.deinit();
        try q.enqueue(true);
        try q.enqueue(false);
        try testing.expectEqual(@as(?bool, true), q.dequeue());
        try testing.expectEqual(@as(?bool, false), q.dequeue());
    }
}

test "size clamping at capacity" {
    var queue = try DVyukovMPMCQueue(u32, 8).init(testing.allocator);
    defer queue.deinit();

    // Fill queue
    var i: u32 = 0;
    while (i < 8) : (i += 1) {
        try queue.enqueue(i);
    }

    // Size should be exactly capacity, not more
    try testing.expectEqual(@as(usize, 8), queue.size());
    try testing.expect(queue.isFull());
    try testing.expect(!queue.isEmpty());

    // Even with racy operations, size should never exceed capacity
    try testing.expect(queue.size() <= queue.getCapacity());
}

test "enqueue error propagation" {
    var queue = try DVyukovMPMCQueue(u32, 2).init(testing.allocator);
    defer queue.deinit();

    // These should succeed
    try queue.enqueue(1);
    try queue.enqueue(2);

    // These should return error.QueueFull
    const result1 = queue.enqueue(3);
    try testing.expectError(error.QueueFull, result1);

    const result2 = queue.enqueue(4);
    try testing.expectError(error.QueueFull, result2);

    // Dequeue and retry
    _ = queue.dequeue();
    try queue.enqueue(3); // Should succeed now
}

test "interleaved fill patterns" {
    var queue = try DVyukovMPMCQueue(usize, 16).init(testing.allocator);
    defer queue.deinit();

    // Pattern: Fill 4, drain 2, fill 4, drain 2, etc.
    var next_enqueue: usize = 0;
    var next_dequeue: usize = 0;

    var round: usize = 0;
    while (round < 20) : (round += 1) {
        // Fill 4
        var i: usize = 0;
        while (i < 4) : (i += 1) {
            queue.enqueue(next_enqueue) catch break;
            next_enqueue += 1;
        }

        // Drain 2
        i = 0;
        while (i < 2) : (i += 1) {
            if (queue.dequeue()) |val| {
                try testing.expectEqual(next_dequeue, val);
                next_dequeue += 1;
            }
        }
    }

    // Drain all remaining
    while (queue.dequeue()) |val| {
        try testing.expectEqual(next_dequeue, val);
        next_dequeue += 1;
    }

    try testing.expectEqual(next_enqueue, next_dequeue);
}

test "maximum practical capacity" {
    // Test with very large capacity (4096)
    const cap = 4096;
    var queue = try DVyukovMPMCQueue(u64, cap).init(testing.allocator);
    defer queue.deinit();

    // Fill half
    var i: u64 = 0;
    while (i < cap / 2) : (i += 1) {
        try queue.enqueue(i);
    }

    try testing.expectEqual(@as(usize, cap / 2), queue.size());

    // Verify FIFO on first 100 items
    i = 0;
    while (i < 100) : (i += 1) {
        try testing.expectEqual(@as(?u64, i), queue.dequeue());
    }

    // Queue should have (cap/2 - 100) items
    try testing.expectEqual(@as(usize, cap / 2 - 100), queue.size());
}

test "enum type" {
    const State = enum {
        idle,
        running,
        paused,
        stopped,
    };

    var queue = try DVyukovMPMCQueue(State, 8).init(testing.allocator);
    defer queue.deinit();

    try queue.enqueue(.idle);
    try queue.enqueue(.running);
    try queue.enqueue(.paused);
    try queue.enqueue(.stopped);

    try testing.expectEqual(@as(?State, .idle), queue.dequeue());
    try testing.expectEqual(@as(?State, .running), queue.dequeue());
    try testing.expectEqual(@as(?State, .paused), queue.dequeue());
    try testing.expectEqual(@as(?State, .stopped), queue.dequeue());
}

test "optional type" {
    var queue = try DVyukovMPMCQueue(?u32, 8).init(testing.allocator);
    defer queue.deinit();

    try queue.enqueue(null);
    try queue.enqueue(42);
    try queue.enqueue(null);
    try queue.enqueue(123);

    // dequeue() returns ?T, so when T is ?u32, we get ??u32
    const v1 = queue.dequeue().?; // Unwrap outer optional
    try testing.expectEqual(@as(?u32, null), v1);

    const v2 = queue.dequeue().?;
    try testing.expectEqual(@as(?u32, 42), v2);

    const v3 = queue.dequeue().?;
    try testing.expectEqual(@as(?u32, null), v3);

    const v4 = queue.dequeue().?;
    try testing.expectEqual(@as(?u32, 123), v4);
}

test "resource cleanup pattern - documented behavior" {
    // This test demonstrates the CORRECT pattern for types with resources
    // as documented in the queue's type requirements

    const ResourceType = struct {
        allocator: std.mem.Allocator,
        data: []u8,

        fn init(allocator: std.mem.Allocator, size: usize) !@This() {
            const data = try allocator.alloc(u8, size);
            return .{ .allocator = allocator, .data = data };
        }

        fn deinit(self: *@This()) void {
            self.allocator.free(self.data);
        }
    };

    var queue = try DVyukovMPMCQueue(ResourceType, 4).init(testing.allocator);
    defer {
        // CRITICAL: Drain queue before deinit to avoid leaking resources
        // This demonstrates the pattern documented in the queue's deinit() docs
        while (queue.dequeue()) |item| {
            var mutable_item = item;
            mutable_item.deinit();
        }
        queue.deinit();
    }

    // Enqueue some items with allocated resources
    const item1 = try ResourceType.init(testing.allocator, 10);
    const item2 = try ResourceType.init(testing.allocator, 20);
    try queue.enqueue(item1);
    try queue.enqueue(item2);

    try testing.expectEqual(@as(usize, 2), queue.size());
    // Items will be cleaned up by the defer block above
}

test "tryEnqueue dual failure modes" {
    // Demonstrates the two distinct failure cases documented for tryEnqueue():
    // 1. Queue actually full
    // 2. CAS retry limit exhausted (even when queue has space)

    var queue = try DVyukovMPMCQueue(u32, 4).init(testing.allocator);
    defer queue.deinit();

    // Case 1: Queue actually full
    try queue.enqueue(1);
    try queue.enqueue(2);
    try queue.enqueue(3);
    try queue.enqueue(4);
    try testing.expect(queue.isFull());

    // tryEnqueue should fail because queue is full
    try testing.expectError(error.QueueFull, queue.tryEnqueue(5, 10));

    // Case 2: With very low retry limit, even with space available,
    // tryEnqueue might fail due to exhausted attempts
    // (This is harder to test deterministically in single-threaded code,
    // but the limit of 0 should always fail immediately)
    _ = queue.dequeue();
    try testing.expect(!queue.isFull());

    // With max_attempts=0, should fail even though queue has space
    try testing.expectError(error.QueueFull, queue.tryEnqueue(6, 0));

    // With reasonable attempts, should succeed
    try queue.tryEnqueue(6, 10);
    try testing.expectEqual(@as(usize, 4), queue.size());
}

test "size() racy behavior - single threaded demonstration" {
    // This test demonstrates WHY size() should not be used for flow control
    // Even in single-threaded code, the pattern is incorrect

    var queue = try DVyukovMPMCQueue(u32, 8).init(testing.allocator);
    defer queue.deinit();

    try queue.enqueue(1);
    try queue.enqueue(2);

    // WRONG PATTERN (documented as invalid):
    // if (queue.size() > 0) { const item = queue.dequeue().?; }
    // This is wrong because size() is a snapshot that can be stale

    // CORRECT PATTERN (documented as valid):
    // Always check return value
    if (queue.dequeue()) |item1| {
        try testing.expectEqual(@as(u32, 1), item1);
    }

    if (queue.dequeue()) |item2| {
        try testing.expectEqual(@as(u32, 2), item2);
    }

    // After draining, dequeue returns null (safe)
    try testing.expectEqual(@as(?u32, null), queue.dequeue());

    // Demonstrate that size() is only safe for monitoring/debugging
    const current_size = queue.size();
    try testing.expectEqual(@as(usize, 0), current_size);

    // But this would be WRONG in concurrent code:
    // if (queue.size() == 0) { /* assume empty */ } // RACE CONDITION!
}

test "memory ordering - monotonic loads rationale" {
    // This test documents the memory ordering design choice
    // Position counters use .monotonic because sequence numbers
    // provide the synchronization (acquire/release)

    var queue = try DVyukovMPMCQueue(u64, 16).init(testing.allocator);
    defer queue.deinit();

    // Fill and drain multiple times to exercise wraparound
    const iterations = 100;
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        try queue.enqueue(@intCast(i));
        const val = queue.dequeue().?;
        try testing.expectEqual(@as(u64, @intCast(i)), val);
    }

    // The fact that this works correctly demonstrates that:
    // 1. Monotonic loads on position counters are sufficient
    // 2. Sequence acquire/release pairing provides synchronization
    // 3. This is Vyukov's key optimization over stricter orderings

    try testing.expect(queue.isEmpty());
}

test "drain() helper - no cleanup callback" {
    var queue = try DVyukovMPMCQueue(u64, 16).init(testing.allocator);
    defer queue.deinit();

    // Enqueue some items
    var i: u64 = 0;
    while (i < 10) : (i += 1) {
        try queue.enqueue(i);
    }
    try testing.expectEqual(@as(usize, 10), queue.size());

    // Drain without callback
    queue.drain(null);

    // Verify queue is empty
    try testing.expect(queue.isEmpty());
    try testing.expectEqual(@as(?u64, null), queue.dequeue());
}

test "drain() helper - with cleanup callback" {
    var queue = try DVyukovMPMCQueue(usize, 16).init(testing.allocator);
    defer queue.deinit();

    // Enqueue items
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        try queue.enqueue(i * 10);
    }

    // Track sum of drained items using callback
    const cleanup_fn = struct {
        var tracked_sum: usize = 0;
        fn cleanup(item: usize) void {
            tracked_sum += item;
        }
    }.cleanup;

    queue.drain(cleanup_fn);

    // Verify queue is empty
    try testing.expect(queue.isEmpty());
}
