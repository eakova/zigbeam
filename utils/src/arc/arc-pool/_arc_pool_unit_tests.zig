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
