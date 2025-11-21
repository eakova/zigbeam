//! Performance benchmarks for BoundedSPSCQueue
//!
//! This file contains:
//! 1. Pure throughput benchmarks (zero contention, minimal overhead)
//! 2. Two-thread throughput benchmarks (concurrent producer/consumer)
//! 3. Ping-pong latency benchmarks (round-trip time)

const std = @import("std");
const Thread = std.Thread;
const BoundedSPSCQueue = @import("spsc-queue").BoundedSPSCQueue;

const WARMUP_ITERATIONS = 100_000;
const BENCHMARK_ITERATIONS = 50_000_000;

// ============================================================================
// Pure Throughput Benchmarks (Zero Contention, Minimal Overhead)
// ============================================================================

fn benchmarkPureEnqueue() !void {
    const Queue = BoundedSPSCQueue(u64);
    const capacity = 65536; // Large queue to minimize wrap-around overhead
    var result = try Queue.init(std.heap.page_allocator, capacity);
    defer result.producer.deinit();

    const iterations: u64 = 60_000; // Small enough to never fill queue

    // Warmup
    var i: u64 = 0;
    while (i < 10_000) : (i += 1) {
        _ = try result.producer.enqueue(i);
    }
    // Drain warmup
    i = 0;
    while (i < 10_000) : (i += 1) {
        _ = result.consumer.dequeue();
    }

    // Benchmark: Pure enqueue with no dequeue overhead
    const start = std.time.nanoTimestamp();
    i = 0;
    while (i < iterations) : (i += 1) {
        _ = try result.producer.enqueue(i);
    }
    const end = std.time.nanoTimestamp();

    const duration_ns = @as(u64, @intCast(end - start));
    const ns_per_op = @as(f64, @floatFromInt(duration_ns)) / @as(f64, @floatFromInt(iterations));
    const ops_per_sec = (@as(f64, @floatFromInt(iterations)) * 1_000_000_000.0) / @as(f64, @floatFromInt(duration_ns));

    std.debug.print("Pure enqueue (zero contention): {d:.2} ns/op ({d:.0} M ops/sec)\n", .{
        ns_per_op,
        ops_per_sec / 1_000_000.0,
    });
}

fn benchmarkPureDequeue() !void {
    const Queue = BoundedSPSCQueue(u64);
    const capacity = 65536; // Large queue
    var result = try Queue.init(std.heap.page_allocator, capacity);
    defer result.producer.deinit();

    const iterations: u64 = 60_000;

    // Warmup: enqueue some items, then dequeue them
    var i: u64 = 0;
    while (i < 10_000) : (i += 1) {
        _ = try result.producer.enqueue(i);
    }
    i = 0;
    while (i < 10_000) : (i += 1) {
        _ = result.consumer.dequeue();
    }

    // Pre-fill the queue for the actual benchmark
    i = 0;
    while (i < iterations) : (i += 1) {
        _ = try result.producer.enqueue(i);
    }

    // Benchmark: Pure dequeue from pre-filled queue
    const start = std.time.nanoTimestamp();
    i = 0;
    while (i < iterations) : (i += 1) {
        _ = result.consumer.dequeue();
    }
    const end = std.time.nanoTimestamp();

    const duration_ns = @as(u64, @intCast(end - start));
    const ns_per_op = @as(f64, @floatFromInt(duration_ns)) / @as(f64, @floatFromInt(iterations));
    const ops_per_sec = (@as(f64, @floatFromInt(iterations)) * 1_000_000_000.0) / @as(f64, @floatFromInt(duration_ns));

    std.debug.print("Pure dequeue (zero contention): {d:.2} ns/op ({d:.0} M ops/sec)\n", .{
        ns_per_op,
        ops_per_sec / 1_000_000.0,
    });
}

// ============================================================================
// Two-Thread Throughput Benchmarks
// ============================================================================

fn benchmarkTwoThreadThroughput(capacity: usize, iterations: u64) !void {
    const Queue = BoundedSPSCQueue(u64);
    var result = try Queue.init(std.heap.page_allocator, capacity);
    defer result.producer.deinit();

    const TestContext = struct {
        producer: *Queue.Producer,
        consumer: *Queue.Consumer,
        iterations: u64,
        start_barrier: std.atomic.Value(bool),
        producer_done: std.atomic.Value(bool),
    };

    var ctx = TestContext{
        .producer = @constCast(&result.producer),
        .consumer = @constCast(&result.consumer),
        .iterations = iterations,
        .start_barrier = std.atomic.Value(bool).init(false),
        .producer_done = std.atomic.Value(bool).init(false),
    };

    const ProducerFn = struct {
        fn run(context: *TestContext) void {
            // Wait for start signal
            while (!context.start_barrier.load(.acquire)) {
                std.atomic.spinLoopHint();
            }

            var i: u64 = 0;
            while (i < context.iterations) {
                context.producer.enqueue(i) catch {
                    std.atomic.spinLoopHint();
                    continue;
                };
                i += 1;
            }

            context.producer_done.store(true, .release);
        }
    };

    const ConsumerFn = struct {
        fn run(context: *TestContext) void {
            // Wait for start signal
            while (!context.start_barrier.load(.acquire)) {
                std.atomic.spinLoopHint();
            }

            var i: u64 = 0;
            while (i < context.iterations) {
                if (context.consumer.dequeue()) |_| {
                    i += 1;
                } else {
                    std.atomic.spinLoopHint();
                }
            }
        }
    };

    // Spawn threads
    const producer_thread = try Thread.spawn(.{}, ProducerFn.run, .{&ctx});
    const consumer_thread = try Thread.spawn(.{}, ConsumerFn.run, .{&ctx});

    // Start benchmark
    const start = std.time.nanoTimestamp();
    ctx.start_barrier.store(true, .release);

    // Wait for completion
    producer_thread.join();
    consumer_thread.join();
    const end = std.time.nanoTimestamp();

    const duration_ns = @as(u64, @intCast(end - start));
    const ns_per_op = duration_ns / iterations;
    const ops_per_sec = (@as(u128, iterations) * 1_000_000_000) / duration_ns;

    std.debug.print("Two-thread throughput (capacity={}): {} ns/op ({} M ops/sec, {} items/sec)\n", .{
        capacity,
        ns_per_op,
        ops_per_sec / 1_000_000,
        ops_per_sec,
    });
}

// ============================================================================
// Ping-Pong Latency Benchmark
// ============================================================================

fn benchmarkPingPongLatency() !void {
    const Queue = BoundedSPSCQueue(u64);
    const capacity = 64;

    // Create two queues: A->B and B->A
    var a_to_b = try Queue.init(std.heap.page_allocator, capacity);
    defer a_to_b.producer.deinit();

    var b_to_a = try Queue.init(std.heap.page_allocator, capacity);
    defer b_to_a.producer.deinit();

    const PingPongContext = struct {
        // Thread A owns a_to_b.producer and b_to_a.consumer
        a_producer: *Queue.Producer,
        a_consumer: *Queue.Consumer,

        // Thread B owns b_to_a.producer and a_to_b.consumer
        b_producer: *Queue.Producer,
        b_consumer: *Queue.Consumer,

        iterations: u64,
        start_barrier: std.atomic.Value(bool),
        total_latency_ns: std.atomic.Value(u64),
    };

    var ctx = PingPongContext{
        .a_producer = @constCast(&a_to_b.producer),
        .a_consumer = @constCast(&b_to_a.consumer),
        .b_producer = @constCast(&b_to_a.producer),
        .b_consumer = @constCast(&a_to_b.consumer),
        .iterations = 100_000,
        .start_barrier = std.atomic.Value(bool).init(false),
        .total_latency_ns = std.atomic.Value(u64).init(0),
    };

    const ThreadA = struct {
        fn run(context: *PingPongContext) void {
            // Wait for start
            while (!context.start_barrier.load(.acquire)) {
                std.atomic.spinLoopHint();
            }

            var total_ns: u64 = 0;
            var i: u64 = 0;
            while (i < context.iterations) : (i += 1) {
                const start = std.time.nanoTimestamp();

                // Send ping
                while (true) {
                    context.a_producer.enqueue(i) catch {
                        std.atomic.spinLoopHint();
                        continue;
                    };
                    break;
                }

                // Wait for pong
                while (true) {
                    if (context.a_consumer.dequeue()) |_| {
                        break;
                    }
                    std.atomic.spinLoopHint();
                }

                const end = std.time.nanoTimestamp();
                total_ns += @intCast(end - start);
            }

            context.total_latency_ns.store(total_ns, .release);
        }
    };

    const ThreadB = struct {
        fn run(context: *PingPongContext) void {
            // Wait for start
            while (!context.start_barrier.load(.acquire)) {
                std.atomic.spinLoopHint();
            }

            var i: u64 = 0;
            while (i < context.iterations) : (i += 1) {
                // Wait for ping
                var ping: u64 = undefined;
                while (true) {
                    if (context.b_consumer.dequeue()) |value| {
                        ping = value;
                        break;
                    }
                    std.atomic.spinLoopHint();
                }

                // Send pong
                while (true) {
                    context.b_producer.enqueue(ping) catch {
                        std.atomic.spinLoopHint();
                        continue;
                    };
                    break;
                }
            }
        }
    };

    // Spawn threads
    const thread_a = try Thread.spawn(.{}, ThreadA.run, .{&ctx});
    const thread_b = try Thread.spawn(.{}, ThreadB.run, .{&ctx});

    // Start benchmark
    ctx.start_barrier.store(true, .release);

    // Wait for completion
    thread_a.join();
    thread_b.join();

    const total_ns = ctx.total_latency_ns.load(.acquire);
    const avg_roundtrip_ns = total_ns / ctx.iterations;
    const avg_oneway_ns = avg_roundtrip_ns / 2;

    std.debug.print("Ping-pong latency: {} ns round-trip ({} ns one-way)\n", .{
        avg_roundtrip_ns,
        avg_oneway_ns,
    });
}

// ============================================================================
// Comparison with BeamDeque (if available)
// ============================================================================

fn benchmarkComparisonWithBeamDeque() !void {
    std.debug.print("\n=== Comparison: SPSC vs BeamDeque (1P/1C) ===\n", .{});

    // SPSC benchmark
    {
        const Queue = BoundedSPSCQueue(u64);
        var result = try Queue.init(std.heap.page_allocator, 1024);
        defer result.producer.deinit();

        const iterations = 5_000_000;

        const TestContext = struct {
            producer: *Queue.Producer,
            consumer: *Queue.Consumer,
            iterations: u64,
            start_barrier: std.atomic.Value(bool),
        };

        var ctx = TestContext{
            .producer = @constCast(&result.producer),
            .consumer = @constCast(&result.consumer),
            .iterations = iterations,
            .start_barrier = std.atomic.Value(bool).init(false),
        };

        const ProducerFn = struct {
            fn run(context: *TestContext) void {
                while (!context.start_barrier.load(.acquire)) {
                    std.atomic.spinLoopHint();
                }
                var i: u64 = 0;
                while (i < context.iterations) {
                    context.producer.enqueue(i) catch {
                        std.atomic.spinLoopHint();
                        continue;
                    };
                    i += 1;
                }
            }
        };

        const ConsumerFn = struct {
            fn run(context: *TestContext) void {
                while (!context.start_barrier.load(.acquire)) {
                    std.atomic.spinLoopHint();
                }
                var i: u64 = 0;
                while (i < context.iterations) {
                    if (context.consumer.dequeue()) |_| {
                        i += 1;
                    } else {
                        std.atomic.spinLoopHint();
                    }
                }
            }
        };

        const producer_thread = try Thread.spawn(.{}, ProducerFn.run, .{&ctx});
        const consumer_thread = try Thread.spawn(.{}, ConsumerFn.run, .{&ctx});

        const start = std.time.nanoTimestamp();
        ctx.start_barrier.store(true, .release);

        producer_thread.join();
        consumer_thread.join();
        const end = std.time.nanoTimestamp();

        const duration_ns = @as(u64, @intCast(end - start));
        const ops_per_sec = (@as(u128, iterations) * 1_000_000_000) / duration_ns;

        std.debug.print("SPSC Queue: {} M ops/sec\n", .{ops_per_sec / 1_000_000});
    }

    std.debug.print("(Note: BeamDeque comparison would require BeamDeque import)\n", .{});
}

// ============================================================================
// Main Benchmark Runner
// ============================================================================

pub fn main() !void {
    std.debug.print("\n=== BoundedSPSCQueue Benchmarks ===\n\n", .{});

    std.debug.print("--- Pure Throughput (Zero Contention) ---\n", .{});
    try benchmarkPureEnqueue();
    try benchmarkPureDequeue();

    std.debug.print("\n--- Two-Thread Throughput (Concurrent Producer/Consumer) ---\n", .{});
    try benchmarkTwoThreadThroughput(64, BENCHMARK_ITERATIONS);
    try benchmarkTwoThreadThroughput(256, BENCHMARK_ITERATIONS);
    try benchmarkTwoThreadThroughput(1024, BENCHMARK_ITERATIONS);
    try benchmarkTwoThreadThroughput(4096, BENCHMARK_ITERATIONS);
    try benchmarkTwoThreadThroughput(8192, BENCHMARK_ITERATIONS);

    std.debug.print("\n--- Ping-Pong Latency ---\n", .{});
    try benchmarkPingPongLatency();

    std.debug.print("\n=== Benchmarks Complete ===\n", .{});
}
