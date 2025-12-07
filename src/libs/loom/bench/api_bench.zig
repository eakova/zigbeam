// Parallel Iterator API Benchmark
//
// Benchmarks all user-facing parallel iterator APIs with CPU-intensive work.
// Results are saved to: src/libs/loom/docs/LOOM_BENCH_RESULTS_YYYY-MM-DD_HHMMSS.md

const std = @import("std");
const loom = @import("loom");
const reporter = @import("bench-reporter");
const par_iter = loom.par_iter;
const ThreadPool = loom.ThreadPool;
const Reducer = loom.Reducer;

const WARMUP = 2;
const ITERS = 5;
const SIZE = 100_000;

var pool: *ThreadPool = undefined;
var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};

// Benchmark result tracking for MD output
const BenchResult = struct {
    name: []const u8,
    seq_ms: f64,
    par_ms: f64,
    ns_per_op: f64,
    speedup: f64,
};

var results: [16]BenchResult = undefined;
var result_count: usize = 0;

fn recordResult(name: []const u8, seq_ms: f64, par_ms: f64) void {
    const ns_per_op = par_ms * 1_000_000.0 / @as(f64, SIZE);
    const speedup = seq_ms / par_ms;
    results[result_count] = .{
        .name = name,
        .seq_ms = seq_ms,
        .par_ms = par_ms,
        .ns_per_op = ns_per_op,
        .speedup = speedup,
    };
    result_count += 1;
}

pub fn main() !void {
    const allocator = gpa.allocator();
    pool = try ThreadPool.init(allocator, .{ .num_threads = 8 });
    defer pool.deinit();

    std.debug.print("=== Parallel Iterator API Benchmark ===\n", .{});
    std.debug.print("Size: {d} | Threads: 8 | Work: ~500ns/elem\n\n", .{SIZE});
    std.debug.print("{s:<20} {s:>10} {s:>10} {s:>10} {s:>8}\n", .{ "API", "Seq(ms)", "Par(ms)", "ns/op", "Speedup" });
    std.debug.print("{s}\n", .{"-" ** 60});

    // Allocate test data
    const data = try allocator.alloc(i64, SIZE);
    defer allocator.free(data);
    resetData(data);

    // forEach
    try benchForEach(data);
    resetData(data);

    // reduce/sum
    try benchSum(data);
    resetData(data);

    // min/max
    try benchMinMax(data);
    resetData(data);

    // map
    try benchMap(allocator, data);
    resetData(data);

    // filter
    try benchFilter(allocator, data);
    resetData(data);

    // any/all
    try benchAnyAll(data);
    resetData(data);

    // find/position
    try benchFindPosition(data);
    resetData(data);

    // count
    try benchCount(data);
    resetData(data);

    // sort
    try benchSort(allocator, data);

    std.debug.print("\n=== Done ===\n", .{});

    // Write MD report
    try writeMdReport();
}

fn writeMdReport() !void {
    const cpu_count = std.Thread.getCpuCount() catch 0;
    try reporter.writeHeader("Loom API Benchmark Results", "macOS Darwin", cpu_count);

    var writer = reporter.MdWriter.init();

    writer.append("## Parallel Iterator API Benchmark\n\n");
    writer.print("**Configuration**: {d} elements, 8 threads, ~500ns/elem CPU-bound work\n\n", .{SIZE});

    // Table header
    writer.append("| API Operation | Seq(ms) | Par(ms) | ns/op | Speedup |\n");
    writer.append("|---------------|---------|---------|-------|---------|\n");

    // Table rows
    for (results[0..result_count]) |r| {
        writer.print("| {s} | {d:.2} | {d:.2} | {d:.0} | **{d:.2}x** |\n", .{
            r.name,
            r.seq_ms,
            r.par_ms,
            r.ns_per_op,
            r.speedup,
        });
    }

    writer.append("\n*Note: Operations with early-exit semantics (any, all, find) don't benefit from full parallelization.*\n\n");

    try writer.flush();
    std.debug.print("Results written to: {s}\n", .{reporter.getMdPath()});
}

fn resetData(data: []i64) void {
    for (data, 0..) |*item, i| {
        item.* = @intCast(i + 1);
    }
}

// CPU-intensive work ~500ns
fn cpuWork(x: *i64) void {
    var v = x.*;
    for (0..500) |_| v = (v *% 1103515245 +% 12345) >> 16;
    x.* = v;
}

fn cpuCompute(x: i64) i64 {
    var v = x;
    for (0..500) |_| v = (v *% 1103515245 +% 12345) >> 16;
    return v;
}

fn cpuPred(x: i64) bool {
    var v = x;
    for (0..500) |_| v = (v *% 1103515245 +% 12345) >> 16;
    return v > 0;
}

fn cpuPredHalf(x: i64) bool {
    var v = x;
    for (0..500) |_| v = (v *% 1103515245 +% 12345) >> 16;
    return @mod(v, 2) == 0;
}

fn printResult(name: []const u8, seq_ms: f64, par_ms: f64) void {
    const ns_per_op = par_ms * 1_000_000.0 / @as(f64, SIZE);
    const speedup = seq_ms / par_ms;
    std.debug.print("{s:<20} {d:>10.2} {d:>10.2} {d:>10.0} {d:>7.2}x\n", .{ name, seq_ms, par_ms, ns_per_op, speedup });
    recordResult(name, seq_ms, par_ms);
}

fn benchForEach(data: []i64) !void {
    // Sequential
    for (0..WARMUP) |_| for (data) |*x| cpuWork(x);
    const s0 = std.time.nanoTimestamp();
    for (0..ITERS) |_| for (data) |*x| cpuWork(x);
    const seq_ms = @as(f64, @floatFromInt(std.time.nanoTimestamp() - s0)) / @as(f64, ITERS) / 1e6;

    // Parallel
    for (0..WARMUP) |_| par_iter(data).withPool(pool).forEach(cpuWork);
    const p0 = std.time.nanoTimestamp();
    for (0..ITERS) |_| par_iter(data).withPool(pool).forEach(cpuWork);
    const par_ms = @as(f64, @floatFromInt(std.time.nanoTimestamp() - p0)) / @as(f64, ITERS) / 1e6;

    printResult("forEach", seq_ms, par_ms);
}

fn benchSum(data: []i64) !void {
    // Sequential
    for (0..WARMUP) |_| {
        var s: i64 = 0;
        for (data) |x| s +%= cpuCompute(x);
        std.mem.doNotOptimizeAway(s);
    }
    const s0 = std.time.nanoTimestamp();
    for (0..ITERS) |_| {
        var s: i64 = 0;
        for (data) |x| s +%= cpuCompute(x);
        std.mem.doNotOptimizeAway(s);
    }
    const seq_ms = @as(f64, @floatFromInt(std.time.nanoTimestamp() - s0)) / @as(f64, ITERS) / 1e6;

    // Parallel (using forEach + final sum since reduce doesn't support custom work)
    for (0..WARMUP) |_| {
        par_iter(data).withPool(pool).forEach(cpuWork);
        std.mem.doNotOptimizeAway(par_iter(data).withPool(pool).sum());
    }
    const p0 = std.time.nanoTimestamp();
    for (0..ITERS) |_| {
        par_iter(data).withPool(pool).forEach(cpuWork);
        std.mem.doNotOptimizeAway(par_iter(data).withPool(pool).sum());
    }
    const par_ms = @as(f64, @floatFromInt(std.time.nanoTimestamp() - p0)) / @as(f64, ITERS) / 1e6;

    printResult("sum (compute+add)", seq_ms, par_ms);
}

fn benchMinMax(data: []i64) !void {
    // Sequential
    for (0..WARMUP) |_| {
        var mn: i64 = std.math.maxInt(i64);
        var mx: i64 = std.math.minInt(i64);
        for (data) |x| {
            const v = cpuCompute(x);
            mn = @min(mn, v);
            mx = @max(mx, v);
        }
        std.mem.doNotOptimizeAway(mn);
        std.mem.doNotOptimizeAway(mx);
    }
    const s0 = std.time.nanoTimestamp();
    for (0..ITERS) |_| {
        var mn: i64 = std.math.maxInt(i64);
        var mx: i64 = std.math.minInt(i64);
        for (data) |x| {
            const v = cpuCompute(x);
            mn = @min(mn, v);
            mx = @max(mx, v);
        }
        std.mem.doNotOptimizeAway(mn);
        std.mem.doNotOptimizeAway(mx);
    }
    const seq_ms = @as(f64, @floatFromInt(std.time.nanoTimestamp() - s0)) / @as(f64, ITERS) / 1e6;

    // Parallel
    for (0..WARMUP) |_| {
        par_iter(data).withPool(pool).forEach(cpuWork);
        std.mem.doNotOptimizeAway(par_iter(data).withPool(pool).min());
        std.mem.doNotOptimizeAway(par_iter(data).withPool(pool).max());
    }
    const p0 = std.time.nanoTimestamp();
    for (0..ITERS) |_| {
        par_iter(data).withPool(pool).forEach(cpuWork);
        std.mem.doNotOptimizeAway(par_iter(data).withPool(pool).min());
        std.mem.doNotOptimizeAway(par_iter(data).withPool(pool).max());
    }
    const par_ms = @as(f64, @floatFromInt(std.time.nanoTimestamp() - p0)) / @as(f64, ITERS) / 1e6;

    printResult("min/max", seq_ms, par_ms);
}

fn benchMap(allocator: std.mem.Allocator, data: []i64) !void {
    // Sequential
    const seq_out = try allocator.alloc(i64, SIZE);
    defer allocator.free(seq_out);
    for (0..WARMUP) |_| {
        for (data, 0..) |x, i| seq_out[i] = cpuCompute(x);
    }
    const s0 = std.time.nanoTimestamp();
    for (0..ITERS) |_| {
        for (data, 0..) |x, i| seq_out[i] = cpuCompute(x);
    }
    const seq_ms = @as(f64, @floatFromInt(std.time.nanoTimestamp() - s0)) / @as(f64, ITERS) / 1e6;

    // Parallel
    for (0..WARMUP) |_| {
        const r = try par_iter(data).withPool(pool).withAlloc(allocator).map(i64, cpuCompute, null);
        allocator.free(r);
    }
    const p0 = std.time.nanoTimestamp();
    for (0..ITERS) |_| {
        const r = try par_iter(data).withPool(pool).withAlloc(allocator).map(i64, cpuCompute, null);
        allocator.free(r);
    }
    const par_ms = @as(f64, @floatFromInt(std.time.nanoTimestamp() - p0)) / @as(f64, ITERS) / 1e6;

    printResult("map", seq_ms, par_ms);
}

fn benchFilter(allocator: std.mem.Allocator, data: []i64) !void {
    // Sequential
    for (0..WARMUP) |_| {
        const r = try par_iter(data).filterSeq(cpuPredHalf, allocator);
        allocator.free(r);
    }
    const s0 = std.time.nanoTimestamp();
    for (0..ITERS) |_| {
        const r = try par_iter(data).filterSeq(cpuPredHalf, allocator);
        allocator.free(r);
    }
    const seq_ms = @as(f64, @floatFromInt(std.time.nanoTimestamp() - s0)) / @as(f64, ITERS) / 1e6;

    // Parallel
    for (0..WARMUP) |_| {
        const r = try par_iter(data).withPool(pool).withAlloc(allocator).filter(cpuPredHalf, null);
        allocator.free(r);
    }
    const p0 = std.time.nanoTimestamp();
    for (0..ITERS) |_| {
        const r = try par_iter(data).withPool(pool).withAlloc(allocator).filter(cpuPredHalf, null);
        allocator.free(r);
    }
    const par_ms = @as(f64, @floatFromInt(std.time.nanoTimestamp() - p0)) / @as(f64, ITERS) / 1e6;

    printResult("filter", seq_ms, par_ms);
}

fn benchAnyAll(data: []i64) !void {
    // Sequential any
    for (0..WARMUP) |_| std.mem.doNotOptimizeAway(par_iter(data).anySeq(cpuPred));
    const s0 = std.time.nanoTimestamp();
    for (0..ITERS) |_| std.mem.doNotOptimizeAway(par_iter(data).anySeq(cpuPred));
    const seq_any_ms = @as(f64, @floatFromInt(std.time.nanoTimestamp() - s0)) / @as(f64, ITERS) / 1e6;

    // Parallel any
    for (0..WARMUP) |_| std.mem.doNotOptimizeAway(par_iter(data).withPool(pool).any(cpuPred));
    const p0 = std.time.nanoTimestamp();
    for (0..ITERS) |_| std.mem.doNotOptimizeAway(par_iter(data).withPool(pool).any(cpuPred));
    const par_any_ms = @as(f64, @floatFromInt(std.time.nanoTimestamp() - p0)) / @as(f64, ITERS) / 1e6;

    printResult("any", seq_any_ms, par_any_ms);

    // Sequential all
    for (0..WARMUP) |_| std.mem.doNotOptimizeAway(par_iter(data).allSeq(cpuPred));
    const s1 = std.time.nanoTimestamp();
    for (0..ITERS) |_| std.mem.doNotOptimizeAway(par_iter(data).allSeq(cpuPred));
    const seq_all_ms = @as(f64, @floatFromInt(std.time.nanoTimestamp() - s1)) / @as(f64, ITERS) / 1e6;

    // Parallel all
    for (0..WARMUP) |_| std.mem.doNotOptimizeAway(par_iter(data).withPool(pool).all(cpuPred));
    const p1 = std.time.nanoTimestamp();
    for (0..ITERS) |_| std.mem.doNotOptimizeAway(par_iter(data).withPool(pool).all(cpuPred));
    const par_all_ms = @as(f64, @floatFromInt(std.time.nanoTimestamp() - p1)) / @as(f64, ITERS) / 1e6;

    printResult("all", seq_all_ms, par_all_ms);
}

fn benchFindPosition(data: []i64) !void {
    // Put target in middle
    data[SIZE / 2] = -999;

    const findPred = struct {
        fn pred(x: i64) bool {
            var v = x;
            for (0..500) |_| v = (v *% 1103515245 +% 12345) >> 16;
            return x == -999;
        }
    }.pred;

    // Sequential find
    for (0..WARMUP) |_| std.mem.doNotOptimizeAway(par_iter(data).findSeq(findPred));
    const s0 = std.time.nanoTimestamp();
    for (0..ITERS) |_| std.mem.doNotOptimizeAway(par_iter(data).findSeq(findPred));
    const seq_ms = @as(f64, @floatFromInt(std.time.nanoTimestamp() - s0)) / @as(f64, ITERS) / 1e6;

    // Parallel find
    for (0..WARMUP) |_| std.mem.doNotOptimizeAway(par_iter(data).withPool(pool).find(findPred));
    const p0 = std.time.nanoTimestamp();
    for (0..ITERS) |_| std.mem.doNotOptimizeAway(par_iter(data).withPool(pool).find(findPred));
    const par_ms = @as(f64, @floatFromInt(std.time.nanoTimestamp() - p0)) / @as(f64, ITERS) / 1e6;

    printResult("find", seq_ms, par_ms);

    // Sequential position
    for (0..WARMUP) |_| std.mem.doNotOptimizeAway(par_iter(data).positionSeq(findPred));
    const s1 = std.time.nanoTimestamp();
    for (0..ITERS) |_| std.mem.doNotOptimizeAway(par_iter(data).positionSeq(findPred));
    const seq_pos_ms = @as(f64, @floatFromInt(std.time.nanoTimestamp() - s1)) / @as(f64, ITERS) / 1e6;

    // Parallel position
    for (0..WARMUP) |_| std.mem.doNotOptimizeAway(par_iter(data).withPool(pool).position(findPred));
    const p1 = std.time.nanoTimestamp();
    for (0..ITERS) |_| std.mem.doNotOptimizeAway(par_iter(data).withPool(pool).position(findPred));
    const par_pos_ms = @as(f64, @floatFromInt(std.time.nanoTimestamp() - p1)) / @as(f64, ITERS) / 1e6;

    printResult("position", seq_pos_ms, par_pos_ms);
}

fn benchCount(data: []i64) !void {
    // Sequential
    for (0..WARMUP) |_| std.mem.doNotOptimizeAway(par_iter(data).countSeq(cpuPredHalf));
    const s0 = std.time.nanoTimestamp();
    for (0..ITERS) |_| std.mem.doNotOptimizeAway(par_iter(data).countSeq(cpuPredHalf));
    const seq_ms = @as(f64, @floatFromInt(std.time.nanoTimestamp() - s0)) / @as(f64, ITERS) / 1e6;

    // Parallel
    for (0..WARMUP) |_| std.mem.doNotOptimizeAway(par_iter(data).withPool(pool).count(cpuPredHalf));
    const p0 = std.time.nanoTimestamp();
    for (0..ITERS) |_| std.mem.doNotOptimizeAway(par_iter(data).withPool(pool).count(cpuPredHalf));
    const par_ms = @as(f64, @floatFromInt(std.time.nanoTimestamp() - p0)) / @as(f64, ITERS) / 1e6;

    printResult("count", seq_ms, par_ms);
}

fn benchSort(allocator: std.mem.Allocator, data: []i64) !void {
    const cmp = struct {
        fn less(a: i64, b: i64) bool {
            return a < b;
        }
    }.less;

    // Sequential (use std.sort as baseline)
    const seq_data = try allocator.alloc(i64, SIZE);
    defer allocator.free(seq_data);

    for (0..WARMUP) |_| {
        @memcpy(seq_data, data);
        std.mem.sort(i64, seq_data, {}, struct {
            fn lt(_: void, a: i64, b: i64) bool {
                return a < b;
            }
        }.lt);
    }
    const s0 = std.time.nanoTimestamp();
    for (0..ITERS) |_| {
        @memcpy(seq_data, data);
        std.mem.sort(i64, seq_data, {}, struct {
            fn lt(_: void, a: i64, b: i64) bool {
                return a < b;
            }
        }.lt);
    }
    const seq_ms = @as(f64, @floatFromInt(std.time.nanoTimestamp() - s0)) / @as(f64, ITERS) / 1e6;

    // Parallel sort
    const par_data = try allocator.alloc(i64, SIZE);
    defer allocator.free(par_data);

    for (0..WARMUP) |_| {
        @memcpy(par_data, data);
        try par_iter(par_data).withPool(pool).withAlloc(allocator).sort(cmp, null);
    }
    const p0 = std.time.nanoTimestamp();
    for (0..ITERS) |_| {
        @memcpy(par_data, data);
        try par_iter(par_data).withPool(pool).withAlloc(allocator).sort(cmp, null);
    }
    const par_ms = @as(f64, @floatFromInt(std.time.nanoTimestamp() - p0)) / @as(f64, ITERS) / 1e6;

    printResult("sort", seq_ms, par_ms);
}
