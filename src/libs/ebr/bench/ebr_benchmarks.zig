//! EBR (Epoch-Based Reclamation) Benchmarks
//!
//! Benchmarks our EBR implementation in single-threaded and multi-threaded
//! pin/unpin workloads.
//!
//! Usage (from repo root):
//!   zig build bench-ebr            # via build.zig
//!
//! Adapted from segmented-queue benchmark to use our high-throughput EBR.

const std = @import("std");
const Thread = std.Thread;
const Timer = std.time.Timer;
const Atomic = std.atomic.Value;
const ebr = @import("ebr");

const Collector = ebr.Collector;
const Guard = ebr.Guard;
const FastGuard = ebr.FastGuard;
const Allocator = std.mem.Allocator;

// --- Benchmark Configuration ---

const TOTAL_OPS_TARGET: u64 = 50_000_000; // Target total operations per scenario
const REPEATS: usize = 3;
const WARMUPS: usize = 1;

// --- Stats Helpers ---

const Stats = struct {
    ns_list: [REPEATS]u64 = [_]u64{0} ** REPEATS,
    ops: u64 = 0,
    len: usize = 0,
};

fn record(stats: *Stats, ops: u64, ns: u64) void {
    std.debug.assert(stats.len < REPEATS);
    stats.ops = ops;
    stats.ns_list[stats.len] = ns;
    stats.len += 1;
}

fn medianNs(stats: Stats) f64 {
    if (stats.len == 0) return 0;
    var buf: [REPEATS]f64 = undefined;
    var i: usize = 0;
    while (i < stats.len) : (i += 1) {
        buf[i] = @as(f64, @floatFromInt(stats.ns_list[i]));
    }
    // insertion sort
    var j: usize = 1;
    while (j < stats.len) : (j += 1) {
        var k: usize = j;
        while (k > 0 and buf[k - 1] > buf[k]) : (k -= 1) {
            const tmp = buf[k - 1];
            buf[k - 1] = buf[k];
            buf[k] = tmp;
        }
    }
    const mid = stats.len / 2;
    if (stats.len % 2 == 1) {
        return buf[mid];
    } else {
        return (buf[mid - 1] + buf[mid]) / 2.0;
    }
}

const Summary = struct {
    ns_per_op: f64,
    ops_per_sec: f64,
    ns_per_pair: f64,
    pairs_per_sec: f64,
};

fn summarize(stats: Stats) Summary {
    if (stats.len == 0 or stats.ops == 0) return .{
        .ns_per_op = 0,
        .ops_per_sec = 0,
        .ns_per_pair = 0,
        .pairs_per_sec = 0,
    };
    const med_ns = medianNs(stats);
    const ns_per_op = med_ns / @as(f64, @floatFromInt(stats.ops));
    const ops_per_sec = if (ns_per_op == 0) 0 else 1_000_000_000.0 / ns_per_op;
    // pairs = ops / 2 (one pair = pin + unpin)
    const pairs = @as(f64, @floatFromInt(stats.ops)) / 2.0;
    const ns_per_pair = med_ns / pairs;
    const pairs_per_sec = if (ns_per_pair == 0) 0 else 1_000_000_000.0 / ns_per_pair;
    return .{
        .ns_per_op = ns_per_op,
        .ops_per_sec = ops_per_sec,
        .ns_per_pair = ns_per_pair,
        .pairs_per_sec = pairs_per_sec,
    };
}

fn scaleRate(rate: f64) struct { value: f64, unit: []const u8 } {
    if (rate >= 1_000_000_000.0) {
        return .{ .value = rate / 1_000_000_000.0, .unit = "Gops/s" };
    }
    if (rate >= 1_000_000.0) {
        return .{ .value = rate / 1_000_000.0, .unit = "Mops/s" };
    }
    if (rate >= 1_000.0) {
        return .{ .value = rate / 1_000.0, .unit = "Kops/s" };
    }
    return .{ .value = rate, .unit = "ops/s" };
}

// --- Benchmark Workloads ---

const WorkerArgs = struct {
    collector: *Collector,
    iterations: u64,
    use_fast: bool,
};

/// Destructor for dummy nodes
fn dummyDestructor(ptr: *anyopaque) void {
    _ = ptr;
    // No-op destructor - we're just measuring throughput
}

fn workerPinUnpin(args: *WorkerArgs) void {
    const handle = args.collector.registerThread() catch return;
    defer args.collector.unregisterThread(handle);

    var i: u64 = 0;
    while (i < args.iterations) : (i += 1) {
        if (args.use_fast) {
            // Use pinFast() for maximum throughput
            const guard = args.collector.pinFast();

            // Occasionally defer a dummy to exercise GC path
            if ((i & 0x3FF) == 0) {
                var dummy: u64 = i;
                args.collector.deferReclaim(@ptrCast(&dummy), dummyDestructor);
            }

            guard.unpin();
        } else {
            // Use standard pin() with nesting support
            const guard = args.collector.pin();

            // Occasionally defer a dummy to exercise GC path
            if ((i & 0x3FF) == 0) {
                var dummy: u64 = i;
                args.collector.deferReclaim(@ptrCast(&dummy), dummyDestructor);
            }

            guard.unpin();
        }
    }
}

fn benchPinUnpin(allocator: Allocator, comptime thread_count: usize, use_fast: bool) !Stats {
    var stats = Stats{};

    const iterations_per_thread: u64 = TOTAL_OPS_TARGET / (thread_count * 2); // 2 ops (pin+unpin) per iteration
    const ops_per_thread: u64 = iterations_per_thread * 2;
    const total_ops: u64 = ops_per_thread * thread_count;

    // Warmups
    var warm: usize = 0;
    while (warm < WARMUPS) : (warm += 1) {
        var collector = try Collector.init(allocator);
        defer collector.deinit();

        var threads: [thread_count]Thread = undefined;
        var args_array: [thread_count]WorkerArgs = undefined;

        var i: usize = 0;
        while (i < thread_count) : (i += 1) {
            args_array[i] = .{
                .collector = &collector,
                .iterations = iterations_per_thread,
                .use_fast = use_fast,
            };
            threads[i] = try Thread.spawn(.{}, workerPinUnpin, .{&args_array[i]});
        }

        for (threads) |t| {
            t.join();
        }
    }

    var rep: usize = 0;
    while (rep < REPEATS) : (rep += 1) {
        var collector = try Collector.init(allocator);
        defer collector.deinit();

        var threads: [thread_count]Thread = undefined;
        var args_array: [thread_count]WorkerArgs = undefined;

        var timer = try Timer.start();

        var i: usize = 0;
        while (i < thread_count) : (i += 1) {
            args_array[i] = .{
                .collector = &collector,
                .iterations = iterations_per_thread,
                .use_fast = use_fast,
            };
            threads[i] = try Thread.spawn(.{}, workerPinUnpin, .{&args_array[i]});
        }

        for (threads) |t| {
            t.join();
        }

        const ns = timer.read();
        record(&stats, total_ops, ns);
    }

    return stats;
}

// --- Main ---

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== EBR Benchmarks (High-Throughput EBR) ===\n", .{});
    std.debug.print("  TOTAL_OPS_TARGET: {d}\n", .{TOTAL_OPS_TARGET});
    std.debug.print("  REPEATS: {d}, WARMUPS: {d}\n\n", .{ REPEATS, WARMUPS });

    // Standard pin() benchmarks
    std.debug.print("--- Standard pin()/Guard (supports nesting) ---\n", .{});
    std.debug.print("{s:20} | {s:>10} | {s:>10} | {s:>12} | {s:>12}\n", .{
        "Config", "ns/op", "ns/pair", "ops/s", "pairs/s",
    });
    std.debug.print("{s:-<20}-+-{s:-<10}-+-{s:-<10}-+-{s:-<12}-+-{s:-<12}\n", .{ "", "", "", "", "" });

    const thread_configs = [_]usize{ 1, 2, 4, 8 };

    inline for (thread_configs) |threads| {
        const stats = try benchPinUnpin(allocator, threads, false);
        const summary = summarize(stats);
        const ops_scaled = scaleRate(summary.ops_per_sec);
        const pairs_scaled = scaleRate(summary.pairs_per_sec);

        std.debug.print(
            "pin/unpin {d} thread{s:2} | {d:>10.2} | {d:>10.2} | {d:>6.2} {s:<5} | {d:>6.2} {s:<5}\n",
            .{
                threads,
                if (threads > 1) "s" else " ",
                summary.ns_per_op,
                summary.ns_per_pair,
                ops_scaled.value,
                ops_scaled.unit,
                pairs_scaled.value,
                pairs_scaled.unit,
            },
        );
    }

    // Fast pinFast() benchmarks
    std.debug.print("\n--- Fast pinFast()/FastGuard (no nesting) ---\n", .{});
    std.debug.print("{s:20} | {s:>10} | {s:>10} | {s:>12} | {s:>12}\n", .{
        "Config", "ns/op", "ns/pair", "ops/s", "pairs/s",
    });
    std.debug.print("{s:-<20}-+-{s:-<10}-+-{s:-<10}-+-{s:-<12}-+-{s:-<12}\n", .{ "", "", "", "", "" });

    inline for (thread_configs) |threads| {
        const stats = try benchPinUnpin(allocator, threads, true);
        const summary = summarize(stats);
        const ops_scaled = scaleRate(summary.ops_per_sec);
        const pairs_scaled = scaleRate(summary.pairs_per_sec);

        std.debug.print(
            "pinFast   {d} thread{s:2} | {d:>10.2} | {d:>10.2} | {d:>6.2} {s:<5} | {d:>6.2} {s:<5}\n",
            .{
                threads,
                if (threads > 1) "s" else " ",
                summary.ns_per_op,
                summary.ns_per_pair,
                ops_scaled.value,
                ops_scaled.unit,
                pairs_scaled.value,
                pairs_scaled.unit,
            },
        );
    }

    std.debug.print("\nNote: 1 pair = 1 pin + 1 unpin, ops = individual pin or unpin calls\n", .{});
    std.debug.print("Target: >1 Gops pairs/s per thread\n", .{});
}
