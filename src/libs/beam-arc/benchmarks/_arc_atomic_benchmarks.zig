//! Arc atomic operations benchmarks
//!
//! Measures performance of atomicLoad, atomicStore, atomicSwap, and atomicCompareSwap
//! in both single-threaded and multi-threaded scenarios.

const std = @import("std");
const Arc = @import("arc.zig").Arc;
const Timer = std.time.Timer;
const Thread = std.Thread;

const ArcU32 = Arc(u32);
const ArcU64 = Arc(u64);
const ArcBuffer = Arc([64]u8);

// All runs write timestamped markdown results under:
//   src/libs/beam-arc/benchmarks/BENCHMARK_RESULTS_YYYY-MM-DD_HHMMSS.md
const MD_PATH_PREFIX = "src/libs/beam-arc/benchmarks/BENCHMARK_RESULTS_";

var g_md_path_buf: [128]u8 = undefined;
var g_md_path: []const u8 = "";

fn initMdPath() void {
    const ts = std.time.timestamp();
    const epoch_seconds: u64 = @intCast(ts);
    const secs_per_day: u64 = 86400;
    const secs_per_hour: u64 = 3600;
    const secs_per_min: u64 = 60;

    var days = epoch_seconds / secs_per_day;
    var remaining = epoch_seconds % secs_per_day;
    const hours = remaining / secs_per_hour;
    remaining = remaining % secs_per_hour;
    const minutes = remaining / secs_per_min;
    const seconds = remaining % secs_per_min;

    var year: u64 = 1970;
    while (true) {
        const days_in_year: u64 = if ((year % 4 == 0 and year % 100 != 0) or year % 400 == 0) 366 else 365;
        if (days < days_in_year) break;
        days -= days_in_year;
        year += 1;
    }

    const is_leap = (year % 4 == 0 and year % 100 != 0) or year % 400 == 0;
    const days_in_months = [_]u64{ 31, if (is_leap) 29 else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };

    var month: u64 = 1;
    for (days_in_months) |dim| {
        if (days < dim) break;
        days -= dim;
        month += 1;
    }
    const day = days + 1;

    const written = std.fmt.bufPrint(&g_md_path_buf, "{s}{d:0>4}-{d:0>2}-{d:0>2}_{d:0>2}{d:0>2}{d:0>2}.md", .{
        MD_PATH_PREFIX, year, month, day, hours, minutes, seconds,
    }) catch &g_md_path_buf;
    g_md_path = written;
}

fn getMdPath() []const u8 {
    if (g_md_path.len == 0) {
        initMdPath();
    }
    return g_md_path;
}

fn appendMdLine(content: []const u8) !void {
    if (content.len == 0) return;
    const path = getMdPath();
    var file = std.fs.cwd().createFile(path, .{ .truncate = false, .exclusive = false }) catch
        try std.fs.cwd().openFile(path, .{ .mode = .read_write });
    defer file.close();
    try file.seekFromEnd(0);
    try file.writeAll(content);
    try file.writeAll("\n");
}

fn initMdHeader() !void {
    const path = getMdPath();
    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    const ts = std.time.timestamp();
    try file.writer().print(
        "# Arc Atomic Operations Benchmarks\n\nTimestamp (epoch seconds): {d}\n\n",
        .{ts},
    );
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n=== Arc Atomic Operations Benchmarks ===\n\n", .{});

    try initMdHeader();

    // Single-threaded benchmarks
    try benchmarkAtomicLoadSingleThreaded(allocator);
    try benchmarkAtomicStoreSingleThreaded(allocator);
    try benchmarkAtomicSwapSingleThreaded(allocator);
    try benchmarkAtomicCompareSwapSingleThreaded(allocator);

    // Multi-threaded benchmarks
    std.debug.print("\n", .{});
    try benchmarkAtomicLoadMultiThreaded(allocator, 2);
    try benchmarkAtomicLoadMultiThreaded(allocator, 4);
    try benchmarkAtomicLoadMultiThreaded(allocator, 8);

    std.debug.print("\n", .{});
    try benchmarkAtomicSwapMultiThreaded(allocator, 2);
    try benchmarkAtomicSwapMultiThreaded(allocator, 4);
    try benchmarkAtomicSwapMultiThreaded(allocator, 8);

    std.debug.print("\n", .{});
    try benchmarkAtomicCompareSwapMultiThreaded(allocator, 2);
    try benchmarkAtomicCompareSwapMultiThreaded(allocator, 4);
    try benchmarkAtomicCompareSwapMultiThreaded(allocator, 8);

    std.debug.print("\n=== Benchmark Complete ===\n", .{});
}

// ============================================================================
// Single-Threaded Benchmarks
// ============================================================================

fn benchmarkAtomicLoadSingleThreaded(allocator: std.mem.Allocator) !void {
    const iterations: usize = 10_000_000;

    var arc = try ArcU64.init(allocator, 42);
    defer arc.release();

    var timer = try Timer.start();

    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const loaded = ArcU64.atomicLoad(&arc, .acquire) orelse unreachable;
        loaded.release();
    }

    const elapsed_ns = timer.read();
    const ns_per_op = elapsed_ns / iterations;
    const throughput = iterations * 1_000_000_000 / elapsed_ns;

    const rate_mops = @as(f64, @floatFromInt(throughput)) / 1_000_000.0;
    std.debug.print(
        "atomicLoad (1T): {d} ns/op, {d:.2} M ops/s ({d} iterations)\n",
        .{ ns_per_op, rate_mops, iterations },
    );
    var buf: [160]u8 = undefined;
    const line = try std.fmt.bufPrint(&buf,
        "- atomicLoad (1T): {d} ns/op, {d:.2} M ops/s ({d} iterations)",
        .{ ns_per_op, rate_mops, iterations },
    );
    try appendMdLine(line);
}

fn benchmarkAtomicStoreSingleThreaded(allocator: std.mem.Allocator) !void {
    const iterations: usize = 1_000_000;

    var arc = try ArcU32.init(allocator, 0);

    var timer = try Timer.start();

    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const new_arc = try ArcU32.init(allocator, @intCast(i));
        ArcU32.atomicStore(&arc, new_arc, .release);
    }

    const elapsed_ns = timer.read();

    arc.release();

    const ns_per_op = elapsed_ns / iterations;
    const throughput = iterations * 1_000_000_000 / elapsed_ns;

    const rate_mops = @as(f64, @floatFromInt(throughput)) / 1_000_000.0;
    std.debug.print(
        "atomicStore (1T): {d} ns/op, {d:.2} M ops/s ({d} iterations)\n",
        .{ ns_per_op, rate_mops, iterations },
    );
    var buf: [160]u8 = undefined;
    const line = try std.fmt.bufPrint(&buf,
        "- atomicStore (1T): {d} ns/op, {d:.2} M ops/s ({d} iterations)",
        .{ ns_per_op, rate_mops, iterations },
    );
    try appendMdLine(line);
}

fn benchmarkAtomicSwapSingleThreaded(allocator: std.mem.Allocator) !void {
    const iterations: usize = 1_000_000;

    var arc = try ArcU32.init(allocator, 0);

    var timer = try Timer.start();

    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const new_arc = try ArcU32.init(allocator, @intCast(i));
        const old_arc = ArcU32.atomicSwap(&arc, new_arc, .acq_rel);
        old_arc.release();
    }

    const elapsed_ns = timer.read();

    arc.release();

    const ns_per_op = elapsed_ns / iterations;
    const throughput = iterations * 1_000_000_000 / elapsed_ns;

    const rate_mops = @as(f64, @floatFromInt(throughput)) / 1_000_000.0;
    std.debug.print(
        "atomicSwap (1T): {d} ns/op, {d:.2} M ops/s ({d} iterations)\n",
        .{ ns_per_op, rate_mops, iterations },
    );
    var buf: [160]u8 = undefined;
    const line = try std.fmt.bufPrint(&buf,
        "- atomicSwap (1T): {d} ns/op, {d:.2} M ops/s ({d} iterations)",
        .{ ns_per_op, rate_mops, iterations },
    );
    try appendMdLine(line);
}

fn benchmarkAtomicCompareSwapSingleThreaded(allocator: std.mem.Allocator) !void {
    const iterations: usize = 1_000_000;

    var arc = try ArcU32.init(allocator, 0);
    defer arc.release();

    var timer = try Timer.start();

    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const expected = arc.clone();
        const new_arc = try ArcU32.init(allocator, @intCast(i));

        const prev = ArcU32.atomicCompareSwap(&arc, expected, new_arc, .acq_rel, .acquire);
        prev.release();
        expected.release();
    }

    const elapsed_ns = timer.read();
    const ns_per_op = elapsed_ns / iterations;
    const throughput = iterations * 1_000_000_000 / elapsed_ns;

    const rate_mops = @as(f64, @floatFromInt(throughput)) / 1_000_000.0;
    std.debug.print(
        "atomicCompareSwap (1T): {d} ns/op, {d:.2} M ops/s ({d} iterations)\n",
        .{ ns_per_op, rate_mops, iterations },
    );
    var buf: [200]u8 = undefined;
    const line = try std.fmt.bufPrint(&buf,
        "- atomicCompareSwap (1T): {d} ns/op, {d:.2} M ops/s ({d} iterations)",
        .{ ns_per_op, rate_mops, iterations },
    );
    try appendMdLine(line);
}

// ============================================================================
// Multi-Threaded Benchmarks
// ============================================================================

fn benchmarkAtomicLoadMultiThreaded(allocator: std.mem.Allocator, num_threads: usize) !void {
    const iterations_per_thread: usize = 1_000_000;

    var shared_arc = try ArcU64.init(allocator, 12345);
    defer shared_arc.release();

    const Context = struct {
        arc: *const ArcU64,
    };

    const ctx = Context{ .arc = &shared_arc };

    const worker_fn = struct {
        fn run(c: Context) void {
            var i: usize = 0;
            while (i < iterations_per_thread) : (i += 1) {
                const loaded = ArcU64.atomicLoad(c.arc, .acquire) orelse unreachable;
                loaded.release();
            }
        }
    }.run;

    var timer = try Timer.start();

    var threads = try allocator.alloc(Thread, num_threads);
    defer allocator.free(threads);

    for (threads) |*t| {
        t.* = try Thread.spawn(.{}, worker_fn, .{ctx});
    }

    for (threads) |t| {
        t.join();
    }

    const elapsed_ns = timer.read();
    const total_ops = iterations_per_thread * num_threads;
    const ns_per_op = elapsed_ns / total_ops;
    const throughput = total_ops * 1_000_000_000 / elapsed_ns;

    const rate_mops = @as(f64, @floatFromInt(throughput)) / 1_000_000.0;
    std.debug.print(
        "atomicLoad ({d}T): {d} ns/op, {d:.2} M ops/s (total {d} ops)\n",
        .{ num_threads, ns_per_op, rate_mops, total_ops },
    );
    var buf: [200]u8 = undefined;
    const line = try std.fmt.bufPrint(&buf,
        "- atomicLoad ({d}T): {d} ns/op, {d:.2} M ops/s (total {d} ops)",
        .{ num_threads, ns_per_op, rate_mops, total_ops },
    );
    try appendMdLine(line);
}

fn benchmarkAtomicSwapMultiThreaded(allocator: std.mem.Allocator, num_threads: usize) !void {
    const iterations_per_thread: usize = 100_000;

    var shared_arc = try ArcU32.init(allocator, 0);
    defer shared_arc.release();

    const Context = struct {
        arc: *ArcU32,
        allocator_: std.mem.Allocator,
        thread_id: u32,
    };

    const worker_fn = struct {
        fn run(c: Context) !void {
            var i: usize = 0;
            while (i < iterations_per_thread) : (i += 1) {
                const new_arc = try ArcU32.init(c.allocator_, c.thread_id);
                const old_arc = ArcU32.atomicSwap(c.arc, new_arc, .acq_rel);
                old_arc.release();
            }
        }
    }.run;

    var timer = try Timer.start();

    var threads = try allocator.alloc(Thread, num_threads);
    defer allocator.free(threads);

    for (threads, 0..) |*t, i| {
        t.* = try Thread.spawn(.{}, worker_fn, .{Context{
            .arc = &shared_arc,
            .allocator_ = allocator,
            .thread_id = @intCast(i),
        }});
    }

    for (threads) |t| {
        t.join();
    }

    const elapsed_ns = timer.read();
    const total_ops = iterations_per_thread * num_threads;
    const ns_per_op = elapsed_ns / total_ops;
    const throughput = total_ops * 1_000_000_000 / elapsed_ns;

    const rate_mops = @as(f64, @floatFromInt(throughput)) / 1_000_000.0;
    std.debug.print(
        "atomicSwap ({d}T): {d} ns/op, {d:.2} M ops/s (total {d} ops)\n",
        .{ num_threads, ns_per_op, rate_mops, total_ops },
    );
    var buf: [200]u8 = undefined;
    const line = try std.fmt.bufPrint(&buf,
        "- atomicSwap ({d}T): {d} ns/op, {d:.2} M ops/s (total {d} ops)",
        .{ num_threads, ns_per_op, rate_mops, total_ops },
    );
    try appendMdLine(line);
}

fn benchmarkAtomicCompareSwapMultiThreaded(allocator: std.mem.Allocator, num_threads: usize) !void {
    const iterations_per_thread: usize = 10_000;

    var shared_arc = try ArcU32.init(allocator, 0);
    defer shared_arc.release();

    const Context = struct {
        arc: *ArcU32,
        allocator_: std.mem.Allocator,
    };

    const worker_fn = struct {
        fn run(c: Context) !void {
            var i: usize = 0;
            while (i < iterations_per_thread) : (i += 1) {
                // CAS retry loop
                while (true) {
                    const current = c.arc.clone();
                    const current_value = current.get().*;
                    const new_value = current_value + 1;

                    const new_arc = try ArcU32.init(c.allocator_, new_value);

                    const prev = ArcU32.atomicCompareSwap(
                        c.arc,
                        current,
                        new_arc,
                        .acq_rel,
                        .acquire
                    );

                    const success = ArcU32.ptrEqual(prev, current);
                    prev.release();
                    current.release();

                    if (success) {
                        break; // CAS succeeded
                    } else {
                        new_arc.release(); // CAS failed, retry
                    }
                }
            }
        }
    }.run;

    const ctx = Context{ .arc = &shared_arc, .allocator_ = allocator };

    var timer = try Timer.start();

    var threads = try allocator.alloc(Thread, num_threads);
    defer allocator.free(threads);

    for (threads) |*t| {
        t.* = try Thread.spawn(.{}, worker_fn, .{ctx});
    }

    for (threads) |t| {
        t.join();
    }

    const elapsed_ns = timer.read();
    const total_ops = iterations_per_thread * num_threads;
    const ns_per_op = elapsed_ns / total_ops;
    const throughput = total_ops * 1_000_000_000 / elapsed_ns;

    const rate_mops = @as(f64, @floatFromInt(throughput)) / 1_000_000.0;
    const final_val = shared_arc.get().*;
    std.debug.print(
        "atomicCAS ({d}T): {d} ns/op, {d:.2} M ops/s (total {d} ops, final value: {d})\n",
        .{ num_threads, ns_per_op, rate_mops, total_ops, final_val },
    );
    var buf: [220]u8 = undefined;
    const line = try std.fmt.bufPrint(&buf,
        "- atomicCAS ({d}T): {d} ns/op, {d:.2} M ops/s (total {d} ops, final value: {d})",
        .{ num_threads, ns_per_op, rate_mops, total_ops, final_val },
    );
    try appendMdLine(line);
}
