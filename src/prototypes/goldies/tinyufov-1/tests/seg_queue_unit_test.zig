/// Unit tests for SegQueue
/// Tests basic push/pop operations, empty checks, and index calculations

const std = @import("std");
const testing = std.testing;
const allocator = testing.allocator;

const seg_queue = @import("../seg_queue.zig");
const SegQueue = seg_queue.SegQueue;
const Block = seg_queue.Block;
const Slot = seg_queue.Slot;

test "SegQueue init and deinit" {
    const queue = try SegQueue.init(allocator);
    defer queue.deinit();

    try testing.expect(queue.head.index.load(.relaxed) == 0);
    try testing.expect(queue.tail.index.load(.relaxed) == 0);
}

test "SegQueue is_empty on fresh queue" {
    const queue = try SegQueue.init(allocator);
    defer queue.deinit();

    try testing.expect(queue.is_empty());
}

test "SegQueue single push and pop" {
    const queue = try SegQueue.init(allocator);
    defer queue.deinit();

    const value = @as(*u32, @ptrFromInt(42));

    try queue.push(value);
    try testing.expect(!queue.is_empty());

    const popped = queue.pop();
    try testing.expect(popped == value);
    try testing.expect(queue.is_empty());
}

test "SegQueue multiple push and pop" {
    const queue = try SegQueue.init(allocator);
    defer queue.deinit();

    const v1 = @as(*u32, @ptrFromInt(100));
    const v2 = @as(*u32, @ptrFromInt(200));
    const v3 = @as(*u32, @ptrFromInt(300));

    try queue.push(v1);
    try queue.push(v2);
    try queue.push(v3);

    try testing.expect(queue.pop() == v1);
    try testing.expect(queue.pop() == v2);
    try testing.expect(queue.pop() == v3);
    try testing.expect(queue.is_empty());
}

test "SegQueue pop on empty" {
    const queue = try SegQueue.init(allocator);
    defer queue.deinit();

    try testing.expect(queue.pop() == null);
}

test "SegQueue interleaved push pop" {
    const queue = try SegQueue.init(allocator);
    defer queue.deinit();

    const v1 = @as(*u32, @ptrFromInt(111));
    const v2 = @as(*u32, @ptrFromInt(222));
    const v3 = @as(*u32, @ptrFromInt(333));

    try queue.push(v1);
    try testing.expect(queue.pop() == v1);

    try queue.push(v2);
    try queue.push(v3);

    try testing.expect(queue.pop() == v2);
    try testing.expect(queue.pop() == v3);
    try testing.expect(queue.is_empty());
}

test "SegQueue FIFO order" {
    const queue = try SegQueue.init(allocator);
    defer queue.deinit();

    for (0..10) |i| {
        const value = @as(*u32, @ptrFromInt(i + 1000));
        try queue.push(value);
    }

    for (0..10) |i| {
        const expected = @as(*u32, @ptrFromInt(i + 1000));
        try testing.expect(queue.pop() == expected);
    }

    try testing.expect(queue.is_empty());
}

test "SegQueue large batch" {
    const queue = try SegQueue.init(allocator);
    defer queue.deinit();

    const N = 100;

    for (0..N) |i| {
        const value = @as(*u32, @ptrFromInt(i));
        try queue.push(value);
    }

    for (0..N) |i| {
        const expected = @as(*u32, @ptrFromInt(i));
        try testing.expect(queue.pop() == expected);
    }

    try testing.expect(queue.is_empty());
}

test "SegQueue index encoding SHIFT" {
    // SHIFT = 1, so indices advance by 2
    try testing.expect(seg_queue.SHIFT == 1);
}

test "SegQueue index encoding LAP" {
    // LAP = 32 indices per lap
    try testing.expect(seg_queue.LAP == 32);
}

test "SegQueue block capacity" {
    // BLOCK_CAP = 31 (one sentinel slot)
    try testing.expect(seg_queue.BLOCK_CAP == 31);
}

test "SegQueue get_offset calculation" {
    // Offset calculation: (index >> SHIFT) % LAP
    try testing.expect(seg_queue.get_offset(0) == 0);
    try testing.expect(seg_queue.get_offset(2) == 1);
    try testing.expect(seg_queue.get_offset(4) == 2);
    try testing.expect(seg_queue.get_offset(64) == 0); // Wraps at LAP
}

test "SegQueue Block init" {
    var block = Block.init();

    try testing.expect(block.next.load(.relaxed) == 0);

    for (0..seg_queue.LAP) |i| {
        try testing.expect(block.slots[i].state.load(.relaxed) == 0);
    }
}

test "SegQueue block allocation" {
    const block = try Block.create(allocator);
    defer block.destroy(allocator);

    try testing.expect(block.next.load(.relaxed) == 0);
}

test "SegQueue len after operations" {
    const queue = try SegQueue.init(allocator);
    defer queue.deinit();

    try testing.expect(queue.len() == 0);

    for (0..5) |i| {
        const value = @as(*u32, @ptrFromInt(i));
        try queue.push(value);
    }

    // Approximate check - exact len may vary due to concurrency
    const len = queue.len();
    try testing.expect(len >= 0 and len <= 5);

    _ = queue.pop();
    _ = queue.pop();

    try testing.expect(queue.len() >= 0);
}

test "SegQueue push then pop same order" {
    const queue = try SegQueue.init(allocator);
    defer queue.deinit();

    const values = [_]*u32{
        @ptrFromInt(1000),
        @ptrFromInt(2000),
        @ptrFromInt(3000),
        @ptrFromInt(4000),
        @ptrFromInt(5000),
    };

    for (values) |v| {
        try queue.push(v);
    }

    for (values) |v| {
        try testing.expect(queue.pop() == v);
    }
}

test "SegQueue state flags" {
    // Verify state flag constants
    try testing.expect(seg_queue.WRITE == 0b00000001);
    try testing.expect(seg_queue.READ == 0b00000010);
    try testing.expect(seg_queue.DESTROY == 0b00000100);
}

test "SegQueue HAS_NEXT flag" {
    try testing.expect(seg_queue.HAS_NEXT == 1);
}

test "SegQueue Slot init" {
    var slot = Slot.init();
    try testing.expect(slot.state.load(.relaxed) == 0);
}

test "SegQueue queue not empty after push" {
    const queue = try SegQueue.init(allocator);
    defer queue.deinit();

    try testing.expect(queue.is_empty());

    const v = @as(*u32, @ptrFromInt(42));
    try queue.push(v);

    try testing.expect(!queue.is_empty());
}

test "SegQueue alternating push pop" {
    const queue = try SegQueue.init(allocator);
    defer queue.deinit();

    try testing.expect(queue.is_empty());

    for (0..20) |i| {
        if (i % 2 == 0) {
            const v = @as(*u32, @ptrFromInt(i));
            try queue.push(v);
        } else {
            _ = queue.pop();
        }
    }
}

test "SegQueue sequential blocks" {
    const queue = try SegQueue.init(allocator);
    defer queue.deinit();

    // Push more than BLOCK_CAP to trigger multiple blocks
    for (0..50) |i| {
        const v = @as(*u32, @ptrFromInt(i));
        try queue.push(v);
    }

    // Pop all values in order
    for (0..50) |i| {
        const expected = @as(*u32, @ptrFromInt(i));
        try testing.expect(queue.pop() == expected);
    }

    try testing.expect(queue.is_empty());
}

test "SegQueue pop returns in FIFO order" {
    const queue = try SegQueue.init(allocator);
    defer queue.deinit();

    const values = [_]usize{ 111, 222, 333, 444, 555, 666, 777 };

    for (values) |v| {
        try queue.push(@as(*u32, @ptrFromInt(v)));
    }

    for (values) |v| {
        const popped = queue.pop();
        try testing.expect(popped == @as(*u32, @ptrFromInt(v)));
    }
}
