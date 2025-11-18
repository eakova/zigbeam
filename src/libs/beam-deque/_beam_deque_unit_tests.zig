const std = @import("std");
const testing = std.testing;
const BeamDeque = @import("beam_deque.zig").BeamDeque;

// =============================================================================
// Single-Threaded Correctness Tests
// =============================================================================

test "BeamDeque: init with valid capacity" {
    var result = try BeamDeque(u32).init(testing.allocator, 16);
    defer result.worker.deinit();

    try testing.expectEqual(@as(usize, 0), result.worker.size());
    try testing.expect(result.worker.isEmpty());
    try testing.expectEqual(@as(usize, 16), result.worker.capacity());
}

test "BeamDeque: init rejects non-power-of-two capacity" {
    try testing.expectError(error.CapacityNotPowerOfTwo, BeamDeque(u32).init(testing.allocator, 15));
    try testing.expectError(error.CapacityNotPowerOfTwo, BeamDeque(u32).init(testing.allocator, 17));
    try testing.expectError(error.CapacityNotPowerOfTwo, BeamDeque(u32).init(testing.allocator, 100));
}

test "BeamDeque: basic push and pop (LIFO)" {
    var result = try BeamDeque(u32).init(testing.allocator, 8);
    defer result.worker.deinit();

    // Push three items
    try result.worker.push(1);
    try result.worker.push(2);
    try result.worker.push(3);

    try testing.expectEqual(@as(usize, 3), result.worker.size());

    // Pop returns LIFO order (last in, first out)
    try testing.expectEqual(@as(?u32, 3), result.worker.pop());
    try testing.expectEqual(@as(?u32, 2), result.worker.pop());
    try testing.expectEqual(@as(?u32, 1), result.worker.pop());
    try testing.expectEqual(@as(?u32, null), result.worker.pop());
}

test "BeamDeque: basic steal (FIFO)" {
    var result = try BeamDeque(u32).init(testing.allocator, 8);
    defer result.worker.deinit();

    // Push three items
    try result.worker.push(1);
    try result.worker.push(2);
    try result.worker.push(3);

    // Steal returns FIFO order (first in, first out)
    try testing.expectEqual(@as(?u32, 1), result.stealer.steal());
    try testing.expectEqual(@as(?u32, 2), result.stealer.steal());
    try testing.expectEqual(@as(?u32, 3), result.stealer.steal());
    try testing.expectEqual(@as(?u32, null), result.stealer.steal());
}

test "BeamDeque: mixed pop and steal" {
    var result = try BeamDeque(u32).init(testing.allocator, 8);
    defer result.worker.deinit();

    // Push five items
    try result.worker.push(1);
    try result.worker.push(2);
    try result.worker.push(3);
    try result.worker.push(4);
    try result.worker.push(5);

    // Steal takes from head (oldest)
    try testing.expectEqual(@as(?u32, 1), result.stealer.steal());
    try testing.expectEqual(@as(?u32, 2), result.stealer.steal());

    // Pop takes from tail (newest)
    try testing.expectEqual(@as(?u32, 5), result.worker.pop());
    try testing.expectEqual(@as(?u32, 4), result.worker.pop());

    // One item left
    try testing.expectEqual(@as(usize, 1), result.worker.size());
    try testing.expectEqual(@as(?u32, 3), result.worker.pop());
}

test "BeamDeque: capacity enforcement (error.Full)" {
    var result = try BeamDeque(u32).init(testing.allocator, 4);
    defer result.worker.deinit();

    // Fill to capacity
    try result.worker.push(1);
    try result.worker.push(2);
    try result.worker.push(3);
    try result.worker.push(4);

    // Next push should fail
    try testing.expectError(error.Full, result.worker.push(5));

    // After pop, can push again
    _ = result.worker.pop();
    try result.worker.push(5);

    try testing.expectEqual(@as(usize, 4), result.worker.size());
}

test "BeamDeque: empty pop returns null" {
    var result = try BeamDeque(u32).init(testing.allocator, 8);
    defer result.worker.deinit();

    try testing.expectEqual(@as(?u32, null), result.worker.pop());
    try testing.expectEqual(@as(?u32, null), result.worker.pop());
}

test "BeamDeque: empty steal returns null" {
    var result = try BeamDeque(u32).init(testing.allocator, 8);
    defer result.worker.deinit();

    try testing.expectEqual(@as(?u32, null), result.stealer.steal());
    try testing.expectEqual(@as(?u32, null), result.stealer.steal());
}

test "BeamDeque: wraparound behavior" {
    var result = try BeamDeque(u32).init(testing.allocator, 4);
    defer result.worker.deinit();

    // Fill, drain, refill multiple times to test wraparound
    var iteration: u32 = 0;
    while (iteration < 10) : (iteration += 1) {
        const base = iteration * 4;

        // Fill
        try result.worker.push(base + 1);
        try result.worker.push(base + 2);
        try result.worker.push(base + 3);
        try result.worker.push(base + 4);

        // Drain
        try testing.expectEqual(@as(?u32, base + 4), result.worker.pop());
        try testing.expectEqual(@as(?u32, base + 3), result.worker.pop());
        try testing.expectEqual(@as(?u32, base + 2), result.worker.pop());
        try testing.expectEqual(@as(?u32, base + 1), result.worker.pop());
    }
}

test "BeamDeque: single item race simulation (owner wins)" {
    var result = try BeamDeque(u32).init(testing.allocator, 8);
    defer result.worker.deinit();

    // Push one item
    try result.worker.push(42);

    // Owner pops (should succeed in single-threaded)
    try testing.expectEqual(@as(?u32, 42), result.worker.pop());

    // Stealer tries to steal from empty deque
    try testing.expectEqual(@as(?u32, null), result.stealer.steal());
}

test "BeamDeque: works with different types" {
    // Test with struct
    const Task = struct {
        id: u64,
        priority: u8,
    };

    var result = try BeamDeque(Task).init(testing.allocator, 8);
    defer result.worker.deinit();

    const task1 = Task{ .id = 1, .priority = 10 };
    const task2 = Task{ .id = 2, .priority = 20 };

    try result.worker.push(task1);
    try result.worker.push(task2);

    const popped = result.worker.pop().?;
    try testing.expectEqual(@as(u64, 2), popped.id);
    try testing.expectEqual(@as(u8, 20), popped.priority);

    const stolen = result.stealer.steal().?;
    try testing.expectEqual(@as(u64, 1), stolen.id);
    try testing.expectEqual(@as(u8, 10), stolen.priority);
}

test "BeamDeque: size tracking" {
    var result = try BeamDeque(u32).init(testing.allocator, 16);
    defer result.worker.deinit();

    try testing.expectEqual(@as(usize, 0), result.worker.size());

    try result.worker.push(1);
    try testing.expectEqual(@as(usize, 1), result.worker.size());

    try result.worker.push(2);
    try result.worker.push(3);
    try testing.expectEqual(@as(usize, 3), result.worker.size());

    _ = result.worker.pop();
    try testing.expectEqual(@as(usize, 2), result.worker.size());

    _ = result.stealer.steal();
    try testing.expectEqual(@as(usize, 1), result.worker.size());

    _ = result.worker.pop();
    try testing.expectEqual(@as(usize, 0), result.worker.size());
    try testing.expect(result.worker.isEmpty());
}

test "BeamDeque: large capacity" {
    var result = try BeamDeque(u64).init(testing.allocator, 1024);
    defer result.worker.deinit();

    // Fill halfway
    var i: u64 = 0;
    while (i < 512) : (i += 1) {
        try result.worker.push(i);
    }

    try testing.expectEqual(@as(usize, 512), result.worker.size());

    // Verify LIFO order on pop
    var expected: u64 = 511;
    while (expected >= 256) : (expected -= 1) {
        const val = result.worker.pop().?;
        try testing.expectEqual(expected, val);
    }

    // Verify FIFO order on steal
    expected = 0;
    while (expected < 256) : (expected += 1) {
        const val = result.stealer.steal().?;
        try testing.expectEqual(expected, val);
    }

    try testing.expect(result.worker.isEmpty());
}
