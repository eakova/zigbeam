// FILE: arc_benchmark.zig
// All comments are in English as requested.

const std = @import("std");
const testing = std.testing;
const Thread = std.Thread;
const Timer = std.time.Timer;

// Adjust import paths for your project structure.
const ArcModule = @import("arc.zig");
const ArcU64 = ArcModule.Arc(u64);
const ArcPoolModule = @import("arc-pool/arc_pool.zig");

// --- Benchmark Configuration ---
// The number of clone/release pairs to perform in each benchmark run.
// A larger number gives more stable results.
const BENCHMARK_ITERATIONS: u64 = 1_000_000;

// The number of threads to use for the multi-threaded benchmark.
// Defaults to the number of available CPU cores.
// Use a fixed thread count to keep arrays comptime-known on Zig 0.15.
const BENCHMARK_THREADS: usize = 4;

const MD_PATH = "src/arc/docs/arc_benchmark_results.md";

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

// Single-Threaded Benchmark
//
// This test measures the raw, best-case performance of `clone` and `release`
// operations without any cross-thread contention. It establishes the baseline
// overhead of the reference counting mechanism.
fn benchCloneReleaseType(comptime T: type, value: T, target_ms: u64, repeats: usize) !struct { stats: Stats, iterations: u64 } {
    const allocator = testing.allocator;
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

pub fn run_single() !void {
    const allocator = testing.allocator;
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
        .{ run_iters, BENCHMARK_THREADS, os_tag, arch_tag, zig_ver, mode_tag, ptr_bits, cpu_count },
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
const WorkerContext = struct {
    iterations: u64,
    shared_arc: *const ArcU64,
};

// The function executed by each worker thread.
fn benchmarkWorker(ctx: *WorkerContext) void {
    var i: u64 = 0;
    while (i < ctx.iterations) : (i += 1) {
        const clone = ctx.shared_arc.clone();
        clone.release();
    }
}

pub fn run_multi() !void {
    // Use a general-purpose allocator that honors alignment requirements.
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create the shared Arc that all threads will contend on.
    var shared_arc = try ArcU64.init(allocator, 456);
    defer shared_arc.release();

    // Prepare contexts and thread handles.
    var threads: [BENCHMARK_THREADS]Thread = undefined;
    var contexts: [BENCHMARK_THREADS]WorkerContext = undefined;
    const iters_per_thread = BENCHMARK_ITERATIONS / BENCHMARK_THREADS;

    var timer = try Timer.start();

    // Spawn all worker threads.
    for (&threads, 0..) |*t, i| {
        contexts[i] = .{
            .iterations = iters_per_thread,
            .shared_arc = &shared_arc,
        };
        t.* = try Thread.spawn(.{}, benchmarkWorker, .{&contexts[i]});
    }

    // Wait for all worker threads to complete.
    for (threads) |t| {
        t.join();
    }

    const elapsed_ns = timer.read();
    const total_iterations = iters_per_thread * BENCHMARK_THREADS;

    // Calculate and print the results.
    const ns_per_op = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(total_iterations));
    const ops_per_sec = @as(f64, @floatFromInt(std.time.ns_per_s)) / ns_per_op;

    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();
    try w.print("## Multi-Threaded\n", .{});
    try w.print("- Threads: {d}\n", .{BENCHMARK_THREADS});
    try w.print("- Total Operations: {d}\n", .{total_iterations});
    try w.print("- Total Time: {d} ms\n", .{elapsed_ns / std.time.ns_per_ms});
    try w.print("- Latency (ns/op): {d:.3}\n", .{ns_per_op});
    var nb: [32]u8 = undefined;
    var nb2: [32]u8 = undefined;
    var nb3: [32]u8 = undefined;
    const ops_u64: u64 = @intFromFloat(ops_per_sec);
    const s_ops = fmt_u64_commas(&nb, ops_u64);
    const s_ops_h = fmt_rate_human(&nb2, ops_u64);
    const per_thread = ops_u64 / BENCHMARK_THREADS;
    const s_per_thread = fmt_rate_human(&nb3, per_thread);
    try w.print("- Throughput: {s} (≈ {s} {s})\n", .{ s_ops, s_ops_h, unit_suffix(ops_u64) });
    try w.print("- Per-thread Throughput: {s} {s}\n\n", .{ s_per_thread, unit_suffix(per_thread) });
    try write_md_append(fbs.getWritten());
    // Console summary
    std.debug.print("ARC MT  threads={} total_ops={}  ns/op={d:.3}  ops/s={}  per-thread≈{}\n", .{ BENCHMARK_THREADS, total_iterations, ns_per_op, ops_u64, per_thread });

    // A simple assertion. Even under contention, performance should be reasonable.
    try testing.expect(ns_per_op < 100.0);
}

fn benchDowngradeUpgrade(comptime T: type, value: T, target_ms: u64, repeats: usize) !struct { stats: Stats, iterations: u64 } {
    const ArcType = ArcModule.Arc(T);
    const allocator = testing.allocator;
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

pub fn run_pool_churn() !void {
    var pool = ArcPoolModule.ArcPool([64]u8).init(testing.allocator);
    defer pool.deinit();

    const result = try benchPoolChurn(&pool, [_]u8{9} ** 64, 60, 2);

    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const wr = fbs.writer();

    try wr.print("## ArcPool Create/Recycle Benchmark\n", .{});
    try wr.print("| Scenario | Iterations | ns/op (median) | ops/s (median) |\n", .{});
    try wr.print("| --- | --- | --- | --- |\n", .{});
    try writeBenchRow(wr, "pool churn", result.iterations, result.stats);
    try wr.print("\n", .{});
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
    try run_single();
    if (shouldRunMT()) try run_multi();
    try run_svo_vs_heap();
    try run_downgrade_upgrade();
    try run_pool_churn();
}
