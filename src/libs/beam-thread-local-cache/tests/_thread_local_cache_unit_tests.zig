//! ThreadLocalCache unit tests.
//! Each scenario calls out the setup and the expected behavior.

const std = @import("std");
const cache_mod = @import("beam-thread-local-cache");

const Item = struct { id: usize };

const RecycleTracker = struct {
    count: usize = 0,
    last_id: ?usize = null,
};

fn recycleCallback(ctx: ?*anyopaque, item: *Item) void {
    if (ctx) |p| {
        const tracker: *RecycleTracker = @ptrCast(@alignCast(p));
        tracker.count += 1;
        tracker.last_id = item.id;
    }
}

// Scenario: Pop on empty cache
//
// Setup: Fresh cache with no prior pushes.
// Expect: `pop()` returns null, `len() == 0`, and `isEmpty() == true`.
test "pop on empty returns null" {
    const Cache = cache_mod.ThreadLocalCache(*Item, null);
    var cache: Cache = .{};
    try std.testing.expect(cache.pop() == null);
    try std.testing.expect(cache.len() == 0);
    try std.testing.expect(cache.isEmpty());
}

// Scenario: LIFO behavior and interleaved push/pop
//
// Setup: Push three items, then pop repeatedly.
// Expect: Items are popped in reverse order, then null, with len tracking.
test "push/pop within capacity and LIFO order" {
    const Cache = cache_mod.ThreadLocalCache(*Item, null);
    var cache: Cache = .{};

    var items: [4]Item = .{ .{ .id = 1 }, .{ .id = 2 }, .{ .id = 3 }, .{ .id = 4 } };

    try std.testing.expect(cache.push(&items[0]));
    try std.testing.expect(cache.push(&items[1]));
    try std.testing.expect(cache.push(&items[2]));
    try std.testing.expectEqual(@as(usize, 3), cache.len());

    // LIFO pops
    try std.testing.expectEqual(@as(?*Item, &items[2]), cache.pop());
    try std.testing.expectEqual(@as(?*Item, &items[1]), cache.pop());
    try std.testing.expectEqual(@as(?*Item, &items[0]), cache.pop());
    try std.testing.expectEqual(@as(usize, 0), cache.len());
    try std.testing.expect(cache.pop() == null);
}

// Scenario: Capacity limit enforcement
//
// Setup: Attempt to push `capacity + 1` items.
// Expect: Exactly `capacity` pushes succeed; additional push returns false and `isFull()`.
test "capacity limit respected" {
    const Cache = cache_mod.ThreadLocalCache(*Item, null);
    var cache: Cache = .{};

    var items: [Cache.capacity + 1]Item = undefined;
    for (&items, 0..) |*it, i| it.* = .{ .id = i };

    // Fill exactly to capacity
    var i: usize = 0;
    while (i < Cache.capacity) : (i += 1) {
        try std.testing.expect(cache.push(&items[i]));
    }
    try std.testing.expect(cache.isFull());

    // One more should fail
    try std.testing.expect(!cache.push(&items[Cache.capacity]));
}

// Scenario: isEmpty/isFull transitions
//
// Setup: Push to capacity, then pop all.
// Expect: isEmpty -> false after first push; isFull at capacity; back to empty after pops.
test "state transitions for isEmpty/isFull" {
    const Cache = cache_mod.ThreadLocalCache(*Item, null);
    var cache: Cache = .{};
    var items: [Cache.capacity]Item = undefined;
    for (&items, 0..) |*it, i| it.* = .{ .id = i };

    try std.testing.expect(cache.isEmpty());
    try std.testing.expect(!cache.isFull());

    try std.testing.expect(cache.push(&items[0]));
    try std.testing.expect(!cache.isEmpty());

    var i: usize = 1;
    while (i < Cache.capacity) : (i += 1) {
        _ = cache.push(&items[i]);
    }
    try std.testing.expect(cache.isFull());

    while (cache.pop() != null) {}
    try std.testing.expect(cache.isEmpty());
}

// Scenario: clear() without a callback
//
// Setup: Push a few items, call clear(null) twice.
// Expect: Cache becomes empty; second clear is idempotent and remains empty.
test "clear without callback simply discards and is idempotent" {
    const Cache = cache_mod.ThreadLocalCache(*Item, null);
    var cache: Cache = .{};
    var items: [3]Item = .{ .{ .id = 1 }, .{ .id = 2 }, .{ .id = 3 } };

    _ = cache.push(&items[0]);
    _ = cache.push(&items[1]);
    _ = cache.push(&items[2]);
    try std.testing.expect(cache.len() == 3);

    cache.clear(null);
    try std.testing.expect(cache.len() == 0);
    try std.testing.expect(cache.isEmpty());

    // Double clear should be safe
    cache.clear(null);
    try std.testing.expect(cache.isEmpty());
}

var null_ctx_hits: usize = 0;
fn recycleCountOnly(_: ?*anyopaque, _: *Item) void {
    null_ctx_hits += 1;
}

// Scenario: clear() with callback drains in LIFO order
//
// Setup: Push two items; clear with a tracker.
// Expect: Callback invoked for each; count==2; last_id is the first pushed (LIFO drain).
test "clear with callback recycles all items in LIFO order" {
    const Cache = cache_mod.ThreadLocalCache(*Item, recycleCallback);
    var cache: Cache = .{};
    var items: [2]Item = .{ .{ .id = 42 }, .{ .id = 77 } };
    var tracker: RecycleTracker = .{};

    _ = cache.push(&items[0]);
    _ = cache.push(&items[1]);
    try std.testing.expect(cache.len() == 2);

    cache.clear(&tracker);

    try std.testing.expect(cache.len() == 0);
    try std.testing.expectEqual(@as(usize, 2), tracker.count);
    // Last recycled will be the first pushed (due to LIFO clear loop)
    try std.testing.expectEqual(@as(?usize, 42), tracker.last_id);
}

// Scenario: partial fill then clear
//
// Setup: Push N < capacity, clear.
// Expect: len reduces from N to 0; no panic; subsequent pushes work.
test "partial fill then clear resets cache" {
    const Cache = cache_mod.ThreadLocalCache(*Item, null);
    var cache: Cache = .{};
    var items: [3]Item = .{ .{ .id = 10 }, .{ .id = 20 }, .{ .id = 30 } };

    try std.testing.expect(cache.push(&items[0]));
    try std.testing.expect(cache.push(&items[1]));
    try std.testing.expectEqual(@as(usize, 2), cache.len());

    cache.clear(null);
    try std.testing.expectEqual(@as(usize, 0), cache.len());

    // Cache should accept pushes again after clear
    try std.testing.expect(cache.push(&items[2]));
    try std.testing.expectEqual(@as(?*Item, &items[2]), cache.pop());
    try std.testing.expect(cache.isEmpty());
}

// Scenario: clear() with callback but null context
//
// Setup: Use cache with callback that increments a global counter even when ctx = null.
// Expect: All cached entries trigger the callback; counter equals number of pushes.
test "clear with callback works without context pointer" {
    const Cache = cache_mod.ThreadLocalCache(*Item, recycleCountOnly);
    var cache: Cache = .{};
    var items: [3]Item = .{ .{ .id = 1 }, .{ .id = 2 }, .{ .id = 3 } };
    null_ctx_hits = 0;

    try std.testing.expect(cache.push(&items[0]));
    try std.testing.expect(cache.push(&items[1]));
    cache.clear(null);

    try std.testing.expectEqual(@as(usize, 2), null_ctx_hits);
    try std.testing.expect(cache.isEmpty());
}

// Scenario: clear() on empty cache does not call callback
//
// Setup: Call clear twice on empty cache using the counting callback.
// Expect: Counter remains zero and cache stays empty.
test "clear on empty cache is a no-op for callbacks" {
    const Cache = cache_mod.ThreadLocalCache(*Item, recycleCountOnly);
    var cache: Cache = .{};
    null_ctx_hits = 0;

    cache.clear(null);
    cache.clear(null);

    try std.testing.expectEqual(@as(usize, 0), null_ctx_hits);
    try std.testing.expect(cache.isEmpty());
}
