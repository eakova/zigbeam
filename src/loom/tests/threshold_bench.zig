const std = @import("std");
const loom = @import("loom");
const ParallelIterator = loom.ParallelIterator;
const Splitter = loom.Splitter;
const ThreadPool = loom.ThreadPool;

fn heavyWork(x: i32) i32 {
    var result: i32 = x;
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        result = result *% 31 +% 17;
    }
    return result;
}

fn benchReduce(data: []i32, threshold: usize, pool: *ThreadPool) i64 {
    const splitter = Splitter.adaptive(threshold);
    var timer = std.time.Timer.start() catch return 0;

    const result = ParallelIterator(i32).init(data)
        .withSplitter(splitter)
        .withPool(pool)
        .reduce(loom.Reducer(i32).sum());

    _ = result;
    return timer.read();
}

fn benchSort(data: []i32, threshold: usize, pool: *ThreadPool, allocator: std.mem.Allocator) i64 {
    // Reset data
    for (data, 0..) |*d, i| {
        d.* = @intCast(data.len - i);
    }

    const splitter = Splitter.adaptive(threshold);
    var timer = std.time.Timer.start() catch return 0;

    ParallelIterator(i32).init(data)
        .withSplitter(splitter)
        .withPool(pool)
        .withAlloc(allocator)
        .sort(struct {
            fn lt(a: i32, b: i32) bool { return a < b; }
        }.lt, null) catch {};

    return timer.read();
}

fn seqReduce(data: []i32) i64 {
    var timer = std.time.Timer.start() catch return 0;
    var sum: i32 = 0;
    for (data) |x| {
        sum +%= x;
    }
    _ = sum;
    return timer.read();
}

fn seqSort(data: []i32) i64 {
    // Reset data
    for (data, 0..) |*d, i| {
        d.* = @intCast(data.len - i);
    }

    var timer = std.time.Timer.start() catch return 0;
    std.mem.sort(i32, data, {}, std.sort.asc(i32));
    return timer.read();
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const stdout = std.io.getStdOut().writer();

    const pool = try ThreadPool.init(allocator, .{});
    defer pool.deinit();

    const num_threads = pool.numWorkers();
    try stdout.print("Threads: {d}\n\n", .{num_threads});

    // Test sizes
    const sizes = [_]usize{ 1000, 2000, 4000, 8000, 16000 };
    const thresholds = [_]usize{ 512, 1024, 2048, 4096, 8192 };

    // Reduce benchmark
    try stdout.print("=== REDUCE THRESHOLD BENCHMARK ===\n", .{});
    try stdout.print("Size     | Sequential |", .{});
    for (thresholds) |t| {
        try stdout.print(" T={d:5} |", .{t});
    }
    try stdout.print("\n", .{});
    try stdout.print("---------+------------+", .{});
    for (thresholds) |_| {
        try stdout.print("---------+", .{});
    }
    try stdout.print("\n", .{});

    for (sizes) |size| {
        const data = try allocator.alloc(i32, size);
        defer allocator.free(data);
        for (data, 0..) |*d, i| d.* = @intCast(i);

        // Sequential baseline
        var seq_total: i64 = 0;
        var run: usize = 0;
        while (run < 10) : (run += 1) {
            seq_total += seqReduce(data);
        }
        const seq_avg = @divFloor(seq_total, 10);

        try stdout.print("{d:8} | {d:8}ns |", .{size, seq_avg});

        for (thresholds) |threshold| {
            var par_total: i64 = 0;
            run = 0;
            while (run < 10) : (run += 1) {
                par_total += benchReduce(data, threshold, pool);
            }
            const par_avg = @divFloor(par_total, 10);
            const speedup = @as(f64, @floatFromInt(seq_avg)) / @as(f64, @floatFromInt(@max(1, par_avg)));
            try stdout.print(" {d:5.2}x |", .{speedup});
        }
        try stdout.print("\n", .{});
    }

    // Sort benchmark
    try stdout.print("\n=== SORT THRESHOLD BENCHMARK ===\n", .{});
    const sort_sizes = [_]usize{ 2000, 4000, 8000, 16000, 32000 };
    const sort_thresholds = [_]usize{ 1024, 2048, 4096, 8192, 16384 };

    try stdout.print("Size     | Sequential |", .{});
    for (sort_thresholds) |t| {
        try stdout.print(" T={d:5} |", .{t});
    }
    try stdout.print("\n", .{});
    try stdout.print("---------+------------+", .{});
    for (sort_thresholds) |_| {
        try stdout.print("---------+", .{});
    }
    try stdout.print("\n", .{});

    for (sort_sizes) |size| {
        const data = try allocator.alloc(i32, size);
        defer allocator.free(data);

        // Sequential baseline
        var seq_total: i64 = 0;
        var run: usize = 0;
        while (run < 5) : (run += 1) {
            seq_total += seqSort(data);
        }
        const seq_avg = @divFloor(seq_total, 5);

        try stdout.print("{d:8} | {d:8}ns |", .{size, seq_avg});

        for (sort_thresholds) |threshold| {
            var par_total: i64 = 0;
            run = 0;
            while (run < 5) : (run += 1) {
                par_total += benchSort(data, threshold, pool, allocator);
            }
            const par_avg = @divFloor(par_total, 5);
            const speedup = @as(f64, @floatFromInt(seq_avg)) / @as(f64, @floatFromInt(@max(1, par_avg)));
            try stdout.print(" {d:5.2}x |", .{speedup});
        }
        try stdout.print("\n", .{});
    }

    try stdout.print("\nLegend: >1.0 = parallel faster, <1.0 = sequential faster\n", .{});
}
