const std = @import("std");
const SegmentedQueueMod = @import("beam-segmented-queue");
const ebr = @import("beam-ebr");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const Queue = SegmentedQueueMod.SegmentedQueue(u64, 64);

    std.debug.print("\n=== EBR Garbage Queue Pressure Diagnostic ===\n\n", .{});
    std.debug.print("Global queue capacity: {d} items\n", .{64 * 64}); // MAX_PARTICIPANTS * 64
    std.debug.print("Collection threshold: {d} items\n\n", .{64 * 8}); // MAX_PARTICIPANTS * 8

    // Test 1: Light load (2P/2C, 1M items)
    {
        std.debug.print("Test 1: Light load (2P/2C, 1M items)\n", .{});
        var queue = try Queue.init(allocator);
        defer queue.deinit();

        const producer_count: usize = 2;
        const consumer_count: usize = 2;
        const total_items: usize = 1_000_000;
        const items_per_producer = total_items / producer_count;

        const AtomicUsize = std.atomic.Value(usize);
        var consumed = AtomicUsize.init(0);
        var produced = AtomicUsize.init(0);

        const ThreadArgs = struct {
            queue: *Queue,
            index: usize,
            items_per_producer: usize,
            consumed: *AtomicUsize,
            total_items: usize,
            produced: *AtomicUsize,
        };

        const Producer = struct {
            fn run(args: *ThreadArgs) !void {
                const participant = try args.queue.createParticipant();
                defer args.queue.destroyParticipant(participant);

                const start = args.index * args.items_per_producer;
                const end = start + args.items_per_producer;

                var i: usize = start;
                while (i < end) : (i += 1) {
                    try args.queue.enqueue(@intCast(i));
                    _ = args.produced.fetchAdd(1, .monotonic);
                }
                std.debug.print("Producer {d} completed\n", .{args.index});
            }
        };

        const Consumer = struct {
            fn run(args: *ThreadArgs) !void {
                const participant = try args.queue.createParticipant();
                defer args.queue.destroyParticipant(participant);

                var local_consumed: usize = 0;
                const batch_size: usize = 10_000; // Larger batch for better throughput

                while (true) {
                    const current = args.consumed.load(.monotonic);
                    if (current >= args.total_items) {
                        std.debug.print("Consumer {d} exiting, consumed {d} items\n", .{ args.index, local_consumed });
                        return;
                    }

                    // Pin guard for a batch of operations, then release
                    // This amortizes guard overhead while still allowing epoch advancement
                    var guard = ebr.pin();
                    var batch_consumed: usize = 0;
                    while (batch_consumed < batch_size) {
                        if (args.queue.dequeue(&guard)) |_| {
                            _ = args.consumed.fetchAdd(1, .monotonic);
                            local_consumed += 1;
                            batch_consumed += 1;
                        } else {
                            break; // Queue empty, release guard and yield
                        }
                    }
                    guard.deinit(); // Release guard to allow epoch advancement

                    if (batch_consumed == 0) {
                        std.Thread.yield() catch {};
                    }
                }
            }
        };

        var producers: [2]std.Thread = undefined;
        var consumers: [2]std.Thread = undefined;
        var producer_args: [2]ThreadArgs = undefined;
        var consumer_args: [2]ThreadArgs = undefined;

        const start_ns = std.time.nanoTimestamp();

        for (0..producer_count) |i| {
            producer_args[i] = .{
                .queue = &queue,
                .index = i,
                .items_per_producer = items_per_producer,
                .consumed = &consumed,
                .total_items = total_items,
                .produced = &produced,
            };
            producers[i] = try std.Thread.spawn(.{}, Producer.run, .{&producer_args[i]});
        }

        for (0..consumer_count) |i| {
            consumer_args[i] = .{
                .queue = &queue,
                .index = i,
                .items_per_producer = items_per_producer,
                .consumed = &consumed,
                .total_items = total_items,
                .produced = &produced,
            };
            consumers[i] = try std.Thread.spawn(.{}, Consumer.run, .{&consumer_args[i]});
        }

        for (producers) |t| t.join();
        for (consumers) |t| t.join();

        const end_ns = std.time.nanoTimestamp();
        const elapsed_s = @as(f64, @floatFromInt(@as(u64, @intCast(end_ns - start_ns)))) / 1e9;

        // Give reclaimer thread time to clean up
        std.Thread.sleep(100_000_000); // 100ms

        const global_epoch = ebr.global();
        var remaining: usize = 0;
        while (global_epoch.global_garbage_queue.dequeue()) |_| {
            remaining += 1;
        }

        std.debug.print("  Elapsed: {d:.3}s\n", .{elapsed_s});
        std.debug.print("  Remaining garbage after 100ms cooldown: {d} items\n", .{remaining});
        std.debug.print("  Queue utilization: {d:.1}%\n\n", .{@as(f64, @floatFromInt(remaining)) / 4096.0 * 100.0});
    }

    // Test 2: Heavy load (4P/4C, 2M items)
    {
        std.debug.print("Test 2: Heavy load (4P/4C, 2M items)\n", .{});
        var queue = try Queue.init(allocator);
        defer queue.deinit();

        const producer_count: usize = 4;
        const consumer_count: usize = 4;
        const total_items: usize = 2_000_000;
        const items_per_producer = total_items / producer_count;

        const AtomicUsize = std.atomic.Value(usize);
        var consumed = AtomicUsize.init(0);
        var produced = AtomicUsize.init(0);

        const ThreadArgs = struct {
            queue: *Queue,
            index: usize,
            items_per_producer: usize,
            consumed: *AtomicUsize,
            total_items: usize,
            produced: *AtomicUsize,
        };

        const Producer = struct {
            fn run(args: *ThreadArgs) !void {
                const participant = try args.queue.createParticipant();
                defer args.queue.destroyParticipant(participant);

                const start = args.index * args.items_per_producer;
                const end = start + args.items_per_producer;

                var i: usize = start;
                while (i < end) : (i += 1) {
                    try args.queue.enqueue(@intCast(i));
                    _ = args.produced.fetchAdd(1, .monotonic);
                }
                std.debug.print("Producer {d} completed\n", .{args.index});
            }
        };

        const Consumer = struct {
            fn run(args: *ThreadArgs) !void {
                const participant = try args.queue.createParticipant();
                defer args.queue.destroyParticipant(participant);

                var local_consumed: usize = 0;
                const batch_size: usize = 10_000; // Larger batch for better throughput

                while (true) {
                    const current = args.consumed.load(.monotonic);
                    if (current >= args.total_items) {
                        std.debug.print("Consumer {d} exiting, consumed {d} items\n", .{ args.index, local_consumed });
                        return;
                    }

                    // Pin guard for a batch of operations, then release
                    // This amortizes guard overhead while still allowing epoch advancement
                    var guard = ebr.pin();
                    var batch_consumed: usize = 0;
                    while (batch_consumed < batch_size) {
                        if (args.queue.dequeue(&guard)) |_| {
                            _ = args.consumed.fetchAdd(1, .monotonic);
                            local_consumed += 1;
                            batch_consumed += 1;
                        } else {
                            break; // Queue empty, release guard and yield
                        }
                    }
                    guard.deinit(); // Release guard to allow epoch advancement

                    if (batch_consumed == 0) {
                        std.Thread.yield() catch {};
                    }
                }
            }
        };

        var producers: [4]std.Thread = undefined;
        var consumers: [4]std.Thread = undefined;
        var producer_args: [4]ThreadArgs = undefined;
        var consumer_args: [4]ThreadArgs = undefined;

        const start_ns = std.time.nanoTimestamp();

        for (0..producer_count) |i| {
            producer_args[i] = .{
                .queue = &queue,
                .index = i,
                .items_per_producer = items_per_producer,
                .consumed = &consumed,
                .total_items = total_items,
                .produced = &produced,
            };
            producers[i] = try std.Thread.spawn(.{}, Producer.run, .{&producer_args[i]});
        }

        for (0..consumer_count) |i| {
            consumer_args[i] = .{
                .queue = &queue,
                .index = i,
                .items_per_producer = items_per_producer,
                .consumed = &consumed,
                .total_items = total_items,
                .produced = &produced,
            };
            consumers[i] = try std.Thread.spawn(.{}, Consumer.run, .{&consumer_args[i]});
        }

        for (producers) |t| t.join();
        for (consumers) |t| t.join();

        const end_ns = std.time.nanoTimestamp();
        const elapsed_s = @as(f64, @floatFromInt(@as(u64, @intCast(end_ns - start_ns)))) / 1e9;

        // Give reclaimer thread time to clean up
        std.Thread.sleep(100_000_000); // 100ms

        const global_epoch = ebr.global();
        var remaining: usize = 0;
        while (global_epoch.global_garbage_queue.dequeue()) |_| {
            remaining += 1;
        }

        std.debug.print("  Elapsed: {d:.3}s\n", .{elapsed_s});
        std.debug.print("  Remaining garbage after 100ms cooldown: {d} items\n", .{remaining});
        std.debug.print("  Queue utilization: {d:.1}%\n\n", .{@as(f64, @floatFromInt(remaining)) / 4096.0 * 100.0});
    }

    std.debug.print("=== Analysis ===\n", .{});
    std.debug.print("The global garbage queue has capacity for 4096 items.\n", .{});
    std.debug.print("Remaining garbage indicates peak utilization during the test.\n", .{});
    std.debug.print("Low utilization (<20%%) means the queue is effectively sized.\n", .{});
    std.debug.print("High utilization (>50%%) suggests potential backpressure under load.\n\n", .{});
}
