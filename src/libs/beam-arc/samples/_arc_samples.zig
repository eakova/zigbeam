//! ARC samples that double as executable documentation.
//! Each block is grouped by difficulty:
//! - **Simple:** how to clone/release and observe shared state.
//! - **Moderate:** weak-reference caches + copy-on-write via `makeMut`.
//! - **Advanced:** ArcPool with cycle detector plus multi-threaded churn.

const std = @import("std");
const testing = std.testing;
const ArcModule = @import("beam-arc");
const ArcPoolModule = @import("beam-arc-pool");
const DetectorModule = @import("beam-arc-cycle-detector");

const ArcU32 = ArcModule.Arc(u32);
const ArcString = ArcModule.Arc([]const u8);
const ArcBytes = ArcModule.Arc([4]u8);
const Pool = ArcPoolModule.ArcPool(Node, false);
const Detector = DetectorModule.ArcCycleDetector(Node);
const CounterPool = ArcPoolModule.ArcPool(struct { value: usize }, false);
const ArcWeak = ArcModule.ArcWeak;

const Node = struct {
    label: u8,
    next: ?ArcModule.Arc(Node) = null,
};

// --------------------------------------------------------------------------
// SIMPLE SAMPLE
// --------------------------------------------------------------------------
/// Simple usage: create, clone, and observe shared state.
/// Steps:
/// 1. Make an `Arc<u32>` with value 10.
/// 2. Clone it (now two owners see the same data).
/// 3. Read both values and return their sum.
pub fn sampleSimpleClone(allocator: std.mem.Allocator) !u32 {
    var arc = try ArcU32.init(allocator, 10);
    defer arc.release();

    var clone = arc.clone();
    defer clone.release();

    return arc.get().* + clone.get().*; // 20
}

test "sample (simple): clone + observe" {
    try testing.expectEqual(@as(u32, 20), try sampleSimpleClone(testing.allocator));
}

// --------------------------------------------------------------------------
// MODERATE SAMPLE
// --------------------------------------------------------------------------
/// Moderate usage: keep weak references and detect evicted entries.
/// Steps:
/// 1. Build two `Arc([]const u8)` strings.
/// 2. Downgrade each to `ArcWeak`.
/// 3. Drop the "hello" strong ref but keep "bye".
/// 4. Upgrading should fail for "hello" and succeed for "bye".
pub fn sampleModerateWeakCache(allocator: std.mem.Allocator) !bool {
    var hello = try ArcString.init(allocator, "hello");
    var bye = try ArcString.init(allocator, "bye");
    defer bye.release();

    const weak_hello = hello.downgrade() orelse return false;
    defer weak_hello.release();
    hello.release();

    const weak_bye = bye.downgrade() orelse return false;
    defer weak_bye.release();

    const hello_hit = weak_hello.upgrade();
    const bye_hit = weak_bye.upgrade();
    if (bye_hit) |arc| arc.release();

    return hello_hit == null and bye_hit != null;
}

test "sample (moderate): weak cache" {
    try testing.expect(try sampleModerateWeakCache(testing.allocator));
}

/// Moderate usage: demonstrate copy-on-write semantics via `makeMut`.
/// Steps:
/// 1. Create an inline `[4]u8` payload and clone it.
/// 2. Call `makeMut` on one owner; it allocates a distinct copy.
/// 3. Modify the new copy and confirm the old clone is untouched.
pub fn sampleModerateMakeMut(allocator: std.mem.Allocator) !bool {
    var arc = try ArcBytes.init(allocator, .{ 1, 2, 3, 4 });
    defer arc.release();
    var clone = arc.clone();
    defer clone.release();

    const ptr = try arc.makeMut();
    ptr.*[0] = 9;

    return clone.get().*[0] == 1 and arc.get().*[0] == 9;
}

test "sample (moderate): makeMut copy-on-write" {
    try testing.expect(try sampleModerateMakeMut(testing.allocator));
}

// --------------------------------------------------------------------------
// ADVANCED SAMPLE
// --------------------------------------------------------------------------
/// Advanced usage: combine `ArcPool` and the cycle detector to find leaks.
/// Steps:
/// 1. Allocate two nodes from `ArcPool`.
/// 2. Wire them into a cycle and track them.
/// 3. Downgrade references, release strong refs.
/// 4. Detector should return both nodes.
pub fn sampleAdvancedPoolAndDetector(allocator: std.mem.Allocator) !usize {
    var pool = Pool.init(allocator, .{});
    defer pool.deinit();

    var detector = Detector.init(allocator, traceNode, null);
    defer detector.deinit();

    var node_a = try pool.create(.{ .label = 'A', .next = null });
    var node_b = try pool.create(.{ .label = 'B', .next = null });

    node_a.asPtr().data.next = node_b.clone();
    node_b.asPtr().data.next = node_a.clone();

    try detector.track(node_a.clone());
    try detector.track(node_b.clone());

    var weak_a = node_a.downgrade().?;
    var weak_b = node_b.downgrade().?;

    node_a.release();
    node_b.release();

    var leaks = try detector.detectCycles();
    defer leaks.deinit();

    for (leaks.list.items) |arc| {
        if (arc.asPtr().data.next) |child| child.release();
        arc.release();
    }
    pool.drainThreadCache();

    weak_a.release();
    weak_b.release();

    return leaks.list.items.len;
}

fn traceNode(_: ?*anyopaque, allocator: std.mem.Allocator, data: *const Node, children: *Detector.ChildList) void {
    if (data.next) |child| {
        if (!child.isInline()) {
            children.append(allocator, child.asPtr()) catch unreachable;
        }
    }
}

test "sample (advanced): pooled cycle detection" {
    try testing.expectEqual(@as(usize, 2), try sampleAdvancedPoolAndDetector(testing.allocator));
}

/// Advanced usage: run pooled work inside `withThreadCache` across threads.
/// Steps:
/// 1. Spawn several threads that call `ArcPool.create`/`recycle`.
/// 2. Each worker runs inside `withThreadCache` so TLS caches flush automatically.
/// 3. Count how many objects flowed through the pool.
pub fn sampleAdvancedPoolWithThreadCache(allocator: std.mem.Allocator) !usize {
    var pool = CounterPool.init(allocator, .{});
    defer pool.deinit();

    var total = std.atomic.Value(usize).init(0);
    var contexts: [4]ThreadCacheCtx = undefined;
    var threads: [4]std.Thread = undefined;
    const base_iters: usize = 8;

    for (&contexts, 0..) |*ctx, idx| {
        ctx.* = .{
            .pool = &pool,
            .sum = &total,
            .iterations = base_iters + idx,
        };
        threads[idx] = try std.Thread.spawn(.{}, poolWorkerThread, .{ctx});
    }
    for (threads) |t| t.join();

    pool.drainThreadCache();
    return total.load(.seq_cst);
}

// --------------------------------------------------------------------------
// NEW: In-place init and cyclic samples
// --------------------------------------------------------------------------
/// Create pooled payloads using in-place initializer (no memcpy).
pub fn sampleInPlaceInitArcPool(allocator: std.mem.Allocator) !u8 {
    const P = struct { bytes: [4]u8 };
    var pool = ArcPoolModule.ArcPool(P, false).init(allocator, .{});
    defer pool.deinit();
    const init_fn = struct { fn f(p: *P) void { @memset(&p.bytes, 42); } }.f;
    var arc = try pool.createWithInitializer(init_fn);
    defer pool.recycle(arc);
    return arc.get().*.bytes[0];
}

test "sample (new): in-place init via ArcPool" {
    try testing.expectEqual(@as(u8, 42), try sampleInPlaceInitArcPool(testing.allocator));
}

/// Construct a self-referential node using `Arc.newCyclic`.
pub fn sampleNewCyclicArc(allocator: std.mem.Allocator) !bool {
    const NodeC = struct { weak_self: ArcWeak(@This()) = ArcWeak(@This()).empty() };
    const ArcNodeC = ArcModule.Arc(NodeC);
    var arc = try ArcNodeC.newCyclic(allocator, struct {
        fn ctor(w: ArcWeak(NodeC)) anyerror!NodeC { return NodeC{ .weak_self = w }; }
    }.ctor);
    const up = arc.get().*.weak_self.upgrade();
    const ok = up != null;
    if (up) |t| t.release();
    arc.release();
    return ok;
}

test "sample (new): newCyclic builds self-weak" {
    try testing.expect(try sampleNewCyclicArc(testing.allocator));
}

const ThreadCacheCtx = struct {
    pool: *CounterPool,
    sum: *std.atomic.Value(usize),
    iterations: usize,
};

fn poolWorkerThread(ctx: *ThreadCacheCtx) void {
    ctx.pool.withThreadCache(populateCounterPool, @ptrCast(ctx)) catch unreachable;
}

fn populateCounterPool(pool: *CounterPool, raw_ctx: *anyopaque) anyerror!void {
    const ctx: *ThreadCacheCtx = @ptrCast(@alignCast(raw_ctx));
    var i: usize = 0;
    while (i < ctx.iterations) : (i += 1) {
        const arc = try pool.create(.{ .value = i });
        _ = ctx.sum.fetchAdd(1, .seq_cst);
        pool.recycle(arc);
    }
}

test "sample (advanced): pool with thread cache" {
    const total = try sampleAdvancedPoolWithThreadCache(testing.allocator);
    try testing.expectEqual(@as(usize, 38), total);
}

// --------------------------------------------------------------------------
// ATOMIC OPERATIONS SAMPLES
// --------------------------------------------------------------------------

/// Atomic operations sample: Safely share Arc across threads.
/// Demonstrates atomicLoad for concurrent readers.
///
/// Steps:
/// 1. Create a shared Arc(u64) with value 777
/// 2. Spawn multiple threads that atomically load the Arc
/// 3. Each thread reads the value safely
/// 4. All threads should see the same value
pub fn sampleAtomicLoadConcurrentReaders(allocator: std.mem.Allocator) !bool {
    const ArcU64 = ArcModule.Arc(u64);

    var shared_arc = try ArcU64.init(allocator, 777);
    defer shared_arc.release();

    const Context = struct {
        arc: *const ArcU64,
        success_count: *std.atomic.Value(usize),
    };

    var success_count = std.atomic.Value(usize).init(0);
    const ctx = Context{ .arc = &shared_arc, .success_count = &success_count };

    const reader_fn = struct {
        fn run(c: Context) void {
            var i: usize = 0;
            while (i < 100) : (i += 1) {
                if (ArcU64.atomicLoad(c.arc, .acquire)) |loaded| {
                    defer loaded.release();
                    if (loaded.get().* == 777) {
                        _ = c.success_count.fetchAdd(1, .monotonic);
                    }
                }
            }
        }
    }.run;

    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, reader_fn, .{ctx});
    }

    for (threads) |t| {
        t.join();
    }

    return success_count.load(.monotonic) == 400; // 4 threads × 100 reads
}

test "sample (atomic): concurrent atomicLoad" {
    try testing.expect(try sampleAtomicLoadConcurrentReaders(testing.allocator));
}

/// Atomic operations sample: Atomically swap buffer in a shared data structure.
/// This demonstrates the work-stealing deque pattern.
///
/// Steps:
/// 1. Create a shared Arc(Buffer)
/// 2. One thread reads from the buffer
/// 3. Another thread atomically swaps to a new buffer
/// 4. Reader safely accesses old buffer via atomicLoad
pub fn sampleAtomicSwapBuffer(allocator: std.mem.Allocator) !bool {
    const Buffer = struct {
        data: [4]u8,
    };
    const ArcBuffer = ArcModule.Arc(Buffer);

    var shared_buffer = try ArcBuffer.init(allocator, .{ .data = .{ 1, 2, 3, 4 } });
    defer shared_buffer.release();

    const Context = struct {
        buffer: *ArcBuffer,
        reads_completed: *std.atomic.Value(bool),
        allocator_: std.mem.Allocator,
    };

    var reads_completed = std.atomic.Value(bool).init(false);

    // Reader thread: atomically loads buffer
    const reader_fn = struct {
        fn run(c: Context) void {
            std.time.sleep(1_000_000); // 1ms - let writer start

            if (ArcBuffer.atomicLoad(c.buffer, .acquire)) |loaded_buffer| {
                defer loaded_buffer.release();
                // Old or new buffer - either is safe!
                const sum = loaded_buffer.get().data[0] +
                           loaded_buffer.get().data[1] +
                           loaded_buffer.get().data[2] +
                           loaded_buffer.get().data[3];
                _ = sum; // Use it
                c.reads_completed.store(true, .release);
            }
        }
    }.run;

    // Writer thread: atomically swaps buffer
    const writer_fn = struct {
        fn run(c: Context) !void {
            const new_buffer = try ArcBuffer.init(c.allocator_, .{ .data = .{ 10, 20, 30, 40 } });
            const old_buffer = ArcBuffer.atomicSwap(c.buffer, new_buffer, .release);
            old_buffer.release();
        }
    }.run;

    const ctx = Context{
        .buffer = &shared_buffer,
        .reads_completed = &reads_completed,
        .allocator_ = allocator,
    };

    const reader_thread = try std.Thread.spawn(.{}, reader_fn, .{ctx});
    const writer_thread = try std.Thread.spawn(.{}, writer_fn, .{ctx});

    reader_thread.join();
    writer_thread.join();

    return reads_completed.load(.acquire);
}

test "sample (atomic): atomicSwap for buffer replacement" {
    try testing.expect(try sampleAtomicSwapBuffer(testing.allocator));
}

/// Atomic operations sample: Lock-free counter with atomicCompareSwap.
/// Demonstrates retry loop pattern.
///
/// Steps:
/// 1. Multiple threads try to increment a shared Arc(u32) counter
/// 2. Each thread uses CAS in a retry loop
/// 3. Only successful CAS operations increment the counter
pub fn sampleAtomicCompareSwapCounter(allocator: std.mem.Allocator) !u32 {
    const ArcU32 = ArcModule.Arc(u32);

    var shared_counter = try ArcU32.init(allocator, 0);
    defer shared_counter.release();

    const Context = struct {
        counter: *ArcU32,
        allocator_: std.mem.Allocator,
    };

    const incrementer_fn = struct {
        fn run(c: Context) !void {
            var i: usize = 0;
            while (i < 25) : (i += 1) {
                // Retry loop for CAS
                while (true) {
                    const current = c.counter.clone();
                    const current_value = current.get().*;
                    const new_value = current_value + 1;

                    const new_arc = try ArcU32.init(c.allocator_, new_value);

                    const prev = ArcU32.atomicCompareSwap(
                        c.counter,
                        current,
                        new_arc,
                        .acq_rel,
                        .acquire
                    );

                    const success = ArcU32.ptrEqual(prev, current);
                    prev.release();
                    current.release();

                    if (success) {
                        break; // CAS succeeded
                    } else {
                        new_arc.release(); // CAS failed, clean up
                        // Retry
                    }
                }
            }
        }
    }.run;

    const ctx = Context{ .counter = &shared_counter, .allocator_ = allocator };

    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, incrementer_fn, .{ctx});
    }

    for (threads) |t| {
        t.join();
    }

    return shared_counter.get().*;
}

test "sample (atomic): CAS-based lock-free counter" {
    const final_value = try sampleAtomicCompareSwapCounter(testing.allocator);
    try testing.expectEqual(@as(u32, 100), final_value); // 4 threads × 25 increments
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const simple = try sampleSimpleClone(allocator);
    const weak_cache = try sampleModerateWeakCache(allocator);
    const cow = try sampleModerateMakeMut(allocator);
    const leak_count = try sampleAdvancedPoolAndDetector(allocator);
    const pool_sum = try sampleAdvancedPoolWithThreadCache(allocator);
    const inplace = try sampleInPlaceInitArcPool(allocator);
    const cyclic_ok = try sampleNewCyclicArc(allocator);

    std.debug.print(
        "ARC samples -> simple_sum={}, weak_cache={}, cow={}, leaks={}, pool_sum={}, inplace_first={}, cyclic={}\n",
        .{ simple, weak_cache, cow, leak_count, pool_sum, inplace, cyclic_ok },
    );
}
