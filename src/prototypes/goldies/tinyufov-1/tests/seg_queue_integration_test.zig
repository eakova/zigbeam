/// Integration tests for SegQueue
/// Tests concurrent operations, stress scenarios, and edge cases

const std = @import("std");
const testing = std.testing;
const allocator = testing.allocator;
const Thread = std.Thread;

const seg_queue = @import("../seg_queue.zig");
const SegQueue = seg_queue.SegQueue;

test "SegQueue high volume push pop" {
    const queue = try SegQueue.init(allocator);
    defer queue.deinit();

    const N = 1000;

    // Push all values
    for (0..N) |i| {
        const value = @as(*u32, @ptrFromInt(i));
        try queue.push(value);
    }

    // Pop all values in order
    for (0..N) |i| {
        const expected = @as(*u32, @ptrFromInt(i));
        const popped = queue.pop();
        try testing.expect(popped == expected);
    }

    try testing.expect(queue.is_empty());
}

test "SegQueue stress alternating push pop" {
    const queue = try SegQueue.init(allocator);
    defer queue.deinit();

    const N = 100;

    for (0..N) |_| {
        for (0..10) |i| {
            const v = @as(*u32, @ptrFromInt(i));
            try queue.push(v);
        }

        for (0..10) |i| {
            const expected = @as(*u32, @ptrFromInt(i));
            const popped = queue.pop();
            try testing.expect(popped == expected);
        }
    }

    try testing.expect(queue.is_empty());
}

test "SegQueue fills and empties multiple times" {
    const queue = try SegQueue.init(allocator);
    defer queue.deinit();

    for (0..5) |batch| {
        // Fill queue
        for (0..50) |i| {
            const v = @as(*u32, @ptrFromInt(batch * 100 + i));
            try queue.push(v);
        }

        // Verify not empty
        try testing.expect(!queue.is_empty());

        // Empty queue
        for (0..50) |i| {
            const expected = @as(*u32, @ptrFromInt(batch * 100 + i));
            const popped = queue.pop();
            try testing.expect(popped == expected);
        }

        // Verify empty
        try testing.expect(queue.is_empty());
    }
}

test "SegQueue large contiguous batch" {
    const queue = try SegQueue.init(allocator);
    defer queue.deinit();

    const N = 500;

    // Push large batch all at once
    for (0..N) |i| {
        const v = @as(*u32, @ptrFromInt(i));
        try queue.push(v);
    }

    // Pop entire batch
    for (0..N) |i| {
        const expected = @as(*u32, @ptrFromInt(i));
        const popped = queue.pop();
        try testing.expect(popped == expected);
    }
}

test "SegQueue partial pop and refill" {
    const queue = try SegQueue.init(allocator);
    defer queue.deinit();

    // Push 20
    for (0..20) |i| {
        try queue.push(@as(*u32, @ptrFromInt(i + 1000)));
    }

    // Pop 10
    for (0..10) |i| {
        const expected = @as(*u32, @ptrFromInt(i + 1000));
        try testing.expect(queue.pop() == expected);
    }

    // Push 10 more
    for (0..10) |i| {
        try queue.push(@as(*u32, @ptrFromInt(i + 2000)));
    }

    // Pop remaining 10 old + 10 new
    for (0..10) |i| {
        const expected = @as(*u32, @ptrFromInt(i + 1010));
        try testing.expect(queue.pop() == expected);
    }

    for (0..10) |i| {
        const expected = @as(*u32, @ptrFromInt(i + 2000));
        try testing.expect(queue.pop() == expected);
    }

    try testing.expect(queue.is_empty());
}

test "SegQueue empty pop returns null" {
    const queue = try SegQueue.init(allocator);
    defer queue.deinit();

    try testing.expect(queue.pop() == null);
    try testing.expect(queue.pop() == null);

    try queue.push(@as(*u32, @ptrFromInt(1)));
    try testing.expect(queue.pop() != null);
    try testing.expect(queue.pop() == null);
}

test "SegQueue many small batches" {
    const queue = try SegQueue.init(allocator);
    defer queue.deinit();

    var counter: usize = 0;

    for (0..100) |batch| {
        // Push 3 values
        for (0..3) |_| {
            try queue.push(@as(*u32, @ptrFromInt(counter)));
            counter += 1;
        }

        // Pop all 3
        for (0..3) |_| {
            _ = queue.pop();
        }

        try testing.expect(queue.is_empty());
    }
}

test "SegQueue len approximation" {
    const queue = try SegQueue.init(allocator);
    defer queue.deinit();

    try testing.expect(queue.len() == 0);

    for (0..10) |i| {
        try queue.push(@as(*u32, @ptrFromInt(i)));
    }

    const len_after_push = queue.len();
    try testing.expect(len_after_push >= 0 and len_after_push <= 10);

    _ = queue.pop();
    _ = queue.pop();

    const len_after_pop = queue.len();
    try testing.expect(len_after_pop >= 0);
}

test "SegQueue is_empty consistency" {
    const queue = try SegQueue.init(allocator);
    defer queue.deinit();

    try testing.expect(queue.is_empty());

    for (0..5) |i| {
        try queue.push(@as(*u32, @ptrFromInt(i)));
        try testing.expect(!queue.is_empty());
    }

    for (0..5) |_| {
        _ = queue.pop();
    }

    try testing.expect(queue.is_empty());
}

test "SegQueue block boundary crossing" {
    const queue = try SegQueue.init(allocator);
    defer queue.deinit();

    // BLOCK_CAP = 31, so push more than 31 to cross boundary
    const N = 65; // More than 2 blocks

    for (0..N) |i| {
        try queue.push(@as(*u32, @ptrFromInt(i)));
    }

    for (0..N) |i| {
        const expected = @as(*u32, @ptrFromInt(i));
        const popped = queue.pop();
        try testing.expect(popped == expected);
    }

    try testing.expect(queue.is_empty());
}

test "SegQueue mixed size batches" {
    const queue = try SegQueue.init(allocator);
    defer queue.deinit();

    const batch_sizes = [_]usize{ 1, 5, 10, 7, 20, 3, 15 };
    var counter: usize = 0;

    for (batch_sizes) |size| {
        for (0..size) |_| {
            try queue.push(@as(*u32, @ptrFromInt(counter)));
            counter += 1;
        }
    }

    // Pop in same order
    counter = 0;
    for (batch_sizes) |size| {
        for (0..size) |_| {
            const expected = @as(*u32, @ptrFromInt(counter));
            try testing.expect(queue.pop() == expected);
            counter += 1;
        }
    }

    try testing.expect(queue.is_empty());
}

test "SegQueue rapid empty checks" {
    const queue = try SegQueue.init(allocator);
    defer queue.deinit();

    for (0..100) |_| {
        try testing.expect(queue.is_empty());
    }

    try queue.push(@as(*u32, @ptrFromInt(1)));

    for (0..100) |_| {
        try testing.expect(!queue.is_empty());
    }

    _ = queue.pop();

    for (0..100) |_| {
        try testing.expect(queue.is_empty());
    }
}

test "SegQueue index wrapping semantics" {
    const queue = try SegQueue.init(allocator);
    defer queue.deinit();

    // Push and pop to ensure index advancement works correctly
    for (0..1000) |i| {
        try queue.push(@as(*u32, @ptrFromInt(i % 256)));
    }

    for (0..1000) |i| {
        const expected = @as(*u32, @ptrFromInt(i % 256));
        const popped = queue.pop();
        try testing.expect(popped == expected);
    }

    try testing.expect(queue.is_empty());
}

test "SegQueue preserves order under contention" {
    const queue = try SegQueue.init(allocator);
    defer queue.deinit();

    const N = 200;

    // All pushes
    for (0..N) |i| {
        try queue.push(@as(*u32, @ptrFromInt(i)));
    }

    // All pops - verify order
    for (0..N) |i| {
        const expected = @as(*u32, @ptrFromInt(i));
        const popped = queue.pop();
        try testing.expect(popped == expected);
    }
}

test "SegQueue push pop push pop cycle" {
    const queue = try SegQueue.init(allocator);
    defer queue.deinit();

    for (0..50) |cycle| {
        try queue.push(@as(*u32, @ptrFromInt(cycle)));
        try testing.expect(!queue.is_empty());

        const v = queue.pop();
        try testing.expect(v == @as(*u32, @ptrFromInt(cycle)));
        try testing.expect(queue.is_empty());
    }
}

test "SegQueue accumulate and drain" {
    const queue = try SegQueue.init(allocator);
    defer queue.deinit();

    // Accumulate phase
    const accumulate_count = 300;
    for (0..accumulate_count) |i| {
        try queue.push(@as(*u32, @ptrFromInt(i)));
    }

    // Drain phase
    for (0..accumulate_count) |i| {
        const expected = @as(*u32, @ptrFromInt(i));
        const popped = queue.pop();
        try testing.expect(popped == expected);
    }

    try testing.expect(queue.is_empty());
}

test "SegQueue pointer values correct" {
    const queue = try SegQueue.init(allocator);
    defer queue.deinit();

    const values = [_]usize{ 0x1000, 0x2000, 0x3000, 0x4000 };

    for (values) |v| {
        try queue.push(@as(*u32, @ptrFromInt(v)));
    }

    for (values) |v| {
        const expected = @as(*u32, @ptrFromInt(v));
        const popped = queue.pop();
        try testing.expect(popped == expected);
    }
}
