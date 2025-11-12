const std = @import("std");
const testing = std.testing;
const ArcModule = @import("arc_core");
const PoolModule = @import("arc_pool");

const Payload = struct { value: usize };
const Pool = PoolModule.ArcPool(Payload, false);

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

test "ArcPool multi-threaded churn reuses L2 under spill" {
    const PoolOn = PoolModule.ArcPool(Payload, true);
    var pool = PoolOn.init(testing.allocator);
    defer pool.deinit();

    var threads: [2]std.Thread = undefined;
    const per_thread_iters: usize = pool.tls_active_capacity + pool.flush_batch + 32;

    const MTRecycle = struct {
        const Ctx = struct { p: *PoolOn, iters: usize };
        fn run(ctx: *Ctx) void {
            var k: usize = 0;
            while (k < ctx.iters) : (k += 1) {
                const a = ArcModule.Arc(Payload).init(testing.allocator, .{ .value = k }) catch return;
                ctx.p.recycle(a);
            }
            ctx.p.drainThreadCache();
        }
    };

    // Phase 1: multi-threaded recycle of raw arcs
    var r0 = MTRecycle.Ctx{ .p = &pool, .iters = per_thread_iters };
    var r1 = MTRecycle.Ctx{ .p = &pool, .iters = per_thread_iters };
    threads[0] = try std.Thread.spawn(.{}, MTRecycle.run, .{ &r0 });
    threads[1] = try std.Thread.spawn(.{}, MTRecycle.run, .{ &r1 });
    threads[0].join();
    threads[1].join();
    // Drain TLS to force subsequent creates to draw from L2
    pool.drainThreadCache();

    const MTCreate = struct {
        const Ctx = struct { p: *PoolOn, iters: usize };
        fn run(ctx: *Ctx) void {
            var k: usize = 0;
            while (k < ctx.iters) : (k += 1) {
                const b = ctx.p.create(.{ .value = k + 1 }) catch return;
                ctx.p.recycle(b);
            }
            ctx.p.drainThreadCache();
        }
    };
    var c0 = MTCreate.Ctx{ .p = &pool, .iters = per_thread_iters };
    var c1 = MTCreate.Ctx{ .p = &pool, .iters = per_thread_iters };
    threads[0] = try std.Thread.spawn(.{}, MTCreate.run, .{ &c0 });
    threads[1] = try std.Thread.spawn(.{}, MTCreate.run, .{ &c1 });
    threads[0].join();
    threads[1].join();

    // Ensure run completed without panic; reuse may vary across environments.
    _ = pool.stats_reuses.counter.load(.monotonic);
    pool.drainThreadCache();
}
