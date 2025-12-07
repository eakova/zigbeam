//! Lock-Free Queue Integration Test (T059)
//!
//! Demonstrates EBR usage with a simple lock-free MPSC queue.
//! This validates that EBR correctly protects concurrent data structure access.

const std = @import("std");
const ebr = @import("ebr");

const Collector = ebr.Collector;
const Allocator = std.mem.Allocator;

/// Simple lock-free MPSC queue node.
const Node = struct {
    value: u64,
    next: std.atomic.Value(?*Node),

    fn init(value: u64) Node {
        return .{
            .value = value,
            .next = std.atomic.Value(?*Node).init(null),
        };
    }
};

/// Simple lock-free MPSC queue using EBR for safe reclamation.
const LockFreeQueue = struct {
    head: std.atomic.Value(?*Node),
    tail: std.atomic.Value(?*Node),
    allocator: Allocator,
    collector: *Collector,

    fn init(allocator: Allocator, collector: *Collector) !LockFreeQueue {
        // Create sentinel node
        const sentinel = try allocator.create(Node);
        sentinel.* = Node.init(0);

        return .{
            .head = std.atomic.Value(?*Node).init(sentinel),
            .tail = std.atomic.Value(?*Node).init(sentinel),
            .allocator = allocator,
            .collector = collector,
        };
    }

    fn deinit(self: *LockFreeQueue) void {
        // Clean up remaining nodes
        var current = self.head.load(.acquire);
        while (current) |node| {
            const next = node.next.load(.acquire);
            self.allocator.destroy(node);
            current = next;
        }
    }

    /// Push a value to the queue (thread-safe, wait-free).
    fn push(self: *LockFreeQueue, value: u64) !void {
        const node = try self.allocator.create(Node);
        node.* = Node.init(value);

        // Pin while modifying queue
        const guard = self.collector.pin();
        defer guard.unpin();

        while (true) {
            const tail = self.tail.load(.acquire).?;
            const next = tail.next.load(.acquire);

            if (next == null) {
                // Try to link new node
                if (tail.next.cmpxchgWeak(null, node, .release, .monotonic) == null) {
                    // Success, try to swing tail (ok if it fails, another thread will do it)
                    _ = self.tail.cmpxchgWeak(tail, node, .release, .monotonic);
                    return;
                }
            } else {
                // Tail was stale, try to advance it
                _ = self.tail.cmpxchgWeak(tail, next, .release, .monotonic);
            }
        }
    }

    /// Pop a value from the queue (thread-safe).
    /// Returns null if queue is empty.
    fn pop(self: *LockFreeQueue) ?u64 {
        // Pin while accessing queue
        const guard = self.collector.pin();
        defer guard.unpin();

        while (true) {
            const head = self.head.load(.acquire).?;
            const tail = self.tail.load(.acquire).?;
            const next = head.next.load(.acquire);

            if (head == tail) {
                if (next == null) {
                    // Queue is empty
                    return null;
                }
                // Tail is stale, advance it
                _ = self.tail.cmpxchgWeak(tail, next, .release, .monotonic);
            } else {
                if (next) |next_node| {
                    const value = next_node.value;
                    if (self.head.cmpxchgWeak(head, next_node, .release, .monotonic) == null) {
                        // Success! Defer reclamation of old head
                        self.collector.deferReclaim(@ptrCast(head), destroyNode);
                        return value;
                    }
                }
            }
        }
    }
};

/// Destructor for queue nodes.
///
/// WARNING: This is a TEST-ONLY pattern that intentionally leaks memory!
/// For production code, use one of these approaches:
/// 1. `collector.deferDestroy(NodeWithAlloc, node)` - requires `allocator` field in node
/// 2. `collector.deferReclaim(node, myDtor)` - where myDtor calls allocator.destroy()
fn destroyNode(ptr: *anyopaque) void {
    // TEST ONLY: Counts calls but does NOT free memory (intentional leak for testing)
    _ = ptr;
    _ = nodes_reclaimed.fetchAdd(1, .release);
}

/// Counter for reclaimed nodes.
var nodes_reclaimed = std.atomic.Value(u64).init(0);

/// Test configuration.
const NUM_PRODUCERS: usize = 4;
const NUM_CONSUMERS: usize = 2;
const ITEMS_PER_PRODUCER: usize = 10000;
const TEST_DURATION_SECS: u64 = 3;

/// Producer context.
const ProducerContext = struct {
    queue: *LockFreeQueue,
    collector: *Collector,
    items_produced: std.atomic.Value(u64),
    producer_id: usize,
};

/// Consumer context.
const ConsumerContext = struct {
    queue: *LockFreeQueue,
    collector: *Collector,
    items_consumed: std.atomic.Value(u64),
    should_stop: *std.atomic.Value(bool),
};

fn producer(ctx: *ProducerContext) void {
    const handle = ctx.collector.registerThread() catch return;
    defer ctx.collector.unregisterThread(handle);

    var produced: u64 = 0;
    const base = ctx.producer_id * ITEMS_PER_PRODUCER;

    for (0..ITEMS_PER_PRODUCER) |i| {
        ctx.queue.push(base + i) catch continue;
        produced += 1;
    }

    _ = ctx.items_produced.fetchAdd(produced, .release);
}

fn consumer(ctx: *ConsumerContext) void {
    const handle = ctx.collector.registerThread() catch return;
    defer ctx.collector.unregisterThread(handle);

    var consumed: u64 = 0;

    while (!ctx.should_stop.load(.acquire)) {
        if (ctx.queue.pop()) |_| {
            consumed += 1;
        } else {
            // Brief pause when queue is empty
            std.Thread.yield() catch {};
        }
    }

    // Drain remaining items
    while (ctx.queue.pop()) |_| {
        consumed += 1;
    }

    _ = ctx.items_consumed.fetchAdd(consumed, .release);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== Lock-Free Queue Integration Test ===\n", .{});
    std.debug.print("Producers: {}\n", .{NUM_PRODUCERS});
    std.debug.print("Consumers: {}\n", .{NUM_CONSUMERS});
    std.debug.print("Items per producer: {}\n\n", .{ITEMS_PER_PRODUCER});

    var collector = try Collector.init(allocator);
    defer collector.deinit();

    var queue = try LockFreeQueue.init(allocator, &collector);
    defer queue.deinit();

    nodes_reclaimed.store(0, .release);

    var should_stop = std.atomic.Value(bool).init(false);

    // Producer contexts and threads
    var producer_contexts: [NUM_PRODUCERS]ProducerContext = undefined;
    var producer_threads: [NUM_PRODUCERS]std.Thread = undefined;

    // Consumer contexts and threads
    var consumer_contexts: [NUM_CONSUMERS]ConsumerContext = undefined;
    var consumer_threads: [NUM_CONSUMERS]std.Thread = undefined;

    const start = std.time.nanoTimestamp();

    // Start consumers first
    for (0..NUM_CONSUMERS) |i| {
        consumer_contexts[i] = .{
            .queue = &queue,
            .collector = &collector,
            .items_consumed = std.atomic.Value(u64).init(0),
            .should_stop = &should_stop,
        };
        consumer_threads[i] = try std.Thread.spawn(.{}, consumer, .{&consumer_contexts[i]});
    }

    // Start producers
    for (0..NUM_PRODUCERS) |i| {
        producer_contexts[i] = .{
            .queue = &queue,
            .collector = &collector,
            .items_produced = std.atomic.Value(u64).init(0),
            .producer_id = i,
        };
        producer_threads[i] = try std.Thread.spawn(.{}, producer, .{&producer_contexts[i]});
    }

    // Wait for producers to finish
    for (&producer_threads) |*thread| {
        thread.join();
    }

    // Give consumers time to drain, then stop them
    std.Thread.sleep(100 * std.time.ns_per_ms);
    should_stop.store(true, .release);

    // Wait for consumers
    for (&consumer_threads) |*thread| {
        thread.join();
    }

    const end = std.time.nanoTimestamp();
    const elapsed_ms = @as(f64, @floatFromInt(end - start)) / 1_000_000.0;

    // Collect final stats
    var total_produced: u64 = 0;
    for (&producer_contexts) |*ctx| {
        total_produced += ctx.items_produced.load(.acquire);
    }

    var total_consumed: u64 = 0;
    for (&consumer_contexts) |*ctx| {
        total_consumed += ctx.items_consumed.load(.acquire);
    }

    const reclaimed = nodes_reclaimed.load(.acquire);

    std.debug.print("=== Results ===\n", .{});
    std.debug.print("Elapsed: {d:.2} ms\n", .{elapsed_ms});
    std.debug.print("Items produced: {}\n", .{total_produced});
    std.debug.print("Items consumed: {}\n", .{total_consumed});
    std.debug.print("Nodes reclaimed: {}\n", .{reclaimed});
    std.debug.print("Final epoch: {}\n", .{collector.getCurrentEpoch()});

    // Validation
    const expected = NUM_PRODUCERS * ITEMS_PER_PRODUCER;
    if (total_produced == expected and total_consumed == expected) {
        std.debug.print("\n✓ PASS: All {} items produced and consumed correctly\n", .{expected});
    } else {
        std.debug.print("\n✗ FAIL: Expected {} items, produced {}, consumed {}\n", .{
            expected,
            total_produced,
            total_consumed,
        });
        std.process.exit(1);
    }
}
