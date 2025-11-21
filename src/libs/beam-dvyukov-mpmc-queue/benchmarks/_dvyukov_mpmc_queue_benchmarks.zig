// FILE: _dvyukov_mpmc_queue_benchmarks.zig
//! Benchmarks for DVyukov MPMC Queue.
//!
//! Purpose:
//! - Measure throughput and latency for single-threaded and multi-threaded scenarios
//! - Test SPSC, MPSC, SPMC, and MPMC patterns
//! - Evaluate performance across different queue capacities
//! - Produce a Markdown report under `src/libs/dvyukov-mpmc-queue/BENCHMARKS.md`
//!
//! Quick run:
//! - `zig build-exe src/libs/dvyukov-mpmc-queue/_dvyukov_mpmc_queue_benchmarks.zig -O ReleaseFast`
//! - `./dvyukov_mpmc_queue_benchmarks`
//! - Report: `src/libs/dvyukov-mpmc-queue/BENCHMARKS.md`

const std = @import("std");
const Thread = std.Thread;
const Timer = std.time.Timer;
const Atomic = std.atomic.Value;
const DVyukovMPMCQueue = @import("beam-dvyukov-mpmc").DVyukovMPMCQueue;
const helpers = @import("helpers");

// --- Benchmark Configuration ---
const MD_PATH_PREFIX = "src/libs/beam-dvyukov-mpmc-queue/benchmarks/DVYUKOV_MPMC_BENCHMARK_RESULTS_";

// Fixed iteration counts for reproducible results
const MAX_TOTAL_ITERS: u64 = 100_000_000; // 100M total operations
const PILOT_ITERS: u64 = 100_000; // Pilot run iterations

// Benchmark parameters
const REPEATS: usize = 3; // Number of repeated measurements
const WARMUPS: usize = 1; // Warmup runs (not measured)

// Global buffer to hold the timestamped path
var g_md_path_buf: [128]u8 = undefined;
var g_md_path: []const u8 = "";

fn getMdPath() []const u8 {
    if (g_md_path.len == 0) {
        g_md_path = helpers.formatTimestampPath(&g_md_path_buf, MD_PATH_PREFIX);
    }
    return g_md_path;
}

// --- Helper Functions ---

fn write_md_truncate(content: []const u8) !void {
    try helpers.writeFileTruncate(getMdPath(), content);
}

fn write_md_append(content: []const u8) !void {
    try helpers.writeFileAppend(getMdPath(), content);
}

// Format u64 with thousands separators
fn fmt_u64_commas(buf: *[32]u8, value: u64) []const u8 {
    return helpers.fmtU64Commas(buf, value);
}

// Format f64 with thousands separators and two decimals
fn fmt_f64_commas2(buf: *[48]u8, val: f64) []const u8 {
    return helpers.fmtF64Commas2(buf, val);
}

// Scale f64 rate to human units
fn scale_rate_f64(scaled: *f64, rate: f64) []const u8 {
    if (rate >= 1_000_000_000.0) {
        scaled.* = rate / 1_000_000_000.0;
        return "G/s";
    }
    if (rate >= 1_000_000.0) {
        scaled.* = rate / 1_000_000.0;
        return "M/s";
    }
    if (rate >= 1_000.0) {
        scaled.* = rate / 1_000.0;
        return "K/s";
    }
    scaled.* = rate;
    return "/s";
}

// --- Statistics ---

const Stats = struct {
    ns_list: [16]u64 = .{0} ** 16,
    ops_list: [16]u64 = .{0} ** 16,
    len: usize = 0,
};

fn record(stats: *Stats, ops: u64, ns: u64) void {
    if (stats.len < 16) {
        stats.ns_list[stats.len] = ns;
        stats.ops_list[stats.len] = ops;
        stats.len += 1;
    }
}

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

fn calculateMedianStats(stats: Stats) struct { ns_per_op: f64, ops_per_sec: f64 } {
    if (stats.len == 0) return .{ .ns_per_op = 0, .ops_per_sec = 0 };

    // Calculate ns/op for each sample
    var ns_per_list: [16]f64 = undefined;
    var i: usize = 0;
    while (i < stats.len) : (i += 1) {
        const ops_f = @as(f64, @floatFromInt(stats.ops_list[i]));
        const ns_f = @as(f64, @floatFromInt(stats.ns_list[i]));
        ns_per_list[i] = if (stats.ops_list[i] == 0) 0.0 else ns_f / ops_f;
    }

    // Sort and find median
    var j: usize = 1;
    while (j < stats.len) : (j += 1) {
        var k: usize = j;
        while (k > 0 and ns_per_list[k - 1] > ns_per_list[k]) : (k -= 1) {
            const tmp = ns_per_list[k - 1];
            ns_per_list[k - 1] = ns_per_list[k];
            ns_per_list[k] = tmp;
        }
    }

    const mid = stats.len / 2;
    const median_ns_per_op = if (stats.len % 2 == 1)
        ns_per_list[mid]
    else
        (ns_per_list[mid - 1] + ns_per_list[mid]) / 2.0;

    const ops_per_sec = if (median_ns_per_op == 0) 0.0 else 1_000_000_000.0 / median_ns_per_op;

    return .{ .ns_per_op = median_ns_per_op, .ops_per_sec = ops_per_sec };
}

// --- Benchmark Helpers ---

fn getAllocator() std.mem.Allocator {
    return std.heap.page_allocator;
}

// --- Single-Threaded Benchmarks ---

fn benchSingleThreaded(comptime capacity: usize, iterations: u64) !Stats {
    const allocator = getAllocator();
    const QueueType = DVyukovMPMCQueue(u64, capacity);

    var stats = Stats{};
    var warmup: usize = 0;
    while (warmup < WARMUPS) : (warmup += 1) {
        var queue_w = try QueueType.init(allocator);
        defer queue_w.deinit();
        var i: u64 = 0;
        while (i < iterations) : (i += 1) {
            try queue_w.enqueue(i);
            _ = queue_w.dequeue();
        }
    }

    var rep: usize = 0;
    while (rep < REPEATS) : (rep += 1) {
        var queue = try QueueType.init(allocator);
        defer queue.deinit();

        var timer = try Timer.start();
        var i: u64 = 0;
        while (i < iterations) : (i += 1) {
            try queue.enqueue(i);
            _ = queue.dequeue();
        }
        const ns = timer.read();
        const total_ops = iterations * 2; // enqueue + dequeue
        record(&stats, total_ops, ns);
    }

    return stats;
}

// --- Multi-Threaded Benchmarks ---

/// Worker context aligned to cache line to prevent false sharing
/// Each context occupies exactly one cache line (128 bytes on ARM64),
/// preventing adjacent threads from causing cache ping-pong
fn WorkerContext(comptime capacity: usize) type {
    return struct {
        // First field sets alignment for entire struct
        queue: *DVyukovMPMCQueue(u64, capacity) align(std.atomic.cache_line),
        iterations: u64,
        start_flag: *Atomic(u8),
        is_producer: bool,

        // Padding to ensure each context occupies full cache line
        // Without this, 5+ contexts would share a cache line → false sharing
        _padding: [
            blk: {
                const fields_size = @sizeOf(*DVyukovMPMCQueue(u64, capacity)) +
                    @sizeOf(u64) +
                    @sizeOf(*Atomic(u8)) +
                    @sizeOf(bool);
                const aligned_size = std.mem.alignForward(usize, fields_size, std.atomic.cache_line);
                const remainder = aligned_size % std.atomic.cache_line;
                break :blk if (remainder == 0) 0 else std.atomic.cache_line - remainder;
            }
        ]u8 = undefined,
    };
}

fn spscProducer(comptime capacity: usize) fn (*WorkerContext(capacity)) void {
    const Ctx = WorkerContext(capacity);
    return struct {
        fn run(ctx: *Ctx) void {
            // Wait for start signal
            while (ctx.start_flag.load(.seq_cst) == 0) {
                Thread.yield() catch {};
            }

            var i: u64 = 0;
            while (i < ctx.iterations) : (i += 1) {
                while (true) {
                    ctx.queue.enqueue(i) catch {
                        std.atomic.spinLoopHint();
                        continue;
                    };
                    break;
                }
            }
        }
    }.run;
}

fn spscConsumer(comptime capacity: usize) fn (*WorkerContext(capacity)) void {
    const Ctx = WorkerContext(capacity);
    return struct {
        fn run(ctx: *Ctx) void {
            // Wait for start signal
            while (ctx.start_flag.load(.seq_cst) == 0) {
                Thread.yield() catch {};
            }

            var count: u64 = 0;
            while (count < ctx.iterations) {
                if (ctx.queue.dequeue()) |_| {
                    count += 1;
                } else {
                    std.atomic.spinLoopHint();
                }
            }
        }
    }.run;
}

fn benchSPSC(comptime capacity: usize, iterations: u64) !Stats {
    const allocator = getAllocator();
    const QueueType = DVyukovMPMCQueue(u64, capacity);
    const Ctx = WorkerContext(capacity);

    var stats = Stats{};
    var warmup: usize = 0;
    while (warmup < WARMUPS) : (warmup += 1) {
        var queue_w = try QueueType.init(allocator);
        defer queue_w.deinit();
        var flag_w = Atomic(u8).init(0);
        var ctx_p_w = Ctx{
            .queue = &queue_w,
            .iterations = iterations,
            .start_flag = &flag_w,
            .is_producer = true,
        };
        var ctx_c_w = Ctx{
            .queue = &queue_w,
            .iterations = iterations,
            .start_flag = &flag_w,
            .is_producer = false,
        };
        const p_w = try Thread.spawn(.{}, spscProducer(capacity), .{&ctx_p_w});
        const c_w = try Thread.spawn(.{}, spscConsumer(capacity), .{&ctx_c_w});
        flag_w.store(1, .seq_cst);
        p_w.join();
        c_w.join();
    }

    var rep: usize = 0;
    while (rep < REPEATS) : (rep += 1) {
        var queue = try QueueType.init(allocator);
        defer queue.deinit();

        var start_flag = Atomic(u8).init(0);
        var ctx_producer = Ctx{
            .queue = &queue,
            .iterations = iterations,
            .start_flag = &start_flag,
            .is_producer = true,
        };
        var ctx_consumer = Ctx{
            .queue = &queue,
            .iterations = iterations,
            .start_flag = &start_flag,
            .is_producer = false,
        };

        const producer_thread = try Thread.spawn(.{}, spscProducer(capacity), .{&ctx_producer});
        const consumer_thread = try Thread.spawn(.{}, spscConsumer(capacity), .{&ctx_consumer});

        var timer = try Timer.start();
        start_flag.store(1, .seq_cst);
        producer_thread.join();
        consumer_thread.join();
        const ns = timer.read();

        const total_ops = iterations * 2; // enqueue + dequeue
        record(&stats, total_ops, ns);
    }

    return stats;
}

fn mpscWorker(comptime capacity: usize) fn (*WorkerContext(capacity)) void {
    const Ctx = WorkerContext(capacity);
    return struct {
        fn run(ctx: *Ctx) void {
            // Wait for start signal
            while (ctx.start_flag.load(.seq_cst) == 0) {
                Thread.yield() catch {};
            }

            if (ctx.is_producer) {
                // Producer: simple retry on full (queue handles backoff internally)
                var i: u64 = 0;
                while (i < ctx.iterations) : (i += 1) {
                    while (true) {
                        ctx.queue.enqueue(i) catch {
                            std.atomic.spinLoopHint();
                            continue;
                        };
                        break;
                    }
                }
            } else {
                // Consumer: simple retry on empty (queue handles backoff internally)
                var count: u64 = 0;
                while (count < ctx.iterations) {
                    if (ctx.queue.dequeue()) |_| {
                        count += 1;
                    } else {
                        std.atomic.spinLoopHint();
                    }
                }
            }
        }
    }.run;
}

fn benchMPSC(comptime capacity: usize, num_producers: usize, items_per_producer: u64) !Stats {
    const allocator = getAllocator();
    const QueueType = DVyukovMPMCQueue(u64, capacity);
    const Ctx = WorkerContext(capacity);
    const total_items = items_per_producer * num_producers;

    var stats = Stats{};
    var warmup: usize = 0;
    while (warmup < WARMUPS) : (warmup += 1) {
        var queue_w = try QueueType.init(allocator);
        defer queue_w.deinit();
        var flag_w = Atomic(u8).init(0);
        const handles_w = try allocator.alloc(Thread, num_producers + 1);
        defer allocator.free(handles_w);
        const contexts_w = try allocator.alloc(Ctx, num_producers + 1);
        defer allocator.free(contexts_w);
        var idx_w: usize = 0;
        while (idx_w < num_producers) : (idx_w += 1) {
            contexts_w[idx_w] = .{
                .queue = &queue_w,
                .iterations = items_per_producer,
                .start_flag = &flag_w,
                .is_producer = true,
            };
            handles_w[idx_w] = try Thread.spawn(.{}, mpscWorker(capacity), .{&contexts_w[idx_w]});
        }
        contexts_w[num_producers] = .{
            .queue = &queue_w,
            .iterations = total_items,
            .start_flag = &flag_w,
            .is_producer = false,
        };
        handles_w[num_producers] = try Thread.spawn(.{}, mpscWorker(capacity), .{&contexts_w[num_producers]});
        flag_w.store(1, .seq_cst);
        for (handles_w) |h| h.join();
    }

    var rep: usize = 0;
    while (rep < REPEATS) : (rep += 1) {
        var queue = try QueueType.init(allocator);
        defer queue.deinit();

        var start_flag = Atomic(u8).init(0);
        const handles = try allocator.alloc(Thread, num_producers + 1);
        defer allocator.free(handles);
        const contexts = try allocator.alloc(Ctx, num_producers + 1);
        defer allocator.free(contexts);

        // Spawn producers
        var idx: usize = 0;
        while (idx < num_producers) : (idx += 1) {
            contexts[idx] = .{
                .queue = &queue,
                .iterations = items_per_producer,
                .start_flag = &start_flag,
                .is_producer = true,
            };
            handles[idx] = try Thread.spawn(.{}, mpscWorker(capacity), .{&contexts[idx]});
        }

        // Spawn consumer
        contexts[num_producers] = .{
            .queue = &queue,
            .iterations = total_items,
            .start_flag = &start_flag,
            .is_producer = false,
        };
        handles[num_producers] = try Thread.spawn(.{}, mpscWorker(capacity), .{&contexts[num_producers]});

        var timer = try Timer.start();
        start_flag.store(1, .seq_cst);
        for (handles) |h| h.join();
        const ns = timer.read();

        const total_ops = total_items * 2;
        record(&stats, total_ops, ns);
    }

    return stats;
}

fn benchSPMC(comptime capacity: usize, num_consumers: usize, total_items: u64) !Stats {
    const allocator = getAllocator();
    const QueueType = DVyukovMPMCQueue(u64, capacity);
    const Ctx = WorkerContext(capacity);
    const items_per_consumer = total_items / num_consumers;

    var stats = Stats{};
    var warmup: usize = 0;
    while (warmup < WARMUPS) : (warmup += 1) {
        var queue_w = try QueueType.init(allocator);
        defer queue_w.deinit();
        var flag_w = Atomic(u8).init(0);
        const handles_w = try allocator.alloc(Thread, num_consumers + 1);
        defer allocator.free(handles_w);
        const contexts_w = try allocator.alloc(Ctx, num_consumers + 1);
        defer allocator.free(contexts_w);
        contexts_w[0] = .{
            .queue = &queue_w,
            .iterations = total_items,
            .start_flag = &flag_w,
            .is_producer = true,
        };
        handles_w[0] = try Thread.spawn(.{}, mpscWorker(capacity), .{&contexts_w[0]});
        var idx_w: usize = 0;
        while (idx_w < num_consumers) : (idx_w += 1) {
            contexts_w[idx_w + 1] = .{
                .queue = &queue_w,
                .iterations = items_per_consumer,
                .start_flag = &flag_w,
                .is_producer = false,
            };
            handles_w[idx_w + 1] = try Thread.spawn(.{}, mpscWorker(capacity), .{&contexts_w[idx_w + 1]});
        }
        flag_w.store(1, .seq_cst);
        for (handles_w) |h| h.join();
    }

    var rep: usize = 0;
    while (rep < REPEATS) : (rep += 1) {
        var queue = try QueueType.init(allocator);
        defer queue.deinit();

        var start_flag = Atomic(u8).init(0);
        const handles = try allocator.alloc(Thread, num_consumers + 1);
        defer allocator.free(handles);
        const contexts = try allocator.alloc(Ctx, num_consumers + 1);
        defer allocator.free(contexts);

        // Spawn producer
        contexts[0] = .{
            .queue = &queue,
            .iterations = total_items,
            .start_flag = &start_flag,
            .is_producer = true,
        };
        handles[0] = try Thread.spawn(.{}, mpscWorker(capacity), .{&contexts[0]});

        // Spawn consumers
        var idx: usize = 0;
        while (idx < num_consumers) : (idx += 1) {
            contexts[idx + 1] = .{
                .queue = &queue,
                .iterations = items_per_consumer,
                .start_flag = &start_flag,
                .is_producer = false,
            };
            handles[idx + 1] = try Thread.spawn(.{}, mpscWorker(capacity), .{&contexts[idx + 1]});
        }

        var timer = try Timer.start();
        start_flag.store(1, .seq_cst);
        for (handles) |h| h.join();
        const ns = timer.read();

        const total_ops = total_items * 2;
        record(&stats, total_ops, ns);
    }

    return stats;
}

fn benchMPMC(comptime capacity: usize, num_producers: usize, num_consumers: usize, items_per_producer: u64) !Stats {
    const allocator = getAllocator();
    const QueueType = DVyukovMPMCQueue(u64, capacity);
    const Ctx = WorkerContext(capacity);
    const total_items = items_per_producer * num_producers;
    const items_per_consumer = total_items / num_consumers;

    var stats = Stats{};
    var warmup: usize = 0;
    while (warmup < WARMUPS) : (warmup += 1) {
        var queue_w = try QueueType.init(allocator);
        defer queue_w.deinit();
        var flag_w = Atomic(u8).init(0);
        const handles_w = try allocator.alloc(Thread, num_producers + num_consumers);
        defer allocator.free(handles_w);
        const contexts_w = try allocator.alloc(Ctx, num_producers + num_consumers);
        defer allocator.free(contexts_w);
        var idx_w: usize = 0;
        while (idx_w < num_producers) : (idx_w += 1) {
            contexts_w[idx_w] = .{
                .queue = &queue_w,
                .iterations = items_per_producer,
                .start_flag = &flag_w,
                .is_producer = true,
            };
            handles_w[idx_w] = try Thread.spawn(.{}, mpscWorker(capacity), .{&contexts_w[idx_w]});
        }
        while (idx_w < num_producers + num_consumers) : (idx_w += 1) {
            contexts_w[idx_w] = .{
                .queue = &queue_w,
                .iterations = items_per_consumer,
                .start_flag = &flag_w,
                .is_producer = false,
            };
            handles_w[idx_w] = try Thread.spawn(.{}, mpscWorker(capacity), .{&contexts_w[idx_w]});
        }
        flag_w.store(1, .seq_cst);
        for (handles_w) |h| h.join();
    }

    var rep: usize = 0;
    while (rep < REPEATS) : (rep += 1) {
        var queue = try QueueType.init(allocator);
        defer queue.deinit();

        var start_flag = Atomic(u8).init(0);
        const handles = try allocator.alloc(Thread, num_producers + num_consumers);
        defer allocator.free(handles);
        const contexts = try allocator.alloc(Ctx, num_producers + num_consumers);
        defer allocator.free(contexts);

        // Spawn producers
        var idx: usize = 0;
        while (idx < num_producers) : (idx += 1) {
            contexts[idx] = .{
                .queue = &queue,
                .iterations = items_per_producer,
                .start_flag = &start_flag,
                .is_producer = true,
            };
            handles[idx] = try Thread.spawn(.{}, mpscWorker(capacity), .{&contexts[idx]});
        }

        // Spawn consumers
        while (idx < num_producers + num_consumers) : (idx += 1) {
            contexts[idx] = .{
                .queue = &queue,
                .iterations = items_per_consumer,
                .start_flag = &start_flag,
                .is_producer = false,
            };
            handles[idx] = try Thread.spawn(.{}, mpscWorker(capacity), .{&contexts[idx]});
        }

        var timer = try Timer.start();
        start_flag.store(1, .seq_cst);
        for (handles) |h| h.join();
        const ns = timer.read();

        const total_ops = total_items * 2;
        record(&stats, total_ops, ns);
    }

    return stats;
}

// --- Report Generation ---

fn writeTableRow(
    writer: anytype,
    scenario: []const u8,
    iterations: u64,
    stats: Stats,
) !void {
    const metrics = calculateMedianStats(stats);

    var buf1: [32]u8 = undefined;
    const s_iters = fmt_u64_commas(&buf1, iterations);

    var buf2: [48]u8 = undefined;
    const s_ns_per_op = fmt_f64_commas2(&buf2, metrics.ns_per_op);

    var scaled: f64 = 0;
    const unit = scale_rate_f64(&scaled, metrics.ops_per_sec);
    var buf3: [48]u8 = undefined;
    const s_rate = fmt_f64_commas2(&buf3, scaled);

    try writer.print("| {s} | {s} | {s} | {s} {s} |\n", .{
        scenario,
        s_iters,
        s_ns_per_op,
        s_rate,
        unit,
    });
}

fn runBenchmarks() !void {
    var buf: [16384]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();

    // Header
    try w.print("# DVyukov MPMC Queue - Benchmark Results\n\n", .{});
    try w.print("Performance measurements for the DVyukov bounded MPMC queue.\n\n", .{});
    try w.print("**Configuration:**\n", .{});
    try w.print("- Total iterations: 100,000,000\n", .{});
    try w.print("- Repeats per scenario: {}\n", .{REPEATS});
    try w.print("- Statistics: Median of {} runs\n\n", .{REPEATS});
    try write_md_truncate(fbs.getWritten());

    // Single-Threaded Benchmarks
    fbs.reset();
    try w.print("## Single-Threaded Performance\n\n", .{});
    try w.print("| Scenario | Iterations | ns/op (median) | Throughput |\n", .{});
    try w.print("|----------|------------|----------------|------------|\n", .{});

    std.debug.print("\n=== Single-Threaded ===\n", .{});
    const capacities = [_]usize{ 64, 256, 1024, 4096 };
    inline for (capacities) |cap| {
        const iters = MAX_TOTAL_ITERS / 2; // Divide by 2 because each iteration = enqueue + dequeue
        const stats = try benchSingleThreaded(cap, iters);
        var scenario_buf: [64]u8 = undefined;
        const scenario = try std.fmt.bufPrint(&scenario_buf, "Capacity {}", .{cap});
        try writeTableRow(w, scenario, iters * 2, stats);
        const metrics = calculateMedianStats(stats);
        std.debug.print("  Cap {}: {d:.2} ns/op, {d:.2} Mops/s\n", .{
            cap,
            metrics.ns_per_op,
            metrics.ops_per_sec / 1_000_000.0,
        });
    }
    try w.print("\n", .{});
    try write_md_append(fbs.getWritten());

    // SPSC Benchmarks
    fbs.reset();
    try w.print("## SPSC (Single Producer, Single Consumer)\n\n", .{});
    try w.print("| Scenario | Iterations | ns/op (median) | Throughput |\n", .{});
    try w.print("|----------|------------|----------------|------------|\n", .{});

    std.debug.print("\n=== SPSC ===\n", .{});
    inline for (capacities) |cap| {
        const iters = MAX_TOTAL_ITERS / 2;
        const stats = try benchSPSC(cap, iters);
        var scenario_buf: [64]u8 = undefined;
        const scenario = try std.fmt.bufPrint(&scenario_buf, "Capacity {}", .{cap});
        try writeTableRow(w, scenario, iters * 2, stats);
        const metrics = calculateMedianStats(stats);
        std.debug.print("  Cap {}: {d:.2} ns/op, {d:.2} Mops/s\n", .{
            cap,
            metrics.ns_per_op,
            metrics.ops_per_sec / 1_000_000.0,
        });
    }
    try w.print("\n", .{});
    try write_md_append(fbs.getWritten());

    // MPSC Benchmarks
    fbs.reset();
    try w.print("## MPSC (Multiple Producers, Single Consumer)\n\n", .{});
    try w.print("| Scenario | Iterations | ns/op (median) | Throughput |\n", .{});
    try w.print("|----------|------------|----------------|------------|\n", .{});

    std.debug.print("\n=== MPSC ===\n", .{});
    const mpsc_configs = [_]struct { producers: usize, cap: usize }{
        .{ .producers = 2, .cap = 512 },
        .{ .producers = 4, .cap = 1024 },
        // COMMENTED OUT: 8+ thread benchmarks
        // .{ .producers = 8, .cap = 2048 },
    };
    inline for (mpsc_configs) |cfg| {
        const items_per_producer = MAX_TOTAL_ITERS / (2 * cfg.producers);
        const stats = try benchMPSC(cfg.cap, cfg.producers, items_per_producer);
        var scenario_buf: [64]u8 = undefined;
        const scenario = try std.fmt.bufPrint(&scenario_buf, "{}P/1C (cap={})", .{ cfg.producers, cfg.cap });
        const total_ops = items_per_producer * cfg.producers * 2;
        try writeTableRow(w, scenario, total_ops, stats);
        const metrics = calculateMedianStats(stats);
        std.debug.print("  {}P/1C: {d:.2} ns/op, {d:.2} Mops/s\n", .{
            cfg.producers,
            metrics.ns_per_op,
            metrics.ops_per_sec / 1_000_000.0,
        });
    }
    try w.print("\n", .{});
    try write_md_append(fbs.getWritten());

    // SPMC Benchmarks
    fbs.reset();
    try w.print("## SPMC (Single Producer, Multiple Consumers)\n\n", .{});
    try w.print("| Scenario | Iterations | ns/op (median) | Throughput |\n", .{});
    try w.print("|----------|------------|----------------|------------|\n", .{});

    std.debug.print("\n=== SPMC ===\n", .{});
    const spmc_configs = [_]struct { consumers: usize, cap: usize }{
        .{ .consumers = 2, .cap = 512 },
        .{ .consumers = 4, .cap = 1024 },
        // COMMENTED OUT: 8+ thread benchmarks
        // .{ .consumers = 8, .cap = 2048 },
    };
    inline for (spmc_configs) |cfg| {
        const total_items = MAX_TOTAL_ITERS / 2;
        const stats = try benchSPMC(cfg.cap, cfg.consumers, total_items);
        var scenario_buf: [64]u8 = undefined;
        const scenario = try std.fmt.bufPrint(&scenario_buf, "1P/{}C (cap={})", .{ cfg.consumers, cfg.cap });
        try writeTableRow(w, scenario, total_items * 2, stats);
        const metrics = calculateMedianStats(stats);
        std.debug.print("  1P/{}C: {d:.2} ns/op, {d:.2} Mops/s\n", .{
            cfg.consumers,
            metrics.ns_per_op,
            metrics.ops_per_sec / 1_000_000.0,
        });
    }
    try w.print("\n", .{});
    try write_md_append(fbs.getWritten());

    // MPMC Benchmarks
    fbs.reset();
    try w.print("## MPMC (Multiple Producers, Multiple Consumers)\n\n", .{});
    try w.print("| Scenario | Iterations | ns/op (median) | Throughput |\n", .{});
    try w.print("|----------|------------|----------------|------------|\n", .{});

    std.debug.print("\n=== MPMC ===\n", .{});
    const mpmc_configs = [_]struct { producers: usize, consumers: usize, cap: usize }{
        .{ .producers = 2, .consumers = 2, .cap = 512 },
        .{ .producers = 4, .consumers = 4, .cap = 2048 },
        // COMMENTED OUT: 8+ thread benchmarks
        // .{ .producers = 8, .consumers = 8, .cap = 4096 },
    };
    inline for (mpmc_configs) |cfg| {
        const items_per_producer = MAX_TOTAL_ITERS / (2 * cfg.producers);
        const stats = try benchMPMC(cfg.cap, cfg.producers, cfg.consumers, items_per_producer);
        var scenario_buf: [64]u8 = undefined;
        const scenario = try std.fmt.bufPrint(&scenario_buf, "{}P/{}C (cap={})", .{ cfg.producers, cfg.consumers, cfg.cap });
        const total_ops = items_per_producer * cfg.producers * 2;
        try writeTableRow(w, scenario, total_ops, stats);
        const metrics = calculateMedianStats(stats);
        std.debug.print("  {}P/{}C: {d:.2} ns/op, {d:.2} Mops/s\n", .{
            cfg.producers,
            cfg.consumers,
            metrics.ns_per_op,
            metrics.ops_per_sec / 1_000_000.0,
        });
    }
    try w.print("\n", .{});
    try write_md_append(fbs.getWritten());

    // Recommendations
    fbs.reset();
    try w.print("## Performance Recommendations\n\n", .{});
    try w.print("Based on benchmark results:\n\n", .{});
    try w.print("- **Low Latency (SPSC)**: Use capacity 256-512 for optimal single-threaded throughput\n", .{});
    try w.print("- **Balanced MPMC**: Use capacity 1024-2048 with 2-4 producers/consumers\n", .{});
    try w.print("- **High Contention**: Use capacity 2048-4096 for 8+ threads\n", .{});
    try w.print("- **Memory Constrained**: Minimum viable capacity is 64, but expect reduced throughput\n\n", .{});
    try w.print("## Notes\n\n", .{});
    try w.print("- All measurements use median of {} runs for statistical stability\n", .{REPEATS});
    try w.print("- Throughput includes both enqueue and dequeue operations\n", .{});
    try w.print("- ns/op = nanoseconds per operation (lower is better)\n", .{});
    try w.print("- Queue capacity must be power of 2\n", .{});
    try write_md_append(fbs.getWritten());
}

pub fn main() !void {
    std.debug.print("\n=== DVyukov MPMC Queue - Benchmarks ===\n", .{});
    std.debug.print("Running comprehensive performance tests...\n", .{});

    try runBenchmarks();

    std.debug.print("\n=== Benchmarks Complete ===\n", .{});
    std.debug.print("Results saved to: {s}\n", .{getMdPath()});
}
