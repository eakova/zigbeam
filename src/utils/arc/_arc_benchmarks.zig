// FILE: _arc_benchmarks.zig
//! Benchmarks for Arc and ArcPool.
//!
//! Purpose:
//! - Measure single-threaded and multi-threaded clone/release throughput for Arc.
//! - Measure ArcPool create/recycle throughput, including stats on/off comparisons.
//! - Produce a Markdown report under `docs/utils/arc_benchmark_results.md` and
//!   print a short console summary for quick checks.
//!
//! Quick run:
//! - `ARC_BENCH_RUN_MT=1 zig build -Doptimize=ReleaseFast bench-arc`
//! - Reports: `docs/utils/arc_benchmark_results.md`

const std = @import("std");
const testing = std.testing;
const Thread = std.Thread;
const Timer = std.time.Timer;
const beam = @import("zig_beam");
const ArcU64 = beam.Utils.Arc(u64);
const ArcArray64 = beam.Utils.Arc([64]u8);
const ArcPoolModule = beam.Utils;

// --- Benchmark Configuration ---
// The number of clone/release pairs to perform in each benchmark run.
// A larger number gives more stable results.
const DEFAULT_MT_THREADS: usize = 4;
const MIN_MT_THREADS: usize = 2;
const MAX_MT_THREADS: usize = 16;

const MD_PATH = "docs/utils/arc_benchmark_results.md";
// Iteration-based cap per scenario (total across threads).
// For a given threads count N, each thread runs roughly MAX_TOTAL_ITERS / N iterations.
const MAX_TOTAL_ITERS: u64 = 250_000_000;

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

// Format f64 with thousands separators and two decimals.
fn fmt_f64_commas2(buf: *[48]u8, val: f64) []const u8 {
    var out_i: usize = 0;
    const ival_f = @floor(val);
    const ival = @as(u64, @intFromFloat(ival_f));
    var frac_f = (val - ival_f) * 100.0;
    if (frac_f < 0) frac_f = -frac_f;
    const frac = @as(u64, @intFromFloat(frac_f + 0.5));
    var ibuf: [32]u8 = undefined;
    const is = fmt_u64_commas(&ibuf, ival);
    // copy integer part
    @memcpy(buf[out_i .. out_i + is.len], is);
    out_i += is.len;
    // decimal point and two digits
    buf[out_i] = '.'; out_i += 1;
    const tens: u8 = @intCast((frac / 10) % 10);
    const ones: u8 = @intCast(frac % 10);
    buf[out_i] = '0' + tens; out_i += 1;
    buf[out_i] = '0' + ones; out_i += 1;
    return buf[0..out_i];
}

// Scale f64 rate to human units and return suffix; writes scaled value into *scaled.
fn scale_rate_f64(scaled: *f64, rate: f64) []const u8 {
    if (rate >= 1_000_000_000.0) { scaled.* = rate / 1_000_000_000.0; return "G/s"; }
    if (rate >= 1_000_000.0) { scaled.* = rate / 1_000_000.0; return "M/s"; }
    if (rate >= 1_000.0) { scaled.* = rate / 1_000.0; return "K/s"; }
    scaled.* = rate; return "/s";
}

fn unit_suffix(rate: u64) []const u8 {
    if (rate >= 1_000_000_000) return "G/s";
    if (rate >= 1_000_000) return "M/s";
    if (rate >= 1_000) return "K/s";
    return "/s";
}

// Stats + helpers
const Stats = struct {
    // Integer summaries (kept for compatibility with existing tables)
    ns_per_list: [16]u64 = .{0} ** 16,
    ops_s_list: [16]u64 = .{0} ** 16,
    // Raw per-run measurements to enable f64-friendly calculations
    ns_list: [16]u64 = .{0} ** 16,
    ops_list: [16]u64 = .{0} ** 16,
    len: usize = 0,
};

// Common return type for small bench helpers to avoid anonymous-struct
// mismatch across functions returning the same shape.
const BenchRes = struct { stats: Stats, iterations: u64 };

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

// Produce a short fractional ns/op approximation from ops/s.
// Returns a string like "0.42" or "<0.01" using hundredths of a ns precision.
fn fmt_ns_from_ops(buf: *[32]u8, ops_s: u64) []const u8 {
    if (ops_s == 0) return "n/a";
    const hundred_ns: u64 = 100_000_000_000; // 1e9 * 100
    const ns100: u64 = hundred_ns / ops_s;
    if (ns100 == 0) return "<0.01";
    // Format integer with two decimal places inserted.
    var tmp: [32]u8 = undefined;
    var s = fmt_u64_commas(&tmp, ns100); // no commas expected for small ns100
    // Build into buf with decimal point before last two digits.
    if (s.len <= 2) {
        // 0.xx
        var i: usize = 0;
        buf[i] = '0'; i += 1;
        buf[i] = '.'; i += 1;
        // pad leading zeros if needed
        if (s.len == 1) { buf[i] = '0'; i += 1; }
        @memcpy(buf[i .. i + s.len], s);
        i += s.len;
        return buf[0..i];
    } else {
        const int_len = s.len - 2;
        @memcpy(buf[0..int_len], s[0..int_len]);
        buf[int_len] = '.';
        @memcpy(buf[int_len + 1 .. int_len + 3], s[int_len .. int_len + 2]);
        return buf[0 .. int_len + 3];
    }
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
    stats.ns_list[stats.len] = ns;
    stats.ops_list[stats.len] = ops;
    stats.len += 1;
}

// f64-friendly helpers (raw ratio medians)
const F64Iqr = struct { median: f64, q1: f64, q3: f64 };

fn computeMedianIqrF64(ratio_fn: fn (u64, u64) f64, ns_list: []const u64, ops_list: []const u64, n: usize) F64Iqr {
    if (n == 0) return .{ .median = 0.0, .q1 = 0.0, .q3 = 0.0 };
    var buf: [16]f64 = .{0.0} ** 16;
    var i: usize = 0;
    while (i < n) : (i += 1) buf[i] = ratio_fn(ns_list[i], ops_list[i]);
    // insertion sort
    var k: usize = 1;
    while (k < n) : (k += 1) {
        var j: usize = k;
        while (j > 0 and buf[j - 1] > buf[j]) : (j -= 1) {
            const tmp = buf[j - 1];
            buf[j - 1] = buf[j];
            buf[j] = tmp;
        }
    }
    const mid = n / 2;
    const med = if (n % 2 == 1) buf[mid] else (buf[mid - 1] + buf[mid]) / 2.0;
    const q1 = buf[n / 4];
    const q3 = buf[(3 * n) / 4];
    return .{ .median = med, .q1 = q1, .q3 = q3 };
}

fn ratio_ns_per_op(ns: u64, ops: u64) f64 {
    if (ops == 0) return 0.0;
    return @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(ops));
}

fn ratio_ops_per_sec(ns: u64, ops: u64) f64 {
    if (ns == 0) return 0.0;
    const num = @as(f64, @floatFromInt(ops)) * 1_000_000_000.0;
    return num / @as(f64, @floatFromInt(ns));
}

fn medianIqrNsPerOpF64(stats: *const Stats) F64Iqr {
    return computeMedianIqrF64(ratio_ns_per_op, stats.ns_list[0..stats.len], stats.ops_list[0..stats.len], stats.len);
}

fn medianIqrOpsPerSecF64(stats: *const Stats) F64Iqr {
    return computeMedianIqrF64(ratio_ops_per_sec, stats.ns_list[0..stats.len], stats.ops_list[0..stats.len], stats.len);
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
fn getAllocator() std.mem.Allocator {
    // Use libc malloc/free for peak allocation throughput in benches.
    return std.heap.c_allocator;
}

fn benchCloneReleaseType(comptime T: type, value: T, target_ms: u64, repeats: usize) !struct { stats: Stats, iterations: u64 } {
    const allocator = getAllocator();
    const ArcType = beam.Utils.Arc(T);
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

pub fn run_single(_: usize) !void {
    const allocator = getAllocator();
    // quick-mode params
    const target_ms_st: u64 = 300;
    const warmups: usize = 0;
    const repeats: usize = 2;
    // Pilot
    // Use a heap-backed Arc payload to avoid SVO and ensure measurable work.
    var arc_pilot = try ArcArray64.init(allocator, [_]u8{1} ** 64);
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
        var arc_w = try ArcArray64.init(allocator, [_]u8{1} ** 64);
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
        var arc = try ArcArray64.init(allocator, [_]u8{1} ** 64);
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

    // Only write requested tables (truncate file first)
    try write_md_truncate("");
    try run_arc_scaling_tables();
    try run_arc_downgrade_tables();
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
const PoolTypeOn = ArcPoolModule.ArcPool(PoolPayload, true);
const PoolTypeOff = ArcPoolModule.ArcPool(PoolPayload, false);
const PoolOff8 = ArcPoolModule.ArcPool(PoolPayload, false);
// Capacity variants now use ArcPool + Options (runtime tls_active_capacity)
const PoolOff16 = PoolTypeOff;
const PoolOff32 = PoolTypeOff;
const PoolOff64 = PoolTypeOff;

const PoolWorkerCtxOn = struct {
    pool: *PoolTypeOn,
    iterations: u64,
    start_flag: *std.atomic.Value(usize),
};

const PoolWorkerCtxOff = struct {
    pool: *PoolTypeOff,
    iterations: u64,
    start_flag: *std.atomic.Value(usize),
};

fn benchmarkWorker(ctx: *WorkerContext) void {
    var i: u64 = 0;
    while (i < ctx.iterations) : (i += 1) {
        const clone = ctx.shared_arc.clone();
        clone.release();
    }
}

// Worker used in the ArcPool benchmark: continuously create/recycle nodes.
fn poolWorkerOn(ctx: *PoolWorkerCtxOn) void {
    var i: u64 = 0;
    // Fixed payload: isolate pool cost from per-iteration construction.
    const payload = [_]u8{0} ** PoolPayloadLen;
    // Warm-up TLS cache to a steady state (unmeasured).
    var w: usize = 0;
    while (w < 128) : (w += 1) {
        const arc_w = ctx.pool.create(payload) catch unreachable;
        ctx.pool.recycle(arc_w);
    }
    // Barrier: wait for the global start flag to begin measured work.
    while (ctx.start_flag.load(.seq_cst) == 0) {
        std.Thread.yield() catch {};
    }
    // Measured work.
    while (i < ctx.iterations) : (i += 1) {
        const arc = ctx.pool.create(payload) catch unreachable;
        ctx.pool.recycle(arc);
    }
}

fn poolWorkerOff(ctx: *PoolWorkerCtxOff) void {
    var i: u64 = 0;
    const payload = [_]u8{0} ** PoolPayloadLen;
    var w: usize = 0;
    while (w < 128) : (w += 1) {
        const arc_w = ctx.pool.create(payload) catch unreachable;
        ctx.pool.recycle(arc_w);
    }
    while (ctx.start_flag.load(.seq_cst) == 0) {
        std.Thread.yield() catch {};
    }
    while (i < ctx.iterations) : (i += 1) {
        const arc = ctx.pool.create(payload) catch unreachable;
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

fn benchMultiCloneReleaseType(
    comptime T: type,
    allocator: std.mem.Allocator,
    threads: usize,
    value: T,
    _: u64,
) !struct { stats: Stats, total_pairs: u64, per_thread: u64 } {
    const ArcType = beam.Utils.Arc(T);
    var per_thread_iters: u64 = 1;
    if (threads > 0) {
        // Divide total budget across threads; ensure at least 1 iteration per thread.
        const div = MAX_TOTAL_ITERS / @as(u64, threads);
        per_thread_iters = if (div == 0) 1 else div;
    }
    const Ctx = struct { shared_arc: *const ArcType, iterations: u64 };
    const Worker = struct {
        fn run(ctx: *Ctx) void {
            var i: u64 = 0;
            while (i < ctx.iterations) : (i += 1) {
                const c = ctx.shared_arc.*.clone();
                c.release();
            }
        }
    };

    var stats = Stats{};
    var shared_arc = try ArcType.init(allocator, value);
    defer shared_arc.release();
    const handles = try allocator.alloc(Thread, threads);
    defer allocator.free(handles);
    const contexts = try allocator.alloc(Ctx, threads);
    defer allocator.free(contexts);
    var idx: usize = 0;
    while (idx < threads) : (idx += 1) {
        contexts[idx] = .{ .shared_arc = &shared_arc, .iterations = per_thread_iters };
        handles[idx] = try Thread.spawn(.{}, Worker.run, .{ &contexts[idx] });
    }
    var timer = try Timer.start();
    for (handles) |h| h.join();
    const ns = timer.read();
    const total_ops: u64 = per_thread_iters * @as(u64, threads);
    record(&stats, total_ops, ns);
    return .{ .stats = stats, .total_pairs = total_ops, .per_thread = per_thread_iters };
}

fn writeArcRowNoVariant(wr: anytype, threads: usize, iterations: u64, stats: Stats) !void {
    var nb1: [32]u8 = undefined;
    const s_thr = fmt_u64_commas(&nb1, threads);
    var nb2: [32]u8 = undefined;
    const s_iters = fmt_u64_commas(&nb2, iterations);
    const nsf = medianIqrNsPerOpF64(&stats);
    const opsf = medianIqrOpsPerSecF64(&stats);
    const ns_display = if (nsf.median > 0.009) nsf.median else -1.0;
    var scaled: f64 = 0; const unit = scale_rate_f64(&scaled, opsf.median);
    var fbuf: [48]u8 = undefined; const s_rate = fmt_f64_commas2(&fbuf, scaled);
    if (ns_display >= 0) {
        try wr.print("| {s} | {s} | {d:.2} | {s} {s} |\n", .{ s_thr, s_iters, ns_display, s_rate, unit });
    } else {
        try wr.print("| {s} | {s} | <0.01 | {s} {s} |\n", .{ s_thr, s_iters, s_rate, unit });
    }
}

fn run_arc_scaling_tables() !void {
    const allocator = getAllocator();
    // Note: 16-thread rows temporarily disabled to keep runs shorter.
    // const threads_list_all = [_]usize{1,4,8,16};
    const threads_list = [_]usize{1,4,8};
    // Iteration-capped mode: no env/time knobs are used.
    const target_ms: u64 = 0;

    // Simple Value Object (SVO)
    // Capture results to reuse in the Clone Throughput table without re-running.
    var svo_iters: [4]u64 = .{0} ** 4;
    var svo_stats: [4]Stats = .{ .{}, .{}, .{}, .{} };
    var buf1: [768]u8 = undefined; var fbs1 = std.io.fixedBufferStream(&buf1); const wr1 = fbs1.writer();
    try wr1.print("### Arc - SVO- (u32)\n", .{});
    try wr1.print("| Thread(s) |  Iterations | ns/op (median) | Throughput (ops/s) |\n| --- | --- | --- | --- |\n", .{});
    for (threads_list, 0..) |tc, idx| {
        const res = try benchMultiCloneReleaseType(u32, allocator, tc, 123, target_ms);
        svo_iters[idx] = MAX_TOTAL_ITERS;
        svo_stats[idx] = res.stats;
        try writeArcRowNoVariant(wr1, tc, MAX_TOTAL_ITERS, res.stats);
    }
    try wr1.print("\n", .{});
    try write_md_append(fbs1.getWritten());

    // Heap ([64]u8)
    // Capture results to reuse in the Clone Throughput table without re-running.
    var heap_iters: [4]u64 = .{0} ** 4;
    var heap_stats: [4]Stats = .{ .{}, .{}, .{}, .{} };
    var buf2: [768]u8 = undefined; var fbs2 = std.io.fixedBufferStream(&buf2); const wr2 = fbs2.writer();
    try wr2.print("### Arc - Heap - ([64]u8)\n", .{});
    try wr2.print("| Thread(s) |  Iterations | ns/op (median) | Throughput (ops/s) |\n| --- | --- | --- | --- |\n", .{});
    for (threads_list, 0..) |tc, idx| {
        const res = try benchMultiCloneReleaseType([64]u8, allocator, tc, [_]u8{7} ** 64, target_ms);
        heap_iters[idx] = MAX_TOTAL_ITERS;
        heap_stats[idx] = res.stats;
        try writeArcRowNoVariant(wr2, tc, MAX_TOTAL_ITERS, res.stats);
    }
    try wr2.print("\n", .{});
    try write_md_append(fbs2.getWritten());

    // Clone Throughput (SVO)
    var buf3: [768]u8 = undefined; var fbs3 = std.io.fixedBufferStream(&buf3); const wr3 = fbs3.writer();
    try wr3.print("### Arc - SVO Clone Throughput - (u32)\n", .{});
    try wr3.print("| Thread(s) |  Iterations | ns/op (median) | Throughput (ops/s) |\n| --- | --- | --- | --- |\n", .{});
    // Reuse results from SVO table (no re-bench)
    for (threads_list, 0..) |tc, idx| {
        try writeArcRowNoVariant(wr3, tc, svo_iters[idx], svo_stats[idx]);
    }
    try wr3.print("\n", .{});
    try write_md_append(fbs3.getWritten());

    // Clone Throughput (Heap)
    var buf4: [768]u8 = undefined; var fbs4 = std.io.fixedBufferStream(&buf4); const wr4 = fbs4.writer();
    try wr4.print("### Arc - Heap Clone Throughput - ([64]u8)\n", .{});
    try wr4.print("| Thread(s) |  Iterations | ns/op (median) | Throughput (ops/s) |\n| --- | --- | --- | --- |\n", .{});
    for (threads_list, 0..) |tc, idx| {
        try writeArcRowNoVariant(wr4, tc, heap_iters[idx], heap_stats[idx]);
    }
    try wr4.print("\n", .{});
    try write_md_append(fbs4.getWritten());
}

fn benchMultiDowngradeUpgradeType(
    comptime T: type,
    allocator: std.mem.Allocator,
    threads: usize,
    value: T,
    _: u64,
) !struct { stats: Stats, total_pairs: u64 } {
    const ArcType = beam.Utils.Arc(T);
    var per_thread_iters: u64 = 1;
    if (threads > 0) {
        const div = MAX_TOTAL_ITERS / @as(u64, threads);
        per_thread_iters = if (div == 0) 1 else div;
    }
    const Ctx = struct { shared: *ArcType, iterations: u64 };
    const Worker = struct {
        fn run(ctx: *Ctx) void {
            var i: u64 = 0;
            while (i < ctx.iterations) : (i += 1) {
                if (ctx.shared.downgrade()) |weak| {
                    if (weak.upgrade()) |tmp| tmp.release();
                    weak.release();
                }
            }
        }
    };
    var stats = Stats{};
    var shared = try ArcType.init(allocator, value); defer shared.release();
    const handles = try allocator.alloc(Thread, threads); defer allocator.free(handles);
    const ctxs = try allocator.alloc(Ctx, threads); defer allocator.free(ctxs);
    var k: usize = 0; while (k < threads) : (k += 1) { ctxs[k] = .{ .shared = &shared, .iterations = per_thread_iters }; handles[k] = try Thread.spawn(.{}, Worker.run, .{ &ctxs[k] }); }
    var t = try Timer.start(); for (handles) |h| h.join(); const ns = t.read();
    const total_ops: u64 = per_thread_iters * @as(u64, threads);
    record(&stats, total_ops, ns);
    return .{ .stats = stats, .total_pairs = total_ops };
}

fn run_arc_downgrade_tables() !void {
    const allocator = getAllocator();
    // Note: 16-thread rows temporarily disabled to keep runs shorter.
    // const threads_list_all = [_]usize{1,4,8,16};
    const threads_list = [_]usize{1,4,8};
    const target_ms: u64 = 0; // iteration-capped mode

    var b1: [768]u8 = undefined; var s1 = std.io.fixedBufferStream(&b1); const w1 = s1.writer();
    try w1.print("### Arc - SVO Downgrade + Upgrade Throughput - (u32)\n", .{});
    try w1.print("| Thread(s) |  Iterations | ns/op (median) | Throughput (ops/s) |\n| --- | --- | --- | --- |\n", .{});
    for (threads_list) |tc| { const r = try benchMultiDowngradeUpgradeType(u32, allocator, tc, 123, target_ms); try writeArcRowNoVariant(w1, tc, MAX_TOTAL_ITERS, r.stats); }
    try w1.print("\n", .{}); try write_md_append(s1.getWritten());

    var b2: [768]u8 = undefined; var s2 = std.io.fixedBufferStream(&b2); const w2 = s2.writer();
    try w2.print("### Arc - Heap Downgrade + Upgrade Throughput - ([64]u8)\n", .{});
    try w2.print("| Thread(s) |  Iterations | ns/op (median) | Throughput (ops/s) |\n| --- | --- | --- | --- |\n", .{});
    for (threads_list) |tc| { const r = try benchMultiDowngradeUpgradeType([64]u8, allocator, tc, [_]u8{7} ** 64, target_ms); try writeArcRowNoVariant(w2, tc, MAX_TOTAL_ITERS, r.stats); }
    try w2.print("\n", .{}); try write_md_append(s2.getWritten());
}

pub fn run_multi(thread_count: usize) !void {
    const allocator = getAllocator();
    const mt_svo = try benchMultiCloneReleaseType(u32, allocator, thread_count, 123, 0);
    const mt_heap = try benchMultiCloneReleaseType([64]u8, allocator, thread_count, [_]u8{5} ** 64, 0);

    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();
    try w.print("### Arc — 4 threads - SVO\n", .{});
    try w.print("| Variant | Iterations | ns/op (median) | Throughput (ops/s) |\n| --- | --- | --- | --- |\n", .{});
    try writeBenchRow(w, "SVO (u32)", mt_svo.total_pairs, mt_svo.stats);
    try w.print("\n", .{});
    try w.print("### Arc — 4 threads - Heap\n", .{});
    try w.print("| Variant | Iterations | ns/op (median) | Throughput (ops/s) |\n| --- | --- | --- | --- |\n", .{});
    try writeBenchRow(w, "Heap ([64]u8)", mt_heap.total_pairs, mt_heap.stats);
    try w.print("\n", .{});
    try w.print("### Arc — 4 threads  - SVO vs Heap Clone Throughput\n", .{});
    try w.print("| Variant | Iterations | ns/op (median) | Throughput (ops/s) |\n| --- | --- | --- | --- |\n", .{});
    try writeBenchRow(w, "SVO (u32)", mt_svo.total_pairs, mt_svo.stats);
    try writeBenchRow(w, "Heap ([64]u8)", mt_heap.total_pairs, mt_heap.stats);
    try w.print("\n", .{});
    try write_md_append(fbs.getWritten());

    // Console summaries
    const f_mt_ns_s = medianIqrNsPerOpF64(&mt_svo.stats);
    const f_mt_ops_s = medianIqrOpsPerSecF64(&mt_svo.stats);
    std.debug.print("ARC MT (SVO, f64)  ns/op={d:.2}  ops/s={d:.2}\n", .{ f_mt_ns_s.median, f_mt_ops_s.median });
    const f_mt_ns_h = medianIqrNsPerOpF64(&mt_heap.stats);
    const f_mt_ops_h = medianIqrOpsPerSecF64(&mt_heap.stats);
    std.debug.print("ARC MT (Heap, f64)  ns/op={d:.2}  ops/s={d:.2}\n", .{ f_mt_ns_h.median, f_mt_ops_h.median });
}

fn benchDowngradeUpgrade(comptime T: type, value: T, target_ms: u64, repeats: usize) !struct { stats: Stats, iterations: u64 } {
    const ArcType = beam.Utils.Arc(T);
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

fn benchPoolChurn(pool: *ArcPoolModule.ArcPool([64]u8, true), value: [64]u8, target_ms: u64, repeats: usize) !struct { stats: Stats, iterations: u64 } {
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
fn measurePoolChurnMTOn(pool: *PoolTypeOn, allocator: std.mem.Allocator, thread_count: usize, iterations: u64) !u64 {
    const handles = try allocator.alloc(Thread, thread_count);
    defer allocator.free(handles);
    const contexts = try allocator.alloc(PoolWorkerCtxOn, thread_count);
    defer allocator.free(contexts);
    var start_flag = std.atomic.Value(usize).init(0);

    var idx: usize = 0;
    while (idx < thread_count) : (idx += 1) {
        contexts[idx] = .{ .pool = pool, .iterations = iterations, .start_flag = &start_flag };
        handles[idx] = try Thread.spawn(.{}, poolWorkerOn, .{ &contexts[idx] });
    }

    // Start measurement after workers finish their warm-up.
    var timer = try Timer.start();
    _ = start_flag.store(1, .seq_cst);
    for (handles) |handle| handle.join();
    const ns = timer.read();
    pool.drainThreadCache();
    return ns;
}

fn measurePoolChurnMTOff(pool: *PoolTypeOff, allocator: std.mem.Allocator, thread_count: usize, iterations: u64) !u64 {
    const handles = try allocator.alloc(Thread, thread_count);
    defer allocator.free(handles);
    const contexts = try allocator.alloc(PoolWorkerCtxOff, thread_count);
    defer allocator.free(contexts);
    var start_flag = std.atomic.Value(usize).init(0);

    var idx: usize = 0;
    while (idx < thread_count) : (idx += 1) {
        contexts[idx] = .{ .pool = pool, .iterations = iterations, .start_flag = &start_flag };
        handles[idx] = try Thread.spawn(.{}, poolWorkerOff, .{ &contexts[idx] });
    }

    var timer = try Timer.start();
    _ = start_flag.store(1, .seq_cst);
    for (handles) |handle| handle.join();
    const ns = timer.read();
    pool.drainThreadCache();
    return ns;
}

/// Multi-threaded ArcPool benchmark (uses `measurePoolChurnMT` under the hood).
fn benchPoolChurnMTOn(thread_count: usize, target_ms: u64, repeats: usize) !struct { stats: Stats, iterations: u64 } {
    const allocator = getAllocator();
    const pilot_iters: u64 = 20_000;

    var pilot_pool = PoolTypeOn.init(allocator, .{});
    const pilot_ns = try measurePoolChurnMTOn(&pilot_pool, allocator, thread_count, pilot_iters);
    pilot_pool.deinit();

    const per_thread_iters = scale_iters(pilot_iters, pilot_ns, target_ms);
    const total_iters = per_thread_iters * @as(u64, thread_count);

    var stats = Stats{};
    var rep: usize = 0;
    while (rep < repeats) : (rep += 1) {
        var pool = PoolTypeOn.init(allocator, .{});
        const ns = try measurePoolChurnMTOn(&pool, allocator, thread_count, per_thread_iters);
        pool.deinit();
        record(&stats, total_iters, ns);
    }

    return .{ .stats = stats, .iterations = total_iters };
}

fn benchPoolChurnMTOff(thread_count: usize, target_ms: u64, repeats: usize) !struct { stats: Stats, iterations: u64 } {
    const allocator = getAllocator();
    const pilot_iters: u64 = 20_000;

    var pilot_pool = PoolTypeOff.init(allocator, .{});
    const pilot_ns = try measurePoolChurnMTOff(&pilot_pool, allocator, thread_count, pilot_iters);
    pilot_pool.deinit();

    const per_thread_iters = scale_iters(pilot_iters, pilot_ns, target_ms);
    const total_iters = per_thread_iters * @as(u64, thread_count);

    var stats = Stats{};
    var rep: usize = 0;
    while (rep < repeats) : (rep += 1) {
        var pool = PoolTypeOff.init(allocator, .{});
        const ns = try measurePoolChurnMTOff(&pool, allocator, thread_count, per_thread_iters);
        pool.deinit();
        record(&stats, total_iters, ns);
    }

    return .{ .stats = stats, .iterations = total_iters };
}

fn writeBenchRow(wr: anytype, label: []const u8, iterations: u64, stats: Stats) !void {
    var nb1: [32]u8 = undefined;
    const s_iters = fmt_u64_commas(&nb1, iterations);
    const nsf = medianIqrNsPerOpF64(&stats);
    const opsf = medianIqrOpsPerSecF64(&stats);
    // ns/op formatting with floor at <0.01
    const ns_display = blk: {
        if (nsf.median > 0.009) break :blk nsf.median;
        // use sentinel negative to print as <0.01
        break :blk -1.0;
    };
    // throughput with human units and two decimals + unit suffix
    var scaled: f64 = 0;
    const unit = scale_rate_f64(&scaled, opsf.median);
    var fbuf: [48]u8 = undefined;
    const s_rate = fmt_f64_commas2(&fbuf, scaled);
    if (ns_display >= 0) {
        try wr.print("| {s} | {s} | {d:.2} | {s} {s} |\n", .{ label, s_iters, ns_display, s_rate, unit });
    } else {
        try wr.print("| {s} | {s} | <0.01 | {s} {s} |\n", .{ label, s_iters, s_rate, unit });
    }
}

pub fn run_svo_vs_heap() !void {
    // Use a longer target for SVO to avoid timer granularity artifacts
    const inline_result = try benchCloneReleaseType(u32, 123, 1000, 2);
    const heap_result = try benchCloneReleaseType([64]u8, [_]u8{7} ** 64, 60, 2);

    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const wr = fbs.writer();

    try wr.print("## Arc — SVO vs Heap Clone Throughput\n", .{});
    try wr.print("| Variant | Iterations | ns/op (median) | Throughput (ops/s) |\n", .{});
    try wr.print("| --- | --- | --- | --- |\n", .{});
    try writeBenchRow(wr, "SVO (u32)", inline_result.iterations, inline_result.stats);
    try writeBenchRow(wr, "Heap ([64]u8)", heap_result.iterations, heap_result.stats);
    try wr.print("\n", .{});
    try write_md_append(fbs.getWritten());

    // Console throughput summary
    const f_thr_inline = medianIqrOpsPerSecF64(&inline_result.stats);
    const f_thr_heap = medianIqrOpsPerSecF64(&heap_result.stats);
    var scaled_a: f64 = 0; var scaled_b: f64 = 0;
    const unit_a = scale_rate_f64(&scaled_a, f_thr_inline.median);
    const unit_b = scale_rate_f64(&scaled_b, f_thr_heap.median);
    var fb1: [48]u8 = undefined; var fb2: [48]u8 = undefined;
    std.debug.print("SVO vs Heap throughput: SVO={s} {s}, Heap={s} {s}\n",
        .{ fmt_f64_commas2(&fb1, scaled_a), unit_a, fmt_f64_commas2(&fb2, scaled_b), unit_b });
}

pub fn run_downgrade_upgrade() !void {
    const result = try benchDowngradeUpgrade([64]u8, [_]u8{5} ** 64, 60, 2);

    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const wr = fbs.writer();

    try wr.print("### Arc — Downgrade + Upgrade\n", .{});
    try wr.print("| Operation | Iterations | ns/op (median) | Throughput (ops/s) |\n", .{});
    try wr.print("| --- | --- | --- | --- |\n", .{});
    try writeBenchRow(wr, "downgrade+upgrade", result.iterations, result.stats);
    try wr.print("\n", .{});
    try write_md_append(fbs.getWritten());

    // Console throughput summary
    const f_thr_du = medianIqrOpsPerSecF64(&result.stats);
    var scaled_du: f64 = 0; const unit_du = scale_rate_f64(&scaled_du, f_thr_du.median);
    var fbuf_du: [48]u8 = undefined;
    std.debug.print("Downgrade+Upgrade throughput: {s} {s}\n", .{ fmt_f64_commas2(&fbuf_du, scaled_du), unit_du });
}

/// Compare raw heap allocations vs ArcPool reuse (single-threaded).
pub fn run_pool_churn() !void {
    var pool = ArcPoolModule.ArcPool([64]u8, true).init(getAllocator(), .{});
    defer pool.deinit();

    const raw_result = try benchRawHeapChurn([_]u8{9} ** 64, 60, 2);
    const pool_result = try benchPoolChurn(&pool, [_]u8{9} ** 64, 60, 2);

    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const wr = fbs.writer();

    try wr.print("## ArcPool — Heap vs Create/Recycle (stats=on)\n", .{});
    try wr.print("| Scenario | Iterations | ns/op (median) | Throughput (ops/s) |\n", .{});
    try wr.print("| --- | --- | --- | --- |\n", .{});
    try writeBenchRow(wr, "direct heap", raw_result.iterations, raw_result.stats);
    try writeBenchRow(wr, "ArcPool recycle", pool_result.iterations, pool_result.stats);
    try wr.print("\n", .{});
    try write_md_append(fbs.getWritten());

    // Console throughput summary
    const f_thr_raw = medianIqrOpsPerSecF64(&raw_result.stats);
    const f_thr_pool = medianIqrOpsPerSecF64(&pool_result.stats);
    var scaled_r: f64 = 0; var scaled_p: f64 = 0;
    const unit_r = scale_rate_f64(&scaled_r, f_thr_raw.median);
    const unit_p = scale_rate_f64(&scaled_p, f_thr_pool.median);
    var fb_r: [48]u8 = undefined; var fb_p: [48]u8 = undefined;
    std.debug.print("Heap vs ArcPool (ST) throughput: heap={s} {s}, pool={s} {s}\n",
        .{ fmt_f64_commas2(&fb_r, scaled_r), unit_r, fmt_f64_commas2(&fb_p, scaled_p), unit_p });
}

/// Compare raw heap allocations vs ArcPool reuse (single-threaded), stats disabled.
pub fn run_pool_churn_off() !void {
    var pool_off = ArcPoolModule.ArcPool([64]u8, false).init(getAllocator(), .{});
    defer pool_off.deinit();

    const raw_result = try benchRawHeapChurn([_]u8{9} ** 64, 60, 2);
    const pool_result = try benchPoolChurnGeneric(ArcPoolModule.ArcPool([64]u8, false), &pool_off, [_]u8{9} ** 64, 60, 2);

    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const wr = fbs.writer();

    try wr.print("## ArcPool — Heap vs Create/Recycle (stats=off)\n", .{});
    try wr.print("| Scenario | Iterations | ns/op (median) | Throughput (ops/s) |\n", .{});
    try wr.print("| --- | --- | --- | --- |\n", .{});
    try writeBenchRow(wr, "direct heap", raw_result.iterations, raw_result.stats);
    try writeBenchRow(wr, "ArcPool recycle", pool_result.iterations, pool_result.stats);
    try wr.print("\n", .{});
    try write_md_append(fbs.getWritten());
}

/// Measure ArcPool churn when multiple threads share the pool.
pub fn run_pool_churn_mt(thread_count: usize) !void {
    const result = try benchPoolChurnMTOn(thread_count, 120, 2);
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

    var f64buf: [32]u8 = undefined;
    const approx = fmt_ns_from_ops(&f64buf, thr.median);
    std.debug.print(
        "ArcPool MT  threads={} total_pairs={} ns/op={} ({}–{}) ops/s={}  (~{s} ns/op)\n",
        .{ thread_count, result.iterations, med.median, med.q1, med.q3, thr.median, approx },
    );
    const f_mt_ns = medianIqrNsPerOpF64(&result.stats);
    const f_mt_ops = medianIqrOpsPerSecF64(&result.stats);
    std.debug.print("ArcPool MT (f64) ns/op={d:.2}  ops/s={d:.2}\n", .{ f_mt_ns.median, f_mt_ops.median });

    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const wr = fbs.writer();
    try wr.print("## ArcPool Multi-Threaded ({d} threads, stats=on)\n", .{thread_count});
    try wr.print("- iters/thread: {s}\n", .{s_iters});
    try wr.print("- total pairs: {s}\n", .{s_total});
    try wr.print("- ns/op median (IQR): {s} ({d}–{d})\n", .{ s_ns, med.q1, med.q3 });
    try wr.print("- ops/s median: {s} (≈ {s} {s})\n\n", .{ s_ops, ops_h, unit_suffix(thr.median) });
    try write_md_append(fbs.getWritten());
}

/// Multi-threaded ArcPool benchmark (stats disabled): dedicated section in MD.
pub fn run_pool_churn_mt_off(thread_count: usize) !void {
    const result = try benchPoolChurnMTOff(thread_count, 120, 2);
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

    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const wr = fbs.writer();
    try wr.print("## ArcPool Multi-Threaded ({d} threads, stats=off)\n", .{thread_count});
    try wr.print("- iters/thread: {s}\n", .{s_iters});
    try wr.print("- total pairs: {s}\n", .{s_total});
    try wr.print("- ns/op median (IQR): {s} ({d}–{d})\n", .{ s_ns, med.q1, med.q3 });
    try wr.print("- ops/s median: {s} (≈ {s} {s})\n\n", .{ s_ops, ops_h, unit_suffix(thr.median) });
    try write_md_append(fbs.getWritten());

    // Console throughput summary
    const f_ops_off = medianIqrOpsPerSecF64(&result.stats);
    var sc_off: f64 = 0; const u_off = scale_rate_f64(&sc_off, f_ops_off.median);
    var ob: [48]u8 = undefined; std.debug.print("ArcPool MT (stats=off) throughput: {s} {s}\n", .{ fmt_f64_commas2(&ob, sc_off), u_off });
}

// Single-threaded pool churn: generic over stats on/off
fn benchPoolChurnGeneric(comptime PoolType: type, pool: *PoolType, value: [64]u8, target_ms: u64, repeats: usize) !BenchRes {
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
        // Small warm-up to prefill TLS for this thread.
        var w: usize = 0;
        while (w < 16) : (w += 1) {
            const arc_w = try pool.create(value);
            pool.recycle(arc_w);
        }
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

const BurstyRes = struct { stats: Stats, iterations: u64 };
fn burstyMeasureCapacity(
    comptime PoolType: type,
    pool: *PoolType,
    burst: usize,
    target_ms: u64,
    repeats: usize,
    drain_between: bool,
) !BurstyRes {
    const payload = [_]u8{2} ** PoolPayloadLen;
    const pilot_cycles: u64 = 2_000;
    var timer = try Timer.start();
    var cyc: u64 = 0;
    while (cyc < pilot_cycles) : (cyc += 1) {
        var list = try std.heap.page_allocator.alloc(ArcArray64, burst);
        defer std.heap.page_allocator.free(list);
        var j: usize = 0; while (j < burst) : (j += 1) list[j] = try pool.create(payload);
        j = 0; while (j < burst) : (j += 1) pool.recycle(list[j]);
    }
    const pilot_ns = timer.read();
    const run_cycles = scale_iters(pilot_cycles, pilot_ns, target_ms);
    var stats = Stats{};
    var rep: usize = 0;
    while (rep < repeats) : (rep += 1) {
        timer = try Timer.start();
        cyc = 0;
        while (cyc < run_cycles) : (cyc += 1) {
            var list = try std.heap.page_allocator.alloc(ArcArray64, burst);
            defer std.heap.page_allocator.free(list);
            var k: usize = 0; while (k < burst) : (k += 1) list[k] = try pool.create(payload);
            k = 0; while (k < burst) : (k += 1) pool.recycle(list[k]);
        }
        const ns = timer.read();
        const ops: u64 = @as(u64, @intCast(burst)) * run_cycles;
        record(&stats, ops, ns);
        if (drain_between) pool.drainThreadCache();
    }
    return .{ .stats = stats, .iterations = @as(u64, @intCast(burst)) * run_cycles };
}

pub fn run_pool_stats_toggle() !void {
    const allocator = getAllocator();
    var pool_on = PoolTypeOn.init(allocator, .{});
    defer pool_on.deinit();
    var pool_off = PoolTypeOff.init(allocator, .{});
    defer pool_off.deinit();

    const on_result = try benchPoolChurnGeneric(PoolTypeOn, &pool_on, [_]u8{7} ** 64, 60, 2);
    const off_result = try benchPoolChurnGeneric(PoolTypeOff, &pool_off, [_]u8{7} ** 64, 60, 2);

    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const wr = fbs.writer();
    try wr.print("## ArcPool — Stats Toggle\n", .{});
    try wr.print("### Single-Threaded\n", .{});
    try wr.print("| Variant | Iterations | ns/op (median) | Throughput (ops/s) |\n", .{});
    try wr.print("| --- | --- | --- | --- |\n", .{});
    try writeBenchRow(wr, "stats=on", on_result.iterations, on_result.stats);
    try writeBenchRow(wr, "stats=off", off_result.iterations, off_result.stats);
    try wr.print("\n", .{});
    try write_md_append(fbs.getWritten());

    const on_med = medianIqr(on_result.stats.ns_per_list[0..on_result.stats.len]);
    const off_med = medianIqr(off_result.stats.ns_per_list[0..off_result.stats.len]);
    const on_thr = medianIqr(on_result.stats.ops_s_list[0..on_result.stats.len]);
    const off_thr = medianIqr(off_result.stats.ops_s_list[0..off_result.stats.len]);
    var f64a: [32]u8 = undefined;
    var f64b: [32]u8 = undefined;
    const approx_on = fmt_ns_from_ops(&f64a, on_thr.median);
    const approx_off = fmt_ns_from_ops(&f64b, off_thr.median);
    std.debug.print(
        "ArcPool ST (stats on) ns/op={} (~{s}) | (off) ns/op={} (~{s})\n",
        .{ on_med.median, approx_on, off_med.median, approx_off },
    );
    const f_on = medianIqrOpsPerSecF64(&on_result.stats);
    const f_off = medianIqrOpsPerSecF64(&off_result.stats);
    var sc_on: f64 = 0; var sc_off: f64 = 0;
    const u_on = scale_rate_f64(&sc_on, f_on.median);
    const u_off2 = scale_rate_f64(&sc_off, f_off.median);
    var tb1: [48]u8 = undefined; var tb2: [48]u8 = undefined;
    std.debug.print("ArcPool ST throughput: on={s} {s} | off={s} {s}\n",
        .{ fmt_f64_commas2(&tb1, sc_on), u_on, fmt_f64_commas2(&tb2, sc_off), u_off2 });
}

/// Cyclic init benchmark: measure pool.createCyclic cost (stats=off).
pub fn run_pool_cyclic_init() !void {
    const allocator = getAllocator();
    var pool = PoolTypeOff.init(allocator, .{});
    defer pool.deinit();

    const ctor = struct {
        fn f(w: beam.Utils.ArcWeak(PoolPayload)) anyerror!PoolPayload {
            _ = w; // store nothing; just return a payload
            return [_]u8{1} ** PoolPayloadLen;
        }
    }.f;

    const pilot_iters: u64 = 20_000;
    var t = try Timer.start();
    var i: u64 = 0;
    while (i < pilot_iters) : (i += 1) {
        const arc = try pool.createCyclic(ctor);
        pool.recycle(arc);
    }
    const pilot_ns = t.read();
    const run_iters = scale_iters(pilot_iters, pilot_ns, 60);

    var stats = Stats{};
    var rep: usize = 0;
    while (rep < 2) : (rep += 1) {
        t = try Timer.start();
        i = 0;
        while (i < run_iters) : (i += 1) {
            const arc = try pool.createCyclic(ctor);
            pool.recycle(arc);
        }
        const ns = t.read();
        record(&stats, run_iters, ns);
        pool.drainThreadCache();
    }

    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const wr = fbs.writer();
    try wr.print("## ArcPool — Cyclic Init (pool.createCyclic, stats=off)\n", .{});
    try wr.print("| Operation | Iterations | ns/op (median) | Throughput (ops/s) |\n", .{});
    try wr.print("| --- | --- | --- | --- |\n", .{});
    try writeBenchRow(wr, "createCyclic(Node)", run_iters, stats);
    try wr.print("\n", .{});
    try write_md_append(fbs.getWritten());

    // Console throughput summary
    const f_thr_cyc = medianIqrOpsPerSecF64(&stats);
    var sc_c: f64 = 0; const u_c = scale_rate_f64(&sc_c, f_thr_cyc.median);
    var cb: [48]u8 = undefined; std.debug.print("createCyclic throughput: {s} {s}\n", .{ fmt_f64_commas2(&cb, sc_c), u_c });
}

/// Compare pop-batching on vs off (by setting pop_batch=1) under MT churn with stats=off.

/// In-place initializer vs copy(64B) comparison using stats=off pool.
pub fn run_pool_inplace_vs_copy(thread_count: usize) !void {
    const allocator = getAllocator();
    var pool_off = PoolTypeOff.init(allocator, .{});
    defer pool_off.deinit();

    // ST: copy baseline
    const copy_st = try benchPoolChurnGeneric(PoolTypeOff, &pool_off, [_]u8{3} ** 64, 60, 2);

    // ST: in-place init (memset pattern)
    const pilot_iters: u64 = 50_000;
    var timer = try Timer.start();
    var i: u64 = 0;
    while (i < pilot_iters) : (i += 1) {
        const arc = try pool_off.createWithInitializer(struct {
            fn init(ptr: *[64]u8) void { @memset(ptr, 5); }
        }.init);
        pool_off.recycle(arc);
    }
    const pilot_ns = timer.read();
    const run_iters = scale_iters(pilot_iters, pilot_ns, 60);
    var stats = Stats{};
    var rep: usize = 0;
    while (rep < 2) : (rep += 1) {
        timer = try Timer.start();
        i = 0;
        while (i < run_iters) : (i += 1) {
            const arc = try pool_off.createWithInitializer(struct {
                fn init(ptr: *[64]u8) void { @memset(ptr, 5); }
            }.init);
            pool_off.recycle(arc);
        }
        const ns = timer.read();
        record(&stats, run_iters, ns);
        pool_off.drainThreadCache();
    }

    var buf: [768]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const wr = fbs.writer();
    try wr.print("## ArcPool — In-place vs Copy (stats=off, ST)\n", .{});
    try wr.print("| Variant | Iterations | ns/op (median) | Throughput (ops/s) |\n", .{});
    try wr.print("| --- | --- | --- | --- |\n", .{});
    try writeBenchRow(wr, "copy 64B", copy_st.iterations, copy_st.stats);
    try writeBenchRow(wr, "in-place (memset)", run_iters, stats);
    try wr.print("\n", .{});
    try write_md_append(fbs.getWritten());

    // MT: copy baseline (reuse existing bench)
    const copy_mt = try benchPoolChurnMTOff(thread_count, 120, 2);

    // MT: in-place init measure
    const pilot_mt: u64 = 20_000;
    var pool_mt = PoolTypeOff.init(allocator, .{});
    const pilot_ns_mt = try measurePoolChurnMTOff(&pool_mt, allocator, thread_count, pilot_mt);
    pool_mt.deinit();
    const per_thread_iters = scale_iters(pilot_mt, pilot_ns_mt, 120);
    const total_iters = per_thread_iters * @as(u64, thread_count);

    const mt_stats = blk: {
        var s = Stats{};
        var r: usize = 0;
        while (r < 2) : (r += 1) {
            var pool = PoolTypeOff.init(allocator, .{});
            const ns = try measurePoolChurnMTOffInplace(&pool, allocator, thread_count, per_thread_iters);
            pool.deinit();
            record(&s, total_iters, ns);
        }
        break :blk s;
    };

    fbs.reset();
    try wr.print("## ArcPool — In-place vs Copy (stats=off, MT)\n", .{});
    try wr.print("| Variant | Iterations | ns/op (median) | Throughput (ops/s) |\n", .{});
    try wr.print("| --- | --- | --- | --- |\n", .{});
    try writeBenchRow(wr, "copy 64B (MT)", copy_mt.iterations, copy_mt.stats);
    try writeBenchRow(wr, "in-place (MT)", total_iters, mt_stats);
    try wr.print("\n", .{});
    try write_md_append(fbs.getWritten());

    // Console throughput summary (ST & MT)
    const f_thr_st = medianIqrOpsPerSecF64(&stats);
    const f_thr_mt = medianIqrOpsPerSecF64(&mt_stats);
    var sc1: f64 = 0; var sc2: f64 = 0;
    const unit_st = scale_rate_f64(&sc1, f_thr_st.median);
    const unit_mt = scale_rate_f64(&sc2, f_thr_mt.median);
    var fx1: [48]u8 = undefined; var fx2: [48]u8 = undefined;
    std.debug.print("In-place vs Copy throughput: ST={s} {s}, MT={s} {s}\n",
        .{ fmt_f64_commas2(&fx1, sc1), unit_st, fmt_f64_commas2(&fx2, sc2), unit_mt });
}

fn measurePoolChurnMTOffInplace(pool: *PoolTypeOff, allocator: std.mem.Allocator, thread_count: usize, iterations: u64) !u64 {
    const handles = try allocator.alloc(Thread, thread_count);
    defer allocator.free(handles);
    const contexts = try allocator.alloc(PoolWorkerCtxOff, thread_count);
    defer allocator.free(contexts);
    var start_flag = std.atomic.Value(usize).init(0);

    var idx: usize = 0;
    while (idx < thread_count) : (idx += 1) {
        contexts[idx] = .{ .pool = pool, .iterations = iterations, .start_flag = &start_flag };
        handles[idx] = try Thread.spawn(.{}, poolWorkerOffInit, .{ &contexts[idx] });
    }

    var timer = try Timer.start();
    _ = start_flag.store(1, .seq_cst);
    for (handles) |h| h.join();
    const ns = timer.read();
    pool.drainThreadCache();
    return ns;
}

fn poolWorkerOffInit(ctx: *PoolWorkerCtxOff) void {
    var i: u64 = 0;
    const payload_init = struct {
        fn init(ptr: *PoolPayload) void { @memset(ptr, 7); }
    }.init;
    var w: usize = 0;
    while (w < 16) : (w += 1) {
        const arc_w = ctx.pool.createWithInitializer(payload_init) catch unreachable;
        ctx.pool.recycle(arc_w);
    }
    while (ctx.start_flag.load(.seq_cst) == 0) {
        std.Thread.yield() catch {};
    }
    while (i < ctx.iterations) : (i += 1) {
        const arc = ctx.pool.createWithInitializer(payload_init) catch unreachable;
        ctx.pool.recycle(arc);
    }
}

/// Compare TLS capacity for stats=off pools under TLS-heavy churn and a bursty pattern.
pub fn run_pool_tls_capacity_compare() !void {
    const allocator = getAllocator();
    // TLS-heavy churn (simple create/recycle loop)
    var p8 = PoolOff8.init(allocator, .{});
    defer p8.deinit();
    var p16 = PoolOff16.init(allocator, .{ .logical_cpus = null });
    p16.tls_active_capacity = 16;
    defer p16.deinit();
    var p32 = PoolOff32.init(allocator, .{ .logical_cpus = null });
    p32.tls_active_capacity = 32;
    defer p32.deinit();
    var p64 = PoolOff64.init(allocator, .{ .logical_cpus = null });
    p64.tls_active_capacity = 64;
    defer p64.deinit();

    const r8 = try benchPoolChurnGeneric(PoolOff8, &p8, [_]u8{1} ** PoolPayloadLen, 60, 2);
    const r16 = try benchPoolChurnGeneric(PoolOff16, &p16, [_]u8{1} ** PoolPayloadLen, 60, 2);
    const r32 = try benchPoolChurnGeneric(PoolOff32, &p32, [_]u8{1} ** PoolPayloadLen, 60, 2);
    const r64 = try benchPoolChurnGeneric(PoolOff64, &p64, [_]u8{1} ** PoolPayloadLen, 60, 2);

    var buf: [768]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const wr = fbs.writer();
    try wr.print("## ArcPool — TLS Capacity (stats=off) — TLS-heavy churn\n", .{});
    try wr.print("| Capacity | Iterations | ns/op (median) | Throughput (ops/s) |\n", .{});
    try wr.print("| --- | --- | --- | --- |\n", .{});
    try writeBenchRow(wr, "8", r8.iterations, r8.stats);
    try writeBenchRow(wr, "16", r16.iterations, r16.stats);
    try writeBenchRow(wr, "32", r32.iterations, r32.stats);
    try writeBenchRow(wr, "64", r64.iterations, r64.stats);
    try wr.print("\n", .{});
    try write_md_append(fbs.getWritten());

    // Console throughput summary for TLS-heavy churn
    const f_thr8 = medianIqrOpsPerSecF64(&r8.stats);
    const f_thr16 = medianIqrOpsPerSecF64(&r16.stats);
    const f_thr32 = medianIqrOpsPerSecF64(&r32.stats);
    const f_thr64 = medianIqrOpsPerSecF64(&r64.stats);
    var sc8: f64 = 0; var sc16: f64 = 0; var sc32: f64 = 0; var sc64: f64 = 0;
    const u8s = scale_rate_f64(&sc8, f_thr8.median);
    const u16s = scale_rate_f64(&sc16, f_thr16.median);
    const u32s = scale_rate_f64(&sc32, f_thr32.median);
    const u64s = scale_rate_f64(&sc64, f_thr64.median);
    var tb8: [48]u8 = undefined; var tb16: [48]u8 = undefined; var tb32: [48]u8 = undefined; var tb64: [48]u8 = undefined;
    std.debug.print("TLS capacity (ST) throughput: 8={s} {s}, 16={s} {s}, 32={s} {s}, 64={s} {s}\n",
        .{ fmt_f64_commas2(&tb8, sc8), u8s, fmt_f64_commas2(&tb16, sc16), u16s, fmt_f64_commas2(&tb32, sc32), u32s, fmt_f64_commas2(&tb64, sc64), u64s });

    var p8b = PoolOff8.init(allocator, .{});
    defer p8b.deinit();
    var p16b = PoolOff16.init(allocator, .{ .logical_cpus = null });
    p16b.tls_active_capacity = 16;
    defer p16b.deinit();
    var p32b = PoolOff32.init(allocator, .{ .logical_cpus = null });
    p32b.tls_active_capacity = 32;
    defer p32b.deinit();
    var p64b = PoolOff64.init(allocator, .{ .logical_cpus = null });
    p64b.tls_active_capacity = 64;
    defer p64b.deinit();

    const burst: usize = 24; // bigger than 8 and 16
    const b8 = try burstyMeasureCapacity(PoolOff8, &p8b, burst, 60, 2, true);
    const b16 = try burstyMeasureCapacity(PoolOff16, &p16b, burst, 60, 2, true);
    const b32 = try burstyMeasureCapacity(PoolOff32, &p32b, burst, 60, 2, true);
    const b64 = try burstyMeasureCapacity(PoolOff64, &p64b, burst, 60, 2, true);

    fbs.reset();
    try wr.print("## ArcPool — TLS Capacity (stats=off) — Bursty cycles (burst=24)\n", .{});
    try wr.print("| Capacity | Items | ns/item (median) | Throughput (items/s) |\n", .{});
    try wr.print("| --- | --- | --- | --- |\n", .{});
    try writeBenchRow(wr, "8", b8.iterations, b8.stats);
    try writeBenchRow(wr, "16", b16.iterations, b16.stats);
    try writeBenchRow(wr, "32", b32.iterations, b32.stats);
    try writeBenchRow(wr, "64", b64.iterations, b64.stats);
    try wr.print("\n", .{});
    try write_md_append(fbs.getWritten());

    // Console throughput summary for bursty (24)
    const f_bthr8 = medianIqrOpsPerSecF64(&b8.stats);
    const f_bthr16 = medianIqrOpsPerSecF64(&b16.stats);
    const f_bthr32 = medianIqrOpsPerSecF64(&b32.stats);
    const f_bthr64 = medianIqrOpsPerSecF64(&b64.stats);
    var bsc8: f64 = 0; var bsc16: f64 = 0; var bsc32: f64 = 0; var bsc64: f64 = 0;
    const bu8 = scale_rate_f64(&bsc8, f_bthr8.median);
    const bu16 = scale_rate_f64(&bsc16, f_bthr16.median);
    const bu32 = scale_rate_f64(&bsc32, f_bthr32.median);
    const bu64 = scale_rate_f64(&bsc64, f_bthr64.median);
    var bb8: [48]u8 = undefined; var bb16: [48]u8 = undefined; var bb32: [48]u8 = undefined; var bb64: [48]u8 = undefined;
    std.debug.print("TLS capacity (burst=24) throughput: 8={s} {s}, 16={s} {s}, 32={s} {s}, 64={s} {s}\n",
        .{ fmt_f64_commas2(&bb8, bsc8), bu8, fmt_f64_commas2(&bb16, bsc16), bu16, fmt_f64_commas2(&bb32, bsc32), bu32, fmt_f64_commas2(&bb64, bsc64), bu64 });

    // Second burst scenario: burst=72, no TLS drain between repeats.
    var p8c = PoolOff8.init(allocator, .{});
    defer p8c.deinit();
    var p16c = PoolOff16.init(allocator, .{ .logical_cpus = null });
    p16c.tls_active_capacity = 16;
    defer p16c.deinit();
    var p32c = PoolOff32.init(allocator, .{ .logical_cpus = null });
    p32c.tls_active_capacity = 32;
    defer p32c.deinit();
    var p64c = PoolOff64.init(allocator, .{ .logical_cpus = null });
    p64c.tls_active_capacity = 64;
    defer p64c.deinit();

    const burst2: usize = 72;
    const b8_nd = try burstyMeasureCapacity(PoolOff8, &p8c, burst2, 60, 2, false);
    const b16_nd = try burstyMeasureCapacity(PoolOff16, &p16c, burst2, 60, 2, false);
    const b32_nd = try burstyMeasureCapacity(PoolOff32, &p32c, burst2, 60, 2, false);
    const b64_nd = try burstyMeasureCapacity(PoolOff64, &p64c, burst2, 60, 2, false);

    fbs.reset();
    try wr.print("## ArcPool — TLS Capacity (stats=off) — Bursty cycles (burst=72, no drain)\n", .{});
    try wr.print("| Capacity | Items | ns/item (median) | Throughput (items/s) |\n", .{});
    try wr.print("| --- | --- | --- | --- |\n", .{});
    try writeBenchRow(wr, "8", b8_nd.iterations, b8_nd.stats);
    try writeBenchRow(wr, "16", b16_nd.iterations, b16_nd.stats);
    try writeBenchRow(wr, "32", b32_nd.iterations, b32_nd.stats);
    try writeBenchRow(wr, "64", b64_nd.iterations, b64_nd.stats);
    try wr.print("\n", .{});
    try write_md_append(fbs.getWritten());

    // Console throughput summary for bursty (72 no drain)
    const f_nd8 = medianIqrOpsPerSecF64(&b8_nd.stats);
    const f_nd16 = medianIqrOpsPerSecF64(&b16_nd.stats);
    const f_nd32 = medianIqrOpsPerSecF64(&b32_nd.stats);
    const f_nd64 = medianIqrOpsPerSecF64(&b64_nd.stats);
    var nsc8: f64 = 0; var nsc16: f64 = 0; var nsc32: f64 = 0; var nsc64: f64 = 0;
    const nu8 = scale_rate_f64(&nsc8, f_nd8.median);
    const nu16 = scale_rate_f64(&nsc16, f_nd16.median);
    const nu32 = scale_rate_f64(&nsc32, f_nd32.median);
    const nu64 = scale_rate_f64(&nsc64, f_nd64.median);
    var nb8: [48]u8 = undefined; var nb16: [48]u8 = undefined; var nb32: [48]u8 = undefined; var nb64: [48]u8 = undefined;
    std.debug.print("TLS capacity (burst=72,no-drain) throughput: 8={s} {s}, 16={s} {s}, 32={s} {s}, 64={s} {s}\n",
        .{ fmt_f64_commas2(&nb8, nsc8), nu8, fmt_f64_commas2(&nb16, nsc16), nu16, fmt_f64_commas2(&nb32, nsc32), nu32, fmt_f64_commas2(&nb64, nsc64), nu64 });
}

pub fn run_pool_stats_toggle_mt(thread_count: usize) !void {
    const on = try benchPoolChurnMTOn(thread_count, 120, 2);
    const off = try benchPoolChurnMTOff(thread_count, 120, 2);

    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const wr = fbs.writer();
    try wr.print("### ArcPool — Multi-Threaded ({} threads)\n", .{thread_count});
    try wr.print("| Variant | Iterations | ns/op (median) | Throughput (ops/s) |\n", .{});
    try wr.print("| --- | --- | --- | --- |\n", .{});
    try writeBenchRow(wr, "stats=on (MT)", on.iterations, on.stats);
    try writeBenchRow(wr, "stats=off (MT)", off.iterations, off.stats);
    try wr.print("\n", .{});
    try write_md_append(fbs.getWritten());

    const on_med = medianIqr(on.stats.ns_per_list[0..on.stats.len]);
    const off_med = medianIqr(off.stats.ns_per_list[0..off.stats.len]);
    const on_thr = medianIqr(on.stats.ops_s_list[0..on.stats.len]);
    const off_thr = medianIqr(off.stats.ops_s_list[0..off.stats.len]);
    var f64c: [32]u8 = undefined;
    var f64d: [32]u8 = undefined;
    const approx_on = fmt_ns_from_ops(&f64c, on_thr.median);
    const approx_off = fmt_ns_from_ops(&f64d, off_thr.median);
    std.debug.print(
        "ArcPool MT (stats on) ns/op={} (~{s}) | (off) ns/op={} (~{s})\n",
        .{ on_med.median, approx_on, off_med.median, approx_off },
    );
}

// Split scenarios (diagnostic): TLS-only, Global-only, Allocator-only
fn benchPoolTlsOnly(pool: *PoolTypeOff, target_ms: u64, repeats: usize) !BenchRes {
    const payload = [_]u8{0} ** PoolPayloadLen;
    // Prefill TLS: a few create/recycle cycles.
    var k: usize = 0;
    while (k < 16) : (k += 1) {
        const arc_w = try pool.create(payload);
        pool.recycle(arc_w);
    }
    return benchPoolChurnGeneric(PoolTypeOff, pool, payload, target_ms, repeats);
}

fn benchPoolGlobalOnly(pool: *PoolTypeOff, target_ms: u64, repeats: usize) !BenchRes {
    const allocator = getAllocator();
    const payload = [_]u8{1} ** PoolPayloadLen;
    // Ensure TLS is emptied into global, then prefill global via recycleSlow.
    pool.drainThreadCache();
    var i: usize = 0;
    while (i < 32) : (i += 1) {
        var arc = try pool.create(payload);
        // Bypass TLS to global freelist only.
        pool.recycleSlow(arc.asPtr());
    }
    // Measured loop: always recycle via recycleSlow to avoid TLS hits.
    const pilot_iters: u64 = 10_000;
    var timer = try Timer.start();
    var j: u64 = 0;
    while (j < pilot_iters) : (j += 1) {
        var arc = try pool.create(payload);
        pool.recycleSlow(arc.asPtr());
    }
    const pilot_ns = timer.read();
    const run_iters = scale_iters(pilot_iters, pilot_ns, target_ms);

    var stats = Stats{};
    var rep: usize = 0;
    while (rep < repeats) : (rep += 1) {
        timer = try Timer.start();
        j = 0;
        while (j < run_iters) : (j += 1) {
            var arc = try pool.create(payload);
            pool.recycleSlow(arc.asPtr());
        }
        const ns = timer.read();
        record(&stats, run_iters, ns);
        pool.drainThreadCache();
    }
    _ = allocator; // currently unused here
    return .{ .stats = stats, .iterations = run_iters };
}

fn benchPoolAllocOnly(target_ms: u64, repeats: usize) !BenchRes {
    const allocator = getAllocator();
    var pool = PoolTypeOff.init(allocator, .{});
    defer pool.deinit();
    const payload = [_]u8{2} ** PoolPayloadLen;

    // Pilot: create without recycle (keep arcs to prevent reuse)
    const pilot_iters: u64 = 5_000;
    var arcs = try std.heap.page_allocator.alloc(ArcArray64, pilot_iters);
    defer std.heap.page_allocator.free(arcs);
    var t = try Timer.start();
    var i: u64 = 0;
    while (i < pilot_iters) : (i += 1) {
        arcs[@intCast(i)] = try ArcArray64.init(allocator, payload);
        // do not recycle; this forces allocator fallback behavior each time
    }
    const pilot_ns = t.read();
    // Release held arcs to avoid leaking
    i = 0;
    while (i < pilot_iters) : (i += 1) arcs[@intCast(i)].release();

    const run_iters = scale_iters(pilot_iters, pilot_ns, target_ms);

    var stats = Stats{};
    var rep: usize = 0;
    while (rep < repeats) : (rep += 1) {
        var list = try std.heap.page_allocator.alloc(ArcArray64, run_iters);
        defer std.heap.page_allocator.free(list);
        t = try Timer.start();
        i = 0;
        while (i < run_iters) : (i += 1) {
            list[@intCast(i)] = try ArcArray64.init(allocator, payload);
        }
        const ns = t.read();
        record(&stats, run_iters, ns);
        // release all
        i = 0;
        while (i < run_iters) : (i += 1) list[@intCast(i)].release();
        pool.drainThreadCache();
    }
    return .{ .stats = stats, .iterations = run_iters };
}

pub fn run_pool_split_scenarios() !void {
    var pool_tls = PoolTypeOff.init(getAllocator(), .{});
    defer pool_tls.deinit();
    const tls = try benchPoolTlsOnly(&pool_tls, 60, 2);

    var pool_global = PoolTypeOff.init(getAllocator(), .{});
    defer pool_global.deinit();
    const global = try benchPoolGlobalOnly(&pool_global, 60, 2);

    const alloc = try benchPoolAllocOnly(60, 1);

    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const wr = fbs.writer();
    try wr.print("## ArcPool Split Scenarios (TLS / Global / Allocator)\n", .{});
    try wr.print("| Scenario | Iterations | ns/op (median) | Throughput (ops/s) |\n", .{});
    try wr.print("| --- | --- | --- | --- |\n", .{});
    try writeBenchRow(wr, "TLS only", tls.iterations, tls.stats);
    try writeBenchRow(wr, "Global only", global.iterations, global.stats);
    try writeBenchRow(wr, "Allocator only", alloc.iterations, alloc.stats);
    try wr.print("\n", .{});
    try write_md_append(fbs.getWritten());

    // Console throughput summary
    const f_thr_tls = medianIqrOpsPerSecF64(&tls.stats);
    const f_thr_glob = medianIqrOpsPerSecF64(&global.stats);
    const f_thr_alloc = medianIqrOpsPerSecF64(&alloc.stats);
    var s1: f64 = 0; var s2: f64 = 0; var s3: f64 = 0;
    const unit_tls = scale_rate_f64(&s1, f_thr_tls.median);
    const unit_glob = scale_rate_f64(&s2, f_thr_glob.median);
    const unit_alloc = scale_rate_f64(&s3, f_thr_alloc.median);
    var sb1: [48]u8 = undefined; var sb2: [48]u8 = undefined; var sb3: [48]u8 = undefined;
    std.debug.print("Split scenarios throughput: TLS={s} {s}, Global={s} {s}, Allocator={s} {s}\n",
        .{ fmt_f64_commas2(&sb1, s1), unit_tls, fmt_f64_commas2(&sb2, s2), unit_glob, fmt_f64_commas2(&sb3, s3), unit_alloc });
}

pub fn main() !void {
    // Produce only the requested Arc tables
    try run_single(4);

    // Optional: one-off uncontended SVO microbench (no time checking).
    // Enable by setting env ARC_BENCH_UNCONTENDED=1
    // Prints results to console only; does not modify the MD report.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    if (std.process.getEnvMap(arena.allocator())) |env| {
        if (env.get("ARC_BENCH_UNCONTENDED")) |_| {
            try run_uncontended_arc_svo_max();
        }
    } else |_| {}
}

// One-off uncontended microbenchmark for Arc SVO (u32), single thread,
// with a fixed maximum iteration count and no time checks inside the loop.
fn run_uncontended_arc_svo_max() !void {
    const allocator = getAllocator();
    const ArcType = beam.Utils.Arc(u32);
    const max_iter: u64 = 500_000_000;

    var base = try ArcType.init(allocator, 123);
    defer base.release();

    var t = try Timer.start();
    var i: u64 = 0;
    while (i < max_iter) : (i += 1) {
        const c = base.clone();
        // Prevent the optimizer from eliding the loop body when SVO makes
        // clone/release a no-op with no externally visible effects.
        std.mem.doNotOptimizeAway(c);
        c.release();
    }
    const ns = t.read();

    // Compute and print simple stats
    // f64-based metrics to avoid integer underflow/overflow artifacts.
    const ns_f = @as(f64, @floatFromInt(ns));
    const it_f = @as(f64, @floatFromInt(max_iter));
    const ns_per_f = if (max_iter == 0) 0.0 else ns_f / it_f;
    const ops_s_f = if (ns == 0) 0.0 else (it_f * 1_000_000_000.0) / ns_f;
    var ib: [32]u8 = undefined; const s_iters = fmt_u64_commas(&ib, max_iter);
    var fb1: [48]u8 = undefined; const s_ns = fmt_f64_commas2(&fb1, ns_per_f);
    var scaled: f64 = 0; const unit = scale_rate_f64(&scaled, ops_s_f);
    var fb2: [48]u8 = undefined; const s_rate = fmt_f64_commas2(&fb2, scaled);
    std.debug.print("[Uncontended SVO 1T] iters={s}  ns/op={s}  Throughput={s} {s}\n", .{ s_iters, s_ns, s_rate, unit });
}
