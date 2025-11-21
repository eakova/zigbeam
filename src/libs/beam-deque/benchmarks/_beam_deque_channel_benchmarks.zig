const std = @import("std");
const Thread = std.Thread;
const Atomic = std.atomic.Value;
const DequeChannel = @import("beam-deque-channel").DequeChannel;

// =============================================================================
// DequeChannel Performance Benchmarks
// =============================================================================

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

fn benchSendRecvSingleThread() !void {
    const allocator = std.heap.c_allocator;
    const Channel = DequeChannel(u64, 256, 4096);

    std.debug.print("\n=== Single-Threaded Send/Recv ===\n", .{});

    var result = try Channel.init(allocator, 1);
    defer result.channel.deinit(&result.workers);

    const iterations: usize = 1_000_000;

    // Warmup
    var i: usize = 0;
    while (i < 10000) : (i += 1) {
        try result.workers[0].send(i);
        _ = result.workers[0].recv();
    }

    // Benchmark
    const start = std.time.nanoTimestamp();
    i = 0;
    while (i < iterations) : (i += 1) {
        try result.workers[0].send(i);
        _ = result.workers[0].recv();
    }
    const end = std.time.nanoTimestamp();

    const elapsed_ns: u64 = @intCast(end - start);
    const total_ops = iterations * 2; // send + recv
    const ns_per_op = elapsed_ns / total_ops;
    const ops_per_sec = (total_ops * 1_000_000_000) / elapsed_ns;

    std.debug.print("Total ops:    {d} (send+recv pairs)\n", .{iterations});
    std.debug.print("Elapsed:      ", .{});
    formatNs(elapsed_ns);
    std.debug.print("\nPer-op:       ", .{});
    formatNs(ns_per_op);
    std.debug.print("\nThroughput:   {d} ops/sec\n", .{ops_per_sec});
}

fn bench4P4C() !void {
    const allocator = std.heap.c_allocator;
    const Channel = DequeChannel(u64, 256, 4096);

    std.debug.print("\n=== 4 Producers / 4 Consumers ===\n", .{});

    var result = try Channel.init(allocator, 8);
    defer result.channel.deinit(&result.workers);

    const items_per_producer: usize = 250_000;
    const total_items = items_per_producer * 4;

    var total_consumed = Atomic(usize).init(0);
    var done = Atomic(bool).init(false);

    // Spawn 4 producer threads (workers 0-3)
    var producers: [4]Thread = undefined;
    for (&producers, 0..) |*producer, idx| {
        producer.* = try Thread.spawn(.{}, struct {
            fn run(
                worker: *Channel.Worker,
                start: usize,
                count: usize,
            ) void {
                var i: usize = 0;
                while (i < count) : (i += 1) {
                    const item = start + i;
                    while (true) {
                        worker.send(item) catch |err| {
                            if (err == error.Full) {
                                Thread.yield() catch {};
                                continue;
                            }
                            std.debug.print("Producer error: {}\n", .{err});
                            return;
                        };
                        break;
                    }
                }
            }
        }.run, .{
            &result.workers[idx],
            idx * items_per_producer,
            items_per_producer,
        });
    }

    // Spawn 4 consumer threads (workers 4-7)
    var consumers: [4]Thread = undefined;
    for (&consumers, 4..) |*consumer, idx| {
        consumer.* = try Thread.spawn(.{}, struct {
            fn run(
                worker: *Channel.Worker,
                done_flag: *Atomic(bool),
                counter: *Atomic(usize),
            ) void {
                var count: usize = 0;

                while (true) {
                    if (worker.recv()) |_| {
                        count += 1;
                    } else {
                        if (done_flag.load(.acquire)) break;
                        Thread.yield() catch {};
                    }
                }

                _ = counter.fetchAdd(count, .monotonic);
            }
        }.run, .{
            &result.workers[idx],
            &done,
            &total_consumed,
        });
    }

    const start = std.time.nanoTimestamp();

    // Wait for producers
    for (producers) |producer| {
        producer.join();
    }

    // Signal done
    done.store(true, .release);

    // Wait for consumers
    for (consumers) |consumer| {
        consumer.join();
    }

    const end = std.time.nanoTimestamp();

    const consumed = total_consumed.load(.monotonic);
    const elapsed_ns: u64 = @intCast(end - start);
    const ns_per_item = elapsed_ns / consumed;
    const items_per_sec = (consumed * 1_000_000_000) / elapsed_ns;

    std.debug.print("Total items:  {d}\n", .{total_items});
    std.debug.print("Consumed:     {d}\n", .{consumed});
    std.debug.print("Elapsed:      ", .{});
    formatNs(elapsed_ns);
    std.debug.print("\nPer-item:     ", .{});
    formatNs(ns_per_item);
    std.debug.print("\nThroughput:   {d} items/sec\n", .{items_per_sec});
}

fn bench8P8C() !void {
    const allocator = std.heap.c_allocator;
    const Channel = DequeChannel(u64, 256, 8192);

    std.debug.print("\n=== 8 Producers / 8 Consumers ===\n", .{});

    var result = try Channel.init(allocator, 16);
    defer result.channel.deinit(&result.workers);

    const items_per_producer: usize = 125_000;
    const total_items = items_per_producer * 8;

    var total_consumed = Atomic(usize).init(0);
    var done = Atomic(bool).init(false);

    // Spawn 8 producer threads (workers 0-7)
    var producers: [8]Thread = undefined;
    for (&producers, 0..) |*producer, idx| {
        producer.* = try Thread.spawn(.{}, struct {
            fn run(
                worker: *Channel.Worker,
                start: usize,
                count: usize,
            ) void {
                var i: usize = 0;
                while (i < count) : (i += 1) {
                    const item = start + i;
                    while (true) {
                        worker.send(item) catch |err| {
                            if (err == error.Full) {
                                Thread.yield() catch {};
                                continue;
                            }
                            std.debug.print("Producer error: {}\n", .{err});
                            return;
                        };
                        break;
                    }
                }
            }
        }.run, .{
            &result.workers[idx],
            idx * items_per_producer,
            items_per_producer,
        });
    }

    // Spawn 8 consumer threads (workers 8-15)
    var consumers: [8]Thread = undefined;
    for (&consumers, 8..) |*consumer, idx| {
        consumer.* = try Thread.spawn(.{}, struct {
            fn run(
                worker: *Channel.Worker,
                done_flag: *Atomic(bool),
                counter: *Atomic(usize),
            ) void {
                var count: usize = 0;

                while (true) {
                    if (worker.recv()) |_| {
                        count += 1;
                    } else {
                        if (done_flag.load(.acquire)) break;
                        Thread.yield() catch {};
                    }
                }

                _ = counter.fetchAdd(count, .monotonic);
            }
        }.run, .{
            &result.workers[idx],
            &done,
            &total_consumed,
        });
    }

    const start = std.time.nanoTimestamp();

    // Wait for producers
    for (producers) |producer| {
        producer.join();
    }

    // Signal done
    done.store(true, .release);

    // Wait for consumers
    for (consumers) |consumer| {
        consumer.join();
    }

    const end = std.time.nanoTimestamp();

    const consumed = total_consumed.load(.monotonic);
    const elapsed_ns: u64 = @intCast(end - start);
    const ns_per_item = elapsed_ns / consumed;
    const items_per_sec = (consumed * 1_000_000_000) / elapsed_ns;

    std.debug.print("Total items:  {d}\n", .{total_items});
    std.debug.print("Consumed:     {d}\n", .{consumed});
    std.debug.print("Elapsed:      ", .{});
    formatNs(elapsed_ns);
    std.debug.print("\nPer-item:     ", .{});
    formatNs(ns_per_item);
    std.debug.print("\nThroughput:   {d} items/sec\n", .{items_per_sec});
}

fn bench1P8CLoadBalancing() !void {
    const allocator = std.heap.c_allocator;
    const Channel = DequeChannel(u64, 128, 2048);

    std.debug.print("\n=== 1 Producer / 8 Consumers (Load Balancing) ===\n", .{});

    var result = try Channel.init(allocator, 9); // 9 workers: 1 producer + 8 consumers
    defer result.channel.deinit(&result.workers);

    const total_items: usize = 500_000;

    var consumed_counts: [8]Atomic(usize) = undefined;
    for (&consumed_counts) |*count| {
        count.* = Atomic(usize).init(0);
    }

    var done = Atomic(bool).init(false);

    // Spawn 8 consumer threads (workers 0-7)
    var consumers: [8]Thread = undefined;
    for (&consumers, 0..) |*consumer, idx| {
        consumer.* = try Thread.spawn(.{}, struct {
            fn run(
                worker: *Channel.Worker,
                done_flag: *Atomic(bool),
                counter: *Atomic(usize),
            ) void {
                var count: usize = 0;

                while (!done_flag.load(.acquire)) {
                    if (worker.recv()) |_| {
                        count += 1;
                    } else {
                        Thread.yield() catch {};
                    }
                }

                // Final drain
                while (worker.recv()) |_| {
                    count += 1;
                }

                counter.store(count, .monotonic);
            }
        }.run, .{
            &result.workers[idx],
            &done,
            &consumed_counts[idx],
        });
    }

    // Single producer (worker 8 - dedicated producer)
    const start = std.time.nanoTimestamp();
    var i: usize = 0;
    while (i < total_items) : (i += 1) {
        while (true) {
            result.workers[8].send(i) catch |err| {
                if (err == error.Full) {
                    Thread.yield() catch {};
                    continue;
                }
                std.debug.print("Producer error: {}\n", .{err});
                return err;
            };
            break;
        }
    }

    // Signal done
    done.store(true, .release);

    // Wait for consumers
    for (consumers) |consumer| {
        consumer.join();
    }

    const end = std.time.nanoTimestamp();

    // Calculate statistics
    var total: usize = 0;
    var min: usize = std.math.maxInt(usize);
    var max: usize = 0;
    for (&consumed_counts) |*count| {
        const c = count.load(.monotonic);
        total += c;
        min = @min(min, c);
        max = @max(max, c);
    }

    const elapsed_ns: u64 = @intCast(end - start);
    const items_per_sec = (total * 1_000_000_000) / elapsed_ns;

    std.debug.print("Total items:  {d}\n", .{total_items});
    std.debug.print("Consumed:     {d}\n", .{total});
    std.debug.print("Elapsed:      ", .{});
    formatNs(elapsed_ns);
    std.debug.print("\nThroughput:   {d} items/sec\n", .{items_per_sec});
    std.debug.print("\nLoad Distribution:\n", .{});
    std.debug.print("  Min:  {d} items\n", .{min});
    std.debug.print("  Max:  {d} items\n", .{max});
    std.debug.print("  Avg:  {d} items\n", .{total / 8});

    // Print individual counts
    std.debug.print("  Per-consumer: ", .{});
    for (&consumed_counts, 0..) |*count, idx| {
        std.debug.print("{d}", .{count.load(.monotonic)});
        if (idx < 7) std.debug.print(", ", .{});
    }
    std.debug.print("\n", .{});
}

pub fn main() !void {
    std.debug.print("\n╔═══════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║   DequeChannel Performance Benchmarks    ║\n", .{});
    std.debug.print("╚═══════════════════════════════════════════════════╝\n", .{});

    try benchSendRecvSingleThread();
    try bench4P4C();
    // COMMENTED OUT: 8+ thread benchmarks
    // try bench8P8C();
    // try bench1P8CLoadBalancing();

    std.debug.print("\n✓ All benchmarks completed\n\n", .{});
}
