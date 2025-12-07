// Parallel Iterator Benchmark
//
// Benchmarks parallel iterator operations with CPU-intensive work:
// - forEach throughput with ~500ns per element work
// - reduce throughput with computation
// - Scaling with thread count
// - Comparison with sequential baseline
//
// Note: Using CPU-bound work (~500ns/element) to properly measure
// parallelization benefit. Memory-bound operations (simple +1)
// saturate memory bandwidth on single core and show no speedup.
//
// Results are saved to: src/libs/loom/docs/LOOM_BENCH_RESULTS_YYYY-MM-DD_HHMMSS.md

const std = @import("std");
const zigparallel = @import("loom");
const reporter = @import("bench-reporter");
const par_iter = zigparallel.par_iter;
const ThreadPool = zigparallel.ThreadPool;
const Splitter = zigparallel.Splitter;
const Reducer = zigparallel.Reducer;

const WARMUP_ITERS = 3;
const BENCH_ITERS = 5;
// Smaller sizes due to CPU-intensive work (~500ns per element)
const ARRAY_SIZES = [_]usize{ 1_000, 10_000, 100_000, 1_000_000 };
const THREAD_COUNTS = [_]usize{ 1, 2, 4, 8 };

// Result tracking for MD output
const SizeResult = struct {
    size: usize,
    seq_reduce_ms: f64,
    seq_foreach_ms: f64,
    thread_results: [4]ThreadResult, // For 1, 2, 4, 8 threads
};

const ThreadResult = struct {
    threads: usize,
    reduce_ms: f64,
    reduce_speedup: f64,
    foreach_ms: f64,
    foreach_speedup: f64,
};

var size_results: [4]SizeResult = undefined;
var size_result_count: usize = 0;

// CPU-intensive work: ~500ns per element
// This ensures parallelization benefits are visible
fn cpuBoundWork(x: *i64) void {
    var val = x.*;
    // 500 iterations of integer math ~500ns
    for (0..500) |_| {
        val = (val *% 1103515245 +% 12345) >> 16;
    }
    x.* = val;
}

// CPU-intensive computation for reduce
fn cpuBoundCompute(val: i64) i64 {
    var result = val;
    for (0..500) |_| {
        result = (result *% 1103515245 +% 12345) >> 16;
    }
    return result;
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("=== Parallel Iterator Benchmark ===\n\n", .{});

    // Run benchmarks for different array sizes
    for (ARRAY_SIZES) |size| {
        std.debug.print("Array size: {d}\n", .{size});
        for (0..50) |_| std.debug.print("=", .{});
        std.debug.print("\n", .{});

        try benchmarkForSize(allocator, size);
        std.debug.print("\n", .{});
    }

    // Write MD report
    try writeMdReport();
}

fn writeMdReport() !void {
    const cpu_count = std.Thread.getCpuCount() catch 0;
    try reporter.writeHeader("Loom Parallel Iterator Benchmark Results", "macOS Darwin", cpu_count);

    var writer = reporter.MdWriter.init();

    writer.append("## Parallel Iterator Benchmark\n\n");
    writer.append("**Work Type**: CPU-bound (~500ns per element) - 500 iterations of integer math\n");
    writer.append("**Note**: Memory-bound operations (trivial `x += 1`) saturate memory bandwidth on single core and show no speedup.\n\n");

    // Write table for each size
    for (size_results[0..size_result_count]) |sr| {
        writer.print("### Array Size: {d}\n\n", .{sr.size});
        writer.append("| Threads | reduce Time | reduce ns/op | reduce K/sec | reduce Speedup | forEach Time | forEach ns/op | forEach K/sec | forEach Speedup |\n");
        writer.append("|---------|-------------|--------------|--------------|----------------|--------------|---------------|---------------|-----------------|\n");

        // Sequential row
        const seq_reduce_ns = sr.seq_reduce_ms * 1_000_000.0 / @as(f64, @floatFromInt(sr.size));
        const seq_foreach_ns = sr.seq_foreach_ms * 1_000_000.0 / @as(f64, @floatFromInt(sr.size));
        writer.print("| Seq | {d:.2}ms | {d:.0}ns | {d:.0}K | - | {d:.2}ms | {d:.0}ns | {d:.0}K | - |\n", .{
            sr.seq_reduce_ms,
            seq_reduce_ns,
            @as(f64, @floatFromInt(sr.size)) / sr.seq_reduce_ms,
            sr.seq_foreach_ms,
            seq_foreach_ns,
            @as(f64, @floatFromInt(sr.size)) / sr.seq_foreach_ms,
        });

        // Thread rows
        for (sr.thread_results) |tr| {
            if (tr.threads == 0) continue;
            const reduce_ns = tr.reduce_ms * 1_000_000.0 / @as(f64, @floatFromInt(sr.size));
            const foreach_ns = tr.foreach_ms * 1_000_000.0 / @as(f64, @floatFromInt(sr.size));
            writer.print("| {d} | {d:.2}ms | {d:.0}ns | {d:.0}K | {d:.2}x | {d:.2}ms | {d:.0}ns | {d:.0}K | {d:.2}x |\n", .{
                tr.threads,
                tr.reduce_ms,
                reduce_ns,
                @as(f64, @floatFromInt(sr.size)) / tr.reduce_ms,
                tr.reduce_speedup,
                tr.foreach_ms,
                foreach_ns,
                @as(f64, @floatFromInt(sr.size)) / tr.foreach_ms,
                tr.foreach_speedup,
            });
        }
        writer.append("\n");
    }

    try writer.flush();
    std.debug.print("Results written to: {s}\n", .{reporter.getMdPath()});
}

fn benchmarkForSize(allocator: std.mem.Allocator, size: usize) !void {
    // Allocate test data
    const data = try allocator.alloc(i64, size);
    defer allocator.free(data);

    // Initialize data
    for (data, 0..) |*item, i| {
        item.* = @intCast(i + 1);
    }

    // Sequential baseline (CPU-bound work ~500ns per element)
    std.debug.print("\nSequential baseline:\n", .{});

    // Sequential reduce (with CPU-bound computation)
    const seq_reduce_time = benchSequentialReduce(data);
    const seq_reduce_ns_per_op = seq_reduce_time * 1_000_000.0 / @as(f64, @floatFromInt(size));
    std.debug.print("  reduce:  {d:.2}ms | {d:.0}ns/op | {d:.2}K elem/sec\n", .{
        seq_reduce_time,
        seq_reduce_ns_per_op,
        @as(f64, @floatFromInt(size)) / seq_reduce_time,
    });

    // Sequential forEach (with CPU-bound work)
    const seq_foreach_time = benchSequentialForEach(data);
    const seq_foreach_ns_per_op = seq_foreach_time * 1_000_000.0 / @as(f64, @floatFromInt(size));
    std.debug.print("  forEach: {d:.2}ms | {d:.0}ns/op | {d:.2}K elem/sec\n", .{
        seq_foreach_time,
        seq_foreach_ns_per_op,
        @as(f64, @floatFromInt(size)) / seq_foreach_time,
    });

    // Initialize result entry
    var sr = SizeResult{
        .size = size,
        .seq_reduce_ms = seq_reduce_time,
        .seq_foreach_ms = seq_foreach_time,
        .thread_results = [_]ThreadResult{.{ .threads = 0, .reduce_ms = 0, .reduce_speedup = 0, .foreach_ms = 0, .foreach_speedup = 0 }} ** 4,
    };

    // Parallel with different thread counts
    for (THREAD_COUNTS, 0..) |num_threads, ti| {
        std.debug.print("\n{d} thread(s):\n", .{num_threads});

        const pool = try ThreadPool.init(allocator, .{ .num_threads = @intCast(num_threads) });
        defer pool.deinit();

        // Reset data
        for (data, 0..) |*item, i| {
            item.* = @intCast(i + 1);
        }

        // Parallel reduce
        const par_reduce_time = benchParallelReduce(data, pool);
        const par_reduce_ns_per_op = par_reduce_time * 1_000_000.0 / @as(f64, @floatFromInt(size));
        const reduce_speedup = seq_reduce_time / par_reduce_time;
        std.debug.print("  reduce:  {d:.2}ms | {d:.0}ns/op | {d:.2}K elem/sec | {d:.2}x\n", .{
            par_reduce_time,
            par_reduce_ns_per_op,
            @as(f64, @floatFromInt(size)) / par_reduce_time,
            reduce_speedup,
        });

        // Parallel forEach
        const par_foreach_time = benchParallelForEach(data, pool);
        const par_foreach_ns_per_op = par_foreach_time * 1_000_000.0 / @as(f64, @floatFromInt(size));
        const foreach_speedup = seq_foreach_time / par_foreach_time;
        std.debug.print("  forEach: {d:.2}ms | {d:.0}ns/op | {d:.2}K elem/sec | {d:.2}x\n", .{
            par_foreach_time,
            par_foreach_ns_per_op,
            @as(f64, @floatFromInt(size)) / par_foreach_time,
            foreach_speedup,
        });

        // Record thread result
        sr.thread_results[ti] = .{
            .threads = num_threads,
            .reduce_ms = par_reduce_time,
            .reduce_speedup = reduce_speedup,
            .foreach_ms = par_foreach_time,
            .foreach_speedup = foreach_speedup,
        };
    }

    // Store size result
    size_results[size_result_count] = sr;
    size_result_count += 1;
}

fn benchSequentialReduce(data: []i64) f64 {
    // Warmup
    for (0..WARMUP_ITERS) |_| {
        var result: i64 = 0;
        for (data) |item| {
            result +%= cpuBoundCompute(item);
        }
        std.mem.doNotOptimizeAway(result);
    }

    // Benchmark
    const start = std.time.nanoTimestamp();
    for (0..BENCH_ITERS) |_| {
        var result: i64 = 0;
        for (data) |item| {
            result +%= cpuBoundCompute(item);
        }
        std.mem.doNotOptimizeAway(result);
    }
    const end = std.time.nanoTimestamp();

    return @as(f64, @floatFromInt(end - start)) / @as(f64, BENCH_ITERS) / 1_000_000.0;
}

fn benchSequentialForEach(data: []i64) f64 {
    // Warmup
    for (0..WARMUP_ITERS) |_| {
        for (data) |*item| {
            cpuBoundWork(item);
        }
    }

    // Benchmark
    const start = std.time.nanoTimestamp();
    for (0..BENCH_ITERS) |_| {
        for (data) |*item| {
            cpuBoundWork(item);
        }
    }
    const end = std.time.nanoTimestamp();

    return @as(f64, @floatFromInt(end - start)) / @as(f64, BENCH_ITERS) / 1_000_000.0;
}

fn benchParallelReduce(data: []i64, pool: *ThreadPool) f64 {
    // Warmup
    for (0..WARMUP_ITERS) |_| {
        // Use forEach with accumulation since par_iter.sum() doesn't support custom reducers
        var result: i64 = 0;
        par_iter(data).withPool(pool).forEach(struct {
            fn compute(x: *i64) void {
                cpuBoundWork(x);
            }
        }.compute);
        for (data) |item| {
            result +%= item;
        }
        std.mem.doNotOptimizeAway(result);
    }

    // Benchmark
    const start = std.time.nanoTimestamp();
    for (0..BENCH_ITERS) |_| {
        var result: i64 = 0;
        par_iter(data).withPool(pool).forEach(struct {
            fn compute(x: *i64) void {
                cpuBoundWork(x);
            }
        }.compute);
        for (data) |item| {
            result +%= item;
        }
        std.mem.doNotOptimizeAway(result);
    }
    const end = std.time.nanoTimestamp();

    return @as(f64, @floatFromInt(end - start)) / @as(f64, BENCH_ITERS) / 1_000_000.0;
}

fn benchParallelForEach(data: []i64, pool: *ThreadPool) f64 {
    // Warmup
    for (0..WARMUP_ITERS) |_| {
        par_iter(data).withPool(pool).forEach(cpuBoundWork);
    }

    // Benchmark
    const start = std.time.nanoTimestamp();
    for (0..BENCH_ITERS) |_| {
        par_iter(data).withPool(pool).forEach(cpuBoundWork);
    }
    const end = std.time.nanoTimestamp();

    return @as(f64, @floatFromInt(end - start)) / @as(f64, BENCH_ITERS) / 1_000_000.0;
}
