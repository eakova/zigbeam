const std = @import("std");
const cache_mod = @import("thread_local_cache.zig");

// Simple item to cache. We only traffic in pointers to this.
const Item = struct { id: usize };

// Callback used in some benchmarks to simulate returning items to a global pool.
const AtomicUsize = std.atomic.Value(usize);
fn recycle_atomic(ctx: ?*anyopaque, _: *Item) void {
    if (ctx) |p| {
        const counter: *AtomicUsize = @ptrCast(@alignCast(p));
        _ = counter.fetchAdd(1, .seq_cst);
    }
}

// Cache type aliases
const CacheNoCb = cache_mod.ThreadLocalCache(*Item, null);
const CacheWithCb = cache_mod.ThreadLocalCache(*Item, recycle_atomic);

fn fmt_rate(ops: usize, ns: u64) u64 {
    if (ns == 0) return 0;
    const num: u128 = @as(u128, ops) * 1_000_000_000;
    return @as(u64, @intCast(num / ns));
}

fn fmt_ns_per(ops: usize, ns: u64) u64 {
    if (ops == 0) return 0;
    return @as(u64, @intCast(@as(u128, ns) / ops));
}

fn bench_push_pop_hits(iterations: usize) !void {
    var cache: CacheNoCb = .{};
    var item = Item{ .id = 1 };
    var timer = try std.time.Timer.start();
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        _ = cache.push(&item);
        _ = cache.pop();
    }
    const ns = timer.read();
    const rate = fmt_rate(iterations, ns);
    const ns_per = fmt_ns_per(iterations, ns);
    std.debug.print("push_pop_hits: iterations={}, total_ns={}, ns/iter={}, iter/s={}\n", .{ iterations, ns, ns_per, rate });
}

fn bench_push_overflow(attempts: usize) !void {
    var cache: CacheNoCb = .{};
    var items: [CacheNoCb.capacity]Item = undefined;
    for (&items, 0..) |*it, i| it.* = .{ .id = i };
    // Fill to capacity
    for (0..CacheNoCb.capacity) |i| {
        _ = cache.push(&items[i]);
    }
    var extra = Item{ .id = 999 };
    var timer = try std.time.Timer.start();
    var i: usize = 0;
    while (i < attempts) : (i += 1) {
        // Expected to fail fast since cache is full
        _ = cache.push(&extra);
    }
    const ns = timer.read();
    const rate = fmt_rate(attempts, ns);
    const ns_per = fmt_ns_per(attempts, ns);
    std.debug.print("push_overflow (full): attempts={}, total_ns={}, ns/attempt={}, attempts/s={}\n", .{ attempts, ns, ns_per, rate });
}

fn bench_clear_no_callback(cycles: usize, fill_n: usize) !void {
    var cache: CacheNoCb = .{};
    var items: [CacheNoCb.capacity]Item = undefined;
    for (&items, 0..) |*it, i| it.* = .{ .id = i };

    var timer = try std.time.Timer.start();
    var c: usize = 0;
    while (c < cycles) : (c += 1) {
        // Fill
        var i: usize = 0;
        while (i < fill_n) : (i += 1) {
            _ = cache.push(&items[i]);
        }
        // Time the clear
        _ = timer.lap();
        cache.clear(null);
    }
    const ns = timer.read();
    const items_cleared = cycles * fill_n;
    const rate = fmt_rate(items_cleared, ns);
    const ns_per = fmt_ns_per(items_cleared, ns);
    std.debug.print("clear_no_callback: cycles={}, items_cleared={}, total_ns={}, ns/item={}, items/s={}\n", .{ cycles, items_cleared, ns, ns_per, rate });
}

fn bench_clear_with_callback(cycles: usize, fill_n: usize) !void {
    var cache: CacheWithCb = .{};
    var items: [CacheWithCb.capacity]Item = undefined;
    for (&items, 0..) |*it, i| it.* = .{ .id = i };
    var counter = AtomicUsize.init(0);

    var timer = try std.time.Timer.start();
    var c: usize = 0;
    while (c < cycles) : (c += 1) {
        var i: usize = 0;
        while (i < fill_n) : (i += 1) {
            _ = cache.push(&items[i]);
        }
        _ = timer.lap();
        cache.clear(&counter);
    }
    const ns = timer.read();
    const items_cleared = cycles * fill_n;
    const rate = fmt_rate(items_cleared, ns);
    const ns_per = fmt_ns_per(items_cleared, ns);
    const total = counter.load(.seq_cst);
    std.debug.print("clear_with_callback: cycles={}, items_cleared={}, callback_count={}, total_ns={}, ns/item={}, items/s={}\n", .{ cycles, items_cleared, total, ns, ns_per, rate });
}

// ---- Multi-threaded benchmarks ----

threadlocal var tls_hits_cache: CacheNoCb = .{};
threadlocal var tls_clear_cache: CacheWithCb = .{};

fn worker_hits(iterations: usize, start_flag: *AtomicUsize) void {
    // Spin-wait for the start signal (0 -> not started, 1 -> go)
    while (start_flag.load(.seq_cst) == 0) {
        std.Thread.yield() catch {};
    }
    var item = Item{ .id = 123 };
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        _ = tls_hits_cache.push(&item);
        _ = tls_hits_cache.pop();
    }
}

fn bench_mt_push_pop(threads_count: usize, iterations_per_thread: usize) !void {
    var start_flag = AtomicUsize.init(0);

    const threads = try std.heap.page_allocator.alloc(std.Thread, threads_count);
    defer std.heap.page_allocator.free(threads);

    for (threads) |*t| {
        t.* = try std.Thread.spawn(.{}, worker_hits, .{ iterations_per_thread, &start_flag });
    }

    var timer = try std.time.Timer.start();
    _ = start_flag.store(1, .seq_cst);
    for (threads) |*t| t.join();
    const ns = timer.read();

    const total_iters = threads_count * iterations_per_thread;
    const rate = fmt_rate(total_iters, ns);
    const ns_per = fmt_ns_per(total_iters, ns);
    std.debug.print("mt_push_pop_hits: threads={}, iters/thread={}, total_ns={}, ns/iter={}, iters/s={}\n", .{ threads_count, iterations_per_thread, ns, ns_per, rate });
}

fn recycle_add(ctx: ?*anyopaque, _: *Item) void {
    // Increment shared atomic to simulate global recycle cost.
    if (ctx) |p| {
        const counter: *AtomicUsize = @ptrCast(@alignCast(p));
        _ = counter.fetchAdd(1, .seq_cst);
    }
}

const CacheWithSharedCb = cache_mod.ThreadLocalCache(*Item, recycle_add);
threadlocal var tls_shared_clear_cache: CacheWithSharedCb = .{};

fn worker_fill_and_clear(cycles: usize, start_flag: *AtomicUsize, shared_counter: *AtomicUsize) void {
    while (start_flag.load(.seq_cst) == 0) {
        std.Thread.yield() catch {};
    }
    var items: [CacheWithSharedCb.capacity]Item = undefined;
    for (&items, 0..) |*it, i| it.* = .{ .id = i };

    var c: usize = 0;
    while (c < cycles) : (c += 1) {
        var i: usize = 0;
        while (i < CacheWithSharedCb.capacity) : (i += 1) {
            _ = tls_shared_clear_cache.push(&items[i]);
        }
        tls_shared_clear_cache.clear(shared_counter);
    }
}

fn bench_mt_fill_and_clear(threads_count: usize, cycles_per_thread: usize) !void {
    var start_flag = AtomicUsize.init(0);
    var shared_counter = AtomicUsize.init(0);

    const threads = try std.heap.page_allocator.alloc(std.Thread, threads_count);
    defer std.heap.page_allocator.free(threads);

    for (threads) |*t| {
        t.* = try std.Thread.spawn(.{}, worker_fill_and_clear, .{ cycles_per_thread, &start_flag, &shared_counter });
    }

    var timer = try std.time.Timer.start();
    _ = start_flag.store(1, .seq_cst);
    for (threads) |*t| t.join();
    const ns = timer.read();

    const total_items = threads_count * cycles_per_thread * CacheWithSharedCb.capacity;
    const rate = fmt_rate(total_items, ns);
    const ns_per = fmt_ns_per(total_items, ns);
    const counted = shared_counter.load(.seq_cst);
    std.debug.print(
        "mt_fill_and_clear (shared atomic cb): threads={}, cycles/thread={}, total_items={}, callback_count={}, total_ns={}, ns/item={}, items/s={}\n",
        .{ threads_count, cycles_per_thread, total_items, counted, ns, ns_per, rate },
    );
}

pub fn main() !void {
    // Configuration knobs — adjust as needed
    const iters_st = 5_000_000; // single-thread iterations
    const attempts_overflow = 50_000_000; // overflow attempts
    const clear_cycles = 2_000_000; // how many clears to perform
    const threads = 4;
    const iters_mt = 2_000_000; // iterations per thread
    const clear_mt_cycles = 1_000_000; // cycles per thread for fill+clear

    std.debug.print("=== ThreadLocalCache Benchmarks ===\n", .{});

    // Single-thread microbenches
    try bench_push_pop_hits(iters_st);
    try bench_push_overflow(attempts_overflow);
    try bench_clear_no_callback(clear_cycles, CacheNoCb.capacity);
    try bench_clear_with_callback(clear_cycles, CacheWithCb.capacity);

    // Multi-thread benchmarks
    try bench_mt_push_pop(threads, iters_mt);
    try bench_mt_fill_and_clear(threads, clear_mt_cycles);
}
