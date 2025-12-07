//! Multi-Threaded EBR Example
//!
//! Demonstrates EBR with multiple concurrent worker threads.
//! Each thread performs independent pin/unpin operations and defers
//! objects for reclamation. Shows proper thread registration patterns.
//!
//! Run: zig build sample-multithread

const std = @import("std");
const ebr = @import("ebr");

/// Shared state for demonstration.
const SharedState = struct {
    collector: *ebr.Collector,
    allocator: std.mem.Allocator,
    operations_done: std.atomic.Value(u64),
    objects_deferred: std.atomic.Value(u64),

    fn init(collector: *ebr.Collector, allocator: std.mem.Allocator) SharedState {
        return .{
            .collector = collector,
            .allocator = allocator,
            .operations_done = std.atomic.Value(u64).init(0),
            .objects_deferred = std.atomic.Value(u64).init(0),
        };
    }
};

/// Node type for deferred destruction.
const Node = struct {
    id: u64,
    allocator: std.mem.Allocator,
};

/// Worker thread function.
fn workerThread(state: *SharedState, worker_id: u8, iterations: u64) void {
    // Each thread MUST register with the collector
    const handle = state.collector.registerThread() catch {
        std.debug.print("Worker {}: Failed to register\n", .{worker_id});
        return;
    };
    defer state.collector.unregisterThread(handle);

    var local_ops: u64 = 0;
    var local_deferred: u64 = 0;

    for (0..iterations) |i| {
        // Pin to enter critical section
        const guard = state.collector.pin();

        // Simulate work in critical section
        if (i % 10 == 0) {
            // Periodically allocate and defer a node
            if (state.allocator.create(Node)) |node| {
                node.* = .{
                    .id = (@as(u64, worker_id) << 56) | i,
                    .allocator = state.allocator,
                };
                state.collector.deferDestroy(Node, node);
                local_deferred += 1;
            } else |_| {}
        }

        // Unpin to exit critical section
        guard.unpin();

        local_ops += 1;

        // Periodically trigger collection
        if (i % 100 == 0) {
            state.collector.collect();
        }
    }

    _ = state.operations_done.fetchAdd(local_ops, .monotonic);
    _ = state.objects_deferred.fetchAdd(local_deferred, .monotonic);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== Multi-Threaded EBR Example ===\n\n", .{});

    // Create collector
    var collector = try ebr.Collector.init(allocator);
    defer collector.deinit();

    var state = SharedState.init(&collector, allocator);

    const num_workers = 4;
    const iterations_per_worker = 10000;

    std.debug.print("Workers: {}\n", .{num_workers});
    std.debug.print("Iterations per worker: {}\n", .{iterations_per_worker});
    std.debug.print("Total operations: {}\n\n", .{num_workers * iterations_per_worker});

    // Spawn worker threads
    var threads: [num_workers]std.Thread = undefined;
    for (0..num_workers) |i| {
        threads[i] = try std.Thread.spawn(
            .{},
            workerThread,
            .{ &state, @as(u8, @intCast(i)), iterations_per_worker },
        );
    }

    // Wait for all threads
    for (&threads) |*t| {
        t.join();
    }

    // Final garbage collection
    _ = collector.tryAdvanceEpoch();
    _ = collector.tryAdvanceEpoch();
    _ = collector.tryAdvanceEpoch();
    collector.collect();

    std.debug.print("Operations completed: {}\n", .{state.operations_done.load(.monotonic)});
    std.debug.print("Objects deferred: {}\n", .{state.objects_deferred.load(.monotonic)});
    std.debug.print("\nAll threads completed, memory safely reclaimed!\n", .{});
}
