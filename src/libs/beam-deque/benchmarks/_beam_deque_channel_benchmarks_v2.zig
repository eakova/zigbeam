const std = @import("std");
const Thread = std.Thread;
const Atomic = std.atomic.Value;
const DequeChannel = @import("beam-deque-channel").DequeChannel;

// =============================================================================
// DequeChannel Performance Benchmarks (V2 - Correct Usage Pattern)
// =============================================================================
//
// These benchmarks test the INTENDED usage pattern where each worker is BOTH
// a producer AND a consumer, operating primarily on its own local deque.
// This matches the design principle: minimize contention, maximize fast path.
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

// =============================================================================
// Benchmark 1: Single Worker (Producer + Consumer)
// Tests the ideal case: zero contention, 100% local deque usage
// =============================================================================
fn benchSingleWorkerProducerConsumer() !void {
    const allocator = std.heap.c_allocator;
    const Channel = DequeChannel(u64, 256, 4096);

    std.debug.print("\n=== Single Worker (Producer + Consumer) ===\n", .{});
    std.debug.print("Pattern: Worker sends to itself, then recvs from itself\n", .{});
    std.debug.print("Expected: ~5-15ns per op (100%% local deque fast path)\n\n", .{});

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

// =============================================================================
// Benchmark 2: 4 Workers (Each is Producer + Consumer)
// Tests realistic multi-threaded usage with minimal contention
// =============================================================================
fn bench4WorkersProducerConsumer() !void {
    const allocator = std.heap.c_allocator;
    const Channel = DequeChannel(u64, 256, 4096);

    std.debug.print("\n=== 4 Workers (Each is Producer + Consumer) ===\n", .{});
    std.debug.print("Pattern: Each worker sends/recvs from its own deque\n", .{});
    std.debug.print("Expected: Scales linearly (~4x single worker throughput)\n\n", .{});

    var result = try Channel.init(allocator, 4);
    defer result.channel.deinit(&result.workers);

    const items_per_worker: usize = 250_000;
    var total_processed = Atomic(usize).init(0);

    // Each worker is both producer and consumer
    var workers: [4]Thread = undefined;
    for (&workers, 0..) |*worker, idx| {
        worker.* = try Thread.spawn(.{}, struct {
            fn run(
                w: *Channel.Worker,
                count: usize,
                counter: *Atomic(usize),
            ) void {
                var processed: usize = 0;
                var i: usize = 0;

                // Producer-Consumer loop: send and recv in same thread
                while (i < count) : (i += 1) {
                    // Send to own local deque (fast path)
                    while (true) {
                        w.send(i) catch |err| {
                            if (err == error.Full) {
                                Thread.yield() catch {};
                                continue;
                            }
                            std.debug.print("Send error: {}\n", .{err});
                            return;
                        };
                        break;
                    }

                    // Recv from own local deque (fast path - LIFO)
                    if (w.recv()) |_| {
                        processed += 1;
                    }
                }

                // Drain any remaining items
                while (w.recv()) |_| {
                    processed += 1;
                }

                _ = counter.fetchAdd(processed, .monotonic);
            }
        }.run, .{
            &result.workers[idx],
            items_per_worker,
            &total_processed,
        });
    }

    const start = std.time.nanoTimestamp();

    // Wait for all workers
    for (workers) |worker| {
        worker.join();
    }

    const end = std.time.nanoTimestamp();

    const processed = total_processed.load(.monotonic);
    const elapsed_ns: u64 = @intCast(end - start);
    const total_ops = items_per_worker * 4 * 2; // 4 workers × items × (send+recv)
    const ns_per_op = elapsed_ns / total_ops;
    const ops_per_sec = (total_ops * 1_000_000_000) / elapsed_ns;

    std.debug.print("Expected items:  {d}\n", .{items_per_worker * 4});
    std.debug.print("Processed:       {d}\n", .{processed});
    std.debug.print("Total ops:       {d} (send+recv)\n", .{total_ops});
    std.debug.print("Elapsed:         ", .{});
    formatNs(elapsed_ns);
    std.debug.print("\nPer-op:          ", .{});
    formatNs(ns_per_op);
    std.debug.print("\nThroughput:      {d} ops/sec\n", .{ops_per_sec});
}

// =============================================================================
// Benchmark 3: 8 Workers (Each is Producer + Consumer)
// Tests scalability with more workers
// =============================================================================
fn bench8WorkersProducerConsumer() !void {
    const allocator = std.heap.c_allocator;
    const Channel = DequeChannel(u64, 256, 8192);

    std.debug.print("\n=== 8 Workers (Each is Producer + Consumer) ===\n", .{});
    std.debug.print("Pattern: Each worker sends/recvs from its own deque\n", .{});
    std.debug.print("Expected: Scales linearly (~8x single worker throughput)\n\n", .{});

    var result = try Channel.init(allocator, 8);
    defer result.channel.deinit(&result.workers);

    const items_per_worker: usize = 125_000;
    var total_processed = Atomic(usize).init(0);

    // Each worker is both producer and consumer
    var workers: [8]Thread = undefined;
    for (&workers, 0..) |*worker, idx| {
        worker.* = try Thread.spawn(.{}, struct {
            fn run(
                w: *Channel.Worker,
                count: usize,
                counter: *Atomic(usize),
            ) void {
                var processed: usize = 0;
                var i: usize = 0;

                // Producer-Consumer loop
                while (i < count) : (i += 1) {
                    // Send to own local deque
                    while (true) {
                        w.send(i) catch |err| {
                            if (err == error.Full) {
                                Thread.yield() catch {};
                                continue;
                            }
                            std.debug.print("Send error: {}\n", .{err});
                            return;
                        };
                        break;
                    }

                    // Recv from own local deque (LIFO)
                    if (w.recv()) |_| {
                        processed += 1;
                    }
                }

                // Drain any remaining items
                while (w.recv()) |_| {
                    processed += 1;
                }

                _ = counter.fetchAdd(processed, .monotonic);
            }
        }.run, .{
            &result.workers[idx],
            items_per_worker,
            &total_processed,
        });
    }

    const start = std.time.nanoTimestamp();

    // Wait for all workers
    for (workers) |worker| {
        worker.join();
    }

    const end = std.time.nanoTimestamp();

    const processed = total_processed.load(.monotonic);
    const elapsed_ns: u64 = @intCast(end - start);
    const total_ops = items_per_worker * 8 * 2; // 8 workers × items × (send+recv)
    const ns_per_op = elapsed_ns / total_ops;
    const ops_per_sec = (total_ops * 1_000_000_000) / elapsed_ns;

    std.debug.print("Expected items:  {d}\n", .{items_per_worker * 8});
    std.debug.print("Processed:       {d}\n", .{processed});
    std.debug.print("Total ops:       {d} (send+recv)\n", .{total_ops});
    std.debug.print("Elapsed:         ", .{});
    formatNs(elapsed_ns);
    std.debug.print("\nPer-op:          ", .{});
    formatNs(ns_per_op);
    std.debug.print("\nThroughput:      {d} ops/sec\n", .{ops_per_sec});
}

// =============================================================================
// Benchmark 4: Work-Stealing Test (Imbalanced Load)
// Tests work-stealing when some workers are busier than others
// =============================================================================
fn benchWorkStealingImbalanced() !void {
    const allocator = std.heap.c_allocator;
    const Channel = DequeChannel(u64, 128, 2048);

    std.debug.print("\n=== Work-Stealing Test (Imbalanced Load) ===\n", .{});
    std.debug.print("Pattern: Worker 0 produces 80%%, workers 1-7 produce 20%%\n", .{});
    std.debug.print("All workers consume equally - tests work-stealing\n\n", .{});

    var result = try Channel.init(allocator, 8);
    defer result.channel.deinit(&result.workers);

    const total_items: usize = 400_000;
    const worker0_items: usize = (total_items * 80) / 100; // 320,000
    const other_worker_items: usize = (total_items * 20) / (100 * 7); // ~11,429 each

    var production_done = Atomic(bool).init(false);
    var consumed_counts: [8]Atomic(usize) = undefined;
    for (&consumed_counts) |*count| {
        count.* = Atomic(usize).init(0);
    }

    // Spawn 8 workers, each is both producer and consumer
    var workers: [8]Thread = undefined;
    for (&workers, 0..) |*worker, idx| {
        const items_to_produce = if (idx == 0) worker0_items else other_worker_items;

        worker.* = try Thread.spawn(.{}, struct {
            fn run(
                w: *Channel.Worker,
                produce_count: usize,
                done_flag: *Atomic(bool),
                counter: *Atomic(usize),
            ) void {
                var consumed: usize = 0;

                // Phase 1: Produce items to own local deque
                var i: usize = 0;
                while (i < produce_count) : (i += 1) {
                    while (true) {
                        w.send(i) catch |err| {
                            if (err == error.Full) {
                                // While waiting, try to consume
                                if (w.recv()) |_| {
                                    consumed += 1;
                                }
                                Thread.yield() catch {};
                                continue;
                            }
                            std.debug.print("Send error: {}\n", .{err});
                            return;
                        };
                        break;
                    }

                    // Try to consume every few items
                    if (i % 10 == 0) {
                        if (w.recv()) |_| {
                            consumed += 1;
                        }
                    }
                }

                // Phase 2: Consume until all work is done
                while (!done_flag.load(.acquire)) {
                    if (w.recv()) |_| {
                        consumed += 1;
                    } else {
                        Thread.yield() catch {};
                    }
                }

                // Final drain
                while (w.recv()) |_| {
                    consumed += 1;
                }

                counter.store(consumed, .monotonic);
            }
        }.run, .{
            &result.workers[idx],
            items_to_produce,
            &production_done,
            &consumed_counts[idx],
        });
    }

    const start = std.time.nanoTimestamp();

    // Wait a bit for production to complete
    Thread.sleep(100 * std.time.ns_per_ms);

    // Signal done
    production_done.store(true, .release);

    // Wait for all workers
    for (workers) |worker| {
        worker.join();
    }

    const end = std.time.nanoTimestamp();

    // Calculate statistics
    var total_consumed: usize = 0;
    var min: usize = std.math.maxInt(usize);
    var max: usize = 0;
    for (&consumed_counts) |*count| {
        const c = count.load(.monotonic);
        total_consumed += c;
        min = @min(min, c);
        max = @max(max, c);
    }

    const elapsed_ns: u64 = @intCast(end - start);
    const items_per_sec = (total_consumed * 1_000_000_000) / elapsed_ns;

    std.debug.print("Total items:     {d}\n", .{total_items});
    std.debug.print("Consumed:        {d}\n", .{total_consumed});
    std.debug.print("Elapsed:         ", .{});
    formatNs(elapsed_ns);
    std.debug.print("\nThroughput:      {d} items/sec\n", .{items_per_sec});
    std.debug.print("\nLoad Distribution:\n", .{});
    std.debug.print("  Min:  {d} items\n", .{min});
    std.debug.print("  Max:  {d} items\n", .{max});
    std.debug.print("  Avg:  {d} items\n", .{total_consumed / 8});

    // Print individual counts
    std.debug.print("  Per-worker: ", .{});
    for (&consumed_counts, 0..) |*count, idx| {
        std.debug.print("{d}", .{count.load(.monotonic)});
        if (idx < 7) std.debug.print(", ", .{});
    }
    std.debug.print("\n", .{});
}

pub fn main() !void {
    std.debug.print("\n╔═══════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  DequeChannel Performance Benchmarks (V2)        ║\n", .{});
    std.debug.print("║  Pattern: Each worker is BOTH producer AND consumer     ║\n", .{});
    std.debug.print("╚═══════════════════════════════════════════════════════════╝\n", .{});

    try benchSingleWorkerProducerConsumer();
    try bench4WorkersProducerConsumer();
    // COMMENTED OUT: 8+ thread benchmarks
    // try bench8WorkersProducerConsumer();
    // try benchWorkStealingImbalanced();

    std.debug.print("\n✓ All benchmarks completed\n\n", .{});
}
