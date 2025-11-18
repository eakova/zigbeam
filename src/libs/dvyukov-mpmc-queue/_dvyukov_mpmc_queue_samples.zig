const std = @import("std");
const DVyukovMPMCQueue = @import("dvyukov_mpmc_queue.zig").DVyukovMPMCQueue;

/// Vyukov Bounded MPMC Queue - Sample Usage
///
/// This standalone application demonstrates various usage patterns of the queue

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) {
            std.debug.print("WARNING: Memory leak detected!\n", .{});
        }
    }
    const allocator = gpa.allocator();

    std.debug.print("\n=== Vyukov Bounded MPMC Queue Samples ===\n\n", .{});

    try sample1_basicUsage(allocator);
    try sample2_producerConsumer(allocator);
    try sample3_multiThreaded(allocator);
    try sample4_customTypes(allocator);

    std.debug.print("\n=== All Samples Complete ===\n", .{});
}

/// Sample 1: Basic single-threaded usage
fn sample1_basicUsage(allocator: std.mem.Allocator) !void {
    std.debug.print("=== Sample 1: Basic Usage ===\n", .{});

    var queue = try DVyukovMPMCQueue(u32, 8).init(allocator);
    defer queue.deinit();

    // Enqueue some items
    try queue.enqueue(10);
    try queue.enqueue(20);
    try queue.enqueue(30);

    std.debug.print("Queue size: {}\n", .{queue.size()});

    // Dequeue items
    while (queue.dequeue()) |item| {
        std.debug.print("  Dequeued: {}\n", .{item});
    }

    std.debug.print("Queue empty: {}\n\n", .{queue.isEmpty()});
}

/// Sample 2: Simple producer-consumer pattern
fn sample2_producerConsumer(allocator: std.mem.Allocator) !void {
    std.debug.print("=== Sample 2: Producer-Consumer Pattern ===\n", .{});

    var queue = try DVyukovMPMCQueue(usize, 16).init(allocator);
    defer queue.deinit();

    // Producer: generate 20 items
    std.debug.print("Producer: Enqueueing 20 items...\n", .{});
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        queue.enqueue(i) catch {
            std.debug.print("  Queue full at item {}\n", .{i});
            break;
        };
    }

    std.debug.print("Producer: Enqueued {} items\n", .{queue.size()});

    // Consumer: process all items
    std.debug.print("Consumer: Processing items...\n", .{});
    var count: usize = 0;
    while (queue.dequeue()) |item| {
        count += 1;
        if (count <= 5 or count > 15) {
            std.debug.print("  Processing item: {}\n", .{item});
        } else if (count == 6) {
            std.debug.print("  ...\n", .{});
        }
    }

    std.debug.print("Consumer: Processed {} items\n\n", .{count});
}

/// Sample 3: Multi-threaded usage
fn sample3_multiThreaded(allocator: std.mem.Allocator) !void {
    std.debug.print("=== Sample 3: Multi-threaded Usage ===\n", .{});

    var queue = try DVyukovMPMCQueue(usize, 256).init(allocator);
    defer queue.deinit();

    const num_producers = 2;
    const num_consumers = 2;
    const items_per_producer = 100;

    var produced = std.atomic.Value(usize).init(0);
    var consumed = std.atomic.Value(usize).init(0);

    const ProducerContext = struct {
        queue: *DVyukovMPMCQueue(usize, 256),
        id: usize,
        count: *std.atomic.Value(usize),
    };

    const ConsumerContext = struct {
        queue: *DVyukovMPMCQueue(usize, 256),
        id: usize,
        count: *std.atomic.Value(usize),
    };

    const producer_fn = struct {
        fn run(ctx: ProducerContext) void {
            var i: usize = 0;
            while (i < items_per_producer) : (i += 1) {
                const value = ctx.id * 1000 + i;
                while (true) {
                    ctx.queue.enqueue(value) catch {
                        // Yield to scheduler, fall back to spinLoopHint if yield fails
                        std.Thread.yield() catch {
                            std.atomic.spinLoopHint();
                        };
                        continue;
                    };
                    break;
                }
                _ = ctx.count.fetchAdd(1, .monotonic);
            }
        }
    }.run;

    const consumer_fn = struct {
        fn run(ctx: ConsumerContext) void {
            var local_count: usize = 0;
            while (local_count < items_per_producer) {
                if (ctx.queue.dequeue()) |_| {
                    local_count += 1;
                    _ = ctx.count.fetchAdd(1, .monotonic);
                } else {
                    // Yield to scheduler, fall back to spinLoopHint if yield fails
                    std.Thread.yield() catch {
                        std.atomic.spinLoopHint();
                    };
                }
            }
        }
    }.run;

    // Spawn producers
    var producers: [num_producers]std.Thread = undefined;
    for (&producers, 0..) |*thread, id| {
        thread.* = try std.Thread.spawn(.{}, producer_fn, .{ProducerContext{
            .queue = &queue,
            .id = id,
            .count = &produced,
        }});
    }

    // Spawn consumers
    var consumers: [num_consumers]std.Thread = undefined;
    for (&consumers, 0..) |*thread, id| {
        thread.* = try std.Thread.spawn(.{}, consumer_fn, .{ConsumerContext{
            .queue = &queue,
            .id = id,
            .count = &consumed,
        }});
    }

    // Wait for producers
    for (producers) |thread| {
        thread.join();
    }
    std.debug.print("All producers finished. Produced: {}\n", .{produced.load(.monotonic)});

    // Wait for consumers
    for (consumers) |thread| {
        thread.join();
    }
    std.debug.print("All consumers finished. Consumed: {}\n", .{consumed.load(.monotonic)});

    std.debug.print("Queue final size: {}\n\n", .{queue.size()});
}

/// Sample 4: Custom types
fn sample4_customTypes(allocator: std.mem.Allocator) !void {
    std.debug.print("=== Sample 4: Custom Types ===\n", .{});

    const Task = struct {
        id: u32,
        priority: u8,
        name: []const u8,
    };

    var queue = try DVyukovMPMCQueue(Task, 8).init(allocator);
    defer queue.deinit();

    // Enqueue tasks
    try queue.enqueue(.{ .id = 1, .priority = 5, .name = "Task A" });
    try queue.enqueue(.{ .id = 2, .priority = 3, .name = "Task B" });
    try queue.enqueue(.{ .id = 3, .priority = 8, .name = "Task C" });

    std.debug.print("Processing tasks:\n", .{});
    while (queue.dequeue()) |task| {
        std.debug.print("  Task {}: {s} (priority: {})\n", .{ task.id, task.name, task.priority });
    }

    std.debug.print("\n", .{});
}
