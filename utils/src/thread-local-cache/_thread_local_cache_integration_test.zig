const std = @import("std");
const cache_mod = @import("thread_local_cache.zig");

const Obj = struct { id: usize };

const Stats = struct { recycled: usize = 0 };

fn recycle(ctx: ?*anyopaque, ptr: *Obj) void {
    _ = ptr; // not used further in this smoke test
    if (ctx) |p| {
        const s: *Stats = @ptrCast(@alignCast(p));
        s.recycled += 1;
    }
}

// Scenario: Single-thread capacity and drain
//
// Setup: Push up to capacity, verify overflow fails, then clear.
// Expect: Exactly `capacity` pushes succeed; `clear` drains all via callback.
test "smoke: push beyond capacity, then clear drains" {
    var cache: Cache = .{};
    var stats: Stats = .{};

    var objs: [16]Obj = undefined;
    for (&objs, 0..) |*o, i| o.* = .{ .id = i };

    var pushes: usize = 0;
    for (&objs) |*o| {
        if (cache.push(o)) pushes += 1;
    }
    try std.testing.expectEqual(Cache.capacity, pushes);
    try std.testing.expect(cache.isFull());

    cache.clear(&stats);
    try std.testing.expectEqual(@as(usize, Cache.capacity), stats.recycled);
    try std.testing.expect(cache.isEmpty());
}

const Cache = cache_mod.ThreadLocalCache(*Obj, recycle);
threadlocal var tls_cache: Cache = .{};

const AtomicUsize = std.atomic.Value(usize);

fn recycleAtomic(ctx: ?*anyopaque, ptr: *Obj) void {
    _ = ptr;
    if (ctx) |p| {
        const counter: *AtomicUsize = @ptrCast(@alignCast(p));
        _ = counter.fetchAdd(1, .seq_cst);
    }
}

const CacheAtomic = cache_mod.ThreadLocalCache(*Obj, recycleAtomic);
threadlocal var tls_cache_atomic: CacheAtomic = .{};

fn workerThread(ctx: *anyopaque) void {
    const recycled: *AtomicUsize = @ptrCast(@alignCast(ctx));

    // Prepare some local objects to push.
    var objs: [32]Obj = undefined;
    for (&objs, 0..) |*o, i| o.* = .{ .id = i };

    // Fill per-thread L1 cache; overflow pushes do nothing.
    for (&objs) |*o| {
        _ = tls_cache_atomic.push(o);
    }

    // Drain per-thread cache to shared counter via callback.
    tls_cache_atomic.clear(recycled);
}

// Scenario: Per-thread isolation and drain via callback
//
// Setup: Spawn N threads, each using a `threadlocal` cache to push many items.
// Expect: Each thread caches up to `capacity`; total recycled == N * capacity after clear.
test "multithreaded: per-thread caches drain independently" {
    var recycled = AtomicUsize.init(0);

    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, workerThread, .{&recycled});
    }
    for (&threads) |*t| t.join();

    // The recycle callback increments the shared atomic once per recycled ptr.
    const total = recycled.load(.seq_cst);
    try std.testing.expectEqual(@as(usize, 4 * Cache.capacity), total);
}

fn workerOverflow(ctx: *anyopaque) void {
    const success_counter: *AtomicUsize = @ptrCast(@alignCast(ctx));

    var objs: [128]Obj = undefined;
    for (&objs, 0..) |*o, i| o.* = .{ .id = i };

    var local_success: usize = 0;
    for (&objs) |*o| {
        if (tls_cache_atomic.push(o)) local_success += 1;
    }
    // Report successes and drain
    _ = success_counter.fetchAdd(local_success, .seq_cst);
    tls_cache_atomic.clear(null);
}

// Scenario: Overflow under load across threads
//
// Setup: Each thread attempts to push far more than capacity.
// Expect: Exactly `threads * capacity` pushes succeed in total; `clear(null)` empties per-thread caches.
test "multithreaded: overflow pushes limited to per-thread capacity" {
    var successes = AtomicUsize.init(0);

    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, workerOverflow, .{&successes});
    }
    for (&threads) |*t| t.join();

    const total_success = successes.load(.seq_cst);
    try std.testing.expectEqual(@as(usize, 4 * Cache.capacity), total_success);
}
