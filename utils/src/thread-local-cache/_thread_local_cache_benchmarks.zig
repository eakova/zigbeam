//! Benchmarks for ThreadLocalCache.
//! Comments walk through the flow step by step:
//! 1) warm up, 2) scale iterations, 3) record stats, 4) print + write docs.

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

const MD_PATH = "docs/thread_local_cache_benchmark_results.md";

fn md_truncate_write(content: []const u8) !void {
    var file = try std.fs.cwd().createFile(MD_PATH, .{ .truncate = true });
    defer file.close();
    try file.writeAll(content);
}

fn md_append(content: []const u8) !void {
    var file = std.fs.cwd().openFile(MD_PATH, .{ .mode = .read_write }) catch
        try std.fs.cwd().createFile(MD_PATH, .{});
    defer file.close();
    try file.seekFromEnd(0);
    try file.writeAll(content);
}

// Format helpers for Markdown: u64 with thousands separators.
fn fmt_u64_commas(buf: *[32]u8, value: u64) []const u8 {
    var i: usize = buf.len;
    var v = value;
    if (v == 0) {
        i -= 1; buf[i] = '0';
        return buf[i..];
    }
    var group: u32 = 0;
    while (v > 0) {
        const digit: u8 = @intCast(v % 10);
        v /= 10;
        i -= 1; buf[i] = '0' + digit;
        group += 1;
        if (v != 0 and group % 3 == 0) {
            i -= 1; buf[i] = ',';
        }
    }
    return buf[i..];
}

fn fmt_rate_human(buf: *[32]u8, rate: u64) []const u8 {
    // Simple unit scaling without floats: K/s, M/s, G/s
    if (rate >= 1_000_000_000) {
        const v = rate / 1_000_000_000;
        const s = fmt_u64_commas(buf, v);
        // reuse the same buffer; append suffix in-place is tricky, so return only number
        // caller prints suffix; this keeps code simple and compatible with Zig 0.15
        return s;
    } else if (rate >= 1_000_000) {
        const v = rate / 1_000_000;
        return fmt_u64_commas(buf, v);
    } else if (rate >= 1_000) {
        const v = rate / 1_000;
        return fmt_u64_commas(buf, v);
    } else {
        return fmt_u64_commas(buf, rate);
    }
}

fn fmt_rate(ops: usize, ns: u64) u64 {
    if (ns == 0) return 0;
    const num: u128 = @as(u128, ops) * 1_000_000_000;
    return @as(u64, @intCast(num / ns));
}

fn fmt_ns_per(ops: usize, ns: u64) u64 {
    if (ops == 0) return 0;
    return @as(u64, @intCast(@as(u128, ns) / ops));
}

// ---- Benchmark helpers (warm-up, repeats, scaling) ----

const Stats = struct {
    // Arrays sized for small repeat counts
    ns_op_list: [16]u64 = .{0} ** 16,
    ops_s_list: [16]u64 = .{0} ** 16,
    len: usize = 0,
};

fn sortAsc(slice: []u64) void {
    var i: usize = 1;
    while (i < slice.len) : (i += 1) {
        var j: usize = i;
        while (j > 0 and slice[j - 1] > slice[j]) : (j -= 1) {
            const tmp = slice[j - 1]; slice[j - 1] = slice[j]; slice[j] = tmp;
        }
    }
}

fn medianIqr(slice_in: []u64) struct { median: u64, q1: u64, q3: u64 } {
    var buf: [16]u64 = .{0} ** 16;
    const n = slice_in.len;
    if (n == 0) return .{ .median = 0, .q1 = 0, .q3 = 0 };
    @memcpy(buf[0..n], slice_in);
    sortAsc(buf[0..n]);
    const mid = n / 2;
    const med = if (n % 2 == 1) buf[mid] else (buf[mid - 1] + buf[mid]) / 2;
    const q1 = buf[n / 4];
    const q3 = buf[(3 * n) / 4];
    return .{ .median = med, .q1 = q1, .q3 = q3 };
}

fn scale_iters(pilot_iters: usize, pilot_ns: u64, target_ms: u64) usize {
    // Guard against tiny pilot measurements that would over-scale.
    var eff_iters = pilot_iters;
    var eff_ns = pilot_ns;
    var guard: u32 = 0;
    while (eff_ns < 1_000_000 and guard < 8) { // ensure at least ~1ms pilot
        eff_iters *= 4;
        guard += 1;
        // We cannot re-measure here without rerunning; assume linear scaling
        eff_ns *= 4;
    }
    if (eff_ns == 0) eff_ns = 1; // avoid div by zero
    const target_ns: u128 = @as(u128, target_ms) * 1_000_000;
    const iters_u128: u128 = (@as(u128, eff_iters) * target_ns + @as(u128, eff_ns) - 1) / @as(u128, eff_ns);
    const max_iters: u128 = 50_000_000; // hard cap to keep total under ~1 minute
    const bounded = if (iters_u128 > max_iters) max_iters else iters_u128;
    return @intCast(bounded);
}

fn record(stats: *Stats, ops: usize, ns: u64) void {
    if (stats.len >= stats.ns_op_list.len) return; // clamp
    stats.ns_op_list[stats.len] = fmt_ns_per(ops, ns);
    stats.ops_s_list[stats.len] = fmt_rate(ops, ns);
    stats.len += 1;
}

const Metrics = struct { total_ops: usize, total_ns: u64, ns_per: u64, rate_per_s: u64 };

/// Measure alternating push/pop when the cache never misses.
fn bench_push_pop_hits(iterations: usize) !Metrics {
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
    return .{ .total_ops = iterations, .total_ns = ns, .ns_per = ns_per, .rate_per_s = rate };
}

/// Measure the "cache full" fast-path (push returns false immediately).
fn bench_push_overflow(attempts: usize) !Metrics {
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
    return .{ .total_ops = attempts, .total_ns = ns, .ns_per = ns_per, .rate_per_s = rate };
}

fn bench_pop_miss(iterations: usize) !Metrics {
    var cache: CacheNoCb = .{};
    var timer = try std.time.Timer.start();
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        _ = cache.pop();
    }
    const ns = timer.read();
    const rate = fmt_rate(iterations, ns);
    const ns_per = fmt_ns_per(iterations, ns);
    return .{ .total_ops = iterations, .total_ns = ns, .ns_per = ns_per, .rate_per_s = rate };
}

/// Measure `clear(null)` when no recycle callback is installed.
fn bench_clear_no_callback(cycles: usize, fill_n: usize) !Metrics {
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
    return .{ .total_ops = items_cleared, .total_ns = ns, .ns_per = ns_per, .rate_per_s = rate };
}

/// Measure `clear(ctx)` when every item must run the recycle callback.
fn bench_clear_with_callback(cycles: usize, fill_n: usize) !Metrics {
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
    _ = total; // recorded via ops count
    return .{ .total_ops = items_cleared, .total_ns = ns, .ns_per = ns_per, .rate_per_s = rate };
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

/// Multi-threaded version of push+pop hits (each thread uses its TLS cache).
fn bench_mt_push_pop(threads_count: usize, iterations_per_thread: usize) !Metrics {
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
    return .{ .total_ops = total_iters, .total_ns = ns, .ns_per = ns_per, .rate_per_s = rate };
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

/// Multi-threaded fill+clear using a shared recycle callback to stress global paths.
fn bench_mt_fill_and_clear(threads_count: usize, cycles_per_thread: usize) !Metrics {
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
    _ = shared_counter.load(.seq_cst);
    return .{ .total_ops = total_items, .total_ns = ns, .ns_per = ns_per, .rate_per_s = rate };
}

pub fn main() !void {
    // Configuration knobs — adjust as needed (static for Zig 0.15 tests)
    // Quick mode: keep total wall-time well under 1 minute
    const target_ms_st: u64 = 100; // aim each ST run to last ~100ms
    const target_ms_mt: u64 = 150; // MT runs ~150ms
    const target_ms_overflow: u64 = 200; // overflow/miss paths need longer to avoid 0ns
    const target_ms_clear_nocb: u64 = 200;
    const target_ms_clear_cb: u64 = 200;
    const warmups: usize = 0;      // avoid extra warm-ups
    const repeats: usize = 2;      // two repeats for median/IQR
    const threads = 4; // static thread count

    // Header + Legend
    var hdr: [1024]u8 = undefined;
    var hdr_fbs = std.io.fixedBufferStream(&hdr);
    try hdr_fbs.writer().print(
        "# ThreadLocalCache Benchmark Results\n\n" ++
        "## Legend\n" ++
        "- iters/attempts/cycles: amount of work per measured run (scaled to target duration).\n" ++
        "- repeats: number of measured runs; latency and throughput report median (IQR) across repeats.\n" ++
        "- ns/op (or ns/item): latency per operation/item; lower is better.\n" ++
        "- ops/s (or items/s): throughput; higher is better.\n" ++
        "- Notes: very fast paths may report ~0ns due to timer granularity in ReleaseFast.\n\n" ++
        "## Config\n" ++
        "- repeats: {}\n" ++
        "- target_ms (ST/MT): {}/{}\n" ++
        "- threads (MT): {}\n\n",
        .{ repeats, target_ms_st, target_ms_mt, threads },
    );
    try md_truncate_write(hdr_fbs.getWritten());

    // Machine specs section
    const builtin = @import("builtin");
    var spec_buf: [512]u8 = undefined;
    var spec_fbs = std.io.fixedBufferStream(&spec_buf);
    const os_tag = @tagName(builtin.os.tag);
    const arch_tag = @tagName(builtin.cpu.arch);
    const mode_tag = @tagName(builtin.mode);
    const ptr_bits: usize = @sizeOf(usize) * 8;
    const zig_ver = builtin.zig_version_string;
    const cpu_count = std.Thread.getCpuCount() catch 0;
    try spec_fbs.writer().print(
        "## Machine\n" ++
        "- OS: {s}\n" ++
        "- Arch: {s}\n" ++
        "- Zig: {s}\n" ++
        "- Build Mode: {s}\n" ++
        "- Pointer Width: {}-bit\n" ++
        "- Logical CPUs: {}\n\n",
        .{ os_tag, arch_tag, zig_ver, mode_tag, ptr_bits, cpu_count },
    );
    try md_append(spec_fbs.getWritten());

    // Single-thread: push_pop_hits (scale iterations)
    var pilot = try bench_push_pop_hits(100_000);
    var run_iters = scale_iters(100_000, pilot.total_ns, target_ms_st);
    var st_stats = Stats{};
    // Warm-ups
    var w: usize = 0; while (w < warmups) : (w += 1) { _ = try bench_push_pop_hits(run_iters); }
    // Repeats
    var rep: usize = 0; while (rep < repeats) : (rep += 1) {
        const r = try bench_push_pop_hits(run_iters);
        record(&st_stats, r.total_ops, r.total_ns);
    }
    const med1 = medianIqr(st_stats.ns_op_list[0..st_stats.len]);
    const thr1 = medianIqr(st_stats.ops_s_list[0..st_stats.len]);
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var nb1: [32]u8 = undefined; var nb2: [32]u8 = undefined; var nb3: [32]u8 = undefined; var nb4: [32]u8 = undefined; var nb5: [32]u8 = undefined; var nb6: [32]u8 = undefined;
    const s_iters = fmt_u64_commas(&nb1, run_iters);
    const s_ns_med = fmt_u64_commas(&nb2, med1.median);
    const s_ns_q1  = fmt_u64_commas(&nb3, med1.q1);
    const s_ns_q3  = fmt_u64_commas(&nb4, med1.q3);
    const s_ops_med = fmt_u64_commas(&nb5, thr1.median);
    const s_ops_h = fmt_rate_human(&nb6, thr1.median);
    // Also compute per-op (push or pop) throughput ≈ 2x pairs/s
    var nb7: [32]u8 = undefined; var nb8: [32]u8 = undefined;
    const ops_per_s = thr1.median * 2;
    const s_ops2_med = fmt_u64_commas(&nb7, ops_per_s);
    const s_ops2_h = fmt_rate_human(&nb8, ops_per_s);
    try fbs.writer().print("## push_pop_hits\n- iters: {s}\n- repeats: {}\n- ns/op median (IQR): {s} ({s}–{s})\n- pairs/s median: {s} (≈ {s} M/s)\n- single-op ops/s median: {s} (≈ {s} M/s)\n\n", .{ s_iters, st_stats.len, s_ns_med, s_ns_q1, s_ns_q3, s_ops_med, s_ops_h, s_ops2_med, s_ops2_h });
    try md_append(fbs.getWritten());
    std.debug.print("push_pop_hits  iters={}  ns/op={} ({}–{})  ops/s={} ({}–{})\n", .{ run_iters, med1.median, med1.q1, med1.q3, thr1.median, thr1.q1, thr1.q3 });

    // Single-thread: pop misses (empty cache)
    pilot = try bench_pop_miss(1_000_000);
    run_iters = scale_iters(1_000_000, pilot.total_ns, target_ms_overflow);
    st_stats = .{}; w = 0; while (w < warmups) : (w += 1) { _ = try bench_pop_miss(run_iters); }
    rep = 0; while (rep < repeats) : (rep += 1) { const r = try bench_pop_miss(run_iters); record(&st_stats, r.total_ops, r.total_ns); }
    const med_miss = medianIqr(st_stats.ns_op_list[0..st_stats.len]);
    const thr_miss = medianIqr(st_stats.ops_s_list[0..st_stats.len]);
    fbs.reset();
    nb1 = .{0} ** 32; nb2 = .{0} ** 32; nb3 = .{0} ** 32; nb4 = .{0} ** 32; nb5 = .{0} ** 32; nb6 = .{0} ** 32;
    const s_pop_iters = fmt_u64_commas(&nb1, run_iters);
    const s_pop_ns = fmt_u64_commas(&nb2, med_miss.median);
    const s_pop_q1 = fmt_u64_commas(&nb3, med_miss.q1);
    const s_pop_q3 = fmt_u64_commas(&nb4, med_miss.q3);
    const s_pop_ops = fmt_u64_commas(&nb5, thr_miss.median);
    const s_pop_ops_h = fmt_rate_human(&nb6, thr_miss.median);
    try fbs.writer().print("## pop_empty\n- attempts: {s}\n- repeats: {}\n- ns/attempt median (IQR): {s} ({s}–{s})\n- attempts/s median: {s} (≈ {s} M/s)\n\n", .{ s_pop_iters, st_stats.len, s_pop_ns, s_pop_q1, s_pop_q3, s_pop_ops, s_pop_ops_h });
    try md_append(fbs.getWritten());
    std.debug.print("pop_empty  attempts={}  ns/attempt={} ({}–{})  attempts/s={} ({}–{})\n", .{ run_iters, med_miss.median, med_miss.q1, med_miss.q3, thr_miss.median, thr_miss.q1, thr_miss.q3 });

    // Single-thread: overflow pushes
    pilot = try bench_push_overflow(1_000_000);
    run_iters = scale_iters(1_000_000, pilot.total_ns, target_ms_overflow);
    st_stats = .{}; w = 0; while (w < warmups) : (w += 1) { _ = try bench_push_overflow(run_iters); }
    rep = 0; while (rep < repeats) : (rep += 1) { const r = try bench_push_overflow(run_iters); record(&st_stats, r.total_ops, r.total_ns); }
    const med2 = medianIqr(st_stats.ns_op_list[0..st_stats.len]);
    const thr2 = medianIqr(st_stats.ops_s_list[0..st_stats.len]);
    fbs.reset();
    nb1 = .{0} ** 32; nb2 = .{0} ** 32; nb3 = .{0} ** 32; nb4 = .{0} ** 32; nb5 = .{0} ** 32; nb6 = .{0} ** 32;
    const s_attempts = fmt_u64_commas(&nb1, run_iters);
    const s_na_med = fmt_u64_commas(&nb2, med2.median);
    const s_na_q1 = fmt_u64_commas(&nb3, med2.q1);
    const s_na_q3 = fmt_u64_commas(&nb4, med2.q3);
    const s_attps_med = fmt_u64_commas(&nb5, thr2.median);
    const s_attps_h = fmt_rate_human(&nb6, thr2.median);
    try fbs.writer().print("## push_overflow(full)\n- attempts: {s}\n- repeats: {}\n- ns/attempt median (IQR): {s} ({s}–{s})\n- attempts/s median: {s} (≈ {s} M/s)\n\n", .{ s_attempts, st_stats.len, s_na_med, s_na_q1, s_na_q3, s_attps_med, s_attps_h });
    try md_append(fbs.getWritten());
    std.debug.print("push_overflow  attempts={}  ns/attempt={} ({}–{})  attempts/s={} ({}–{})\n", .{ run_iters, med2.median, med2.q1, med2.q3, thr2.median, thr2.q1, thr2.q3 });

    // clear(null) scaled by cycles
    pilot = try bench_clear_no_callback(100_000, CacheNoCb.capacity);
    var run_cycles = scale_iters(100_000, pilot.total_ns, target_ms_clear_nocb);
    st_stats = .{}; w = 0; while (w < warmups) : (w += 1) { _ = try bench_clear_no_callback(run_cycles, CacheNoCb.capacity); }
    rep = 0; while (rep < repeats) : (rep += 1) { const r = try bench_clear_no_callback(run_cycles, CacheNoCb.capacity); record(&st_stats, r.total_ops, r.total_ns); }
    const med3 = medianIqr(st_stats.ns_op_list[0..st_stats.len]);
    const thr3 = medianIqr(st_stats.ops_s_list[0..st_stats.len]);
    fbs.reset();
    nb1 = .{0} ** 32; nb2 = .{0} ** 32; nb3 = .{0} ** 32; nb4 = .{0} ** 32; nb5 = .{0} ** 32; nb6 = .{0} ** 32;
    const s_cycles = fmt_u64_commas(&nb1, run_cycles);
    const s_items_per = fmt_u64_commas(&nb2, CacheNoCb.capacity);
    const s_ni_med = fmt_u64_commas(&nb3, med3.median);
    const s_ni_q1 = fmt_u64_commas(&nb4, med3.q1);
    const s_items_s = fmt_u64_commas(&nb5, thr3.median);
    const s_items_h = fmt_rate_human(&nb6, thr3.median);
    try fbs.writer().print("## clear_no_callback\n- cycles: {s} (items/cycle: {s})\n- repeats: {}\n- ns/item median (IQR): {s} ({s}–{s})\n- items/s median: {s} (≈ {s} M/s)\n\n", .{ s_cycles, s_items_per, st_stats.len, s_ni_med, s_ni_q1, s_ni_med, s_items_s, s_items_h });
    try md_append(fbs.getWritten());
    std.debug.print("clear_no_callback  cycles={}  ns/item={} ({}–{})  items/s={} ({}–{})\n", .{ run_cycles, med3.median, med3.q1, med3.q3, thr3.median, thr3.q1, thr3.q3 });

    // clear(callback) scaled by cycles
    pilot = try bench_clear_with_callback(100_000, CacheWithCb.capacity);
    run_cycles = scale_iters(100_000, pilot.total_ns, target_ms_clear_cb);
    st_stats = .{}; w = 0; while (w < warmups) : (w += 1) { _ = try bench_clear_with_callback(run_cycles, CacheWithCb.capacity); }
    rep = 0; while (rep < repeats) : (rep += 1) { const r = try bench_clear_with_callback(run_cycles, CacheWithCb.capacity); record(&st_stats, r.total_ops, r.total_ns); }
    const med4 = medianIqr(st_stats.ns_op_list[0..st_stats.len]);
    const thr4 = medianIqr(st_stats.ops_s_list[0..st_stats.len]);
    fbs.reset();
    nb1 = .{0} ** 32; nb2 = .{0} ** 32; nb3 = .{0} ** 32; nb4 = .{0} ** 32; nb5 = .{0} ** 32; nb6 = .{0} ** 32;
    const s_cycles_cb = fmt_u64_commas(&nb1, run_cycles);
    const s_items_per_cb = fmt_u64_commas(&nb2, CacheWithCb.capacity);
    const s_cb_med = fmt_u64_commas(&nb3, med4.median);
    const s_items_s_cb = fmt_u64_commas(&nb4, thr4.median);
    const s_items_h_cb = fmt_rate_human(&nb6, thr4.median);
    try fbs.writer().print("## clear_with_callback\n- cycles: {s} (items/cycle: {s})\n- repeats: {}\n- ns/item median (IQR): {s} ({s}–{s})\n- items/s median: {s} (≈ {s} M/s)\n\n", .{ s_cycles_cb, s_items_per_cb, st_stats.len, s_cb_med, s_cb_med, s_cb_med, s_items_s_cb, s_items_h_cb });
    try md_append(fbs.getWritten());
    std.debug.print("clear_with_callback  cycles={}  ns/item={} ({}–{})  items/s={} ({}–{})\n", .{ run_cycles, med4.median, med4.q1, med4.q3, thr4.median, thr4.q1, thr4.q3 });

    // Multi-thread benchmarks
    // Scale MT iterations per thread via pilot at 200k/threads
    const pilot_mt = try bench_mt_push_pop(threads, 200_000);
    const iters_mt = scale_iters(200_000, pilot_mt.total_ns, target_ms_mt);
    var mt_stats = Stats{}; w = 0; while (w < warmups) : (w += 1) { _ = try bench_mt_push_pop(threads, iters_mt); }
    rep = 0; while (rep < repeats) : (rep += 1) { const r = try bench_mt_push_pop(threads, iters_mt); record(&mt_stats, r.total_ops, r.total_ns); }
    const med5 = medianIqr(mt_stats.ns_op_list[0..mt_stats.len]);
    const thr5 = medianIqr(mt_stats.ops_s_list[0..mt_stats.len]);
    fbs.reset();
    nb1 = .{0} ** 32; nb2 = .{0} ** 32; nb3 = .{0} ** 32; nb4 = .{0} ** 32; nb5 = .{0} ** 32; nb6 = .{0} ** 32;
    const s_itps_med = fmt_u64_commas(&nb1, thr5.median);
    const s_iter_thr = fmt_u64_commas(&nb2, iters_mt);
    const s_ns_med_5 = fmt_u64_commas(&nb3, med5.median);
    const s_itps_h = fmt_rate_human(&nb4, thr5.median);
    const per_thread = thr5.median / @as(u64, @intCast(threads));
    const per_thread_ops = per_thread * 2; // per-thread single-op rate
    const s_per_thread_pairs = fmt_rate_human(&nb5, per_thread);
    const s_per_thread_ops = fmt_rate_human(&nb6, per_thread_ops);
    try fbs.writer().print("## mt_push_pop_hits\n- threads: {}\n- iters/thread: {s}\n- repeats: {}\n- ns/iter median (IQR): {s} ({s}–{s})\n- pairs/s median: {s} (≈ {s} M/s)\n- per-thread pairs/s median: {s} M/s\n- per-thread single-op ops/s median: {s} M/s\n\n", .{ threads, s_iter_thr, mt_stats.len, s_ns_med_5, s_ns_med_5, s_ns_med_5, s_itps_med, s_itps_h, s_per_thread_pairs, s_per_thread_ops });
    try md_append(fbs.getWritten());
    std.debug.print("mt_push_pop_hits  threads={} iters/thread={}  ns/iter={} ({}–{})  iters/s={} ({}–{})\n", .{ threads, iters_mt, med5.median, med5.q1, med5.q3, thr5.median, thr5.q1, thr5.q3 });

    const pilot_mt2 = try bench_mt_fill_and_clear(threads, 200_000);
    const clear_mt_cycles = scale_iters(200_000, pilot_mt2.total_ns, target_ms_mt);
    mt_stats = .{}; w = 0; while (w < warmups) : (w += 1) { _ = try bench_mt_fill_and_clear(threads, clear_mt_cycles); }
    rep = 0; while (rep < repeats) : (rep += 1) { const r = try bench_mt_fill_and_clear(threads, clear_mt_cycles); record(&mt_stats, r.total_ops, r.total_ns); }
    const med6 = medianIqr(mt_stats.ns_op_list[0..mt_stats.len]);
    const thr6 = medianIqr(mt_stats.ops_s_list[0..mt_stats.len]);
    fbs.reset();
    nb1 = .{0} ** 32; nb2 = .{0} ** 32; nb3 = .{0} ** 32; nb4 = .{0} ** 32; nb5 = .{0} ** 32;
    const s_cycles_mt = fmt_u64_commas(&nb1, clear_mt_cycles);
    const s_ns_med_6 = fmt_u64_commas(&nb2, med6.median);
    const s_items_s_6 = fmt_u64_commas(&nb3, thr6.median);
    const s_items_h_6 = fmt_rate_human(&nb4, thr6.median);
    const per_thread_items = thr6.median / @as(u64, @intCast(threads));
    const s_per_thread_items = fmt_rate_human(&nb5, per_thread_items);
    try fbs.writer().print("## mt_fill_and_clear(shared_cb)\n- threads: {}\n- cycles/thread: {s}\n- repeats: {}\n- ns/item median (IQR): {s} ({s}–{s})\n- items/s median: {s} (≈ {s} M/s)\n- per-thread items/s median: {s} M/s\n\n", .{ threads, s_cycles_mt, mt_stats.len, s_ns_med_6, s_ns_med_6, s_ns_med_6, s_items_s_6, s_items_h_6, s_per_thread_items });
    try md_append(fbs.getWritten());
    std.debug.print("mt_fill_and_clear  threads={} cycles/thread={}  ns/item={} ({}–{})  items/s={} ({}–{})\n", .{ threads, clear_mt_cycles, med6.median, med6.q1, med6.q3, thr6.median, thr6.q1, thr6.q3 });

    std.debug.print("\nSummary written to: {s}\n", .{MD_PATH});
}
