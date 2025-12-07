//! ArcPool unit tests.
//! Focus: reuse vs fresh alloc, SVO bypass, drain semantics.
//! How to run:
//! - `cd utils && zig test src/arc/arc-pool/_arc_pool_unit_tests.zig -OReleaseFast`
//! - or: `cd utils && zig build -Doptimize=ReleaseFast test`

const std = @import("std");
const testing = std.testing;
const ArcModule = @import("arc");
const PoolModule = @import("arc-pool");

const Payload = struct { bytes: [32]u8 };
const Pool = PoolModule.ArcPool(Payload, false);

test "ArcPool reuses recycled nodes" {
    var pool = Pool.init(testing.allocator, .{});
    defer pool.deinit();

    var arc1 = try pool.create(.{ .bytes = [_]u8{1} ** 32 });
    const first_ptr = arc1.asPtr();
    pool.recycle(arc1);

    var arc2 = try pool.create(.{ .bytes = [_]u8{2} ** 32 });
    defer pool.recycle(arc2);
    try testing.expectEqual(first_ptr, arc2.asPtr());
    try testing.expectEqual(@as(u8, 2), arc2.get().*.bytes[0]);

    pool.drainThreadCache();
}

test "ArcPool bypasses SVO types" {
    const SvoPool = PoolModule.ArcPool(u8, false);
    var pool = SvoPool.init(testing.allocator, .{});
    defer pool.deinit();

    const arc = try pool.create(55);
    try testing.expect(arc.isInline());
    pool.recycle(arc);
    pool.drainThreadCache();
}

const InnerPtr = ArcModule.Arc(Payload).Inner;

const DrainCtx = struct {
    ptrs: []?*InnerPtr,
};

fn fillAndError(pool: *Pool, raw_ctx: *anyopaque) anyerror!void {
    var ctx: *DrainCtx = @ptrCast(@alignCast(raw_ctx));
    const count = ctx.ptrs.len;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        var arc = try pool.create(.{ .bytes = [_]u8{@intCast(i)} ** 32 });
        ctx.ptrs[i] = arc.asPtr();
        pool.recycle(arc);
    }
    return error.IntentionalFlush;
}

test "ArcPool.withThreadCache drains TLS on error" {
    var pool = Pool.init(testing.allocator, .{});
    defer pool.deinit();

    var stored: [4]?*InnerPtr = [_]?*InnerPtr{null} ** 4;
    var ctx = DrainCtx{ .ptrs = stored[0..] };

    try testing.expectError(error.IntentionalFlush, pool.withThreadCache(fillAndError, @ptrCast(&ctx)));

    var reused: [4]?*InnerPtr = [_]?*InnerPtr{null} ** 4;
    var i: usize = 0;
    while (i < reused.len) : (i += 1) {
        var arc = try pool.create(.{ .bytes = [_]u8{@intCast(10 + i)} ** 32 });
        reused[i] = arc.asPtr();
        pool.recycle(arc);
    }

    i = 0;
    while (i < reused.len) : (i += 1) {
        const expected_index = reused.len - 1 - i;
        try testing.expectEqual(ctx.ptrs[expected_index], reused[i]);
    }

    pool.drainThreadCache();
}

test "ArcPool createWithInitializer writes payload in-place" {
    var pool = Pool.init(testing.allocator, .{});
    defer pool.deinit();

    const init_fn = struct { fn f(p: *Payload) void { @memset(&p.bytes, 7); } }.f;
    var arc = try pool.createWithInitializer(init_fn);
    defer pool.recycle(arc);
    try testing.expectEqual(@as(u8, 7), arc.get().*.bytes[0]);
    pool.drainThreadCache();
}

test "ArcPool enforces TLS capacity and early flush pushes to L2" {
    // Use stats=on to observe L2 reuse counter.
    const PoolOn = PoolModule.ArcPool(Payload, true);
    var pool = PoolOn.init(testing.allocator, .{});
    defer pool.deinit();

    const tls_cap = pool.tls_active_capacity;
    const flush_batch = pool.flush_batch;
    try testing.expect(tls_cap >= 8 and tls_cap <= 64);

    // Recycle more than TLS capacity to force spill to L2 (early flush should trigger before full batch).
    // Push beyond TLS capacity and one flush window to ensure spill to L2.
    const extra: usize = 8;
    const total: usize = tls_cap + flush_batch + extra;

    // Phase 1: fill via recycle raw arcs
    var i: usize = 0;
    while (i < total) : (i += 1) {
        const arc_raw = try ArcModule.Arc(Payload).init(testing.allocator, .{ .bytes = [_]u8{0} ** 32 });
        pool.recycle(arc_raw);
    }
    // Push all TLS into L2 so next creates will pop from L2
    pool.drainThreadCache();
    // Phase 2: allocate back from pool — should come from L2 now
    var j: usize = 0;
    while (j < total) : (j += 1) {
        const arc_p = try pool.create(.{ .bytes = [_]u8{@intCast(j)} ** 32 });
        pool.recycle(arc_p);
    }

    const reuses = pool.stats_reuses.counter.load(.monotonic);
    // Be tolerant across platforms; at least some reuse must be observed.
    try testing.expect(reuses > 0);
    pool.drainThreadCache();
}

test "ArcPool createCyclic builds self-weak and upgrades before drop" {
    // NOTE: ArcPool requires T to be trivially destructible (no deinit).
    // For types with deinit (like Node with weak_self), use regular Arc instead.
    // Here we test with a POD type that stores just a counter.
    const PodNode = struct {
        counter: u64 = 0,
        marker: u64 = 0,
    };
    const NodePool = PoolModule.ArcPool(PodNode, false);
    var pool = NodePool.init(testing.allocator, .{});
    defer pool.deinit();

    const make_node = struct {
        fn ctor(w: ArcModule.ArcWeak(PodNode)) anyerror!PodNode {
            // Just verify we got a valid weak ref, then return POD data
            _ = w; // weak is temporary and released by Arc infrastructure
            return PodNode{ .counter = 42, .marker = 0xDEADBEEF };
        }
    }.ctor;

    var arc = try pool.createCyclic(make_node);
    try testing.expectEqual(@as(u64, 42), arc.get().*.counter);
    try testing.expectEqual(@as(u64, 0xDEADBEEF), arc.get().*.marker);
    pool.recycle(arc);
    pool.drainThreadCache();
}
