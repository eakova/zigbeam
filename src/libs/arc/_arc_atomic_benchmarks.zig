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

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n=== Arc Atomic Operations Benchmarks ===\n\n", .{});

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

    std.debug.print(
        "atomicLoad (1T): {d} ns/op, {d:.2} M ops/s ({d} iterations)\n",
        .{ ns_per_op, @as(f64, @floatFromInt(throughput)) / 1_000_000.0, iterations }
    );
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

    std.debug.print(
        "atomicStore (1T): {d} ns/op, {d:.2} M ops/s ({d} iterations)\n",
        .{ ns_per_op, @as(f64, @floatFromInt(throughput)) / 1_000_000.0, iterations }
    );
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

    std.debug.print(
        "atomicSwap (1T): {d} ns/op, {d:.2} M ops/s ({d} iterations)\n",
        .{ ns_per_op, @as(f64, @floatFromInt(throughput)) / 1_000_000.0, iterations }
    );
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

    std.debug.print(
        "atomicCompareSwap (1T): {d} ns/op, {d:.2} M ops/s ({d} iterations)\n",
        .{ ns_per_op, @as(f64, @floatFromInt(throughput)) / 1_000_000.0, iterations }
    );
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

    std.debug.print(
        "atomicLoad ({d}T): {d} ns/op, {d:.2} M ops/s (total {d} ops)\n",
        .{ num_threads, ns_per_op, @as(f64, @floatFromInt(throughput)) / 1_000_000.0, total_ops }
    );
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

    std.debug.print(
        "atomicSwap ({d}T): {d} ns/op, {d:.2} M ops/s (total {d} ops)\n",
        .{ num_threads, ns_per_op, @as(f64, @floatFromInt(throughput)) / 1_000_000.0, total_ops }
    );
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

    std.debug.print(
        "atomicCAS ({d}T): {d} ns/op, {d:.2} M ops/s (total {d} ops, final value: {d})\n",
        .{
            num_threads,
            ns_per_op,
            @as(f64, @floatFromInt(throughput)) / 1_000_000.0,
            total_ops,
            shared_arc.get().*
        }
    );
}
