const std = @import("std");
const SegmentedQueueMod = @import("segmented-queue");
const ebr = @import("ebr");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        std.debug.print("SegmentedQueue EBR stress leak status: {any}\n", .{leaked});
    }
    const allocator = gpa.allocator();

    // Initialize EBR collector
    var collector = try ebr.Collector.init(allocator);
    defer collector.deinit();

    const Queue = SegmentedQueueMod.SegmentedQueue(u64, 64);

    var queue = try Queue.init(allocator, &collector);
    defer queue.deinit();

    const producer_count: usize = 2;
    const consumer_count: usize = 2;
    const total_items: usize = 200_000;
    const items_per_producer = total_items / producer_count;

    const AtomicUsize = std.atomic.Value(usize);
    var consumed = AtomicUsize.init(0);
    var produced = AtomicUsize.init(0);
    var enqueue_errors = AtomicUsize.init(0);
    var empty_polls = AtomicUsize.init(0);

    const ThreadArgs = struct {
        queue: *Queue,
        collector: *ebr.Collector,
        index: usize,
        items_per_producer: usize,
        consumed: *AtomicUsize,
        total_items: usize,
        produced: *AtomicUsize,
        enqueue_errors: *AtomicUsize,
        empty_polls: *AtomicUsize,
    };

    const Producer = struct {
        fn run(args: *ThreadArgs) void {
            // Register thread with EBR collector
            const handle = args.collector.registerThread() catch {
                std.debug.print("Producer {d} failed to register thread\n", .{args.index});
                return;
            };
            defer args.collector.unregisterThread(handle);

            const start = args.index * args.items_per_producer;
            const end = start + args.items_per_producer;

            var i: usize = start;
            while (i < end) : (i += 1) {
                args.queue.enqueueWithAutoGuard(@intCast(i)) catch {
                    _ = args.enqueue_errors.fetchAdd(1, .monotonic);
                    std.debug.print("Producer {d} error at item {d}\n", .{ args.index, i });
                    break;
                };

                _ = args.produced.fetchAdd(1, .monotonic);

                if ((i & 0xFF) == 0) {
                    std.Thread.yield() catch {};
                }
            }
            std.debug.print("Producer {d} completed\n", .{args.index});
        }
    };

    const Consumer = struct {
        fn run(args: *ThreadArgs) void {
            // Register thread with EBR collector
            const handle = args.collector.registerThread() catch {
                std.debug.print("Consumer {d} failed to register thread\n", .{args.index});
                return;
            };
            defer args.collector.unregisterThread(handle);

            var local_consumed: usize = 0;
            var empty_streak: usize = 0;
            while (true) {
                const current = args.consumed.load(.monotonic);
                if (current >= args.total_items) {
                    std.debug.print("Consumer {d} exiting, consumed {d} items\n", .{ args.index, local_consumed });
                    return;
                }

                // Use auto-guard version for simpler code
                if (args.queue.dequeueWithAutoGuard()) |_| {
                    _ = args.consumed.fetchAdd(1, .monotonic);
                    local_consumed += 1;
                    empty_streak = 0;
                } else {
                    _ = args.empty_polls.fetchAdd(1, .monotonic);
                    empty_streak += 1;

                    if (empty_streak % 10000 == 0) {
                        const global_consumed = args.consumed.load(.monotonic);
                        const global_produced = args.produced.load(.monotonic);
                        std.debug.print("Consumer {d} stuck: local={d}, global_consumed={d}, global_produced={d}, empty_streak={d}\n", .{
                            args.index,
                            local_consumed,
                            global_consumed,
                            global_produced,
                            empty_streak,
                        });
                    }

                    std.Thread.yield() catch {};
                }
            }
        }
    };

    var producers: [producer_count]std.Thread = undefined;
    var consumers: [consumer_count]std.Thread = undefined;

    var producer_args: [producer_count]ThreadArgs = undefined;
    var consumer_args: [consumer_count]ThreadArgs = undefined;

    std.debug.print("\n=== Starting SegmentedQueue benchmark ===\n", .{});
    std.debug.print("Producers: {d}, Consumers: {d}, Total items: {d}\n\n", .{ producer_count, consumer_count, total_items });

    const start_ns = std.time.nanoTimestamp();

    var p_idx: usize = 0;
    while (p_idx < producer_count) : (p_idx += 1) {
        producer_args[p_idx] = .{
            .queue = &queue,
            .collector = &collector,
            .index = p_idx,
            .items_per_producer = items_per_producer,
            .consumed = &consumed,
            .total_items = total_items,
            .produced = &produced,
            .enqueue_errors = &enqueue_errors,
            .empty_polls = &empty_polls,
        };
        producers[p_idx] = try std.Thread.spawn(.{}, Producer.run, .{&producer_args[p_idx]});
    }

    var c_idx: usize = 0;
    while (c_idx < consumer_count) : (c_idx += 1) {
        consumer_args[c_idx] = .{
            .queue = &queue,
            .collector = &collector,
            .index = c_idx,
            .items_per_producer = items_per_producer,
            .consumed = &consumed,
            .total_items = total_items,
            .produced = &produced,
            .enqueue_errors = &enqueue_errors,
            .empty_polls = &empty_polls,
        };
        consumers[c_idx] = try std.Thread.spawn(.{}, Consumer.run, .{&consumer_args[c_idx]});
    }

    for (producers) |t| t.join();

    std.debug.print("\n=== All producers done, waiting for consumers ===\n", .{});
    std.debug.print("Produced: {d}, Consumed: {d}, Empty polls: {d}\n\n", .{
        produced.load(.monotonic),
        consumed.load(.monotonic),
        empty_polls.load(.monotonic),
    });

    for (consumers) |t| t.join();

    const end_ns = std.time.nanoTimestamp();
    const elapsed_ns: u64 = @intCast(end_ns - start_ns);
    const elapsed_s = @as(f64, @floatFromInt(elapsed_ns)) / 1e9;

    const produced_total = produced.load(.monotonic);
    const consumed_total = consumed.load(.monotonic);
    const enqueue_err_total = enqueue_errors.load(.monotonic);
    const empty_polls_total = empty_polls.load(.monotonic);

    const throughput = if (elapsed_s > 0.0)
        @as(f64, @floatFromInt(consumed_total)) / elapsed_s
    else
        0.0;

    std.debug.print(
        \\SegmentedQueue EBR stress results:
        \\  producers:        {d}
        \\  consumers:        {d}
        \\  segment_capacity: {d}
        \\  total_items:      {d}
        \\  produced:         {d}
        \\  consumed:         {d}
        \\  enqueue_errors:   {d}
        \\  empty_polls:      {d}
        \\  elapsed_sec:      {d:.3}
        \\  throughput_ops/s: {d:.1}
        \\
        ,
        .{
            producer_count,
            consumer_count,
            64,
            total_items,
            produced_total,
            consumed_total,
            enqueue_err_total,
            empty_polls_total,
            elapsed_s,
            throughput,
        },
    );
}
