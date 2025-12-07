const std = @import("std");
const Thread = std.Thread;
const Atomic = std.atomic.Value;
const Deque = @import("deque").Deque;

// =============================================================================
// Performance Benchmarks
// =============================================================================

const BenchConfig = struct {
    iterations: usize = 1_000_000,
    warmup: usize = 10_000,
    // num_threads: usize = 8, // COMMENTED OUT: 8+ thread benchmarks
    num_threads: usize = 4,
};

fn formatNs(ns: u64) void {
    if (ns < 1000) {
        std.debug.print("{d}ns", .{ns});
    } else if (ns < 1_000_000) {
        std.debug.print("{d:.2}µs", .{@as(f64, @floatFromInt(ns)) / 1000.0});
    } else if (ns < 1_000_000_000) {
        std.debug.print("{d:.2}ms", .{@as(f64, @floatFromInt(ns)) / 1_000_000.0});
    } else {
        std.debug.print("{d:.2}s", .{@as(f64, @floatFromInt(ns)) / 1_000_000_000.0});
    }
}

fn benchOwnerPush() !void {
    const config = BenchConfig{};
    const allocator = std.heap.c_allocator;

    std.debug.print("\n=== Owner Push Throughput ===\n", .{});

    var result = try Deque(u64).init(allocator, 4096);
    defer result.worker.deinit();

    // Warmup - fill and drain a few times
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        var j: usize = 0;
        while (j < 1000) : (j += 1) {
            try result.worker.push(j);
        }
        while (result.worker.pop()) |_| {}
    }

    // Benchmark
    const start = std.time.nanoTimestamp();
    i = 0;
    while (i < config.iterations) : (i += 1) {
        // Fill to 75% capacity then drain
        var j: usize = 0;
        while (j < 3072) : (j += 1) {
            try result.worker.push(i);
        }
        while (result.worker.pop()) |_| {}
    }
    const end = std.time.nanoTimestamp();

    const total_ops = config.iterations * 3072;
    const elapsed_ns: u64 = @intCast(end - start);
    const ns_per_op = elapsed_ns / total_ops;
    const ops_per_sec = (total_ops * 1_000_000_000) / elapsed_ns;

    std.debug.print("Total ops:    {d}\n", .{total_ops});
    std.debug.print("Elapsed:      ", .{});
    formatNs(elapsed_ns);
    std.debug.print("\nPer-op:       ", .{});
    formatNs(ns_per_op);
    std.debug.print("\nThroughput:   {d} ops/sec\n", .{ops_per_sec});
}

fn benchOwnerPop() !void {
    const config = BenchConfig{};
    const allocator = std.heap.c_allocator;

    std.debug.print("\n=== Owner Pop Throughput ===\n", .{});

    var result = try Deque(u64).init(allocator, 4096);
    defer result.worker.deinit();

    // Pre-fill the deque
    var i: usize = 0;
    while (i < 3072) : (i += 1) {
        try result.worker.push(i);
    }

    // Warmup
    i = 0;
    while (i < config.warmup) : (i += 1) {
        _ = result.worker.pop();
    }
    while (i < 3072) : (i += 1) {
        try result.worker.push(i);
    }

    // Benchmark
    const start = std.time.nanoTimestamp();
    var total_pops: usize = 0;
    i = 0;
    while (i < config.iterations) : (i += 1) {
        // Fill
        var j: usize = 0;
        while (j < 3072) : (j += 1) {
            try result.worker.push(i);
        }

        // Pop all
        while (result.worker.pop()) |_| {
            total_pops += 1;
        }
    }
    const end = std.time.nanoTimestamp();

    const elapsed_ns: u64 = @intCast(end - start);
    const ns_per_op = elapsed_ns / total_pops;
    const ops_per_sec = (total_pops * 1_000_000_000) / elapsed_ns;

    std.debug.print("Total ops:    {d}\n", .{total_pops});
    std.debug.print("Elapsed:      ", .{});
    formatNs(elapsed_ns);
    std.debug.print("\nPer-op:       ", .{});
    formatNs(ns_per_op);
    std.debug.print("\nThroughput:   {d} ops/sec\n", .{ops_per_sec});
}

fn benchThiefSteal() !void {
    const config = BenchConfig{};
    const allocator = std.heap.c_allocator;

    std.debug.print("\n=== Thief Steal Throughput (Single Thief) ===\n", .{});

    var result = try Deque(u64).init(allocator, 4096);
    defer result.worker.deinit();

    // Pre-fill
    var i: usize = 0;
    while (i < 3072) : (i += 1) {
        try result.worker.push(i);
    }

    // Warmup
    i = 0;
    while (i < config.warmup) : (i += 1) {
        _ = result.stealer.steal();
    }
    while (i < 3072) : (i += 1) {
        try result.worker.push(i);
    }

    // Benchmark
    const start = std.time.nanoTimestamp();
    var total_steals: usize = 0;
    i = 0;
    while (i < config.iterations) : (i += 1) {
        // Fill
        var j: usize = 0;
        while (j < 3072) : (j += 1) {
            try result.worker.push(i);
        }

        // Steal all
        while (result.stealer.steal()) |_| {
            total_steals += 1;
        }
    }
    const end = std.time.nanoTimestamp();

    const elapsed_ns: u64 = @intCast(end - start);
    const ns_per_op = elapsed_ns / total_steals;
    const ops_per_sec = (total_steals * 1_000_000_000) / elapsed_ns;

    std.debug.print("Total ops:    {d}\n", .{total_steals});
    std.debug.print("Elapsed:      ", .{});
    formatNs(elapsed_ns);
    std.debug.print("\nPer-op:       ", .{});
    formatNs(ns_per_op);
    std.debug.print("\nThroughput:   {d} ops/sec\n", .{ops_per_sec});
}

fn benchConcurrentSteal() !void {
    // COMMENTED OUT: 8+ thread benchmarks
    // const config = BenchConfig{ .num_threads = 8 };
    const config = BenchConfig{ .num_threads = 4 };
    const allocator = std.heap.c_allocator;

    std.debug.print("\n=== Concurrent Steal ({d} Thieves) ===\n", .{config.num_threads});

    var result = try Deque(u64).init(allocator, 8192);
    defer result.worker.deinit();

    const total_items: usize = 1_000_000;
    var stolen = Atomic(usize).init(0);
    var done = Atomic(bool).init(false);

    // Spawn thieves FIRST (they will steal as we push)
    // COMMENTED OUT: 8+ thread benchmarks - changed from [8]Thread to [4]Thread
    var thieves: [4]Thread = undefined;
    for (&thieves) |*thief| {
        thief.* = try Thread.spawn(.{}, struct {
            fn run(stealer: *Deque(u64).Stealer, counter: *Atomic(usize), done_flag: *Atomic(bool)) void {
                var count: usize = 0;
                while (!done_flag.load(.acquire) or !stealer.isEmpty()) {
                    if (stealer.steal()) |_| {
                        count += 1;
                    }
                }
                _ = counter.fetchAdd(count, .monotonic);
            }
        }.run, .{ &result.stealer, &stolen, &done });
    }

    // Push items with retry on Full (thieves drain concurrently)
    const start = std.time.nanoTimestamp();
    var i: usize = 0;
    while (i < total_items) : (i += 1) {
        while (true) {
            result.worker.push(i) catch |err| {
                if (err == error.Full) {
                    // Give thieves time to drain
                    Thread.yield() catch {};
                    continue;
                }
                return err;
            };
            break;
        }
    }

    // Signal done
    done.store(true, .release);

    // Wait for thieves
    for (thieves) |thief| {
        thief.join();
    }
    const end = std.time.nanoTimestamp();

    const total_stolen = stolen.load(.monotonic);
    const elapsed_ns: u64 = @intCast(end - start);
    const ns_per_op = elapsed_ns / total_stolen;
    const ops_per_sec = (total_stolen * 1_000_000_000) / elapsed_ns;

    std.debug.print("Total stolen: {d}\n", .{total_stolen});
    std.debug.print("Elapsed:      ", .{});
    formatNs(elapsed_ns);
    std.debug.print("\nPer-op:       ", .{});
    formatNs(ns_per_op);
    std.debug.print("\nThroughput:   {d} ops/sec\n", .{ops_per_sec});
}

fn benchMixedWorkload() !void {
    const config = BenchConfig{ .num_threads = 4 };
    const allocator = std.heap.c_allocator;

    std.debug.print("\n=== Mixed Workload (Owner Push/Pop + {d} Thieves) ===\n", .{config.num_threads});

    var result = try Deque(u64).init(allocator, 4096);
    defer result.worker.deinit();

    const total_items: usize = 500_000;
    var stolen = Atomic(usize).init(0);
    var done = Atomic(bool).init(false);

    // Spawn thieves
    var thieves: [4]Thread = undefined;
    for (&thieves) |*thief| {
        thief.* = try Thread.spawn(.{}, struct {
            fn run(stealer: *Deque(u64).Stealer, counter: *Atomic(usize), done_flag: *Atomic(bool)) void {
                var count: usize = 0;
                while (!done_flag.load(.acquire) or !stealer.isEmpty()) {
                    if (stealer.steal()) |_| {
                        count += 1;
                    }
                }
                _ = counter.fetchAdd(count, .monotonic);
            }
        }.run, .{ &result.stealer, &stolen, &done });
    }

    // Owner pushes and occasionally pops
    const start = std.time.nanoTimestamp();
    var pushed: usize = 0;
    var owner_popped: usize = 0;
    while (pushed < total_items) : (pushed += 1) {
        while (true) {
            result.worker.push(pushed) catch |err| {
                if (err == error.Full) {
                    // Give thieves time to drain
                    Thread.yield() catch {};
                    continue;
                }
                return err;
            };
            break;
        }

        // Pop every 5th item
        if (pushed % 5 == 0) {
            if (result.worker.pop()) |_| {
                owner_popped += 1;
            }
        }
    }

    done.store(true, .release);

    for (thieves) |thief| {
        thief.join();
    }

    while (result.worker.pop()) |_| {
        owner_popped += 1;
    }

    const end = std.time.nanoTimestamp();

    const total_stolen = stolen.load(.monotonic);
    const elapsed_ns: u64 = @intCast(end - start);
    const total_ops = total_items;
    const ops_per_sec = (total_ops * 1_000_000_000) / elapsed_ns;

    std.debug.print("Total pushed: {d}\n", .{total_items});
    std.debug.print("Owner popped: {d}\n", .{owner_popped});
    std.debug.print("Thieves stole: {d}\n", .{total_stolen});
    std.debug.print("Elapsed:      ", .{});
    formatNs(elapsed_ns);
    std.debug.print("\nThroughput:   {d} ops/sec\n", .{ops_per_sec});
}

fn benchLastItemRace() !void {
    const allocator = std.heap.c_allocator;

    std.debug.print("\n=== Last Item Race Performance ===\n", .{});

    var result = try Deque(u64).init(allocator, 8);
    defer result.worker.deinit();

    const iterations: usize = 100_000;

    const start = std.time.nanoTimestamp();
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        // Push one item
        try result.worker.push(42);

        // Spawn thief
        const thief = try Thread.spawn(.{}, struct {
            fn run(stealer: *Deque(u64).Stealer) void {
                _ = stealer.steal();
            }
        }.run, .{&result.stealer});

        // Owner pops
        _ = result.worker.pop();

        thief.join();
    }
    const end = std.time.nanoTimestamp();

    const elapsed_ns: u64 = @intCast(end - start);
    const ns_per_race = elapsed_ns / iterations;

    std.debug.print("Iterations:   {d}\n", .{iterations});
    std.debug.print("Elapsed:      ", .{});
    formatNs(elapsed_ns);
    std.debug.print("\nPer-race:     ", .{});
    formatNs(ns_per_race);
    std.debug.print("\n", .{});
}

pub fn main() !void {
    std.debug.print("\n╔═══════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║      Deque Performance Benchmarks            ║\n", .{});
    std.debug.print("╚═══════════════════════════════════════════════════╝\n", .{});

    try benchOwnerPush();
    try benchOwnerPop();
    try benchThiefSteal();
    try benchConcurrentSteal();
    try benchMixedWorkload();
    try benchLastItemRace();

    std.debug.print("\n✓ All benchmarks completed\n\n", .{});
}
