// FILE: _ebr_benchmarks.zig
//! Comprehensive benchmarks for Epoch-Based Reclamation (EBR)
//!
//! Metrics tracked:
//! - Operations per second (throughput)
//! - Latency percentiles: p50, p90, p95, p99, p999
//! - Latency histogram with buckets
//! - Memory usage (allocated, peak, retired objects)
//! - Thread scalability
//!
//! Scenarios:
//! 1. Single-threaded pin/unpin latency
//! 2. Single-threaded retire throughput
//! 3. Multi-threaded concurrent pin/unpin
//! 4. Multi-threaded AtomicPtr operations
//! 5. Memory reclamation under load
//! 6. Thread scalability (1, 2, 4, 8 threads)

const std = @import("std");
const ebr_module = @import("ebr.zig");
const EBR = ebr_module.EBR;
const ThreadState = ebr_module.ThreadState;
const Guard = ebr_module.Guard;
const pin = ebr_module.pin;
const AtomicPtr = ebr_module.AtomicPtr;

// Thread-local state for benchmarks
threadlocal var bench_thread_state: ThreadState = .{};

/// Latency sample in nanoseconds
const LatencySample = u64;

/// Statistics collector
const Stats = struct {
    samples: std.ArrayList(LatencySample),
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) Stats {
        return .{
            .samples = std.ArrayList(LatencySample){},
            .allocator = allocator,
        };
    }

    fn deinit(self: *Stats) void {
        self.samples.deinit(self.allocator);
    }

    fn record(self: *Stats, latency_ns: u64) !void {
        try self.samples.append(self.allocator, latency_ns);
    }

    fn compute(self: *Stats) !StatsSummary {
        if (self.samples.items.len == 0) {
            return StatsSummary{
                .count = 0,
                .min = 0,
                .max = 0,
                .mean = 0,
                .p50 = 0,
                .p90 = 0,
                .p95 = 0,
                .p99 = 0,
                .p999 = 0,
            };
        }

        // Sort samples for percentile calculation
        std.mem.sort(u64, self.samples.items, {}, comptime std.sort.asc(u64));

        const count = self.samples.items.len;
        const min = self.samples.items[0];
        const max = self.samples.items[count - 1];

        var sum: u128 = 0;
        for (self.samples.items) |sample| {
            sum += sample;
        }
        const mean = @as(u64, @intCast(sum / count));

        const p50 = self.percentile(50);
        const p90 = self.percentile(90);
        const p95 = self.percentile(95);
        const p99 = self.percentile(99);
        const p999 = self.percentile(99.9);

        return StatsSummary{
            .count = count,
            .min = min,
            .max = max,
            .mean = mean,
            .p50 = p50,
            .p90 = p90,
            .p95 = p95,
            .p99 = p99,
            .p999 = p999,
        };
    }

    fn percentile(self: *Stats, p: f64) u64 {
        const count = self.samples.items.len;
        if (count == 0) return 0;

        const index = @as(usize, @intFromFloat(@as(f64, @floatFromInt(count)) * p / 100.0));
        const clamped = @min(index, count - 1);
        return self.samples.items[clamped];
    }

    fn histogram(self: *Stats) void {
        if (self.samples.items.len == 0) return;

        const buckets = [_]u64{
            100,    // 100ns
            500,    // 500ns
            1000,   // 1us
            5000,   // 5us
            10000,  // 10us
            50000,  // 50us
            100000, // 100us
            500000, // 500us
            1000000, // 1ms
            std.math.maxInt(u64), // infinity
        };

        var counts: [buckets.len]usize = [_]usize{0} ** buckets.len;

        for (self.samples.items) |sample| {
            for (buckets, 0..) |bucket, i| {
                if (sample <= bucket) {
                    counts[i] += 1;
                    break;
                }
            }
        }

        std.debug.print("Latency Histogram:\n", .{});
        std.debug.print("  <100ns:    {d:>8}\n", .{counts[0]});
        std.debug.print("  <500ns:    {d:>8}\n", .{counts[1]});
        std.debug.print("  <1us:      {d:>8}\n", .{counts[2]});
        std.debug.print("  <5us:      {d:>8}\n", .{counts[3]});
        std.debug.print("  <10us:     {d:>8}\n", .{counts[4]});
        std.debug.print("  <50us:     {d:>8}\n", .{counts[5]});
        std.debug.print("  <100us:    {d:>8}\n", .{counts[6]});
        std.debug.print("  <500us:    {d:>8}\n", .{counts[7]});
        std.debug.print("  <1ms:      {d:>8}\n", .{counts[8]});
        std.debug.print("  >=1ms:     {d:>8}\n", .{counts[9]});
    }
};

const StatsSummary = struct {
    count: usize,
    min: u64,
    max: u64,
    mean: u64,
    p50: u64,
    p90: u64,
    p95: u64,
    p99: u64,
    p999: u64,

    fn print(self: StatsSummary, label: []const u8) void {
        std.debug.print("\n{s}:\n", .{label});
        std.debug.print("  Samples:   {d}\n", .{self.count});
        std.debug.print("  Min:       {d}ns\n", .{self.min});
        std.debug.print("  Mean:      {d}ns\n", .{self.mean});
        std.debug.print("  p50:       {d}ns\n", .{self.p50});
        std.debug.print("  p90:       {d}ns\n", .{self.p90});
        std.debug.print("  p95:       {d}ns\n", .{self.p95});
        std.debug.print("  p99:       {d}ns\n", .{self.p99});
        std.debug.print("  p999:      {d}ns\n", .{self.p999});
        std.debug.print("  Max:       {d}ns\n", .{self.max});
    }
};

/// Memory usage tracker
const MemoryTracker = struct {
    allocated: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    peak: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    retired_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    fn recordAllocation(self: *MemoryTracker, size: usize) void {
        const new_allocated = self.allocated.fetchAdd(size, .monotonic) + size;

        var current_peak = self.peak.load(.monotonic);
        while (new_allocated > current_peak) {
            if (self.peak.cmpxchgWeak(
                current_peak,
                new_allocated,
                .monotonic,
                .monotonic,
            )) |updated| {
                current_peak = updated;
            } else {
                break;
            }
        }
    }

    fn recordDeallocation(self: *MemoryTracker, size: usize) void {
        _ = self.allocated.fetchSub(size, .monotonic);
    }

    fn recordRetire(self: *MemoryTracker) void {
        _ = self.retired_count.fetchAdd(1, .monotonic);
    }

    fn print(self: *MemoryTracker) void {
        std.debug.print("\nMemory Usage:\n", .{});
        std.debug.print("  Current:   {d} bytes\n", .{self.allocated.load(.monotonic)});
        std.debug.print("  Peak:      {d} bytes\n", .{self.peak.load(.monotonic)});
        std.debug.print("  Retired:   {d} objects\n", .{self.retired_count.load(.monotonic)});
    }
};

/// Benchmark: Single-threaded pin/unpin latency
pub fn benchmark_pin_unpin_latency(allocator: std.mem.Allocator) !void {
    var global = try EBR.init(.{ .allocator = allocator });
    defer global.deinit();

    try bench_thread_state.ensureInitialized(.{
        .global = &global,
        .allocator = allocator,
    });
    defer bench_thread_state.deinitThread();

    var stats = Stats.init(allocator);
    defer stats.deinit();

    const iterations = 100000;
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const start = std.time.nanoTimestamp();
        var guard = pin(&bench_thread_state, &global);
        guard.unpin();
        const end = std.time.nanoTimestamp();

        const latency = @as(u64, @intCast(end - start));
        try stats.record(latency);
    }

    const summary = try stats.compute();

    summary.print("Pin/Unpin Latency");
    stats.histogram();
}

/// Benchmark: Single-threaded retire throughput
pub fn benchmark_retire_throughput(allocator: std.mem.Allocator) !void {
    var global = try EBR.init(.{ .allocator = allocator });
    defer global.deinit();

    try bench_thread_state.ensureInitialized(.{
        .global = &global,
        .allocator = allocator,
    });
    defer bench_thread_state.deinitThread();

    var stats = Stats.init(allocator);
    defer stats.deinit();

    var memory = MemoryTracker{};

    const TestData = struct {
        value: u64,
        tracker: *MemoryTracker,
        alloc: std.mem.Allocator,

        fn deleter(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.tracker.recordDeallocation(@sizeOf(@This()));
            self.alloc.destroy(self);
        }
    };

    const iterations = 10000;
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        var guard = pin(&bench_thread_state, &global);

        const start = std.time.nanoTimestamp();

        const data = try allocator.create(TestData);
        memory.recordAllocation(@sizeOf(TestData));
        data.* = TestData{
            .value = i,
            .tracker = &memory,
            .alloc = allocator,
        };

        guard.retire(.{
            .ptr = data,
            .deleter = TestData.deleter,
        });
        memory.recordRetire();

        const end = std.time.nanoTimestamp();

        const latency = @as(u64, @intCast(end - start));
        try stats.record(latency);

        guard.unpin();

        if (i % 1000 == 0) {
            var flush_guard = pin(&bench_thread_state, &global);
            flush_guard.flush();
            flush_guard.unpin();
        }
    }

    // Final cleanup
    var final_guard = pin(&bench_thread_state, &global);
    final_guard.flush();
    final_guard.unpin();

    const summary = try stats.compute();

    summary.print("Retire Throughput");
    stats.histogram();
    memory.print();
}

/// Benchmark: Multi-threaded concurrent pin/unpin
pub fn benchmark_concurrent_pin_unpin(allocator: std.mem.Allocator, thread_count: usize) !void {
    var global = try EBR.init(.{ .allocator = allocator });
    defer global.deinit();

    const ThreadContext = struct {
        global: *EBR,
        thread_id: usize,
        iterations: usize,
        stats: *Stats,  // Each thread gets its own stats
        allocator: std.mem.Allocator,

        threadlocal var thread_state: ThreadState = .{};

        fn worker(ctx: *@This()) !void {
            try thread_state.ensureInitialized(.{
                .global = ctx.global,
                .allocator = ctx.allocator,
            });
            defer thread_state.deinitThread();

            var i: usize = 0;
            while (i < ctx.iterations) : (i += 1) {
                const start = std.time.nanoTimestamp();
                var guard = pin(&thread_state, ctx.global);
                guard.unpin();
                const end = std.time.nanoTimestamp();

                const latency = @as(u64, @intCast(end - start));
                try ctx.stats.record(latency);
            }
        }
    };

    // Each thread gets its own Stats to avoid contention
    var per_thread_stats = try allocator.alloc(Stats, thread_count);
    defer {
        for (per_thread_stats) |*s| {
            s.deinit();
        }
        allocator.free(per_thread_stats);
    }

    for (per_thread_stats) |*s| {
        s.* = Stats.init(allocator);
    }

    const iterations_per_thread = 10000;
    const threads = try allocator.alloc(std.Thread, thread_count);
    defer allocator.free(threads);

    const contexts = try allocator.alloc(ThreadContext, thread_count);
    defer allocator.free(contexts);

    const start_time = std.time.nanoTimestamp();

    for (threads, contexts, 0..) |*t, *ctx, idx| {
        ctx.* = ThreadContext{
            .global = &global,
            .thread_id = idx,
            .iterations = iterations_per_thread,
            .stats = &per_thread_stats[idx],  // Each thread gets its own stats
            .allocator = allocator,
        };
        t.* = try std.Thread.spawn(.{}, ThreadContext.worker, .{ctx});
    }

    for (threads) |*t| {
        t.join();
    }

    const end_time = std.time.nanoTimestamp();
    const total_time_ns = @as(u64, @intCast(end_time - start_time));
    const total_ops = thread_count * iterations_per_thread;
    const ops_per_sec = (@as(f64, @floatFromInt(total_ops)) / @as(f64, @floatFromInt(total_time_ns))) * 1_000_000_000.0;

    // Merge all thread stats
    var merged_stats = Stats.init(allocator);
    defer merged_stats.deinit();

    for (per_thread_stats) |*s| {
        for (s.samples.items) |sample| {
            try merged_stats.record(sample);
        }
    }

    const summary = try merged_stats.compute();

    std.debug.print("\n=== Concurrent Pin/Unpin ({d} threads) ===\n", .{thread_count});
    std.debug.print("Total operations: {d}\n", .{total_ops});
    std.debug.print("Total time:       {d}ns\n", .{total_time_ns});
    std.debug.print("Throughput:       {d:.2} ops/sec\n", .{ops_per_sec});
    summary.print("Per-operation Latency");
    merged_stats.histogram();
}

/// Benchmark: Multi-threaded AtomicPtr operations
pub fn benchmark_atomic_ptr_ops(allocator: std.mem.Allocator, thread_count: usize) !void {
    var global = try EBR.init(.{ .allocator = allocator });
    defer global.deinit();

    const SharedData = AtomicPtr(u64);
    var shared = SharedData.init(.{});

    var memory = MemoryTracker{};

    const ThreadContext = struct {
        global: *EBR,
        shared: *SharedData,
        thread_id: usize,
        iterations: usize,
        stats: *Stats,
        memory: *MemoryTracker,
        allocator: std.mem.Allocator,

        threadlocal var thread_state: ThreadState = .{};

        fn worker(ctx: *@This()) !void {
            try thread_state.ensureInitialized(.{
                .global = ctx.global,
                .allocator = ctx.allocator,
            });
            defer thread_state.deinitThread();

            const TestDeleter = struct {
                value: *u64,
                mem_tracker: *MemoryTracker,
                alloc: std.mem.Allocator,

                fn delete(self_ptr: *anyopaque) void {
                    const self: *@This() = @ptrCast(@alignCast(self_ptr));
                    self.mem_tracker.recordDeallocation(@sizeOf(u64));
                    self.alloc.destroy(self.value);
                    self.mem_tracker.recordDeallocation(@sizeOf(@This()));
                    self.alloc.destroy(self);
                }
            };

            var i: usize = 0;
            while (i < ctx.iterations) : (i += 1) {
                var guard = pin(&thread_state, ctx.global);

                const start = std.time.nanoTimestamp();

                const new_value = try ctx.allocator.create(u64);
                ctx.memory.recordAllocation(@sizeOf(u64));
                new_value.* = ctx.thread_id * 100000 + i;

                const old = ctx.shared.swap(.{ .value = new_value });

                if (old) |old_ptr| {
                    const deleter = try ctx.allocator.create(TestDeleter);
                    ctx.memory.recordAllocation(@sizeOf(TestDeleter));
                    deleter.* = TestDeleter{
                        .value = old_ptr,
                        .mem_tracker = ctx.memory,
                        .alloc = ctx.allocator,
                    };
                    guard.retire(.{
                        .ptr = deleter,
                        .deleter = TestDeleter.delete,
                    });
                    ctx.memory.recordRetire();
                }

                const end = std.time.nanoTimestamp();

                const latency = @as(u64, @intCast(end - start));
                try ctx.stats.record(latency);

                guard.unpin();

                if (i % 100 == 0) {
                    var flush_guard = pin(&thread_state, ctx.global);
                    flush_guard.flush();
                    flush_guard.unpin();
                }
            }

            var final_guard = pin(&thread_state, ctx.global);
            final_guard.flush();
            final_guard.unpin();
        }
    };

    // Each thread gets its own Stats to avoid contention
    const iterations_per_thread = 1000;
    var per_thread_stats = try allocator.alloc(Stats, thread_count);
    defer {
        for (per_thread_stats) |*s| {
            s.deinit();
        }
        allocator.free(per_thread_stats);
    }

    for (per_thread_stats) |*s| {
        s.* = Stats.init(allocator);
    }

    const threads = try allocator.alloc(std.Thread, thread_count);
    defer allocator.free(threads);

    const contexts = try allocator.alloc(ThreadContext, thread_count);
    defer allocator.free(contexts);

    const start_time = std.time.nanoTimestamp();

    for (threads, contexts, 0..) |*t, *ctx, idx| {
        ctx.* = ThreadContext{
            .global = &global,
            .shared = &shared,
            .thread_id = idx,
            .iterations = iterations_per_thread,
            .stats = &per_thread_stats[idx],  // Each thread gets its own stats
            .memory = &memory,
            .allocator = allocator,
        };
        t.* = try std.Thread.spawn(.{}, ThreadContext.worker, .{ctx});
    }

    for (threads) |*t| {
        t.join();
    }

    const end_time = std.time.nanoTimestamp();

    // Cleanup final value
    var cleanup_state: ThreadState = .{};
    try cleanup_state.ensureInitialized(.{
        .global = &global,
        .allocator = allocator,
    });
    defer cleanup_state.deinitThread();

    var cleanup_guard = pin(&cleanup_state, &global);
    const final = shared.load(.{ .guard = &cleanup_guard });
    if (final) |f| {
        allocator.destroy(f);
    }
    cleanup_guard.flush();
    cleanup_guard.unpin();

    const total_time_ns = @as(u64, @intCast(end_time - start_time));
    const total_ops = thread_count * iterations_per_thread;
    const ops_per_sec = (@as(f64, @floatFromInt(total_ops)) / @as(f64, @floatFromInt(total_time_ns))) * 1_000_000_000.0;

    // Merge all thread stats
    var merged_stats = Stats.init(allocator);
    defer merged_stats.deinit();

    for (per_thread_stats) |*s| {
        for (s.samples.items) |sample| {
            try merged_stats.record(sample);
        }
    }

    const summary = try merged_stats.compute();

    std.debug.print("\n=== AtomicPtr Operations ({d} threads) ===\n", .{thread_count});
    std.debug.print("Total operations: {d}\n", .{total_ops});
    std.debug.print("Total time:       {d}ns\n", .{total_time_ns});
    std.debug.print("Throughput:       {d:.2} ops/sec\n", .{ops_per_sec});
    summary.print("Per-operation Latency");
    merged_stats.histogram();
    memory.print();
}

/// Benchmark: Thread scalability test
pub fn benchmark_scalability(allocator: std.mem.Allocator) !void {
    std.debug.print("\n=== Thread Scalability Analysis ===\n", .{});

    const thread_counts = [_]usize{ 1, 2, 4, 8 };

    for (thread_counts) |tc| {
        try benchmark_concurrent_pin_unpin(allocator, tc);
    }
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("\n==========================================\n", .{});
    std.debug.print("EBR Benchmark Suite\n", .{});
    std.debug.print("==========================================\n", .{});

    std.debug.print("\n[1/6] Pin/Unpin Latency...\n", .{});
    try benchmark_pin_unpin_latency(allocator);

    std.debug.print("\n[2/6] Retire Throughput...\n", .{});
    try benchmark_retire_throughput(allocator);

    std.debug.print("\n[3/6] Concurrent Pin/Unpin (4 threads)...\n", .{});
    try benchmark_concurrent_pin_unpin(allocator, 4);

    std.debug.print("\n[4/6] AtomicPtr Operations (4 threads)...\n", .{});
    try benchmark_atomic_ptr_ops(allocator, 4);

    std.debug.print("\n[5/6] AtomicPtr Operations (8 threads)...\n", .{});
    try benchmark_atomic_ptr_ops(allocator, 8);

    std.debug.print("\n[6/6] Thread Scalability...\n", .{});
    try benchmark_scalability(allocator);

    std.debug.print("\n==========================================\n", .{});
    std.debug.print("All benchmarks completed\n", .{});
    std.debug.print("==========================================\n", .{});
}
