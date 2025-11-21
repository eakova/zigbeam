//! EBR (Epoch-Based Reclamation) Benchmarks
//!
//! Benchmarks the segmented-queue EBR implementation (`src/libs/segmented-queue/ebr.zig`)
//! in single-threaded and multi-threaded pin/unpin workloads.
//!
//! Usage (from repo root):
//!   zig build bench-ebr            # via build.zig
//! or:
//!   zig build-exe src/libs/segmented-queue/_ebr_benchmarks.zig -O ReleaseFast -Mebr=src/libs/segmented-queue/ebr.zig
//!   ./_ebr_benchmarks

const std = @import("std");
const Thread = std.Thread;
const Timer = std.time.Timer;
const Atomic = std.atomic.Value;
const EBR = @import("beam-ebr");

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

fn summarize(stats: Stats) struct { ns_per_op: f64, ops_per_sec: f64 } {
    if (stats.len == 0 or stats.ops == 0) return .{ .ns_per_op = 0, .ops_per_sec = 0 };
    const med_ns = medianNs(stats);
    const ns_per_op = med_ns / @as(f64, @floatFromInt(stats.ops));
    const ops_per_sec = if (ns_per_op == 0) 0 else 1_000_000_000.0 / ns_per_op;
    return .{ .ns_per_op = ns_per_op, .ops_per_sec = ops_per_sec };
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
    global_epoch: *EBR.GlobalEpoch,
    iterations: u64,
};

fn workerPinUnpin(args: *WorkerArgs) !void {
    const allocator = std.heap.page_allocator;
    var participant = EBR.Participant.init(allocator);
    try args.global_epoch.registerParticipant(&participant);
    // Bind participant to this worker thread so EBR.pin() can be used.
    EBR.setThreadParticipant(&participant);

    var i: u64 = 0;
    while (i < args.iterations) : (i += 1) {
        var guard = EBR.pin();
        // Occasionally retire a dummy node to exercise GC path, but keep
        // the hot loop dominated by pure pin/unpin.
        if ((i & 0x3FF) == 0) {
            const Dummy = struct {
                value: u64,
            };
            const dummy = try allocator.create(Dummy);
            dummy.* = .{ .value = i };

            const g = EBR.Garbage{
                .ptr = @ptrCast(dummy),
                .destroy_fn = struct {
                    fn destroy(ptr: *anyopaque, alloc: Allocator) void {
                        const d: *Dummy = @ptrCast(@alignCast(ptr));
                        _ = d.value;
                        alloc.destroy(d);
                    }
                }.destroy,
                .epoch = 0,
            };
            guard.deferDestroy(g);
        }
        guard.deinit();
    }

    participant.deinit(args.global_epoch);
    args.global_epoch.unregisterParticipant(&participant);
}

fn benchPinUnpin(comptime thread_count: usize) !Stats {
    const allocator = std.heap.page_allocator;
    var stats = Stats{};

    const iterations_per_thread: u64 = TOTAL_OPS_TARGET / (thread_count * 2); // 2 ops (pin+unpin) per iteration
    const ops_per_thread: u64 = iterations_per_thread * 2;
    const total_ops: u64 = ops_per_thread * thread_count;

    // Warmups
    var warm: usize = 0;
    while (warm < WARMUPS) : (warm += 1) {
        var global_epoch = try EBR.GlobalEpoch.init(.{ .allocator = allocator });
        defer global_epoch.deinit();

        var threads: [thread_count]Thread = undefined;
        var args_array: [thread_count]WorkerArgs = undefined;

        var i: usize = 0;
        while (i < thread_count) : (i += 1) {
            args_array[i] = .{
                .global_epoch = &global_epoch,
                .iterations = iterations_per_thread,
            };
            threads[i] = try Thread.spawn(.{}, workerPinUnpin, .{&args_array[i]});
        }

        for (threads) |t| {
            t.join();
        }
    }

    var rep: usize = 0;
    while (rep < REPEATS) : (rep += 1) {
        var global_epoch = try EBR.GlobalEpoch.init(.{ .allocator = allocator });
        defer global_epoch.deinit();

        var threads: [thread_count]Thread = undefined;
        var args_array: [thread_count]WorkerArgs = undefined;

        var timer = try Timer.start();

        var i: usize = 0;
        while (i < thread_count) : (i += 1) {
            args_array[i] = .{
                .global_epoch = &global_epoch,
                .iterations = iterations_per_thread,
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
    std.debug.print("EBR Benchmarks (segmented-queue EBR)\n", .{});
    std.debug.print("  TOTAL_OPS_TARGET: {d}\n", .{TOTAL_OPS_TARGET});
    std.debug.print("  REPEATS: {d}, WARMUPS: {d}\n\n", .{ REPEATS, WARMUPS });

    const configs = [_]struct {
        threads: usize,
        label: []const u8,
    }{
        .{ .threads = 1, .label = "pin/unpin 1 thread" },
        .{ .threads = 2, .label = "pin/unpin 2 threads" },
        .{ .threads = 4, .label = "pin/unpin 4 threads" },
        // COMMENTED OUT: 8+ thread benchmarks
        // .{ .threads = 8, .label = "pin/unpin 8 threads" },
    };

    inline for (configs) |cfg| {
        const stats = try benchPinUnpin(cfg.threads);
        const summary = summarize(stats);
        const scaled = scaleRate(summary.ops_per_sec);

        std.debug.print(
            "{s:24} | threads={d:2} | median ns/op={d:.1} | throughput={d:.2} {s}\n",
            .{
                cfg.label,
                cfg.threads,
                summary.ns_per_op,
                scaled.value,
                scaled.unit,
            },
        );
    }
}
