// FILE: arc_benchmark.zig
// All comments are in English as requested.

const std = @import("std");
const testing = std.testing;
const Thread = std.Thread;
const Timer = std.time.Timer;
const utils = @import("zig_beam_utils");

const ArcModule = utils.arc;
const ArcU64 = ArcModule.Arc(u64);
const ArcArray64 = ArcModule.Arc([64]u8);
const ArcPoolModule = utils.arc_pool;

// --- Benchmark Configuration ---
// The number of clone/release pairs to perform in each benchmark run.
// A larger number gives more stable results.
const DEFAULT_MT_THREADS: usize = 4;
const MIN_MT_THREADS: usize = 2;
const MAX_MT_THREADS: usize = 16;

const MD_PATH = "docs/arc_benchmark_results.md";

fn write_md_truncate(content: []const u8) !void {
    var file = try std.fs.cwd().createFile(MD_PATH, .{ .truncate = true });
    defer file.close();
    try file.writeAll(content);
}

fn write_md_append(content: []const u8) !void {
    // Open existing or create if missing, without truncating.
    var file = std.fs.cwd().createFile(MD_PATH, .{ .truncate = false, .exclusive = false }) catch
        try std.fs.cwd().openFile(MD_PATH, .{ .mode = .read_write });
    defer file.close();
    try file.seekFromEnd(0);
    try file.writeAll(content);
}

// Formatting helpers (Zig 0.15 friendly): integers with thousands separators,
// and simple human unit scaling for rates.
fn fmt_u64_commas(buf: *[32]u8, value: u64) []const u8 {
    var i: usize = buf.len;
    var v = value;
    if (v == 0) {
        i -= 1;
        buf[i] = '0';
        return buf[i..];
    }
    var group: u32 = 0;
    while (v > 0) {
        const digit: u8 = @intCast(v % 10);
        v /= 10;
        i -= 1;
        buf[i] = '0' + digit;
        group += 1;
        if (v != 0 and group % 3 == 0) {
            i -= 1;
            buf[i] = ',';
        }
    }
    return buf[i..];
}

fn fmt_rate_human(buf: *[32]u8, rate: u64) []const u8 {
    if (rate >= 1_000_000_000) return fmt_u64_commas(buf, rate / 1_000_000_000); // G/s
    if (rate >= 1_000_000) return fmt_u64_commas(buf, rate / 1_000_000); // M/s
    if (rate >= 1_000) return fmt_u64_commas(buf, rate / 1_000); // K/s
    return fmt_u64_commas(buf, rate);
}

fn unit_suffix(rate: u64) []const u8 {
    if (rate >= 1_000_000_000) return "G/s";
    if (rate >= 1_000_000) return "M/s";
    if (rate >= 1_000) return "K/s";
    return "/s";
}

// Stats + helpers
const Stats = struct {
    ns_per_list: [16]u64 = .{0} ** 16,
    ops_s_list: [16]u64 = .{0} ** 16,
    len: usize = 0,
};

fn sortAsc(slice: []u64) void {
    var i: usize = 1;
    while (i < slice.len) : (i += 1) {
        var j: usize = i;
        while (j > 0 and slice[j - 1] > slice[j]) : (j -= 1) {
            const tmp = slice[j - 1];
            slice[j - 1] = slice[j];
            slice[j] = tmp;
        }
    }
}

fn medianIqr(slice_in: []const u64) struct { median: u64, q1: u64, q3: u64 } {
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

fn fmt_rate_u64(ops: u64, ns: u64) u64 {
    if (ns == 0) return 0;
    const num: u128 = @as(u128, ops) * 1_000_000_000;
    return @as(u64, @intCast(num / ns));
}

fn fmt_ns_per_u64(ops: u64, ns: u64) u64 {
    if (ops == 0) return 0;
    return @as(u64, @intCast(@as(u128, ns) / ops));
}

fn scale_iters(pilot_iters: u64, pilot_ns: u64, target_ms: u64) u64 {
    var eff_iters = pilot_iters;
    var eff_ns = pilot_ns;
    var guard: u32 = 0;
    while (eff_ns < 1_000_000 and guard < 8) { // ensure ~1ms pilot
        eff_iters *= 4;
        eff_ns *= 4;
        guard += 1;
    }
    if (eff_ns == 0) eff_ns = 1;
    const target_ns: u128 = @as(u128, target_ms) * 1_000_000;
    const iters_u128: u128 = (@as(u128, eff_iters) * target_ns + @as(u128, eff_ns) - 1) / @as(u128, eff_ns);
    const max_iters: u128 = 50_000_000;
    const bounded = if (iters_u128 > max_iters) max_iters else iters_u128;
    return @as(u64, @intCast(bounded));
}

fn record(stats: *Stats, ops: u64, ns: u64) void {
    if (stats.len >= stats.ns_per_list.len) return;
    stats.ns_per_list[stats.len] = fmt_ns_per_u64(ops, ns);
    stats.ops_s_list[stats.len] = fmt_rate_u64(ops, ns);
    stats.len += 1;
}

fn detectThreadCount() usize {
    const raw = std.Thread.getCpuCount() catch DEFAULT_MT_THREADS;
    const safe = if (raw == 0) DEFAULT_MT_THREADS else raw;
    const min_clamped = if (safe < MIN_MT_THREADS) MIN_MT_THREADS else safe;
    return if (min_clamped > MAX_MT_THREADS) MAX_MT_THREADS else min_clamped;
}

// Single-Threaded Benchmark
//
// This test measures the raw, best-case performance of `clone` and `release`
// operations without any cross-thread contention. It establishes the baseline
// overhead of the reference counting mechanism.
var global_gpa = std.heap.GeneralPurposeAllocator(.{}){};

fn getAllocator() std.mem.Allocator {
    return global_gpa.allocator();
}

fn benchCloneReleaseType(comptime T: type, value: T, target_ms: u64, repeats: usize) !struct { stats: Stats, iterations: u64 } {
    const allocator = getAllocator();
    const ArcType = ArcModule.Arc(T);
    const pilot_iters: u64 = 100_000;

    var arc_pilot = try ArcType.init(allocator, value);
    defer arc_pilot.release();
    var t0 = try Timer.start();
    var i: u64 = 0;
    while (i < pilot_iters) : (i += 1) {
        const c = arc_pilot.clone();
        c.release();
    }
    const pilot_ns = t0.read();
    const run_iters = scale_iters(pilot_iters, pilot_ns, target_ms);

    var stats = Stats{};
    var rep: usize = 0;
    while (rep < repeats) : (rep += 1) {
        var arc = try ArcType.init(allocator, value);
        defer arc.release();
        var timer = try Timer.start();
        i = 0;
        while (i < run_iters) : (i += 1) {
            const c = arc.clone();
            c.release();
        }
        const ns = timer.read();
        record(&stats, run_iters, ns);
    }

    return .{ .stats = stats, .iterations = run_iters };
}

pub fn run_single(mt_threads: usize) !void {
    const allocator = getAllocator();
    // quick-mode params
    const target_ms_st: u64 = 100;
    const warmups: usize = 0;
    const repeats: usize = 2;
    // Pilot
    var arc_pilot = try ArcU64.init(allocator, 123);
    defer arc_pilot.release();
    var t0 = try Timer.start();
    var i: u64 = 0;
    while (i < 100_000) : (i += 1) {
        const c = arc_pilot.clone();
        c.release();
    }
    const pilot_ns = t0.read();
    const run_iters = scale_iters(100_000, pilot_ns, target_ms_st);
    // Measured runs
    var stats = Stats{};
    var w: usize = 0;
    while (w < warmups) : (w += 1) {
        var arc_w = try ArcU64.init(allocator, 123);
        defer arc_w.release();
        var t = try Timer.start();
        i = 0;
        while (i < run_iters) : (i += 1) {
            const c = arc_w.clone();
            c.release();
        }
        _ = t.read();
    }
    var rep: usize = 0;
    while (rep < repeats) : (rep += 1) {
        var arc = try ArcU64.init(allocator, 123);
        defer arc.release();
        var timer = try Timer.start();
        i = 0;
        while (i < run_iters) : (i += 1) {
            const c = arc.clone();
            c.release();
        }
        const ns = timer.read();
        record(&stats, run_iters, ns);
    }

    // Header, Legend, Config, Machine
    var header_buf: [2048]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&header_buf);
    const wr = fbs.writer();
    const builtin = @import("builtin");
    const os_tag = @tagName(builtin.os.tag);
    const arch_tag = @tagName(builtin.cpu.arch);
    const mode_tag = @tagName(builtin.mode);
    const ptr_bits: usize = @sizeOf(usize) * 8;
    const zig_ver = builtin.zig_version_string;
    const cpu_count = std.Thread.getCpuCount() catch 0;
    try wr.print(
        "# ARC Benchmark Results\n\n" ++
            "## Legend\n" ++
            "- Iterations: number of clone+release pairs per measured run.\n" ++
            "- ns/op: latency per pair (lower is better).\n" ++
            "- ops/s: pairs per second (higher is better).\n\n" ++
            "## Config\n" ++
            "- iterations: {d}\n" ++
            "- threads (MT): {d}\n\n" ++
            "## Machine\n" ++
            "- OS: {s}\n- Arch: {s}\n- Zig: {s}\n- Build Mode: {s}\n- Pointer Width: {}-bit\n- Logical CPUs: {}\n\n",
        .{ run_iters, mt_threads, os_tag, arch_tag, zig_ver, mode_tag, ptr_bits, cpu_count },
    );
    try wr.print("## Single-Threaded\n", .{});
    const med = medianIqr(stats.ns_per_list[0..stats.len]);
    const thr = medianIqr(stats.ops_s_list[0..stats.len]);
    var nb: [32]u8 = undefined;
    var nb2: [32]u8 = undefined;
    var nb3: [32]u8 = undefined;
    var nb4: [32]u8 = undefined;
    const s_iters = fmt_u64_commas(&nb, run_iters);
    const s_ns_med = fmt_u64_commas(&nb2, med.median);
    const s_ops = fmt_u64_commas(&nb3, thr.median);
    const s_ops_h = fmt_rate_human(&nb4, thr.median);
    try wr.print("- Iterations: {s}\n", .{s_iters});
    try wr.print("- Latency (ns/op) median (IQR): {s} ({d}–{d})\n", .{ s_ns_med, med.q1, med.q3 });
    try wr.print("- Throughput: {s} (≈ {s} {s})\n\n", .{ s_ops, s_ops_h, unit_suffix(thr.median) });
    try write_md_truncate(fbs.getWritten());
    // Console summary
    std.debug.print("ARC ST  iters={}  ns/op={} ({}–{})  ops/s={}\n", .{ run_iters, med.median, med.q1, med.q3, thr.median });
}

// # Multi-Threaded Benchmark
//
// This test measures the performance of `clone` and `release` under high
// contention. Multiple threads will hammer the same shared `Arc` instance,
// stress-testing the atomic operations and the CAS loop in `clone`.
// This is a true test of the library's scalability.

// Context for each worker thread in the multi-threaded benchmark.
// Holds the shared Arc pointer and the iteration budget for that thread.
const WorkerContext = struct {
    iterations: u64,
    shared_arc: *const ArcU64,
};

const PoolPayload = [64]u8;
const PoolPayloadLen = 64;
const PoolType = ArcPoolModule.ArcPool(PoolPayload);

const PoolWorkerCtx = struct {
    pool: *PoolType,
    iterations: u64,
};

fn benchmarkWorker(ctx: *WorkerContext) void {
    var i: u64 = 0;
    while (i < ctx.iterations) : (i += 1) {
        const clone = ctx.shared_arc.clone();
        clone.release();
    }
}

// Worker used in the ArcPool benchmark: continuously create/recycle nodes.
fn poolWorker(ctx: *PoolWorkerCtx) void {
    var i: u64 = 0;
    while (i < ctx.iterations) : (i += 1) {
        const arc = ctx.pool.create([_]u8{@intCast(i & 0xFF)} ** PoolPayloadLen) catch unreachable;
        ctx.pool.recycle(arc);
    }
}

/// Measure clone/release throughput for a shared Arc across multiple threads.
fn benchMultiCloneRelease(
    allocator: std.mem.Allocator,
    threads: usize,
    target_ms: u64,
    repeats: usize,
) !struct { stats: Stats, total_pairs: u64, per_thread: u64 } {
    const pilot_iters: u64 = 100_000;
    var pilot_arc = try ArcU64.init(allocator, 456);
    defer pilot_arc.release();
    var timer = try Timer.start();
    var i: u64 = 0;
    while (i < pilot_iters) : (i += 1) {
        const clone = pilot_arc.clone();
        clone.release();
    }
    const pilot_ns = timer.read();
    const per_thread_iters = scale_iters(pilot_iters, pilot_ns, target_ms);
    const total_iters = per_thread_iters * @as(u64, threads);

    var stats = Stats{};
    var rep: usize = 0;
    while (rep < repeats) : (rep += 1) {
        var shared_arc = try ArcU64.init(allocator, 456);
        defer shared_arc.release();

        const handles = try allocator.alloc(Thread, threads);
        defer allocator.free(handles);
        const contexts = try allocator.alloc(WorkerContext, threads);
        defer allocator.free(contexts);

        var idx: usize = 0;
        while (idx < threads) : (idx += 1) {
            contexts[idx] = .{
                .iterations = per_thread_iters,
                .shared_arc = &shared_arc,
            };
            handles[idx] = try Thread.spawn(.{}, benchmarkWorker, .{ &contexts[idx] });
        }

        timer = try Timer.start();
        for (handles) |handle| handle.join();
        const ns = timer.read();
        record(&stats, total_iters, ns);
    }

    return .{ .stats = stats, .total_pairs = total_iters, .per_thread = per_thread_iters };
}

pub fn run_multi(thread_count: usize) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const result = try benchMultiCloneRelease(allocator, thread_count, 150, 2);
    const med = medianIqr(result.stats.ns_per_list[0..result.stats.len]);
    const thr = medianIqr(result.stats.ops_s_list[0..result.stats.len]);

    var nb1: [32]u8 = undefined;
    var nb2: [32]u8 = undefined;
    var nb3: [32]u8 = undefined;
    var nb4: [32]u8 = undefined;
    var nb5: [32]u8 = undefined;
    const s_iters = fmt_u64_commas(&nb1, result.per_thread);
    const s_total = fmt_u64_commas(&nb2, result.total_pairs);
    const s_ns = fmt_u64_commas(&nb3, med.median);
    const s_ops = fmt_u64_commas(&nb4, thr.median);
    const ops_h = fmt_rate_human(&nb5, thr.median);

    std.debug.print(
        "ARC MT  threads={} iters/thread={} total_pairs={} ns/op={} ({}–{})  ops/s={}\n",
        .{ thread_count, result.per_thread, result.total_pairs, med.median, med.q1, med.q3, thr.median },
    );

    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();
    try w.print("## Multi-Threaded ({d} threads)\n", .{thread_count});
    try w.print("- iters/thread: {s}\n", .{s_iters});
    try w.print("- total pairs: {s}\n", .{s_total});
    try w.print("- ns/op median (IQR): {s} ({d}–{d})\n", .{ s_ns, med.q1, med.q3 });
    try w.print("- ops/s median: {s} (≈ {s} {s})\n\n", .{ s_ops, ops_h, unit_suffix(thr.median) });
    try write_md_append(fbs.getWritten());
}

fn benchDowngradeUpgrade(comptime T: type, value: T, target_ms: u64, repeats: usize) !struct { stats: Stats, iterations: u64 } {
    const ArcType = ArcModule.Arc(T);
    const allocator = getAllocator();
    const pilot_iters: u64 = 50_000;

    var arc = try ArcType.init(allocator, value);
    defer arc.release();
    var timer = try Timer.start();
    var i: u64 = 0;
    while (i < pilot_iters) : (i += 1) {
        if (arc.downgrade()) |weak| {
            if (weak.upgrade()) |tmp| tmp.release();
            weak.release();
        }
    }
    const pilot_ns = timer.read();
    const run_iters = scale_iters(pilot_iters, pilot_ns, target_ms);

    var stats = Stats{};
    var rep: usize = 0;
    while (rep < repeats) : (rep += 1) {
        var bench_arc = try ArcType.init(allocator, value);
        defer bench_arc.release();
        timer = try Timer.start();
        i = 0;
        while (i < run_iters) : (i += 1) {
            if (bench_arc.downgrade()) |weak| {
                if (weak.upgrade()) |tmp| tmp.release();
                weak.release();
            }
        }
        const ns = timer.read();
        record(&stats, run_iters, ns);
    }

    return .{ .stats = stats, .iterations = run_iters };
}

fn benchRawHeapChurn(value: [64]u8, target_ms: u64, repeats: usize) !struct { stats: Stats, iterations: u64 } {
    const pilot_iters: u64 = 50_000;
    const allocator = getAllocator();
    var timer = try Timer.start();
    var i: u64 = 0;
    while (i < pilot_iters) : (i += 1) {
        var arc = try ArcArray64.init(allocator, value);
        arc.release();
    }
    const pilot_ns = timer.read();
    const run_iters = scale_iters(pilot_iters, pilot_ns, target_ms);

    var stats = Stats{};
    var rep: usize = 0;
    while (rep < repeats) : (rep += 1) {
        timer = try Timer.start();
        i = 0;
        while (i < run_iters) : (i += 1) {
            var arc = try ArcArray64.init(allocator, value);
            arc.release();
        }
        const ns = timer.read();
        record(&stats, run_iters, ns);
    }

    return .{ .stats = stats, .iterations = run_iters };
}

fn benchPoolChurn(pool: *ArcPoolModule.ArcPool([64]u8), value: [64]u8, target_ms: u64, repeats: usize) !struct { stats: Stats, iterations: u64 } {
    const pilot_iters: u64 = 50_000;
    var timer = try Timer.start();
    var i: u64 = 0;
    while (i < pilot_iters) : (i += 1) {
        const arc = try pool.create(value);
        pool.recycle(arc);
    }
    const pilot_ns = timer.read();
    const run_iters = scale_iters(pilot_iters, pilot_ns, target_ms);

    var stats = Stats{};
    var rep: usize = 0;
    while (rep < repeats) : (rep += 1) {
        timer = try Timer.start();
        i = 0;
        while (i < run_iters) : (i += 1) {
            const arc = try pool.create(value);
            pool.recycle(arc);
        }
        const ns = timer.read();
        record(&stats, run_iters, ns);
        pool.drainThreadCache();
    }

    return .{ .stats = stats, .iterations = run_iters };
}

/// Spawn `thread_count` workers that hammer `ArcPool.create`/`recycle`.
fn measurePoolChurnMT(pool: *PoolType, allocator: std.mem.Allocator, thread_count: usize, iterations: u64) !u64 {
    const handles = try allocator.alloc(Thread, thread_count);
    defer allocator.free(handles);
    const contexts = try allocator.alloc(PoolWorkerCtx, thread_count);
    defer allocator.free(contexts);

    var idx: usize = 0;
    while (idx < thread_count) : (idx += 1) {
        contexts[idx] = .{ .pool = pool, .iterations = iterations };
        handles[idx] = try Thread.spawn(.{}, poolWorker, .{ &contexts[idx] });
    }

    var timer = try Timer.start();
    for (handles) |handle| handle.join();
    const ns = timer.read();
    pool.drainThreadCache();
    return ns;
}

/// Multi-threaded ArcPool benchmark (uses `measurePoolChurnMT` under the hood).
fn benchPoolChurnMT(thread_count: usize, target_ms: u64, repeats: usize) !struct { stats: Stats, iterations: u64 } {
    const allocator = getAllocator();
    const pilot_iters: u64 = 20_000;

    var pilot_pool = PoolType.init(allocator);
    const pilot_ns = try measurePoolChurnMT(&pilot_pool, allocator, thread_count, pilot_iters);
    pilot_pool.deinit();

    const per_thread_iters = scale_iters(pilot_iters, pilot_ns, target_ms);
    const total_iters = per_thread_iters * @as(u64, thread_count);

    var stats = Stats{};
    var rep: usize = 0;
    while (rep < repeats) : (rep += 1) {
        var pool = PoolType.init(allocator);
        const ns = try measurePoolChurnMT(&pool, allocator, thread_count, per_thread_iters);
        pool.deinit();
        record(&stats, total_iters, ns);
    }

    return .{ .stats = stats, .iterations = total_iters };
}

fn writeBenchRow(wr: anytype, label: []const u8, iterations: u64, stats: Stats) !void {
    var nb1: [32]u8 = undefined;
    var nb2: [32]u8 = undefined;
    var nb3: [32]u8 = undefined;
    const med = medianIqr(stats.ns_per_list[0..stats.len]);
    const thr = medianIqr(stats.ops_s_list[0..stats.len]);
    const s_iters = fmt_u64_commas(&nb1, iterations);
    const s_ns = fmt_u64_commas(&nb2, med.median);
    const s_ops = fmt_u64_commas(&nb3, thr.median);
    try wr.print("| {s} | {s} | {s} | {s} |\n", .{ label, s_iters, s_ns, s_ops });
}

pub fn run_svo_vs_heap() !void {
    const inline_result = try benchCloneReleaseType(u32, 123, 60, 2);
    const heap_result = try benchCloneReleaseType([64]u8, [_]u8{7} ** 64, 60, 2);

    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const wr = fbs.writer();

    try wr.print("## SVO vs Heap Clone Throughput\n", .{});
    try wr.print("| Variant | Iterations | ns/op (median) | ops/s (median) |\n", .{});
    try wr.print("| --- | --- | --- | --- |\n", .{});
    try writeBenchRow(wr, "SVO (u32)", inline_result.iterations, inline_result.stats);
    try writeBenchRow(wr, "Heap ([64]u8)", heap_result.iterations, heap_result.stats);
    try wr.print("\n", .{});
    try write_md_append(fbs.getWritten());
}

pub fn run_downgrade_upgrade() !void {
    const result = try benchDowngradeUpgrade([64]u8, [_]u8{5} ** 64, 60, 2);

    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const wr = fbs.writer();

    try wr.print("## Downgrade + Upgrade Benchmark\n", .{});
    try wr.print("| Operation | Iterations | ns/op (median) | ops/s (median) |\n", .{});
    try wr.print("| --- | --- | --- | --- |\n", .{});
    try writeBenchRow(wr, "downgrade+upgrade", result.iterations, result.stats);
    try wr.print("\n", .{});
    try write_md_append(fbs.getWritten());
}

/// Compare raw heap allocations vs ArcPool reuse (single-threaded).
pub fn run_pool_churn() !void {
    var pool = ArcPoolModule.ArcPool([64]u8).init(getAllocator());
    defer pool.deinit();

    const raw_result = try benchRawHeapChurn([_]u8{9} ** 64, 60, 2);
    const pool_result = try benchPoolChurn(&pool, [_]u8{9} ** 64, 60, 2);

    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const wr = fbs.writer();

    try wr.print("## Heap vs ArcPool Create/Recycle Benchmark\n", .{});
    try wr.print("| Scenario | Iterations | ns/op (median) | ops/s (median) |\n", .{});
    try wr.print("| --- | --- | --- | --- |\n", .{});
    try writeBenchRow(wr, "direct heap", raw_result.iterations, raw_result.stats);
    try writeBenchRow(wr, "ArcPool recycle", pool_result.iterations, pool_result.stats);
    try wr.print("\n", .{});
    try write_md_append(fbs.getWritten());
}

/// Measure ArcPool churn when multiple threads share the pool.
pub fn run_pool_churn_mt(thread_count: usize) !void {
    const result = try benchPoolChurnMT(thread_count, 120, 2);
    const med = medianIqr(result.stats.ns_per_list[0..result.stats.len]);
    const thr = medianIqr(result.stats.ops_s_list[0..result.stats.len]);

    var nb1: [32]u8 = undefined;
    var nb2: [32]u8 = undefined;
    var nb3: [32]u8 = undefined;
    var nb4: [32]u8 = undefined;
    var nb5: [32]u8 = undefined;
    const s_iters = fmt_u64_commas(&nb1, result.iterations / @as(u64, thread_count));
    const s_total = fmt_u64_commas(&nb2, result.iterations);
    const s_ns = fmt_u64_commas(&nb3, med.median);
    const s_ops = fmt_u64_commas(&nb4, thr.median);
    const ops_h = fmt_rate_human(&nb5, thr.median);

    std.debug.print(
        "ArcPool MT  threads={} total_pairs={} ns/op={} ({}–{}) ops/s={}\n",
        .{ thread_count, result.iterations, med.median, med.q1, med.q3, thr.median },
    );

    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const wr = fbs.writer();
    try wr.print("## ArcPool Multi-Threaded ({d} threads)\n", .{thread_count});
    try wr.print("- iters/thread: {s}\n", .{s_iters});
    try wr.print("- total pairs: {s}\n", .{s_total});
    try wr.print("- ns/op median (IQR): {s} ({d}–{d})\n", .{ s_ns, med.q1, med.q3 });
    try wr.print("- ops/s median: {s} (≈ {s} {s})\n\n", .{ s_ops, ops_h, unit_suffix(thr.median) });
    try write_md_append(fbs.getWritten());
}

fn shouldRunMT() bool {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var env = std.process.getEnvMap(arena.allocator()) catch return false;
    if (env.get("ARC_BENCH_RUN_MT")) |v| {
        return std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "true");
    }
    return false;
}

pub fn main() !void {
    const mt_threads = detectThreadCount();
    try run_single(mt_threads);
    if (shouldRunMT()) {
        try run_multi(mt_threads);
        try run_pool_churn_mt(mt_threads);
    }
    try run_svo_vs_heap();
    try run_downgrade_upgrade();
    try run_pool_churn();
}
