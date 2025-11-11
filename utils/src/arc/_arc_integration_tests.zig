const std = @import("std");
const testing = std.testing;
const ArcModule = @import("arc.zig");
const ArcPoolModule = @import("arc_pool.zig");

const ArcU64 = ArcModule.Arc(u64);
const PoolValue = struct {
    bytes: [32]u8,
};
const Pool = ArcPoolModule.ArcPool(PoolValue);

const WorkerCtx = struct {
    shared: *ArcU64,
    iterations: usize,
};

fn workerClone(_: void, ctx: *WorkerCtx) void {
    var i: usize = 0;
    while (i < ctx.iterations) : (i += 1) {
        var clone = ctx.shared.clone();
        clone.release();
    }
}

test "Arc multi-threaded clone/release keeps counts stable" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var shared = try ArcU64.init(allocator, 123);
    defer shared.release();

    const thread_count = 4;
    const iterations: usize = 2_000;
    var contexts: [thread_count]WorkerCtx = undefined;
    var threads: [thread_count]std.Thread = undefined;

    for (&contexts, 0..) |*ctx, i| {
        ctx.* = .{ .shared = &shared, .iterations = iterations + i * 137 };
        threads[i] = try std.Thread.spawn(.{}, workerClone, .{ctx});
    }

    for (threads) |t| t.join();

    try testing.expectEqual(@as(usize, 1), shared.strongCount());
    try testing.expectEqual(@as(u64, 123), shared.get().*);
}

test "ArcPool recycles heap allocated inners" {
    var pool = Pool.init(testing.allocator);
    defer pool.deinit();

    var arc_one = try pool.create(.{ .bytes = [_]u8{0} ** 32 });
    const first_ptr = arc_one.asPtr();
    pool.recycle(arc_one);

    var pattern: [32]u8 = undefined;
    var i: usize = 0;
    while (i < pattern.len) : (i += 1) pattern[i] = @intCast(i);

    var arc_two = try pool.create(.{ .bytes = pattern });
    defer pool.recycle(arc_two);
    const second_ptr = arc_two.asPtr();

    try testing.expectEqual(first_ptr, second_ptr);
    try testing.expectEqual(pattern, arc_two.get().*.bytes);
}
