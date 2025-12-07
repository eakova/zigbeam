const std = @import("std");
const Thread = std.Thread;
const Atomic = std.atomic.Value;
const DequeChannel = @import("deque-channel").DequeChannel;

// =============================================================================
// DequeChannel Performance Benchmarks (V2 - Correct Usage Pattern)
// =============================================================================
//
// These benchmarks test the INTENDED usage pattern where each worker is BOTH
// a producer AND a consumer, operating primarily on its own local deque.
// This matches the design principle: minimize contention, maximize fast path.
// =============================================================================

// Stats structure for tracking operations
const WorkerStats = struct {
    send_ok: usize = 0,
    send_retries: usize = 0, // error.Full retries
    recv_ok: usize = 0,
    recv_null: usize = 0, // recv returned null
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
    var stats = WorkerStats{};

    // Warmup
    var i: usize = 0;
    while (i < 10000) : (i += 1) {
        try result.workers[0].send(i);
        _ = result.workers[0].recv();
    }

    // Benchmark with stats tracking
    const start = std.time.nanoTimestamp();
    i = 0;
    while (i < iterations) : (i += 1) {
        // Send with retry tracking
        while (true) {
            result.workers[0].send(i) catch |err| {
                if (err == error.Full) {
                    stats.send_retries += 1;
                    continue;
                }
                return err;
            };
            stats.send_ok += 1;
            break;
        }

        // Recv with null tracking
        if (result.workers[0].recv()) |_| {
            stats.recv_ok += 1;
        } else {
            stats.recv_null += 1;
        }
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

    // Stats
    std.debug.print("\nOperation Stats:\n", .{});
    std.debug.print("  Send OK:      {d}\n", .{stats.send_ok});
    std.debug.print("  Send Retries: {d} ({d:.2}%%)\n", .{ stats.send_retries, if (stats.send_ok > 0) @as(f64, @floatFromInt(stats.send_retries)) * 100.0 / @as(f64, @floatFromInt(stats.send_ok + stats.send_retries)) else 0.0 });
    std.debug.print("  Recv OK:      {d}\n", .{stats.recv_ok});
    std.debug.print("  Recv Null:    {d} ({d:.2}%%)\n", .{ stats.recv_null, if (stats.recv_ok > 0) @as(f64, @floatFromInt(stats.recv_null)) * 100.0 / @as(f64, @floatFromInt(stats.recv_ok + stats.recv_null)) else 0.0 });
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

    // Atomic counters for stats
    var total_send_ok = Atomic(usize).init(0);
    var total_send_retries = Atomic(usize).init(0);
    var total_recv_ok = Atomic(usize).init(0);
    var total_recv_null = Atomic(usize).init(0);

    // Each worker is both producer and consumer
    var workers: [4]Thread = undefined;
    for (&workers, 0..) |*worker, idx| {
        worker.* = try Thread.spawn(.{}, struct {
            fn run(
                w: *Channel.Worker,
                count: usize,
                send_ok: *Atomic(usize),
                send_retries: *Atomic(usize),
                recv_ok: *Atomic(usize),
                recv_null: *Atomic(usize),
            ) void {
                var local_send_ok: usize = 0;
                var local_send_retries: usize = 0;
                var local_recv_ok: usize = 0;
                var local_recv_null: usize = 0;
                var i: usize = 0;

                // Producer-Consumer loop: send and recv in same thread
                while (i < count) : (i += 1) {
                    // Send to own local deque (fast path)
                    while (true) {
                        w.send(i) catch |err| {
                            if (err == error.Full) {
                                local_send_retries += 1;
                                Thread.yield() catch {};
                                continue;
                            }
                            std.debug.print("Send error: {}\n", .{err});
                            return;
                        };
                        local_send_ok += 1;
                        break;
                    }

                    // Recv from own local deque (fast path - LIFO)
                    if (w.recv()) |_| {
                        local_recv_ok += 1;
                    } else {
                        local_recv_null += 1;
                    }
                }

                // Drain any remaining items
                while (w.recv()) |_| {
                    local_recv_ok += 1;
                }

                // Aggregate stats
                _ = send_ok.fetchAdd(local_send_ok, .monotonic);
                _ = send_retries.fetchAdd(local_send_retries, .monotonic);
                _ = recv_ok.fetchAdd(local_recv_ok, .monotonic);
                _ = recv_null.fetchAdd(local_recv_null, .monotonic);
            }
        }.run, .{
            &result.workers[idx],
            items_per_worker,
            &total_send_ok,
            &total_send_retries,
            &total_recv_ok,
            &total_recv_null,
        });
    }

    const start = std.time.nanoTimestamp();

    // Wait for all workers
    for (workers) |worker| {
        worker.join();
    }

    const end = std.time.nanoTimestamp();

    const send_ok = total_send_ok.load(.monotonic);
    const send_retries = total_send_retries.load(.monotonic);
    const recv_ok = total_recv_ok.load(.monotonic);
    const recv_null = total_recv_null.load(.monotonic);

    const elapsed_ns: u64 = @intCast(end - start);
    const total_ops = items_per_worker * 4 * 2; // 4 workers × items × (send+recv)
    const ns_per_op = elapsed_ns / total_ops;
    const ops_per_sec = (total_ops * 1_000_000_000) / elapsed_ns;

    std.debug.print("Expected items:  {d}\n", .{items_per_worker * 4});
    std.debug.print("Processed:       {d}\n", .{recv_ok});
    std.debug.print("Total ops:       {d} (send+recv)\n", .{total_ops});
    std.debug.print("Elapsed:         ", .{});
    formatNs(elapsed_ns);
    std.debug.print("\nPer-op:          ", .{});
    formatNs(ns_per_op);
    std.debug.print("\nThroughput:      {d} ops/sec\n", .{ops_per_sec});

    // Stats
    std.debug.print("\nOperation Stats:\n", .{});
    std.debug.print("  Send OK:      {d}\n", .{send_ok});
    std.debug.print("  Send Retries: {d} ({d:.2}%%)\n", .{ send_retries, if (send_ok > 0) @as(f64, @floatFromInt(send_retries)) * 100.0 / @as(f64, @floatFromInt(send_ok + send_retries)) else 0.0 });
    std.debug.print("  Recv OK:      {d}\n", .{recv_ok});
    std.debug.print("  Recv Null:    {d} ({d:.2}%%)\n", .{ recv_null, if (recv_ok > 0) @as(f64, @floatFromInt(recv_null)) * 100.0 / @as(f64, @floatFromInt(recv_ok + recv_null)) else 0.0 });
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

    // Atomic counters for stats
    var total_send_ok = Atomic(usize).init(0);
    var total_send_retries = Atomic(usize).init(0);
    var total_recv_ok = Atomic(usize).init(0);
    var total_recv_null = Atomic(usize).init(0);

    // Each worker is both producer and consumer
    var workers: [8]Thread = undefined;
    for (&workers, 0..) |*worker, idx| {
        worker.* = try Thread.spawn(.{}, struct {
            fn run(
                w: *Channel.Worker,
                count: usize,
                send_ok: *Atomic(usize),
                send_retries: *Atomic(usize),
                recv_ok: *Atomic(usize),
                recv_null: *Atomic(usize),
            ) void {
                var local_send_ok: usize = 0;
                var local_send_retries: usize = 0;
                var local_recv_ok: usize = 0;
                var local_recv_null: usize = 0;
                var i: usize = 0;

                // Producer-Consumer loop
                while (i < count) : (i += 1) {
                    // Send to own local deque
                    while (true) {
                        w.send(i) catch |err| {
                            if (err == error.Full) {
                                local_send_retries += 1;
                                Thread.yield() catch {};
                                continue;
                            }
                            std.debug.print("Send error: {}\n", .{err});
                            return;
                        };
                        local_send_ok += 1;
                        break;
                    }

                    // Recv from own local deque (LIFO)
                    if (w.recv()) |_| {
                        local_recv_ok += 1;
                    } else {
                        local_recv_null += 1;
                    }
                }

                // Drain any remaining items
                while (w.recv()) |_| {
                    local_recv_ok += 1;
                }

                // Aggregate stats
                _ = send_ok.fetchAdd(local_send_ok, .monotonic);
                _ = send_retries.fetchAdd(local_send_retries, .monotonic);
                _ = recv_ok.fetchAdd(local_recv_ok, .monotonic);
                _ = recv_null.fetchAdd(local_recv_null, .monotonic);
            }
        }.run, .{
            &result.workers[idx],
            items_per_worker,
            &total_send_ok,
            &total_send_retries,
            &total_recv_ok,
            &total_recv_null,
        });
    }

    const start = std.time.nanoTimestamp();

    // Wait for all workers
    for (workers) |worker| {
        worker.join();
    }

    const end = std.time.nanoTimestamp();

    const send_ok = total_send_ok.load(.monotonic);
    const send_retries = total_send_retries.load(.monotonic);
    const recv_ok = total_recv_ok.load(.monotonic);
    const recv_null = total_recv_null.load(.monotonic);

    const elapsed_ns: u64 = @intCast(end - start);
    const total_ops = items_per_worker * 8 * 2; // 8 workers × items × (send+recv)
    const ns_per_op = elapsed_ns / total_ops;
    const ops_per_sec = (total_ops * 1_000_000_000) / elapsed_ns;

    std.debug.print("Expected items:  {d}\n", .{items_per_worker * 8});
    std.debug.print("Processed:       {d}\n", .{recv_ok});
    std.debug.print("Total ops:       {d} (send+recv)\n", .{total_ops});
    std.debug.print("Elapsed:         ", .{});
    formatNs(elapsed_ns);
    std.debug.print("\nPer-op:          ", .{});
    formatNs(ns_per_op);
    std.debug.print("\nThroughput:      {d} ops/sec\n", .{ops_per_sec});

    // Stats
    std.debug.print("\nOperation Stats:\n", .{});
    std.debug.print("  Send OK:      {d}\n", .{send_ok});
    std.debug.print("  Send Retries: {d} ({d:.2}%%)\n", .{ send_retries, if (send_ok > 0) @as(f64, @floatFromInt(send_retries)) * 100.0 / @as(f64, @floatFromInt(send_ok + send_retries)) else 0.0 });
    std.debug.print("  Recv OK:      {d}\n", .{recv_ok});
    std.debug.print("  Recv Null:    {d} ({d:.2}%%)\n", .{ recv_null, if (recv_ok > 0) @as(f64, @floatFromInt(recv_null)) * 100.0 / @as(f64, @floatFromInt(recv_ok + recv_null)) else 0.0 });
}

// =============================================================================
// Benchmark 4: Work-Stealing Test (Imbalanced Load)
// Tests work-stealing when some workers are busier than others
// =============================================================================
fn benchWorkStealingImbalanced() !void {
    const allocator = std.heap.c_allocator;
    // Increased capacities: 128→256 local, 2048→4096 global
    const Channel = DequeChannel(u64, 256, 4096);

    std.debug.print("\n=== Work-Stealing Test (Imbalanced Load) ===\n", .{});
    std.debug.print("Config: local=256, global=4096 (counter-based drain)\n", .{});
    std.debug.print("Pattern: Worker 0 produces 80%%, workers 1-7 produce 20%%\n", .{});
    std.debug.print("Phase 1: Produce (recv on backpressure), Phase 2: Drain via stealing\n\n", .{});

    var result = try Channel.init(allocator, 8);
    defer result.channel.deinit(&result.workers);

    const worker0_items: usize = 320_000;
    const other_worker_items: usize = 11_429; // 7 workers × 11,429 = 80,003
    const total_items: usize = worker0_items + (7 * other_worker_items); // 400,003 exact

    var consumed_counts: [8]Atomic(usize) = undefined;
    for (&consumed_counts) |*count| {
        count.* = Atomic(usize).init(0);
    }

    // Atomic counters for stats
    var total_send_ok = Atomic(usize).init(0);
    var total_send_retries = Atomic(usize).init(0);
    var total_recv_ok = Atomic(usize).init(0);
    var total_recv_null = Atomic(usize).init(0);

    // Global counter for completion detection
    var global_consumed = Atomic(usize).init(0);

    const start = std.time.nanoTimestamp();

    // Spawn 8 workers, each is both producer and consumer
    var workers: [8]Thread = undefined;
    for (&workers, 0..) |*worker, idx| {
        const items_to_produce = if (idx == 0) worker0_items else other_worker_items;

        worker.* = try Thread.spawn(.{}, struct {
            fn run(
                w: *Channel.Worker,
                produce_count: usize,
                total_target: usize,
                counter: *Atomic(usize),
                global_counter: *Atomic(usize),
                send_ok: *Atomic(usize),
                send_retries: *Atomic(usize),
                recv_ok: *Atomic(usize),
                recv_null: *Atomic(usize),
            ) void {
                var consumed: usize = 0;
                var local_send_ok: usize = 0;
                var local_send_retries: usize = 0;
                var local_recv_null: usize = 0;

                // Phase 1: Produce items (recv ONLY on backpressure)
                var i: usize = 0;
                while (i < produce_count) : (i += 1) {
                    while (true) {
                        w.send(i) catch |err| {
                            if (err == error.Full) {
                                local_send_retries += 1;
                                // Backpressure: must consume to make room
                                if (w.recv()) |_| {
                                    consumed += 1;
                                    _ = global_counter.fetchAdd(1, .monotonic);
                                }
                                Thread.yield() catch {};
                                continue;
                            }
                            std.debug.print("Send error: {}\n", .{err});
                            return;
                        };
                        local_send_ok += 1;
                        break;
                    }
                    // NO recv here - let work accumulate for stealing
                }

                // Phase 2: Drain until all items consumed globally
                while (global_counter.load(.monotonic) < total_target) {
                    if (w.recv()) |_| {
                        consumed += 1;
                        _ = global_counter.fetchAdd(1, .monotonic);
                    } else {
                        local_recv_null += 1;
                        Thread.yield() catch {};
                    }
                }

                counter.store(consumed, .monotonic);
                _ = send_ok.fetchAdd(local_send_ok, .monotonic);
                _ = send_retries.fetchAdd(local_send_retries, .monotonic);
                _ = recv_ok.fetchAdd(consumed, .monotonic);
                _ = recv_null.fetchAdd(local_recv_null, .monotonic);
            }
        }.run, .{
            &result.workers[idx],
            items_to_produce,
            total_items,
            &consumed_counts[idx],
            &global_consumed,
            &total_send_ok,
            &total_send_retries,
            &total_recv_ok,
            &total_recv_null,
        });
    }

    // Wait for all workers to complete
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

    const send_ok = total_send_ok.load(.monotonic);
    const send_retries = total_send_retries.load(.monotonic);
    const recv_ok = total_recv_ok.load(.monotonic);
    const recv_null = total_recv_null.load(.monotonic);

    const elapsed_ns: u64 = @intCast(end - start);
    const items_per_sec = (total_consumed * 1_000_000_000) / elapsed_ns;

    const items_lost = if (send_ok > total_consumed) send_ok - total_consumed else 0;

    std.debug.print("Total items:     {d}\n", .{total_items});
    std.debug.print("Sent OK:         {d}\n", .{send_ok});
    std.debug.print("Consumed:        {d}\n", .{total_consumed});
    std.debug.print("Items Lost:      {d}", .{items_lost});
    if (items_lost > 0) {
        std.debug.print(" *** ERROR ***", .{});
    } else {
        std.debug.print(" (OK)", .{});
    }
    std.debug.print("\nElapsed:         ", .{});
    formatNs(elapsed_ns);
    std.debug.print("\nThroughput:      {d} items/sec\n", .{items_per_sec});
    std.debug.print("\nLoad Distribution:\n", .{});
    std.debug.print("  Min:  {d} items\n", .{min});
    std.debug.print("  Max:  {d} items\n", .{max});
    std.debug.print("  Avg:  {d} items\n", .{total_consumed / 8});

    // Stats
    std.debug.print("\nOperation Stats:\n", .{});
    std.debug.print("  Send OK:      {d}\n", .{send_ok});
    std.debug.print("  Send Retries: {d} ({d:.2}%%)\n", .{ send_retries, if (send_ok > 0) @as(f64, @floatFromInt(send_retries)) * 100.0 / @as(f64, @floatFromInt(send_ok + send_retries)) else 0.0 });
    std.debug.print("  Recv OK:      {d}\n", .{recv_ok});
    std.debug.print("  Recv Null:    {d} ({d:.2}%%)\n", .{ recv_null, if (recv_ok > 0) @as(f64, @floatFromInt(recv_null)) * 100.0 / @as(f64, @floatFromInt(recv_ok + recv_null)) else 0.0 });

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
    try bench8WorkersProducerConsumer();
    try benchWorkStealingImbalanced();

    std.debug.print("\n✓ All benchmarks completed\n\n", .{});
}
