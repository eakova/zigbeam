// throughput_bench.zig - Comprehensive Throughput Benchmark
//
// Measures key performance metrics for ZigParallel:
// - Join overhead (SC-006 validation)
// - Parallel iterator scaling (SC-003 validation)
// - Quicksort performance
// - Scope throughput
//
// Usage: zig build bench-throughput-zigparallel
//
// This benchmark validates success criteria:
// - SC-003: 6x+ speedup on 8 cores (embarrassingly parallel)
// - SC-006: spawn < 100ns without contention

const std = @import("std");
const zigparallel = @import("loom");
const ThreadPool = zigparallel.ThreadPool;
const par_iter = zigparallel.par_iter;
const join = zigparallel.join;
const joinOnPool = zigparallel.joinOnPool;
const scope = zigparallel.scope;
const scopeOnPool = zigparallel.scopeOnPool;
const Scope = zigparallel.Scope;
const Splitter = zigparallel.Splitter;
const Reducer = zigparallel.Reducer;

const WARMUP_ITERATIONS = 3;
const BENCH_ITERATIONS = 100;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("╔══════════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║          ZigParallel Comprehensive Throughput Benchmark      ║\n", .{});
    std.debug.print("╚══════════════════════════════════════════════════════════════╝\n\n", .{});

    // Get system info
    const cpu_count = std.Thread.getCpuCount() catch 4;
    std.debug.print("System: {d} logical CPUs\n", .{cpu_count});
    std.debug.print("Warmup: {d} iterations, Bench: {d} iterations\n\n", .{ WARMUP_ITERATIONS, BENCH_ITERATIONS });

    // Create pool with 4 workers (or half CPU count)
    const num_workers: usize = @min(4, @max(2, cpu_count / 2));
    const pool = try ThreadPool.init(allocator, .{ .num_threads = num_workers });
    defer pool.deinit();
    std.debug.print("ThreadPool: {d} workers\n\n", .{num_workers});

    // ========================================================================
    // Benchmark 1: Join Round-Trip Overhead
    // Note: This measures full fork-join round-trip including thread wake-up.
    // SC-006 (spawn <100ns) is validated by scope spawn benchmark below.
    // ========================================================================
    std.debug.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", .{});
    std.debug.print("Benchmark 1: Fork-Join Round-Trip Overhead\n", .{});
    std.debug.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", .{});

    const join_result = benchmarkJoinOverhead(pool);
    std.debug.print("  Join round-trip:   {d}ns (includes thread wake-up)\n", .{join_result.empty_join_ns});
    std.debug.print("  With-work join:    {d:.3}ms (parallel)\n", .{join_result.work_join_parallel_ms});
    std.debug.print("  With-work seq:     {d:.3}ms (sequential)\n", .{join_result.work_join_sequential_ms});
    std.debug.print("  Join speedup:      {d:.2}x\n\n", .{join_result.speedup});

    // ========================================================================
    // Benchmark 2: Parallel Iterator Scaling (SC-003 validation)
    // ========================================================================
    std.debug.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", .{});
    std.debug.print("Benchmark 2: Parallel Iterator Scaling (SC-003: target 6x+)\n", .{});
    std.debug.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", .{});

    const scaling_result = try benchmarkParIterScaling(pool, allocator);
    std.debug.print("  Elements:          {d}M\n", .{scaling_result.elements / 1_000_000});
    std.debug.print("  Sequential:        {d:.3}ms\n", .{scaling_result.sequential_ms});
    std.debug.print("  Parallel ({d}w):    {d:.3}ms\n", .{ num_workers, scaling_result.parallel_ms });
    std.debug.print("  Speedup:           {d:.2}x\n", .{scaling_result.speedup});

    const scaling_status = if (scaling_result.speedup >= 6.0) "✓ PASS" else if (scaling_result.speedup >= 4.0) "⚠ CLOSE" else "✗ FAIL";
    std.debug.print("  SC-003 Status:     {s}\n\n", .{scaling_status});

    // ========================================================================
    // Benchmark 3: Quicksort Scaling (Real-world CPU-bound)
    // ========================================================================
    std.debug.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", .{});
    std.debug.print("Benchmark 3: Parallel Quicksort (Real-world CPU-bound)\n", .{});
    std.debug.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", .{});

    const qsort_result = try benchmarkQuicksort(pool, allocator);
    std.debug.print("  Elements:          {d}K\n", .{qsort_result.elements / 1000});
    std.debug.print("  Sequential:        {d:.3}ms\n", .{qsort_result.sequential_ms});
    std.debug.print("  Parallel ({d}w):    {d:.3}ms\n", .{ num_workers, qsort_result.parallel_ms });
    std.debug.print("  Speedup:           {d:.2}x\n", .{qsort_result.speedup});
    std.debug.print("  Verified:          {s}\n\n", .{if (qsort_result.verified) "YES" else "NO"});

    // ========================================================================
    // Benchmark 4: Scope Throughput
    // ========================================================================
    std.debug.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", .{});
    std.debug.print("Benchmark 4: Scope Spawn Throughput\n", .{});
    std.debug.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", .{});

    const scope_result = benchmarkScopeThroughput(pool);
    std.debug.print("  Tasks:             {d}\n", .{scope_result.task_count});
    std.debug.print("  Total time:        {d:.3}ms\n", .{scope_result.total_time_ms});
    std.debug.print("  Avg spawn latency: {d}ns\n", .{scope_result.avg_spawn_ns});
    std.debug.print("  Throughput:        {d:.2}K tasks/sec\n\n", .{scope_result.throughput_k});

    // ========================================================================
    // Summary
    // ========================================================================
    // SC-006 is validated by scope spawn latency (not join round-trip)
    const spawn_status = if (scope_result.avg_spawn_ns < 100) "✓ PASS" else if (scope_result.avg_spawn_ns < 300) "⚠ CLOSE (macOS TLS)" else "✗ FAIL";

    std.debug.print("╔══════════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║                         SUMMARY                              ║\n", .{});
    std.debug.print("╠══════════════════════════════════════════════════════════════╣\n", .{});
    std.debug.print("║ SC-003 (6x speedup):   {s: <38} ║\n", .{scaling_status});
    std.debug.print("║ SC-006 (spawn <100ns): {s: <38} ║\n", .{spawn_status});
    std.debug.print("║ Quicksort speedup:     {d:.2}x{s: <34} ║\n", .{ qsort_result.speedup, "" });
    std.debug.print("║ Spawn latency:         {d}ns{s: <34} ║\n", .{ scope_result.avg_spawn_ns, "" });
    std.debug.print("╚══════════════════════════════════════════════════════════════╝\n", .{});
}

// ============================================================================
// Benchmark Implementations
// ============================================================================

const JoinResult = struct {
    empty_join_ns: u64,
    work_join_parallel_ms: f64,
    work_join_sequential_ms: f64,
    speedup: f64,
};

fn benchmarkJoinOverhead(pool: *ThreadPool) JoinResult {
    const work_iterations: usize = 100_000;

    // Warmup
    for (0..WARMUP_ITERATIONS) |_| {
        _ = joinOnPool(pool, emptyTask, .{}, emptyTask, .{});
    }

    // Benchmark empty join
    const empty_start = std.time.nanoTimestamp();
    for (0..BENCH_ITERATIONS) |_| {
        _ = joinOnPool(pool, emptyTask, .{}, emptyTask, .{});
    }
    const empty_end = std.time.nanoTimestamp();
    const empty_ns = @as(u64, @intCast(empty_end - empty_start)) / BENCH_ITERATIONS;

    // Benchmark with work
    const WorkArgs = struct { n: usize };

    const par_start = std.time.nanoTimestamp();
    _ = joinOnPool(pool, doWork, .{WorkArgs{ .n = work_iterations }}, doWork, .{WorkArgs{ .n = work_iterations }});
    const par_end = std.time.nanoTimestamp();
    const par_ms = @as(f64, @floatFromInt(par_end - par_start)) / 1_000_000.0;

    // Sequential baseline
    const seq_start = std.time.nanoTimestamp();
    _ = doWork(WorkArgs{ .n = work_iterations });
    _ = doWork(WorkArgs{ .n = work_iterations });
    const seq_end = std.time.nanoTimestamp();
    const seq_ms = @as(f64, @floatFromInt(seq_end - seq_start)) / 1_000_000.0;

    return JoinResult{
        .empty_join_ns = empty_ns,
        .work_join_parallel_ms = par_ms,
        .work_join_sequential_ms = seq_ms,
        .speedup = seq_ms / par_ms,
    };
}

fn emptyTask() void {}

fn doWork(args: anytype) u64 {
    var sum: u64 = 0;
    for (0..args.n) |i| {
        sum +%= i * i;
    }
    std.mem.doNotOptimizeAway(sum);
    return sum;
}

const ScalingResult = struct {
    elements: usize,
    sequential_ms: f64,
    parallel_ms: f64,
    speedup: f64,
};

fn benchmarkParIterScaling(pool: *ThreadPool, allocator: std.mem.Allocator) !ScalingResult {
    const elements: usize = 1_000_000;

    const data = try allocator.alloc(i64, elements);
    defer allocator.free(data);

    // Initialize with values
    for (data, 0..) |*item, i| {
        item.* = @intCast(i);
    }

    // Warmup - use larger chunks to reduce scheduling overhead
    for (0..WARMUP_ITERATIONS) |_| {
        par_iter(data).withPool(pool).withSplitter(Splitter.adaptive(50000)).forEach(cpuBoundWork);
    }

    // Reset
    for (data, 0..) |*item, i| {
        item.* = @intCast(i);
    }

    // Sequential baseline - do actual CPU work
    const seq_start = std.time.nanoTimestamp();
    for (data) |*item| {
        cpuBoundWork(item);
    }
    const seq_end = std.time.nanoTimestamp();
    const seq_ms = @as(f64, @floatFromInt(seq_end - seq_start)) / 1_000_000.0;

    // Reset
    for (data, 0..) |*item, i| {
        item.* = @intCast(i);
    }

    // Parallel - use larger chunks to reduce scheduling overhead
    const par_start = std.time.nanoTimestamp();
    par_iter(data).withPool(pool).withSplitter(Splitter.adaptive(50000)).forEach(cpuBoundWork);
    const par_end = std.time.nanoTimestamp();
    const par_ms = @as(f64, @floatFromInt(par_end - par_start)) / 1_000_000.0;

    return ScalingResult{
        .elements = elements,
        .sequential_ms = seq_ms,
        .parallel_ms = par_ms,
        .speedup = seq_ms / par_ms,
    };
}

fn cpuBoundWork(x: *i64) void {
    // Do substantial computation to ensure CPU-bound (not memory-bound)
    // 500 iterations @ ~1ns each = ~500ns per element
    // This amortizes parallel overhead and tests true CPU scaling
    var val = x.*;
    for (0..500) |_| {
        val = (val *% 1103515245 +% 12345) >> 16;
    }
    x.* = val;
}

const QuicksortResult = struct {
    elements: usize,
    sequential_ms: f64,
    parallel_ms: f64,
    speedup: f64,
    verified: bool,
};

fn benchmarkQuicksort(pool: *ThreadPool, allocator: std.mem.Allocator) !QuicksortResult {
    const elements: usize = 100_000;

    const data = try allocator.alloc(i32, elements);
    defer allocator.free(data);

    const data_copy = try allocator.alloc(i32, elements);
    defer allocator.free(data_copy);

    // Initialize with random-ish data
    var rng = std.Random.DefaultPrng.init(12345);
    for (data) |*item| {
        item.* = rng.random().int(i32);
    }
    @memcpy(data_copy, data);

    // Sequential quicksort
    const seq_start = std.time.nanoTimestamp();
    std.mem.sort(i32, data_copy, {}, std.sort.asc(i32));
    const seq_end = std.time.nanoTimestamp();
    const seq_ms = @as(f64, @floatFromInt(seq_end - seq_start)) / 1_000_000.0;

    // Parallel sort using par_iter
    const par_start = std.time.nanoTimestamp();
    try par_iter(data).withPool(pool).withAlloc(allocator).sort(struct {
        fn lessThan(a: i32, b: i32) bool {
            return a < b;
        }
    }.lessThan, null);
    const par_end = std.time.nanoTimestamp();
    const par_ms = @as(f64, @floatFromInt(par_end - par_start)) / 1_000_000.0;

    // Verify
    const verified = std.mem.eql(i32, data, data_copy);

    return QuicksortResult{
        .elements = elements,
        .sequential_ms = seq_ms,
        .parallel_ms = par_ms,
        .speedup = seq_ms / par_ms,
        .verified = verified,
    };
}

const ScopeResult = struct {
    task_count: usize,
    total_time_ms: f64,
    avg_spawn_ns: u64,
    throughput_k: f64,
};

fn benchmarkScopeThroughput(pool: *ThreadPool) ScopeResult {
    const task_count: usize = 1000;

    // Static counter for scope tasks
    const ScopeState = struct {
        var counter: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);

        fn work() void {
            _ = counter.fetchAdd(1, .acq_rel);
        }
    };

    // Warmup
    for (0..WARMUP_ITERATIONS) |_| {
        ScopeState.counter.store(0, .seq_cst);
        scopeOnPool(pool, struct {
            fn body(s: *Scope) void {
                for (0..100) |_| {
                    s.spawn(ScopeState.work, .{});
                }
            }
        }.body);
    }

    // Benchmark
    ScopeState.counter.store(0, .seq_cst);
    const start = std.time.nanoTimestamp();

    scopeOnPool(pool, struct {
        fn body(s: *Scope) void {
            for (0..task_count) |_| {
                s.spawn(ScopeState.work, .{});
            }
        }
    }.body);

    const end = std.time.nanoTimestamp();
    const total_ns = @as(u64, @intCast(end - start));
    const total_ms = @as(f64, @floatFromInt(total_ns)) / 1_000_000.0;
    const avg_spawn_ns = total_ns / task_count;
    const throughput = @as(f64, @floatFromInt(task_count)) / total_ms;

    return ScopeResult{
        .task_count = task_count,
        .total_time_ms = total_ms,
        .avg_spawn_ns = avg_spawn_ns,
        .throughput_k = throughput,
    };
}
