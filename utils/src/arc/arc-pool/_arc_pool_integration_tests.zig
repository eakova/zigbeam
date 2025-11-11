const std = @import("std");
const testing = std.testing;
const ArcModule = @import("arc_core");
const PoolModule = @import("arc_pool");

const Payload = struct { value: usize };
const Pool = PoolModule.ArcPool(Payload);

const WorkerCtx = struct {
    pool: *Pool,
    iterations: usize,
    counter: *std.atomic.Value(usize),
};

fn worker(ctx: *WorkerCtx) void {
    ctx.pool.withThreadCache(run, ctx) catch unreachable;
}

fn run(pool: *Pool, ctx_ptr: *anyopaque) anyerror!void {
    var ctx: *WorkerCtx = @ptrCast(@alignCast(ctx_ptr));
    var i: usize = 0;
    while (i < ctx.iterations) : (i += 1) {
        const arc = try pool.create(.{ .value = i });
        _ = ctx.counter.fetchAdd(1, .seq_cst);
        pool.recycle(arc);
    }
}

test "ArcPool multi-threaded create/recycle" {
    var pool = Pool.init(testing.allocator);
    defer pool.deinit();

    var counter = std.atomic.Value(usize).init(0);
    var threads: [4]std.Thread = undefined;
    var contexts: [4]WorkerCtx = undefined;

    for (&threads, 0..) |*t, idx| {
        contexts[idx] = .{ .pool = &pool, .iterations = 1_000 + idx * 321, .counter = &counter };
        t.* = try std.Thread.spawn(.{}, worker, .{&contexts[idx]});
    }
    for (threads) |t| t.join();

    pool.drainThreadCache();
    const total = counter.load(.seq_cst);
    try testing.expectEqual(@as(usize, 1000 + 1321 + 1642 + 1963), total);
}
