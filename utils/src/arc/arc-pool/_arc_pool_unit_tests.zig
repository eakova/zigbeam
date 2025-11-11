const std = @import("std");
const testing = std.testing;
const ArcModule = @import("arc_core");
const PoolModule = @import("arc_pool");

const Payload = struct { bytes: [32]u8 };
const Pool = PoolModule.ArcPool(Payload);

test "ArcPool reuses recycled nodes" {
    var pool = Pool.init(testing.allocator);
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
    const SvoPool = PoolModule.ArcPool(u8);
    var pool = SvoPool.init(testing.allocator);
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
    var pool = Pool.init(testing.allocator);
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
