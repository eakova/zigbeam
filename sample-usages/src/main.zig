const std = @import("std");
const usage_sample = @import("usage_sample");
const beam = @import("zigbeam");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // 1) Tagged pointer example (store a 1-bit tag in a pointer)
    try sampleTaggedPointer();

    // 2) Thread-local cache example (push/pop)
    sampleThreadLocalCache();

    // 3) Arc + ArcPool example
    try sampleArcAndPool(alloc);

    // 4) DVyukov MPMC queue example
    try sampleDvyukovQueue(alloc);

    // 5) Deque example
    try sampleDeque(alloc);

    // 6) DequeChannel example
    try sampleDequeChannel(alloc);

    // 7) Bounded SPSC queue example
    try sampleSpscQueue(alloc);

    // 8) SegmentedQueue example (single-threaded)
    try sampleSegmentedQueue(alloc);

    // 9) Task example (spawn + cancel)
    try sampleTask(alloc);

    // 10) Backoff and CachePadded examples
    sampleBackoff();
    sampleCachePadded();

    // Keep original sample’s buffered print
    try usage_sample.bufferedPrint();
}

fn sampleTaggedPointer() !void {
    const TaggedPointer = beam.Libs.TaggedPointer;
    const PtrTag = TaggedPointer(*usize, 1);
    var x: usize = 42;
    var tagged = try PtrTag.new(&x, 1);
    std.debug.print("Tagged: tag={}, ptr={*}\n", .{ tagged.getTag(), tagged.getPtr() });
}

fn sampleThreadLocalCache() void {
    const CacheType = beam.Libs.ThreadLocalCache;
    const Cache = CacheType(*usize, null);
    var cache: Cache = .{};

    var x: usize = 123;
    _ = cache.push(&x);
    const got = cache.pop().?;
    std.debug.print("ThreadLocalCache pop -> {}\n", .{got.*});
}

fn sampleArcAndPool(alloc: std.mem.Allocator) !void {
    const ArcType = beam.Libs.Arc;
    const Arc = ArcType(u64);
    var a = try Arc.init(alloc, 123);
    defer a.release();
    const c = a.clone();
    defer c.release();
    std.debug.print("Arc value = {}\n", .{a.get().*});

    const ArcPoolType = beam.Libs.ArcPool;
    const Pool = ArcPoolType([64]u8, false);
    var pool = Pool.init(alloc, .{});
    defer pool.deinit();
    const payload = [_]u8{0} ** 64;
    const pooled = try pool.create(payload);
    pool.recycle(pooled);
    std.debug.print("ArcPool create+recycle ok (64B)\n", .{});
}

fn sampleDvyukovQueue(alloc: std.mem.Allocator) !void {
    const QueueType = beam.Libs.DVyukovMPMCQueue;
    var queue = try QueueType(u32, 8).init(alloc);
    defer queue.deinit();

    try queue.enqueue(77);
    const got = queue.dequeue().?;
    std.debug.print("DVyukov queue dequeue -> {}\n", .{got});
}

fn sampleDeque(alloc: std.mem.Allocator) !void {
    const DequeType = beam.Libs.Deque;
    const Result = try DequeType(u32).init(alloc, 16);
    defer Result.worker.deinit();

    try Result.worker.push(1);
    try Result.worker.push(2);
    const v2 = Result.worker.pop().?;
    const v1 = Result.worker.pop().?;
    std.debug.print("Deque pop order -> {d}, {d}\n", .{ v2, v1 });
}

fn sampleSpscQueue(alloc: std.mem.Allocator) !void {
    const QueueType = beam.Libs.BoundedSPSCQueue;
    var res = try QueueType(u32).init(alloc, 8);
    defer res.producer.deinit();

    try res.producer.enqueue(10);
    const v = res.consumer.dequeue().?;
    std.debug.print("SPSC dequeue -> {}\n", .{v});
}

fn sampleSegmentedQueue(alloc: std.mem.Allocator) !void {
    const SegmentedQueue = beam.Libs.SegmentedQueue;
    const Queue = SegmentedQueue(u64, 64);
    var queue = try Queue.init(alloc);
    defer queue.deinit();

    const participant = try queue.createParticipant();
    defer queue.destroyParticipant(participant);

    try queue.enqueue(1);
    try queue.enqueue(2);

    if (queue.dequeueWithAutoGuard()) |v1| {
        std.debug.print("SegmentedQueue dequeue 1 -> {}\n", .{v1});
    }
}

fn sampleDequeChannel(alloc: std.mem.Allocator) !void {
    const DequeChannelType = beam.Libs.DequeChannel;
    const Channel = DequeChannelType(u32, 16, 64);
    var init_result = try Channel.init(alloc, 2);
    defer init_result.channel.deinit(&init_result.workers);

    var workers = init_result.workers;

    try workers[0].send(10);
    try workers[0].send(20);

    var recv_count: usize = 0;
    while (recv_count < 2) {
        if (workers[1].recv()) |v| {
            std.debug.print("DequeChannel recv -> {}\n", .{v});
            recv_count += 1;
        } else {
            std.Thread.yield() catch {};
        }
    }
}

fn sampleTask(alloc: std.mem.Allocator) !void {
    const Task = beam.Libs.Task;

    const Worker = struct {
        fn run(ctx: Task.Context, flag: *std.atomic.Value(bool)) void {
            const cancelled = ctx.sleep(10);
            flag.store(cancelled, .release);
        }
    };

    var flag = std.atomic.Value(bool).init(false);
    var task = try Task.spawn(alloc, Worker.run, .{&flag});
    defer task.wait();

    task.cancel();
    task.wait();
    const was_cancelled = flag.load(.acquire);
    std.debug.print("Task cancelled -> {any}\n", .{was_cancelled});
}

fn sampleBackoff() void {
    const Backoff = beam.Libs.Backoff;
    var b = Backoff.init(.{});
    var i: u32 = 0;
    while (i < 4) : (i += 1) {
        b.spin();
    }
    std.debug.print("Backoff spin completed\n", .{});
}

fn sampleCachePadded() void {
    const CP = beam.Libs.CachePadded;
    const PaddedU64 = CP.Static(u64);
    var v = PaddedU64.init(123);
    std.debug.print("CachePadded.Static value -> {d}\n", .{v.value});
}

test "beam: tagged pointer roundtrip" {
    const TaggedPointer = beam.Libs.TaggedPointer;
    const PtrTag = TaggedPointer(*usize, 1);
    var v: usize = 7;
    const bits = (try PtrTag.new(&v, 1)).toUnsigned();
    const tp = PtrTag.fromUnsigned(bits);
    try std.testing.expectEqual(@as(u1, 1), tp.getTag());
    try std.testing.expectEqual(&v, tp.getPtr());
}
