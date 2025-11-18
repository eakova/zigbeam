// FILE: _deque_benchmarks.zig
//! Benchmarks for Work-Stealing Deque and Thread Pool.
//!
//! Purpose:
//! - Measure single-threaded push/pop throughput for WorkStealingDeque
//! - Measure multi-threaded work-stealing throughput (owner + thieves)
//! - Measure thread pool submit/execute throughput
//! - Produce a Markdown report under `src/libs/deque/DEQUE_BENCHMARK_RESULTS.md`
//!
//! Quick run:
//! - `zig build -Doptimize=ReleaseFast bench-deque`
//! - Reports: `src/libs/deque/DEQUE_BENCHMARK_RESULTS.md`

const std = @import("std");
const testing = std.testing;
const Thread = std.Thread;
const Timer = std.time.Timer;
const Atomic = std.atomic.Value;
const beam = @import("zig_beam");
const deque_mod = struct {
    pub const WorkStealingDeque = beam.Libs.WorkStealingDeque;
};
const pool_mod = struct {
    pub const WorkStealingPool = beam.Libs.WorkStealingPool;
};
const Task = beam.Libs.Task;

// --- Benchmark Configuration ---
const MD_PATH = "src/libs/deque/DEQUE_BENCHMARK_RESULTS.md";

// --- Formatting Helpers (from arc benchmarks) ---

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

fn fmt_f64_commas2(buf: *[48]u8, val: f64) []const u8 {
    var out_i: usize = 0;
    const ival_f = @floor(val);
    const ival = @as(u64, @intFromFloat(ival_f));
    var frac_f = (val - ival_f) * 100.0;
    if (frac_f < 0) frac_f = -frac_f;
    const frac = @as(u64, @intFromFloat(frac_f + 0.5));
    var ibuf: [32]u8 = undefined;
    const is = fmt_u64_commas(&ibuf, ival);
    @memcpy(buf[out_i .. out_i + is.len], is);
    out_i += is.len;
    buf[out_i] = '.';
    out_i += 1;
    const tens: u8 = @intCast((frac / 10) % 10);
    const ones: u8 = @intCast(frac % 10);
    buf[out_i] = '0' + tens;
    out_i += 1;
    buf[out_i] = '0' + ones;
    out_i += 1;
    return buf[0..out_i];
}

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

// --- Stats Structure ---

const Stats = struct {
    ns_list: [16]u64 = .{0} ** 16,
    ops_list: [16]u64 = .{0} ** 16,
    len: usize = 0,
};

fn record(stats: *Stats, ops: u64, ns: u64) void {
    if (stats.len >= 16) return;
    stats.ns_list[stats.len] = ns;
    stats.ops_list[stats.len] = ops;
    stats.len += 1;
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

fn calcMedian(stats: *const Stats) struct { ops_s: f64, ns_per: f64 } {
    if (stats.len == 0) return .{ .ops_s = 0, .ns_per = 0 };

    var ops_rates: [16]f64 = undefined;
    for (0..stats.len) |i| {
        const ns_f = @as(f64, @floatFromInt(stats.ns_list[i]));
        const ops_f = @as(f64, @floatFromInt(stats.ops_list[i]));
        ops_rates[i] = if (ns_f == 0) 0 else (ops_f * 1_000_000_000.0) / ns_f;
    }

    // Simple median (sort and pick middle)
    var sorted = ops_rates[0..stats.len];
    var i: usize = 1;
    while (i < sorted.len) : (i += 1) {
        var j: usize = i;
        while (j > 0 and sorted[j - 1] > sorted[j]) : (j -= 1) {
            const tmp = sorted[j - 1];
            sorted[j - 1] = sorted[j];
            sorted[j] = tmp;
        }
    }

    const mid = sorted.len / 2;
    const median_ops_s = if (sorted.len % 2 == 1)
        sorted[mid]
    else
        (sorted[mid - 1] + sorted[mid]) / 2.0;

    const ns_per = if (median_ops_s == 0) 0 else 1_000_000_000.0 / median_ops_s;

    return .{ .ops_s = median_ops_s, .ns_per = ns_per };
}

fn write_md_truncate(content: []const u8) !void {
    var file = try std.fs.cwd().createFile(MD_PATH, .{ .truncate = true });
    defer file.close();
    try file.writeAll(content);
}

fn write_md_append(content: []const u8) !void {
    var file = std.fs.cwd().createFile(MD_PATH, .{ .truncate = false, .exclusive = false }) catch
        try std.fs.cwd().openFile(MD_PATH, .{ .mode = .read_write });
    defer file.close();
    try file.seekFromEnd(0);
    try file.writeAll(content);
}

fn getAllocator() std.mem.Allocator {
    return std.heap.c_allocator;
}

// =============================================================================
// Benchmark 1: Single-Threaded Deque Push/Pop
// =============================================================================

fn benchDequePushPop(comptime T: type, target_ms: u64, repeats: usize) !Stats {
    const allocator = getAllocator();
    var stats = Stats{};

    // Pilot run to estimate iterations
    var deque_pilot = try deque_mod.WorkStealingDeque(T).init(allocator);
    defer deque_pilot.deinit();

    var t0 = try Timer.start();
    var i: u64 = 0;
    while (i < 100_000) : (i += 1) {
        try deque_pilot.push(@as(T, @intCast(i % 256)));
        if (i % 2 == 0) _ = deque_pilot.pop();
    }
    // Clear remaining
    while (deque_pilot.pop()) |_| {}
    const pilot_ns = t0.read();

    // Calculate target iterations
    const pilot_iters: u64 = 100_000;
    const scale = (@as(u64, target_ms) * 1_000_000) / pilot_ns;
    const run_iters = pilot_iters * @max(1, scale);

    // Measured runs
    var rep: usize = 0;
    while (rep < repeats) : (rep += 1) {
        var deque = try deque_mod.WorkStealingDeque(T).init(allocator);
        defer deque.deinit();

        var timer = try Timer.start();
        i = 0;
        while (i < run_iters) : (i += 1) {
            try deque.push(@as(T, @intCast(i % 256)));
            if (i % 2 == 0) _ = deque.pop();
        }
        // Clear remaining
        while (deque.pop()) |_| {}
        const ns = timer.read();

        record(&stats, run_iters, ns);
    }

    return stats;
}

// =============================================================================
// Benchmark 2: Work-Stealing (1 Owner + N Thieves)
// =============================================================================

const StealContext = struct {
    deque: *deque_mod.WorkStealingDeque(u64),
    iterations: u64,
    stolen: *Atomic(usize),
};

fn stealWorker(ctx: *const StealContext) void {
    var count: usize = 0;
    var attempts: usize = 0;
    const max_attempts = ctx.iterations * 2;

    while (attempts < max_attempts and count < ctx.iterations / 4) : (attempts += 1) {
        if (ctx.deque.steal()) |_| {
            count += 1;
        } else {
            Thread.yield() catch {};
        }
    }

    _ = ctx.stolen.fetchAdd(count, .monotonic);
}

fn benchWorkStealing(num_thieves: usize, target_ms: u64, repeats: usize) !Stats {
    const allocator = getAllocator();
    var stats = Stats{};

    // Pilot run
    var deque_pilot = try deque_mod.WorkStealingDeque(u64).init(allocator);
    defer deque_pilot.deinit();

    var t0 = try Timer.start();
    var i: u64 = 0;
    while (i < 50_000) : (i += 1) {
        try deque_pilot.push(i);
    }
    const pilot_ns = t0.read();

    const pilot_iters: u64 = 50_000;
    const scale = (@as(u64, target_ms) * 1_000_000) / pilot_ns;
    const run_iters = pilot_iters * @max(1, scale);

    // Measured runs
    var rep: usize = 0;
    while (rep < repeats) : (rep += 1) {
        var deque = try deque_mod.WorkStealingDeque(u64).init(allocator);
        defer deque.deinit();

        var stolen = Atomic(usize).init(0);
        var done_flag = Atomic(bool).init(false);

        // Spawn thieves
        const thieves = try allocator.alloc(Thread, num_thieves);
        defer allocator.free(thieves);

        const StealContextWithFlag = struct {
            deque: *deque_mod.WorkStealingDeque(u64),
            iterations: u64,
            stolen: *Atomic(usize),
            done: *Atomic(bool),
        };

        const stealWorkerWithFlag = struct {
            fn run(ctx: *const StealContextWithFlag) void {
                var count: usize = 0;
                var attempts: usize = 0;
                const max_attempts = ctx.iterations * 2;

                while (attempts < max_attempts and count < ctx.iterations / 4) : (attempts += 1) {
                    if (ctx.done.load(.acquire)) break;

                    if (ctx.deque.steal()) |_| {
                        count += 1;
                    } else {
                        Thread.yield() catch {};
                    }
                }

                _ = ctx.stolen.fetchAdd(count, .monotonic);
            }
        }.run;

        for (thieves) |*thief| {
            thief.* = try Thread.spawn(.{}, stealWorkerWithFlag, .{&StealContextWithFlag{
                .deque = &deque,
                .iterations = run_iters,
                .stolen = &stolen,
                .done = &done_flag,
            }});
        }

        // Owner pushes items
        var timer = try Timer.start();
        i = 0;
        while (i < run_iters) : (i += 1) {
            try deque.push(i);
        }

        // Wait for thieves
        for (thieves) |thief| {
            thief.join();
        }

        // Signal done
        done_flag.store(true, .release);

        const ns = timer.read();
        record(&stats, run_iters, ns);

        // Clear remaining
        while (deque.pop()) |_| {}
    }

    return stats;
}

// =============================================================================
// Benchmark 3: Work-Stealing Distributed (Multiple Deques with Cross-Stealing)
// =============================================================================

fn benchWorkStealingDistributed(num_workers: usize, target_ms: u64, repeats: usize) !Stats {
    const allocator = getAllocator();
    var stats = Stats{};

    // Pilot run
    var deque_pilot = try deque_mod.WorkStealingDeque(u64).init(allocator);
    defer deque_pilot.deinit();

    var t0 = try Timer.start();
    var i: u64 = 0;
    while (i < 50_000) : (i += 1) {
        try deque_pilot.push(i);
        if (i % 2 == 0) _ = deque_pilot.pop();
    }
    const pilot_ns = t0.read();

    const pilot_iters: u64 = 50_000;
    const scale = (@as(u64, target_ms) * 1_000_000) / pilot_ns;
    const run_iters = pilot_iters * @max(1, scale);

    // Measured runs
    var rep: usize = 0;
    while (rep < repeats) : (rep += 1) {
        // Create one deque per worker
        const deques = try allocator.alloc(deque_mod.WorkStealingDeque(u64), num_workers);
        defer allocator.free(deques);

        for (deques) |*d| {
            d.* = try deque_mod.WorkStealingDeque(u64).init(allocator);
        }
        defer for (deques) |*d| {
            d.deinit();
        };

        var total_ops = Atomic(u64).init(0);

        // Worker context: each worker has own deque, can steal from others
        const WorkerContext = struct {
            worker_id: usize,
            deques: []deque_mod.WorkStealingDeque(u64),
            iterations: u64,
            total_ops: *Atomic(u64),
        };

        const worker_fn = struct {
            fn run(ctx: *const WorkerContext) void {
                var my_ops: u64 = 0;
                const my_deque = &ctx.deques[ctx.worker_id];
                const iters_per_worker = ctx.iterations / ctx.deques.len;

                // Phase 1: Generate work locally (fast - goes to local deque)
                var j: u64 = 0;
                while (j < iters_per_worker) : (j += 1) {
                    my_deque.push(ctx.worker_id * 1000000 + j) catch break;
                    my_ops += 1;
                }

                // Phase 2: Process own work with occasional stealing from others
                var steal_attempts: usize = 0;
                // Cap max attempts to avoid excessive spinning with many workers
                const max_steal_attempts = @min(iters_per_worker, 100_000);
                while (true) {
                    // Try own deque first
                    if (my_deque.pop()) |_| {
                        my_ops += 1;
                        continue;
                    }

                    // Try stealing from another worker
                    steal_attempts += 1;
                    if (steal_attempts > max_steal_attempts) break;

                    const victim_id = (ctx.worker_id + steal_attempts) % ctx.deques.len;
                    if (victim_id == ctx.worker_id) continue;

                    if (ctx.deques[victim_id].steal()) |_| {
                        my_ops += 1;
                        steal_attempts = 0; // Reset on success
                    } else {
                        Thread.yield() catch {};
                    }
                }

                _ = ctx.total_ops.fetchAdd(my_ops, .monotonic);
            }
        }.run;

        // Spawn workers
        const workers = try allocator.alloc(Thread, num_workers);
        defer allocator.free(workers);

        // Create worker contexts (must persist for thread lifetime!)
        const contexts = try allocator.alloc(WorkerContext, num_workers);
        defer allocator.free(contexts);

        var timer = try Timer.start();

        for (workers, 0..) |*w, worker_id| {
            contexts[worker_id] = WorkerContext{
                .worker_id = worker_id,
                .deques = deques,
                .iterations = run_iters,
                .total_ops = &total_ops,
            };
            w.* = try Thread.spawn(.{}, worker_fn, .{&contexts[worker_id]});
        }

        for (workers) |w| {
            w.join();
        }

        const ns = timer.read();
        const ops = total_ops.load(.monotonic);
        record(&stats, ops, ns);
    }

    return stats;
}

// =============================================================================
// Benchmark 4: Thread Pool Submit/Execute (External Injection - Shows Bottleneck)
// =============================================================================

fn benchPoolSubmit(comptime num_shards: usize, num_tasks: u64, repeats: usize) !Stats {
    const allocator = getAllocator();
    var stats = Stats{};

    var rep: usize = 0;
    while (rep < repeats) : (rep += 1) {
        const Pool = pool_mod.WorkStealingPool(num_shards);
        const pool = try Pool.init(allocator, .{});
        defer pool.deinit();

        var counter = Atomic(usize).init(0);

        const worker_fn = struct {
            fn run(c: *Atomic(usize)) void {
                _ = c.fetchAdd(1, .monotonic);
            }
        }.run;

        var timer = try Timer.start();

        var i: u64 = 0;
        while (i < num_tasks) : (i += 1) {
            const task = try Task.init(allocator, worker_fn, .{&counter});
            // Retry on QueueFull with spinloop (bounded injector capacity)
            while (true) {
                pool.submit(task) catch |err| {
                    if (err == error.QueueFull) {
                        // Spinloop instead of yield - don't give up CPU
                        std.atomic.spinLoopHint();
                        continue;
                    }
                    return err;
                };
                break;
            }
        }

        pool.waitIdle();
        const ns = timer.read();

        record(&stats, num_tasks, ns);
    }

    return stats;
}

// =============================================================================
// Benchmark 5: Thread Pool Multi-Producer Submit (Multiple External Threads)
// =============================================================================

fn benchPoolMultiProducerSubmit(comptime num_producers: usize, comptime num_shards: usize, num_tasks: u64, repeats: usize) !Stats {
    const allocator = getAllocator();
    var stats = Stats{};

    var rep: usize = 0;
    while (rep < repeats) : (rep += 1) {
        const Pool = pool_mod.WorkStealingPool(num_shards);
        const pool = try Pool.init(allocator, .{});
        defer pool.deinit();

        var counter = Atomic(usize).init(0);

        const worker_fn = struct {
            fn run(c: *Atomic(usize)) void {
                _ = c.fetchAdd(1, .monotonic);
            }
        }.run;

        // Context for each producer thread
        const ProducerContext = struct {
            pool_ptr: *Pool,
            tasks_per_producer: u64,
            counter: *Atomic(usize),
            allocator_ref: std.mem.Allocator,
        };

        const producer_fn = struct {
            fn run(ctx: *const ProducerContext) void {
                var i: u64 = 0;
                while (i < ctx.tasks_per_producer) : (i += 1) {
                    const task = Task.init(ctx.allocator_ref, worker_fn, .{ctx.counter}) catch return;
                    // Retry on QueueFull with spinloop (bounded injector capacity)
                    while (true) {
                        ctx.pool_ptr.submit(task) catch |err| {
                            if (err == error.QueueFull) {
                                // Spinloop instead of yield - don't give up CPU
                                std.atomic.spinLoopHint();
                                continue;
                            }
                            return;
                        };
                        break;
                    }
                }
            }
        }.run;

        // Create producer threads
        const producers = try allocator.alloc(Thread, num_producers);
        defer allocator.free(producers);

        const contexts = try allocator.alloc(ProducerContext, num_producers);
        defer allocator.free(contexts);

        const tasks_per_producer = num_tasks / num_producers;

        var timer = try Timer.start();

        // Spawn all producers
        for (producers, 0..) |*p, i| {
            contexts[i] = ProducerContext{
                .pool_ptr = pool,
                .tasks_per_producer = tasks_per_producer,
                .counter = &counter,
                .allocator_ref = allocator,
            };
            p.* = try Thread.spawn(.{}, producer_fn, .{&contexts[i]});
        }

        // Wait for all producers to finish
        for (producers) |p| {
            p.join();
        }

        pool.waitIdle();
        const ns = timer.read();

        record(&stats, num_tasks, ns);
    }

    return stats;
}

// =============================================================================
// Report Generation
// =============================================================================

fn run_deque_single_threaded_table() !void {
    const allocator = getAllocator();
    var buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);

    try write_md_append("\n# WorkStealingDeque Benchmarks\n\n");
    try write_md_append("## Single-Threaded Push/Pop Performance\n\n");
    try write_md_append("| Item Type | Operations/sec | ns/op | Notes |\n");
    try write_md_append("|-----------|----------------|-------|-------|\n");

    std.debug.print("\n=== Single-Threaded Deque Push/Pop ===\n", .{});

    // Benchmark u64
    {
        const stats = try benchDequePushPop(u64, 300, 3);
        const result = calcMedian(&stats);

        var buf1: [48]u8 = undefined;
        var buf2: [48]u8 = undefined;
        var scaled: f64 = 0;
        const unit = scale_rate_f64(&scaled, result.ops_s);
        const s_ops = fmt_f64_commas2(&buf1, scaled);
        const s_ns = fmt_f64_commas2(&buf2, result.ns_per);

        std.debug.print("  u64: {s} {s}  ({s} ns/op)\n", .{ s_ops, unit, s_ns });

        const line = try std.fmt.allocPrint(fba.allocator(), "| u64 | {s} {s} | {s} | Mixed push/pop |\n", .{ s_ops, unit, s_ns });
        try write_md_append(line);
        fba.reset();
    }

    // Benchmark usize
    {
        const stats = try benchDequePushPop(usize, 300, 3);
        const result = calcMedian(&stats);

        var buf1: [48]u8 = undefined;
        var buf2: [48]u8 = undefined;
        var scaled: f64 = 0;
        const unit = scale_rate_f64(&scaled, result.ops_s);
        const s_ops = fmt_f64_commas2(&buf1, scaled);
        const s_ns = fmt_f64_commas2(&buf2, result.ns_per);

        std.debug.print("  usize: {s} {s}  ({s} ns/op)\n", .{ s_ops, unit, s_ns });

        const line = try std.fmt.allocPrint(fba.allocator(), "| usize | {s} {s} | {s} | Mixed push/pop |\n", .{ s_ops, unit, s_ns });
        try write_md_append(line);
        fba.reset();
    }

    _ = allocator;
}

fn run_work_stealing_table() !void {
    const allocator = getAllocator();
    var buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);

    try write_md_append("\n## Work-Stealing Performance (1 Owner + N Thieves)\n\n");
    try write_md_append("| Thieves | Operations/sec | ns/op | Notes |\n");
    try write_md_append("|---------|----------------|-------|-------|\n");

    std.debug.print("\n=== Work-Stealing (1 Owner + N Thieves) ===\n", .{});

    const thief_counts = [_]usize{2}; // Reduced for debugging

    for (thief_counts) |num_thieves| {
        const stats = try benchWorkStealing(num_thieves, 100, 1); // Reduced for debugging
        const result = calcMedian(&stats);

        var buf1: [48]u8 = undefined;
        var buf2: [48]u8 = undefined;
        var scaled: f64 = 0;
        const unit = scale_rate_f64(&scaled, result.ops_s);
        const s_ops = fmt_f64_commas2(&buf1, scaled);
        const s_ns = fmt_f64_commas2(&buf2, result.ns_per);

        std.debug.print("  {} thieves: {s} {s}  ({s} ns/op)\n", .{ num_thieves, s_ops, unit, s_ns });

        const line = try std.fmt.allocPrint(fba.allocator(), "| {} | {s} {s} | {s} | Owner push, thieves steal |\n", .{ num_thieves, s_ops, unit, s_ns });
        try write_md_append(line);
        fba.reset();
    }

    _ = allocator;
}

fn run_distributed_work_stealing_table() !void {
    const allocator = getAllocator();
    var buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);

    try write_md_append("\n## Distributed Work-Stealing Performance (Multiple Deques)\n\n");
    try write_md_append("| Workers | Operations/sec | ns/op | Notes |\n");
    try write_md_append("|---------|----------------|-------|-------|\n");

    std.debug.print("\n=== Distributed Work-Stealing (Multiple Deques) ===\n", .{});

    const worker_counts = [_]usize{ 2, 4, 8 };

    for (worker_counts) |num_workers| {
        const stats = try benchWorkStealingDistributed(num_workers, 300, 3);
        const result = calcMedian(&stats);

        var buf1: [48]u8 = undefined;
        var buf2: [48]u8 = undefined;
        var scaled: f64 = 0;
        const unit = scale_rate_f64(&scaled, result.ops_s);
        const s_ops = fmt_f64_commas2(&buf1, scaled);
        const s_ns = fmt_f64_commas2(&buf2, result.ns_per);

        std.debug.print("  {} workers: {s} {s}  ({s} ns/op)\n", .{ num_workers, s_ops, unit, s_ns });

        const line = try std.fmt.allocPrint(fba.allocator(), "| {} | {s} {s} | {s} | Workers generate local work + cross-steal |\n", .{ num_workers, s_ops, unit, s_ns });
        try write_md_append(line);
        fba.reset();
    }

    _ = allocator;
}

fn run_pool_submit_table() !void {
    const allocator = getAllocator();
    var buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);

    try write_md_append("\n## Thread Pool Submit/Execute Performance (External Injection)\n\n");
    try write_md_append("| Workers | Tasks | Operations/sec | ns/task | Notes |\n");
    try write_md_append("|---------|-------|----------------|---------|-------|\n");

    std.debug.print("\n=== Thread Pool Submit/Execute (External Injection) ===\n", .{});

    const task_counts = [_]u64{ 10_000, 50_000, 100_000 };

    // Run benchmarks for 8 shards (16 workers)
    inline for (task_counts) |num_tasks| {
        const stats = try benchPoolSubmit(8, num_tasks, 2);
        const result = calcMedian(&stats);

        var buf1: [48]u8 = undefined;
        var buf2: [48]u8 = undefined;
        var buf3: [32]u8 = undefined;
        var scaled: f64 = 0;
        const unit = scale_rate_f64(&scaled, result.ops_s);
        const s_ops = fmt_f64_commas2(&buf1, scaled);
        const s_ns = fmt_f64_commas2(&buf2, result.ns_per);
        const s_tasks = fmt_u64_commas(&buf3, num_tasks);

        std.debug.print("  8 workers (8 shards), {s} tasks: {s} {s}  ({s} ns/task)\n", .{ s_tasks, s_ops, unit, s_ns });

        const line = try std.fmt.allocPrint(fba.allocator(), "| 8 | {s} | {s} {s} | {s} | All via Injector (8 shards) |\n", .{ s_tasks, s_ops, unit, s_ns });
        try write_md_append(line);
        fba.reset();
    }

    // Run benchmarks for 16 shards (32 workers)
    inline for (task_counts) |num_tasks| {
        const stats = try benchPoolSubmit(16, num_tasks, 2);
        const result = calcMedian(&stats);

        var buf1: [48]u8 = undefined;
        var buf2: [48]u8 = undefined;
        var buf3: [32]u8 = undefined;
        var scaled: f64 = 0;
        const unit = scale_rate_f64(&scaled, result.ops_s);
        const s_ops = fmt_f64_commas2(&buf1, scaled);
        const s_ns = fmt_f64_commas2(&buf2, result.ns_per);
        const s_tasks = fmt_u64_commas(&buf3, num_tasks);

        std.debug.print("  16 workers (16 shards), {s} tasks: {s} {s}  ({s} ns/task)\n", .{ s_tasks, s_ops, unit, s_ns });

        const line = try std.fmt.allocPrint(fba.allocator(), "| 16 | {s} | {s} {s} | {s} | All via Injector (16 shards) |\n", .{ s_tasks, s_ops, unit, s_ns });
        try write_md_append(line);
        fba.reset();
    }

    _ = allocator;
}

fn run_pool_multi_producer_submit_table() !void {
    const allocator = getAllocator();
    var buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);

    try write_md_append("\n## Thread Pool Multi-Producer Submit/Execute Performance\n\n");
    try write_md_append("| Producers | Workers | Tasks | Operations/sec | ns/task | Notes |\n");
    try write_md_append("|-----------|---------|-------|----------------|---------|-------|\n");

    std.debug.print("\n=== Thread Pool Multi-Producer Submit/Execute ===\n", .{});

    const producer_counts = [_]usize{ 2, 4, 8 };
    const task_counts = [_]u64{ 10_000, 50_000, 100_000 };

    // Helper to run benchmarks for a given producer/worker combination
    const runBench = struct {
        fn run(comptime num_prod: usize, comptime num_work: usize, fba_ref: *std.heap.FixedBufferAllocator) !void {
            inline for (task_counts) |num_tasks| {
                const stats = try benchPoolMultiProducerSubmit(num_prod, num_work, num_tasks, 2);
                const result = calcMedian(&stats);

                var buf1: [48]u8 = undefined;
                var buf2: [48]u8 = undefined;
                var buf3: [32]u8 = undefined;
                var scaled: f64 = 0;
                const unit = scale_rate_f64(&scaled, result.ops_s);
                const s_ops = fmt_f64_commas2(&buf1, scaled);
                const s_ns = fmt_f64_commas2(&buf2, result.ns_per);
                const s_tasks = fmt_u64_commas(&buf3, num_tasks);

                std.debug.print("  {} producers, {} workers, {s} tasks: {s} {s}  ({s} ns/task)\n", .{ num_prod, num_work, s_tasks, s_ops, unit, s_ns });

                const line = try std.fmt.allocPrint(fba_ref.allocator(), "| {} | {} | {s} | {s} {s} | {s} | {} producers competing |\n", .{ num_prod, num_work, s_tasks, s_ops, unit, s_ns, num_prod });
                try write_md_append(line);
                fba_ref.reset();
            }
        }
    }.run;

    // Run all combinations
    inline for (producer_counts) |num_producers| {
        try runBench(num_producers, 8, &fba); // 8 shards → 16 workers (2:1 ratio)
        try runBench(num_producers, 16, &fba); // 16 shards → 32 workers (2:1 ratio)
    }

    _ = allocator;
}

// =============================================================================
// Main
// =============================================================================

pub fn main() !void {
    std.debug.print("\n" ++ "=" ** 60 ++ "\n", .{});
    std.debug.print("  Work-Stealing Deque & Thread Pool Benchmarks\n", .{});
    std.debug.print("=" ** 60 ++ "\n", .{});

    // Initialize markdown file
    try write_md_truncate("# Work-Stealing Deque & Thread Pool - Benchmark Results\n\n");
    try write_md_append("Platform: ARM64 (Apple Silicon)\n");
    try write_md_append("Build: ReleaseFast\n");
    try write_md_append("\n");

    // Run benchmarks
    try run_deque_single_threaded_table();

    // Multi-threaded benchmarks - now fixed with atomic pointer approach
    try run_work_stealing_table();

    // NEW: Distributed work-stealing (realistic scenario)
    try run_distributed_work_stealing_table();

    // Thread pool with external injection (shows bottleneck)
    // TODO: Fix waitIdle() hang issue before re-enabling
    // try run_pool_submit_table();

    // NEW: Thread pool with multi-producer external injection
    // TODO: Fix waitIdle() hang issue before re-enabling
    // try run_pool_multi_producer_submit_table();

    std.debug.print("\n" ++ "=" ** 60 ++ "\n", .{});
    std.debug.print("  Benchmarks Complete!\n", .{});
    std.debug.print("  Results: {s}\n", .{MD_PATH});
    std.debug.print("=" ** 60 ++ "\n\n", .{});
}
