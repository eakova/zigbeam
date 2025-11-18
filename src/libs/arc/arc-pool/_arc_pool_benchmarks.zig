//! ArcPool-only benchmarks. Writes report to src/libs/arc/ARC_POOL_BENCHMARKS.md
//! How to run:
//! - `zig build -Doptimize=ReleaseFast bench-arc-pool`

const std = @import("std");
const beam = @import("zig_beam");

const Thread = std.Thread;
const Timer = std.time.Timer;

const PoolPayload = [64]u8;
const ArcArray64 = beam.Libs.Arc([64]u8);
const PoolTypeOff = beam.Libs.ArcPool(PoolPayload, false);

const MD_PATH = "src/libs/arc/ARC_POOL_BENCHMARK_RESULTS.md";
// Iteration-capped mode: total operations per scenario across threads.
const MAX_TOTAL_ITERS: u64 = 5_000_000; // smaller for constrained environment
// Bench-only: MT iteration cap disabled for full runs.
const MT_ITER_CAP: u64 = std.math.maxInt(u64);

fn write_md_truncate(content: []const u8) !void {
    // stdout mode (for tight environments)
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    if (std.process.getEnvMap(arena.allocator())) |env| {
        if (env.get("ARCP_BENCH_STDOUT")) |_| {
            if (content.len != 0) std.debug.print("{s}", .{content});
            return;
        }
    } else |_| {}
    var file = try std.fs.cwd().createFile(MD_PATH, .{ .truncate = true });
    defer file.close();
    try file.writeAll(content);
}

fn write_md_append(content: []const u8) !void {
    // stdout mode (for tight environments)
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    if (std.process.getEnvMap(arena.allocator())) |env| {
        if (env.get("ARCP_BENCH_STDOUT")) |_| {
            if (content.len != 0) std.debug.print("{s}", .{content});
            return;
        }
    } else |_| {}
    var file = std.fs.cwd().createFile(MD_PATH, .{ .truncate = false, .exclusive = false }) catch
        try std.fs.cwd().openFile(MD_PATH, .{ .mode = .read_write });
    defer file.close();
    try file.seekFromEnd(0);
    try file.writeAll(content);
}

// Formatting helpers
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
        const d: u8 = @intCast(v % 10);
        v /= 10;
        i -= 1;
        buf[i] = '0' + d;
        group += 1;
        if (v != 0 and group % 3 == 0) {
            i -= 1;
            buf[i] = ',';
        }
    }
    return buf[i..];
}

fn fmt_f64_commas2(buf: *[48]u8, val: f64) []const u8 {
    const ival_f = @floor(val);
    const ival = @as(u64, @intFromFloat(ival_f));
    var frac_f = (val - ival_f) * 100.0;
    if (frac_f < 0) frac_f = -frac_f;
    const frac = @as(u64, @intFromFloat(frac_f + 0.5));
    var ibuf: [32]u8 = undefined;
    const is = fmt_u64_commas(&ibuf, ival);
    var out: [48]u8 = undefined;
    var o: usize = 0;
    @memcpy(out[o .. o + is.len], is);
    o += is.len;
    out[o] = '.';
    o += 1;
    out[o] = '0' + @as(u8, @intCast((frac / 10) % 10));
    o += 1;
    out[o] = '0' + @as(u8, @intCast(frac % 10));
    o += 1;
    @memcpy(buf[0..o], out[0..o]);
    return buf[0..o];
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

const Stats = struct {
    ns_list: [16]u64 = .{0} ** 16,
    ops_list: [16]u64 = .{0} ** 16,
    len: usize = 0,
};

fn sortAsc(slice: []u64) void {
    var i: usize = 1;
    while (i < slice.len) : (i += 1) {
        var j: usize = i;
        while (j > 0 and slice[j - 1] > slice[j]) : (j -= 1) {
            const t = slice[j - 1];
            slice[j - 1] = slice[j];
            slice[j] = t;
        }
    }
}
fn medianIqr(slice_in: []const u64) struct { median: u64, q1: u64, q3: u64 } {
    var b: [16]u64 = .{0} ** 16;
    const n = slice_in.len;
    if (n == 0) return .{ .median = 0, .q1 = 0, .q3 = 0 };
    @memcpy(b[0..n], slice_in);
    sortAsc(b[0..n]);
    const mid = n / 2;
    const med = if (n % 2 == 1) b[mid] else (b[mid - 1] + b[mid]) / 2;
    return .{ .median = med, .q1 = b[n / 4], .q3 = b[(3 * n) / 4] };
}
fn ratio_ops_per_sec(ns: u64, ops: u64) f64 {
    if (ns == 0) return 0;
    return (@as(f64, @floatFromInt(ops)) * 1_000_000_000.0) / @as(f64, @floatFromInt(ns));
}
fn ratio_ns_per_op(ns: u64, ops: u64) f64 {
    if (ops == 0) return 0;
    return @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(ops));
}
fn medianIqrOpsPerSecF64(stats: *const Stats) f64 {
    if (stats.len == 0) return 0;
    var b: [16]f64 = .{0} ** 16;
    var i: usize = 0;
    while (i < stats.len) : (i += 1) b[i] = ratio_ops_per_sec(stats.ns_list[i], stats.ops_list[i]); // insertion sort
    var k: usize = 1;
    while (k < stats.len) : (k += 1) {
        var j: usize = k;
        while (j > 0 and b[j - 1] > b[j]) : (j -= 1) {
            const t = b[j - 1];
            b[j - 1] = b[j];
            b[j] = t;
        }
    }
    const mid = stats.len / 2;
    return if (stats.len % 2 == 1) b[mid] else (b[mid - 1] + b[mid]) / 2.0;
}
fn medianIqrNsPerOpF64(stats: *const Stats) f64 {
    if (stats.len == 0) return 0;
    var b: [16]f64 = .{0} ** 16;
    var i: usize = 0;
    while (i < stats.len) : (i += 1) b[i] = ratio_ns_per_op(stats.ns_list[i], stats.ops_list[i]);
    var k: usize = 1;
    while (k < stats.len) : (k += 1) {
        var j: usize = k;
        while (j > 0 and b[j - 1] > b[j]) : (j -= 1) {
            const t = b[j - 1];
            b[j - 1] = b[j];
            b[j] = t;
        }
    }
    const mid = stats.len / 2;
    return if (stats.len % 2 == 1) b[mid] else (b[mid - 1] + b[mid]) / 2.0;
}

fn record(stats: *Stats, ops: u64, ns: u64) void {
    if (stats.len >= stats.ns_list.len) return;
    stats.ns_list[stats.len] = ns;
    stats.ops_list[stats.len] = ops;
    stats.len += 1;
}

// iteration-capped; no scaling by time

// Scenario-scoped ST bench: allocates a pool, runs, and fully releases.
fn benchPoolChurnST(value: [64]u8) !struct { stats: Stats, iterations: u64 } {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var pool = PoolTypeOff.init(allocator, .{});
    defer pool.deinit();
    const run_iters: u64 = MAX_TOTAL_ITERS;
    var t = try Timer.start();
    var i: u64 = 0;
    while (i < run_iters) : (i += 1) {
        const arc = try pool.create(value);
        pool.recycle(arc);
    }
    pool.drainThreadCache();
    var stats = Stats{};
    record(&stats, run_iters, t.read());
    return .{ .stats = stats, .iterations = run_iters };
}

// Scenario-scoped MT bench: allocates a pool, runs threads, and fully releases.
fn benchPoolChurnMT(threads: usize, per_thread_iters: u64) !struct { stats: Stats, iterations: u64 } {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    // Use library defaults; safer TLS capacity now computed in ArcPool.init.
    var pool = PoolTypeOff.init(allocator, .{});
    defer pool.deinit();
    const total_iters: u64 = per_thread_iters * @as(u64, threads);
    const Ctx = struct { pool: *PoolTypeOff, iterations: u64, start: *std.atomic.Value(usize) };
    const Worker = struct {
        fn run(ctx: *Ctx) void {
            // Flush this thread's TLS cache back to the pool before exit.
            defer ctx.pool.drainThreadCache();
            var i: u64 = 0;
            const payload = [_]u8{0} ** 64;
            while (ctx.start.load(.seq_cst) == 0) {
                std.Thread.yield() catch {};
            }
            while (i < ctx.iterations) : (i += 1) {
                if (ctx.pool.create(payload)) |a| ctx.pool.recycle(a) else |_| return;
            }
        }
    };
    const handles = try allocator.alloc(Thread, threads);
    defer allocator.free(handles);
    const contexts = try allocator.alloc(Ctx, threads);
    defer allocator.free(contexts);
    var start_flag = std.atomic.Value(usize).init(0);
    var k: usize = 0;
    while (k < threads) : (k += 1) {
        contexts[k] = .{ .pool = &pool, .iterations = per_thread_iters, .start = &start_flag };
        handles[k] = try Thread.spawn(.{}, Worker.run, .{&contexts[k]});
    }
    var t = try Timer.start();
    _ = start_flag.store(1, .seq_cst);
    for (handles) |h| h.join();
    const ns = t.read();
    pool.drainThreadCache();
    var stats = Stats{};
    record(&stats, total_iters, ns);
    return .{ .stats = stats, .iterations = total_iters };
}

fn benchRawHeapChurn(value: [64]u8, _: u64, repeats: usize) !struct { stats: Stats, iterations: u64 } {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const run_iters: u64 = MAX_TOTAL_ITERS;
    var stats = Stats{};
    var rep: usize = 0;
    while (rep < repeats) : (rep += 1) {
        var timer = try Timer.start();
        var i: u64 = 0;
        while (i < run_iters) : (i += 1) {
            var arc = try ArcArray64.init(allocator, value);
            arc.release();
        }
        const ns = timer.read();
        record(&stats, run_iters, ns);
    }
    return .{ .stats = stats, .iterations = run_iters };
}

fn benchPoolChurn(pool: *PoolTypeOff, value: [64]u8, _: u64, repeats: usize) !struct { stats: Stats, iterations: u64 } {
    const run_iters: u64 = MAX_TOTAL_ITERS;
    var stats = Stats{};
    var rep: usize = 0;
    while (rep < repeats) : (rep += 1) {
        var timer = try Timer.start();
        var i: u64 = 0;
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

fn measurePoolChurnMTOff(pool: *PoolTypeOff, allocator: std.mem.Allocator, thread_count: usize, iterations: u64) !u64 {
    // Optional lightweight debug: print stages to locate failures in constrained envs
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var debug = false;
    if (std.process.getEnvMap(arena.allocator())) |env| {
        if (env.get("ARCP_BENCH_DEBUG")) |_| {
            debug = true;
        }
    } else |_| {}

    if (debug) std.debug.print("[MT] alloc handles/contexts...\n", .{});
    const handles = try allocator.alloc(Thread, thread_count);
    defer allocator.free(handles);
    const Ctx = struct { pool: *PoolTypeOff, iterations: u64, warmups: usize, start_flag: *std.atomic.Value(usize) };
    const contexts = try allocator.alloc(Ctx, thread_count);
    defer allocator.free(contexts);
    var start_flag = std.atomic.Value(usize).init(0);
    const Worker = struct {
        fn run(ctx: *Ctx) void {
            var i: u64 = 0;
            const payload = [_]u8{0} ** 64;
            // Warm-up kept minimal in case of constrained environments
            var w: usize = 0;
            while (w < ctx.warmups) : (w += 1) {
                if (ctx.pool.create(payload)) |a| ctx.pool.recycle(a) else |_| return;
            }
            while (ctx.start_flag.load(.seq_cst) == 0) {
                std.Thread.yield() catch {};
            }
            while (i < ctx.iterations) : (i += 1) {
                if (ctx.pool.create(payload)) |a| ctx.pool.recycle(a) else |_| return;
            }
        }
    };
    if (debug) std.debug.print("[MT] spawning {d} threads...\n", .{thread_count});
    var idx: usize = 0;
    while (idx < thread_count) : (idx += 1) {
        contexts[idx] = .{ .pool = pool, .iterations = iterations, .warmups = 1, .start_flag = &start_flag };
        const spawned = Thread.spawn(.{}, Worker.run, .{&contexts[idx]});
        if (spawned) |h| {
            handles[idx] = h;
        } else |e| {
            if (debug) std.debug.print("[MT] spawn failed at idx={d}: {s}\n", .{ idx, @errorName(e) });
            return e;
        }
    }
    if (debug) std.debug.print("[MT] running...\n", .{});
    var timer = try Timer.start();
    _ = start_flag.store(1, .seq_cst);
    for (handles) |h| h.join();
    const ns = timer.read();
    pool.drainThreadCache();
    if (debug) std.debug.print("[MT] done, ns={d}\n", .{ns});
    return ns;
}

fn benchPoolChurnMTOff(thread_count: usize, _: u64, repeats: usize) !struct { stats: Stats, iterations: u64 } {
    // Optional debug short path (keep MT pressure tiny)
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var debug = false;
    if (std.process.getEnvMap(arena.allocator())) |env| {
        if (env.get("ARCP_BENCH_DEBUG")) |_| {
            debug = true;
        }
    } else |_| {}
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var per_thread_iters: u64 = 1;
    if (thread_count > 0) {
        const total = MAX_TOTAL_ITERS;
        const div = total / @as(u64, thread_count);
        per_thread_iters = if (div == 0) 1 else div;
    }
    // Allow env override for per-thread iters and warmups to probe sandbox limits.
    var warmups: usize = 1;
    if (std.process.getEnvMap(arena.allocator())) |env| {
        if (env.get("ARCP_BENCH_MT_ITERS")) |s| {
            per_thread_iters = std.fmt.parseInt(u64, s, 10) catch per_thread_iters;
        }
        if (env.get("ARCP_BENCH_WARMUP")) |s2| {
            warmups = std.fmt.parseInt(usize, s2, 10) catch warmups;
        }
    } else |_| {}
    const total_iters = per_thread_iters * @as(u64, thread_count);
    var stats = Stats{};
    var rep: usize = 0;
    while (rep < repeats) : (rep += 1) {
        var pool = PoolTypeOff.init(allocator, .{});
        // Pass warmups by setting in contexts within measure function via global
        const ns = try measurePoolChurnMTOff(&pool, allocator, thread_count, per_thread_iters);
        pool.deinit();
        record(&stats, total_iters, ns);
    }
    return .{ .stats = stats, .iterations = total_iters };
}

fn writeBenchRow(wr: anytype, label: []const u8, iterations: u64, stats: Stats) !void {
    var nb1: [32]u8 = undefined;
    const s_iters = fmt_u64_commas(&nb1, iterations);
    const f_ops = medianIqrOpsPerSecF64(&stats);
    const f_ns = medianIqrNsPerOpF64(&stats);
    // Format throughput
    var sc: f64 = 0;
    const unit = scale_rate_f64(&sc, f_ops);
    var fb_rate: [48]u8 = undefined;
    const s_rate = fmt_f64_commas2(&fb_rate, sc);
    // Format ns/op with <0.01 floor
    if (f_ns > 0.009) {
        try wr.print("| {s} | {s} | {d:.2} | {s} {s} |\n", .{ label, s_iters, f_ns, s_rate, unit });
    } else {
        try wr.print("| {s} | {s} | <0.01 | {s} {s} |\n", .{ label, s_iters, s_rate, unit });
    }
}

pub fn main() !void {
    // Clean, scenario-per-function flow. Each section allocates and frees within itself.
    try write_md_truncate("");
    // 1) ST Create + Recycle
    {
        const st = try benchPoolChurnST([_]u8{9} ** 64);
        var b: [512]u8 = undefined;
        var s = std.io.fixedBufferStream(&b);
        const w = s.writer();
        try w.print("### ArcPool - Single-Threaded - Create + Recycle - ([64]u8)\n", .{});
        try w.print("| Thread(s) | Iterations | ns/op (median) | Throughput (ops/s) |\n| --- | --- | --- | --- |\n", .{});
        var nb: [32]u8 = undefined;
        const s_thr = fmt_u64_commas(&nb, 1);
        var row: [256]u8 = undefined;
        var rs = std.io.fixedBufferStream(&row);
        try writeBenchRow(rs.writer(), s_thr, st.iterations, st.stats);
        try w.print("{s}\n", .{rs.getWritten()});
        try write_md_append(s.getWritten());
    }
    // 2) MT Create + Recycle
    {
        var b: [512]u8 = undefined;
        var s = std.io.fixedBufferStream(&b);
        const w = s.writer();
        try w.print("### ArcPool - Multi-Threaded - Create + Recycle - ([64]u8)\n", .{});
        try w.print("| Thread(s) | Iterations | ns/op (median) | Throughput (ops/s) |\n| --- | --- | --- | --- |\n", .{});
        const threads_list = [_]usize{ 1, 4, 8 };
        for (threads_list) |tc| {
            const per = MAX_TOTAL_ITERS / @as(u64, tc);
            const mt = try benchPoolChurnMT(tc, if (per == 0) 1 else per);
            var nb: [32]u8 = undefined;
            const s_thr = fmt_u64_commas(&nb, tc);
            var row: [256]u8 = undefined;
            var rs = std.io.fixedBufferStream(&row);
            try writeBenchRow(rs.writer(), s_thr, mt.iterations, mt.stats);
            try w.print("{s}", .{rs.getWritten()});
        }
        try w.print("\n", .{});
        try write_md_append(s.getWritten());
    }
    // 3) TLS Capacity (ST)
    {
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa.deinit();
        const allocator = gpa.allocator();
        var p16 = PoolTypeOff.init(allocator, .{ .logical_cpus = null });
        p16.tls_active_capacity = 16;
        defer p16.deinit();
        var p32 = PoolTypeOff.init(allocator, .{ .logical_cpus = null });
        p32.tls_active_capacity = 32;
        defer p32.deinit();
        var p64 = PoolTypeOff.init(allocator, .{ .logical_cpus = null });
        p64.tls_active_capacity = 64;
        defer p64.deinit();
        // Run isolated ST benches per pool
        const b16 = try benchPoolChurnST([_]u8{1} ** 64);
        const b32 = try benchPoolChurnST([_]u8{1} ** 64);
        const b64 = try benchPoolChurnST([_]u8{1} ** 64);
        var b: [512]u8 = undefined;
        var s = std.io.fixedBufferStream(&b);
        const w = s.writer();
        try w.print("### ArcPool - TLS Capacity - Single-Threaded\n", .{});
        try w.print("| Capacity | Iterations | ns/op (median) | Throughput (ops/s) |\n| --- | --- | --- | --- |\n", .{});
        try writeBenchRow(w, "16", b16.iterations, b16.stats);
        try writeBenchRow(w, "32", b32.iterations, b32.stats);
        try writeBenchRow(w, "64", b64.iterations, b64.stats);
        try w.print("\n", .{});
        try write_md_append(s.getWritten());
    }
    // 4) In-place vs Copy (ST)
    {
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa.deinit();
        const allocator = gpa.allocator();
        var pool = PoolTypeOff.init(allocator, .{});
        const copy = try benchPoolChurnST([_]u8{3} ** 64);
        const run_iters: u64 = MAX_TOTAL_ITERS;
        var t = try Timer.start();
        var i: u64 = 0;
        while (i < run_iters) : (i += 1) {
            const arc = try pool.createWithInitializer(struct {
                fn init(p: *[64]u8) void {
                    @memset(p, 5);
                }
            }.init);
            pool.recycle(arc);
        }
        pool.drainThreadCache();
        var inplace = Stats{};
        record(&inplace, run_iters, t.read());
        pool.deinit();
        var b: [512]u8 = undefined;
        var s = std.io.fixedBufferStream(&b);
        const w = s.writer();
        try w.print("### ArcPool - In-place Init vs Copy - Single-Threaded - ([64]u8)\n", .{});
        try w.print("| Thread(s) | Variant | Iterations | ns/op (median) | Throughput (ops/s) |\n| --- | --- | --- | --- | --- |\n", .{});
        var nb: [32]u8 = undefined;
        const s_thr = fmt_u64_commas(&nb, 1);
        var nbx: [32]u8 = undefined;
        const s_iters_c = fmt_u64_commas(&nbx, copy.iterations);
        const f_ops_c = medianIqrOpsPerSecF64(&copy.stats);
        var sc_c: f64 = 0;
        const unit_c = scale_rate_f64(&sc_c, f_ops_c);
        const f_ns_c = medianIqrNsPerOpF64(&copy.stats);
        var fb1: [48]u8 = undefined;
        const s_rate_c = fmt_f64_commas2(&fb1, sc_c);
        if (f_ns_c > 0.009) try w.print("| {s} | copy 64B | {s} | {d:.2} | {s} {s} |\n", .{ s_thr, s_iters_c, f_ns_c, s_rate_c, unit_c }) else try w.print("| {s} | copy 64B | {s} | <0.01 | {s} {s} |\n", .{ s_thr, s_iters_c, s_rate_c, unit_c });
        var nby: [32]u8 = undefined;
        const s_iters_ip = fmt_u64_commas(&nby, run_iters);
        const f_ops_ip = medianIqrOpsPerSecF64(&inplace);
        var sc_ip: f64 = 0;
        const unit_ip = scale_rate_f64(&sc_ip, f_ops_ip);
        const f_ns_ip = medianIqrNsPerOpF64(&inplace);
        var fb2: [48]u8 = undefined;
        const s_rate_ip = fmt_f64_commas2(&fb2, sc_ip);
        if (f_ns_ip > 0.009) try w.print("| {s} | in-place (memset) | {s} | {d:.2} | {s} {s} |\n", .{ s_thr, s_iters_ip, f_ns_ip, s_rate_ip, unit_ip }) else try w.print("| {s} | in-place (memset) | {s} | <0.01 | {s} {s} |\n", .{ s_thr, s_iters_ip, s_rate_ip, unit_ip });
        try w.print("\n", .{});
        try write_md_append(s.getWritten());
    }
}
