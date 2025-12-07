// Work-Stealing Benchmark
//
// Measures work-stealing efficiency under imbalanced workloads.
// Tests how well the scheduler balances work across threads.
//
// Results are saved to: src/libs/loom/docs/LOOM_BENCH_RESULTS_YYYY-MM-DD_HHMMSS.md

const std = @import("std");
const loom = @import("loom");
const reporter = @import("bench-reporter");
const par_iter = loom.par_iter;
const ThreadPool = loom.ThreadPool;

const WARMUP = 2;
const ITERS = 3;
const SIZE = 10_000;
const THREADS = 8;

var pool: *ThreadPool = undefined;

// Result tracking for MD output
const WorkloadResult = struct {
    name: []const u8,
    seq_ms: f64,
    par_ms: f64,
    ns_per_op: f64,
    speedup: f64,
};

var workload_results: [8]WorkloadResult = undefined;
var workload_count: usize = 0;

var efficiency_seq_ms: f64 = 0;
var efficiency_par_ms: f64 = 0;
var efficiency_ideal_ms: f64 = 0;
var efficiency_no_steal_ms: f64 = 0;
var efficiency_speedup: f64 = 0;
var efficiency_pct: f64 = 0;
var work_stealing_effective: bool = false;

fn recordWorkload(name: []const u8, seq_ms: f64, par_ms: f64) void {
    const ns_per_op = par_ms * 1e6 / @as(f64, SIZE);
    const speedup = seq_ms / par_ms;
    workload_results[workload_count] = .{
        .name = name,
        .seq_ms = seq_ms,
        .par_ms = par_ms,
        .ns_per_op = ns_per_op,
        .speedup = speedup,
    };
    workload_count += 1;
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    pool = try ThreadPool.init(allocator, .{ .num_threads = THREADS });
    defer pool.deinit();

    std.debug.print("=== Work-Stealing Benchmark ===\n", .{});
    std.debug.print("Size: {d} | Threads: {d}\n\n", .{ SIZE, THREADS });
    std.debug.print("{s:<25} {s:>10} {s:>10} {s:>10} {s:>10}\n", .{ "Workload", "Seq(ms)", "Par(ms)", "ns/op", "Speedup" });
    std.debug.print("{s}\n", .{"-" ** 65});

    const data = try allocator.alloc(i64, SIZE);
    defer allocator.free(data);

    // 1. Uniform work (baseline)
    try benchUniform(data, 500);

    // 2. Skewed (first half heavy)
    try benchSkewed(data, 900, 100);

    // 3. Heavy skew (10% heavy)
    try benchHeavySkew(data, 4500, 50);

    // 4. Single heavy chunk at start
    try benchSingleHeavyChunk(data);

    std.debug.print("\n=== Work-Stealing Efficiency Test ===\n\n", .{});
    try benchEfficiency(allocator);

    std.debug.print("\n=== Done ===\n", .{});

    // Write MD report
    try writeMdReport();
}

fn writeMdReport() !void {
    const cpu_count = std.Thread.getCpuCount() catch 0;
    try reporter.writeHeader("Loom Work-Stealing Benchmark Results", "macOS Darwin", cpu_count);

    var writer = reporter.MdWriter.init();

    writer.append("## Work-Stealing Efficiency Benchmark\n\n");
    writer.print("**Configuration**: {d} elements, {d} threads\n\n", .{ SIZE, THREADS });

    // Workload distribution table
    writer.append("### Workload Distribution Tests\n\n");
    writer.append("| Workload Pattern | Seq(ms) | Par(ms) | ns/op | Speedup |\n");
    writer.append("|------------------|---------|---------|-------|---------|\n");

    for (workload_results[0..workload_count]) |r| {
        writer.print("| {s} | {d:.2} | {d:.2} | {d:.0} | **{d:.2}x** |\n", .{
            r.name,
            r.seq_ms,
            r.par_ms,
            r.ns_per_op,
            r.speedup,
        });
    }

    // Efficiency test section
    writer.append("\n### Extreme Imbalance Test\n\n");
    writer.append("**Config**: 100 heavy tasks @ 10K iters + 900 light tasks @ 100 iters\n\n");
    writer.append("| Metric | Value |\n");
    writer.append("|--------|-------|\n");
    writer.print("| Sequential | {d:.2}ms |\n", .{efficiency_seq_ms});
    writer.print("| Parallel (8T) | {d:.2}ms |\n", .{efficiency_par_ms});
    writer.print("| Ideal parallel | {d:.2}ms |\n", .{efficiency_ideal_ms});
    writer.print("| No-steal worst | {d:.2}ms |\n", .{efficiency_no_steal_ms});
    writer.print("| Speedup | {d:.2}x (ideal: 8.0x) |\n", .{efficiency_speedup});
    writer.print("| Efficiency | {d:.1}% |\n", .{efficiency_pct});
    if (work_stealing_effective) {
        writer.append("| Work-stealing | ✓ EFFECTIVE |\n");
    } else {
        writer.append("| Work-stealing | ⚠ LIMITED |\n");
    }

    writer.append("\n**Analysis**: Static chunk assignment causes poor load balancing with extreme work imbalance.\n");
    writer.append("Heavy tasks clustered in early chunks leave later threads idle.\n");
    writer.append("Dynamic work-stealing helps slightly but chunk granularity limits effectiveness.\n\n");

    try writer.flush();
    std.debug.print("Results written to: {s}\n", .{reporter.getMdPath()});
}

fn doWork(x: *i64, iters: u32) void {
    var v = x.*;
    for (0..iters) |_| {
        v = (v *% 1103515245 +% 12345) >> 16;
    }
    x.* = v;
}

fn resetData(data: []i64) void {
    for (data, 0..) |*d, i| d.* = @intCast(i + 1);
}

fn benchUniform(data: []i64, iters: u32) !void {
    resetData(data);

    // Sequential
    for (0..WARMUP) |_| for (data) |*d| doWork(d, iters);
    const s0 = std.time.nanoTimestamp();
    for (0..ITERS) |_| for (data) |*d| doWork(d, iters);
    const seq_ms = @as(f64, @floatFromInt(std.time.nanoTimestamp() - s0)) / @as(f64, ITERS) / 1e6;

    resetData(data);

    // Parallel
    for (0..WARMUP) |_| {
        par_iter(data).withPool(pool).forEach(struct {
            fn f(x: *i64) void {
                doWork(x, 500);
            }
        }.f);
    }
    const p0 = std.time.nanoTimestamp();
    for (0..ITERS) |_| {
        par_iter(data).withPool(pool).forEach(struct {
            fn f(x: *i64) void {
                doWork(x, 500);
            }
        }.f);
    }
    const par_ms = @as(f64, @floatFromInt(std.time.nanoTimestamp() - p0)) / @as(f64, ITERS) / 1e6;

    printResult("Uniform (500)", seq_ms, par_ms);
}

fn benchSkewed(data: []i64, heavy: u32, light: u32) !void {
    resetData(data);
    const half = SIZE / 2;

    // Sequential
    for (0..WARMUP) |_| {
        for (data[0..half]) |*d| doWork(d, heavy);
        for (data[half..]) |*d| doWork(d, light);
    }
    const s0 = std.time.nanoTimestamp();
    for (0..ITERS) |_| {
        for (data[0..half]) |*d| doWork(d, heavy);
        for (data[half..]) |*d| doWork(d, light);
    }
    const seq_ms = @as(f64, @floatFromInt(std.time.nanoTimestamp() - s0)) / @as(f64, ITERS) / 1e6;

    resetData(data);

    // Parallel - use index to determine work
    for (0..WARMUP) |_| {
        par_iter(data).withPool(pool).forEachIndexed(struct {
            fn f(i: usize, x: *i64) void {
                const iters: u32 = if (i < SIZE / 2) 900 else 100;
                doWork(x, iters);
            }
        }.f);
    }
    const p0 = std.time.nanoTimestamp();
    for (0..ITERS) |_| {
        par_iter(data).withPool(pool).forEachIndexed(struct {
            fn f(i: usize, x: *i64) void {
                const iters: u32 = if (i < SIZE / 2) 900 else 100;
                doWork(x, iters);
            }
        }.f);
    }
    const par_ms = @as(f64, @floatFromInt(std.time.nanoTimestamp() - p0)) / @as(f64, ITERS) / 1e6;

    printResult("Skewed (900/100)", seq_ms, par_ms);
}

fn benchHeavySkew(data: []i64, heavy: u32, light: u32) !void {
    resetData(data);
    const tenth = SIZE / 10;

    // Sequential
    for (0..WARMUP) |_| {
        for (data[0..tenth]) |*d| doWork(d, heavy);
        for (data[tenth..]) |*d| doWork(d, light);
    }
    const s0 = std.time.nanoTimestamp();
    for (0..ITERS) |_| {
        for (data[0..tenth]) |*d| doWork(d, heavy);
        for (data[tenth..]) |*d| doWork(d, light);
    }
    const seq_ms = @as(f64, @floatFromInt(std.time.nanoTimestamp() - s0)) / @as(f64, ITERS) / 1e6;

    resetData(data);

    // Parallel
    for (0..WARMUP) |_| {
        par_iter(data).withPool(pool).forEachIndexed(struct {
            fn f(i: usize, x: *i64) void {
                const iters: u32 = if (i < SIZE / 10) 4500 else 50;
                doWork(x, iters);
            }
        }.f);
    }
    const p0 = std.time.nanoTimestamp();
    for (0..ITERS) |_| {
        par_iter(data).withPool(pool).forEachIndexed(struct {
            fn f(i: usize, x: *i64) void {
                const iters: u32 = if (i < SIZE / 10) 4500 else 50;
                doWork(x, iters);
            }
        }.f);
    }
    const par_ms = @as(f64, @floatFromInt(std.time.nanoTimestamp() - p0)) / @as(f64, ITERS) / 1e6;

    printResult("Heavy skew (4500/50)", seq_ms, par_ms);
}

fn benchSingleHeavyChunk(data: []i64) !void {
    resetData(data);
    // First 1/8 of data is very heavy, rest is light
    // This tests if work-stealing can rescue threads stuck with light work

    const heavy_end = SIZE / 8;
    const heavy_iters: u32 = 3000;
    const light_iters: u32 = 100;

    // Sequential
    for (0..WARMUP) |_| {
        for (data[0..heavy_end]) |*d| doWork(d, heavy_iters);
        for (data[heavy_end..]) |*d| doWork(d, light_iters);
    }
    const s0 = std.time.nanoTimestamp();
    for (0..ITERS) |_| {
        for (data[0..heavy_end]) |*d| doWork(d, heavy_iters);
        for (data[heavy_end..]) |*d| doWork(d, light_iters);
    }
    const seq_ms = @as(f64, @floatFromInt(std.time.nanoTimestamp() - s0)) / @as(f64, ITERS) / 1e6;

    resetData(data);

    // Parallel
    for (0..WARMUP) |_| {
        par_iter(data).withPool(pool).forEachIndexed(struct {
            fn f(i: usize, x: *i64) void {
                const iters: u32 = if (i < SIZE / 8) 3000 else 100;
                doWork(x, iters);
            }
        }.f);
    }
    const p0 = std.time.nanoTimestamp();
    for (0..ITERS) |_| {
        par_iter(data).withPool(pool).forEachIndexed(struct {
            fn f(i: usize, x: *i64) void {
                const iters: u32 = if (i < SIZE / 8) 3000 else 100;
                doWork(x, iters);
            }
        }.f);
    }
    const par_ms = @as(f64, @floatFromInt(std.time.nanoTimestamp() - p0)) / @as(f64, ITERS) / 1e6;

    printResult("Single heavy chunk", seq_ms, par_ms);
}

fn benchEfficiency(allocator: std.mem.Allocator) !void {
    // Extreme imbalance: 100 heavy tasks (10K iters) + 900 light tasks (100 iters)
    const test_size: usize = 1000;
    const heavy_count: usize = 100;
    const heavy_iters: u32 = 10000;
    const light_iters: u32 = 100;

    const data = try allocator.alloc(i64, test_size);
    defer allocator.free(data);

    for (data, 0..) |*d, i| d.* = @intCast(i + 1);

    // Sequential
    const s0 = std.time.nanoTimestamp();
    for (data, 0..) |*d, i| {
        const iters: u32 = if (i < heavy_count) heavy_iters else light_iters;
        doWork(d, iters);
    }
    const seq_ms = @as(f64, @floatFromInt(std.time.nanoTimestamp() - s0)) / 1e6;

    for (data, 0..) |*d, i| d.* = @intCast(i + 1);

    // Parallel
    const p0 = std.time.nanoTimestamp();
    par_iter(data).withPool(pool).forEachIndexed(struct {
        fn f(i: usize, x: *i64) void {
            const iters: u32 = if (i < 100) 10000 else 100;
            doWork(x, iters);
        }
    }.f);
    const par_ms = @as(f64, @floatFromInt(std.time.nanoTimestamp() - p0)) / 1e6;

    const speedup = seq_ms / par_ms;
    const efficiency = speedup / @as(f64, THREADS) * 100.0;

    // Theoretical: total work = 100*10000 + 900*100 = 1,090,000 iterations
    // Ideal parallel time = total / threads
    const total_iters = heavy_count * heavy_iters + (test_size - heavy_count) * light_iters;
    const ideal_par_iters = @as(f64, @floatFromInt(total_iters)) / @as(f64, THREADS);
    const avg_iter_ns = seq_ms * 1e6 / @as(f64, @floatFromInt(total_iters));
    const ideal_par_ms = ideal_par_iters * avg_iter_ns / 1e6;

    // Without stealing: thread 0 gets chunk with all heavy work
    // Worst case: one thread does 100 heavy = 1,000,000 iters
    const no_steal_iters = heavy_count * heavy_iters;
    const no_steal_ms = @as(f64, @floatFromInt(no_steal_iters)) * avg_iter_ns / 1e6;

    std.debug.print("Extreme imbalance test (100 heavy @ 10K, 900 light @ 100):\n\n", .{});
    std.debug.print("  Sequential:     {d:>8.2}ms\n", .{seq_ms});
    std.debug.print("  Parallel (8T):  {d:>8.2}ms\n", .{par_ms});
    std.debug.print("  Ideal parallel: {d:>8.2}ms\n", .{ideal_par_ms});
    std.debug.print("  No-steal worst: {d:>8.2}ms\n", .{no_steal_ms});
    std.debug.print("\n", .{});
    std.debug.print("  Speedup:        {d:>8.2}x (ideal: {d:.1}x)\n", .{ speedup, @as(f64, THREADS) });
    std.debug.print("  Efficiency:     {d:>8.1}%\n", .{efficiency});

    if (par_ms < no_steal_ms * 0.9) {
        std.debug.print("  Work-stealing:  ✓ EFFECTIVE\n", .{});
        work_stealing_effective = true;
    } else {
        std.debug.print("  Work-stealing:  ⚠ LIMITED\n", .{});
        work_stealing_effective = false;
    }

    // Record for MD output
    efficiency_seq_ms = seq_ms;
    efficiency_par_ms = par_ms;
    efficiency_ideal_ms = ideal_par_ms;
    efficiency_no_steal_ms = no_steal_ms;
    efficiency_speedup = speedup;
    efficiency_pct = efficiency;
}

fn printResult(name: []const u8, seq_ms: f64, par_ms: f64) void {
    const ns_per_op = par_ms * 1e6 / @as(f64, SIZE);
    const speedup = seq_ms / par_ms;
    std.debug.print("{s:<25} {d:>10.2} {d:>10.2} {d:>10.0} {d:>9.2}x\n", .{ name, seq_ms, par_ms, ns_per_op, speedup });
    recordWorkload(name, seq_ms, par_ms);
}
