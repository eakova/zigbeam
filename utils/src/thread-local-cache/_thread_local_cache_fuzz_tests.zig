const std = @import("std");
const cache_mod = @import("thread_local_cache.zig");

// Fuzzing the ThreadLocalCache by applying random sequences of push/pop/clear
// operations and checking invariants against a reference model.
//
// Invariants checked per step:
// - 0 <= model_len <= capacity
// - cache.len() == model_len
// - cache.isEmpty() == (model_len == 0)
// - cache.isFull() == (model_len == capacity)
// - pop() returns null iff model_len == 0; otherwise returns the last pushed item (LIFO)
// - clear(null) resets model_len to 0
// - clear(&tracker) resets model_len to 0 and increments tracker by number of cleared items

const Item = struct { id: usize };

const RecycleTracker = struct {
    count: usize = 0,
};

fn recycleFuzz(ctx: ?*anyopaque, _: *Item) void {
    if (ctx) |p| {
        const tracker: *RecycleTracker = @ptrCast(@alignCast(p));
        tracker.count += 1;
    }
}

const Cache = cache_mod.ThreadLocalCache(*Item, recycleFuzz);

const Context = struct {
    fn testOne(_: @This(), input: []const u8) !void {
        var cache: Cache = .{};
        var tracker: RecycleTracker = .{};

        // Reference model: simple LIFO stack of pointers pushed so far.
        var model: [Cache.capacity]?*Item = [_]?*Item{null} ** Cache.capacity;
        var model_len: usize = 0;

        // Static items we can reference with pointers; avoids allocator noise.
        var items: [16]Item = undefined;
        for (&items, 0..) |*it, i| it.* = .{ .id = i };

        var i: usize = 0;
        while (i < input.len) : (i += 1) {
            const b = input[i];
            const op = b & 0x03; // 0: push, 1: pop, 2: clear(null), 3: clear(&tracker)

            switch (op) {
                0 => { // push
                    const idx = (b >> 2) % items.len;
                    const ptr = &items[idx];
                    const ok = cache.push(ptr);
                    if (ok) {
                        if (model_len < Cache.capacity) {
                            model[model_len] = ptr;
                            model_len += 1;
                        } else {
                            // If push returned true, capacity must have allowed it.
                            return error.CacheModelOverflow;
                        }
                    } else {
                        // If push failed, model must already be at capacity.
                        if (model_len != Cache.capacity) return error.CacheModelUnderfullReject;
                    }
                },
                1 => { // pop
                    const got = cache.pop();
                    if (model_len == 0) {
                        if (got != null) return error.CachePoppedWhenEmpty;
                    } else {
                        model_len -= 1;
                        const expected = model[model_len].?;
                        if (got != expected) return error.CachePopMismatch;
                        model[model_len] = null;
                    }
                },
                2 => { // clear without callback
                    cache.clear(null);
                    // No callback => tracker unchanged; model reset
                    model_len = 0;
                    for (model[0..]) |*slot| slot.* = null;
                },
                3 => { // clear with callback (counts items)
                    const before = tracker.count;
                    cache.clear(&tracker);
                    // Tracker should increase by exactly model_len
                    const after = tracker.count;
                    if (after - before != model_len) return error.CacheClearCountMismatch;
                    // Reset model
                    model_len = 0;
                    for (model[0..]) |*slot| slot.* = null;
                },
                else => unreachable,
            }

            // Cross-check observable state against model
            if (cache.len() != model_len) return error.CacheLenMismatch;
            if (cache.isEmpty() != (model_len == 0)) return error.CacheEmptyMismatch;
            if (cache.isFull() != (model_len == Cache.capacity)) return error.CacheFullMismatch;
        }
    }
};

test "fuzz: random op sequences preserve cache invariants" {
    try std.testing.fuzz(Context{}, Context.testOne, .{});
}

