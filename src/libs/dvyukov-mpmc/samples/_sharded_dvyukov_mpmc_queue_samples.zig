const std = @import("std");
const Thread = std.Thread;
const Atomic = std.atomic.Value;
const ShardedDVyukovMPMCQueue = @import("sharded-dvyukov-mpmc").ShardedDVyukovMPMCQueue;

/// Sharded DVyukov MPMC Queue - Sample Usage
///
/// This standalone application demonstrates various usage patterns of the sharded queue
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) {
            std.debug.print("WARNING: Memory leak detected!\n", .{});
        }
    }
    const allocator = gpa.allocator();

    std.debug.print("\n=== Sharded DVyukov MPMC Queue Samples ===\n\n", .{});

    try sample1_basicUsage(allocator);
    try sample2_threadAffinity(allocator);
    try sample3_highContention(allocator);
    try sample4_monitoring(allocator);

    std.debug.print("\n=== All Samples Complete ===\n", .{});
}

/// Sample 1: Basic single-threaded usage with shards
fn sample1_basicUsage(allocator: std.mem.Allocator) !void {
    std.debug.print("=== Sample 1: Basic Usage (4 shards) ===\n", .{});

    // Create a sharded queue with 4 shards, 16 capacity each
    var queue = try ShardedDVyukovMPMCQueue(u32, 4, 16).init(allocator);
    defer queue.deinit();

    std.debug.print("Total capacity: {} (4 shards x 16)\n", .{queue.totalCapacity()});
    std.debug.print("Number of shards: {}\n", .{queue.shardCount()});

    // Enqueue to different shards
    try queue.enqueueToShard(0, 100);
    try queue.enqueueToShard(1, 200);
    try queue.enqueueToShard(2, 300);
    try queue.enqueueToShard(3, 400);

    std.debug.print("Total items: {}\n", .{queue.totalSize()});

    // Dequeue from corresponding shards
    std.debug.print("Shard 0: {?}\n", .{queue.dequeueFromShard(0)});
    std.debug.print("Shard 1: {?}\n", .{queue.dequeueFromShard(1)});
    std.debug.print("Shard 2: {?}\n", .{queue.dequeueFromShard(2)});
    std.debug.print("Shard 3: {?}\n\n", .{queue.dequeueFromShard(3)});
}

/// Sample 2: Thread-affinity pattern (recommended)
fn sample2_threadAffinity(allocator: std.mem.Allocator) !void {
    std.debug.print("=== Sample 2: Thread-Affinity Pattern ===\n", .{});

    const num_threads = 4;
    const num_shards = 4; // Optimal: 1 thread per shard
    const items_per_thread = 100;

    var queue = try ShardedDVyukovMPMCQueue(u64, num_shards, 128).init(allocator);
    defer queue.deinit();

    const WorkerCtx = struct {
        queue: *ShardedDVyukovMPMCQueue(u64, num_shards, 128),
        thread_id: usize,
        start_flag: *Atomic(u8),
        is_producer: bool,

        fn run(ctx: *@This()) void {
            // Wait for all threads to be ready
            while (ctx.start_flag.load(.seq_cst) == 0) {
                Thread.yield() catch {};
            }

            // Each thread uses its own shard (thread affinity)
            const my_shard = ctx.thread_id % num_shards;

            if (ctx.is_producer) {
                var i: u64 = 0;
                while (i < items_per_thread) : (i += 1) {
                    ctx.queue.enqueueToShard(my_shard, i) catch {
                        Thread.yield() catch {};
                        continue;
                    };
                }
            } else {
                var count: u64 = 0;
                while (count < items_per_thread) {
                    if (ctx.queue.dequeueFromShard(my_shard)) |_| {
                        count += 1;
                    } else {
                        Thread.yield() catch {};
                    }
                }
            }
        }
    };

    var start_flag = Atomic(u8).init(0);
    const handles = try allocator.alloc(Thread, num_threads * 2);
    defer allocator.free(handles);
    const contexts = try allocator.alloc(WorkerCtx, num_threads * 2);
    defer allocator.free(contexts);

    // Spawn producers
    var i: usize = 0;
    while (i < num_threads) : (i += 1) {
        contexts[i] = .{
            .queue = &queue,
            .thread_id = i,
            .start_flag = &start_flag,
            .is_producer = true,
        };
        handles[i] = try Thread.spawn(.{}, WorkerCtx.run, .{&contexts[i]});
    }

    // Spawn consumers
    while (i < num_threads * 2) : (i += 1) {
        contexts[i] = .{
            .queue = &queue,
            .thread_id = i - num_threads,
            .start_flag = &start_flag,
            .is_producer = false,
        };
        handles[i] = try Thread.spawn(.{}, WorkerCtx.run, .{&contexts[i]});
    }

    std.debug.print("Starting {} producers + {} consumers...\n", .{ num_threads, num_threads });
    start_flag.store(1, .seq_cst);

    for (handles) |h| h.join();

    std.debug.print("Completed! Total items processed: {}\n", .{num_threads * items_per_thread});
    std.debug.print("Final queue size: {}\n\n", .{queue.totalSize()});
}

/// Sample 3: High contention scenario (8P/8C with sharding)
fn sample3_highContention(allocator: std.mem.Allocator) !void {
    std.debug.print("=== Sample 3: High Contention (8P/8C) ===\n", .{});

    const num_producers = 8;
    const num_consumers = 8;
    const num_shards = 8; // 1P+1C per shard = optimal
    const items_per_producer = 10_000;

    var queue = try ShardedDVyukovMPMCQueue(u64, num_shards, 256).init(allocator);
    defer queue.deinit();

    const WorkerCtx = struct {
        queue: *ShardedDVyukovMPMCQueue(u64, num_shards, 256),
        shard_id: usize,
        iterations: usize,
        start_flag: *Atomic(u8),
        is_producer: bool,

        fn run(ctx: *@This()) void {
            while (ctx.start_flag.load(.seq_cst) == 0) {
                Thread.yield() catch {};
            }

            if (ctx.is_producer) {
                var i: u64 = 0;
                while (i < ctx.iterations) : (i += 1) {
                    while (true) {
                        ctx.queue.enqueueToShard(ctx.shard_id, i) catch {
                            Thread.yield() catch {};
                            continue;
                        };
                        break;
                    }
                }
            } else {
                var count: u64 = 0;
                while (count < ctx.iterations) {
                    if (ctx.queue.dequeueFromShard(ctx.shard_id)) |_| {
                        count += 1;
                    } else {
                        Thread.yield() catch {};
                    }
                }
            }
        }
    };

    var start_flag = Atomic(u8).init(0);
    const total_threads = num_producers + num_consumers;
    const handles = try allocator.alloc(Thread, total_threads);
    defer allocator.free(handles);
    const contexts = try allocator.alloc(WorkerCtx, total_threads);
    defer allocator.free(contexts);

    // Spawn producers
    var i: usize = 0;
    while (i < num_producers) : (i += 1) {
        contexts[i] = .{
            .queue = &queue,
            .shard_id = i % num_shards,
            .iterations = items_per_producer,
            .start_flag = &start_flag,
            .is_producer = true,
        };
        handles[i] = try Thread.spawn(.{}, WorkerCtx.run, .{&contexts[i]});
    }

    // Spawn consumers
    while (i < total_threads) : (i += 1) {
        contexts[i] = .{
            .queue = &queue,
            .shard_id = (i - num_producers) % num_shards,
            .iterations = items_per_producer,
            .start_flag = &start_flag,
            .is_producer = false,
        };
        handles[i] = try Thread.spawn(.{}, WorkerCtx.run, .{&contexts[i]});
    }

    var timer = try std.time.Timer.start();
    start_flag.store(1, .seq_cst);
    for (handles) |h| h.join();
    const elapsed_ns = timer.read();

    const total_ops = num_producers * items_per_producer * 2; // enq + deq
    const ops_per_sec = @as(f64, @floatFromInt(total_ops)) / (@as(f64, @floatFromInt(elapsed_ns)) / 1e9);

    std.debug.print("Processed {} operations in {d:.2}ms\n", .{
        total_ops,
        @as(f64, @floatFromInt(elapsed_ns)) / 1e6,
    });
    std.debug.print("Throughput: {d:.2} Mops/s\n\n", .{ops_per_sec / 1_000_000});
}

/// Sample 4: Monitoring and diagnostics
fn sample4_monitoring(allocator: std.mem.Allocator) !void {
    std.debug.print("=== Sample 4: Monitoring Individual Shards ===\n", .{});

    var queue = try ShardedDVyukovMPMCQueue(u64, 4, 16).init(allocator);
    defer queue.deinit();

    // Fill shards unevenly
    try queue.enqueueToShard(0, 1);
    try queue.enqueueToShard(0, 2);
    try queue.enqueueToShard(0, 3);

    try queue.enqueueToShard(1, 10);

    try queue.enqueueToShard(3, 100);
    try queue.enqueueToShard(3, 101);

    // Monitor individual shards
    std.debug.print("Shard status:\n", .{});
    var i: usize = 0;
    while (i < queue.shardCount()) : (i += 1) {
        std.debug.print("  Shard {}: size={}, empty={}, full={}\n", .{
            i,
            queue.shardSize(i),
            queue.isShardEmpty(i),
            queue.isShardFull(i),
        });
    }

    std.debug.print("Total size across all shards: {}\n", .{queue.totalSize()});

    // Drain specific shard
    std.debug.print("\nDraining shard 0:\n", .{});
    while (queue.dequeueFromShard(0)) |item| {
        std.debug.print("  {}\n", .{item});
    }

    std.debug.print("Shard 0 now empty: {}\n\n", .{queue.isShardEmpty(0)});
}
