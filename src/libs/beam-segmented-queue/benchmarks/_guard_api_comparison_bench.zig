const std = @import("std");
const SegmentedQueueMod = @import("beam-segmented-queue");
const ebr = @import("beam-ebr");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        std.debug.print("Leak status: {any}\n", .{leaked});
    }
    const allocator = gpa.allocator();

    const Queue = SegmentedQueueMod.SegmentedQueue(u64, 64);

    std.debug.print("\n=== SegmentedQueue API Comparison Benchmark ===\n", .{});
    std.debug.print("Comparing TLS-based API vs Batching API\n\n", .{});

    // Test 1: Simple API (TLS guard per operation - formerly "WithAutoGuard")
    {
        var queue = try Queue.init(allocator);
        defer queue.deinit();

        const participant = try queue.createParticipant();
        defer queue.destroyParticipant(participant);

        const iterations: usize = 100_000;
        const start = std.time.nanoTimestamp();

        var i: usize = 0;
        while (i < iterations) : (i += 1) {
            try queue.enqueueWithAutoGuard(i);
        }

        i = 0;
        while (i < iterations) : (i += 1) {
            _ = queue.dequeueWithAutoGuard();
        }

        const end = std.time.nanoTimestamp();
        const elapsed_ns: u64 = @intCast(end - start);
        const elapsed_s = @as(f64, @floatFromInt(elapsed_ns)) / 1e9;
        const ops = iterations * 2; // enqueue + dequeue
        const throughput = @as(f64, @floatFromInt(ops)) / elapsed_s;

        std.debug.print("Simple API (TLS guard per operation):\n", .{});
        std.debug.print("  iterations:  {d}\n", .{iterations});
        std.debug.print("  total_ops:   {d}\n", .{ops});
        std.debug.print("  elapsed_sec: {d:.6}\n", .{elapsed_s});
        std.debug.print("  throughput:  {d:.1} ops/sec\n\n", .{throughput});
    }

    // Test 2: Primary API (explicit guard management per operation)
    {
        var queue = try Queue.init(allocator);
        defer queue.deinit();

        const participant = try queue.createParticipant();
        defer queue.destroyParticipant(participant);

        const iterations: usize = 100_000;
        const start = std.time.nanoTimestamp();

        var i: usize = 0;
        while (i < iterations) : (i += 1) {
            try queue.enqueue(i);
        }

        i = 0;
        while (i < iterations) : (i += 1) {
            var guard = ebr.pin();
            defer guard.deinit();
            _ = queue.dequeue(&guard);
        }

        const end = std.time.nanoTimestamp();
        const elapsed_ns: u64 = @intCast(end - start);
        const elapsed_s = @as(f64, @floatFromInt(elapsed_ns)) / 1e9;
        const ops = iterations * 2; // enqueue + dequeue
        const throughput = @as(f64, @floatFromInt(ops)) / elapsed_s;

        std.debug.print("Primary API (explicit guard per dequeue):\n", .{});
        std.debug.print("  iterations:  {d}\n", .{iterations});
        std.debug.print("  total_ops:   {d}\n", .{ops});
        std.debug.print("  elapsed_sec: {d:.6}\n", .{elapsed_s});
        std.debug.print("  throughput:  {d:.1} ops/sec\n\n", .{throughput});
    }

    // Test 3: Batch API comparison (slice-based batching)
    std.debug.print("=== Batch Size Impact (Slice-based Batching API) ===\n", .{});
    const batch_sizes = [_]usize{ 1, 10, 100, 1000, 10000 };

    for (batch_sizes) |batch_size| {
        var queue = try Queue.init(allocator);
        defer queue.deinit();

        const participant = try queue.createParticipant();
        defer queue.destroyParticipant(participant);

        const total_items: usize = 100_000;
        const num_batches = total_items / batch_size;

        const start = std.time.nanoTimestamp();

        // Enqueue in batches using enqueueMany
        var batch_idx: usize = 0;
        while (batch_idx < num_batches) : (batch_idx += 1) {
            var batch_data: [10000]u64 = undefined;
            const batch_start = batch_idx * batch_size;
            for (0..batch_size) |i| {
                batch_data[i] = batch_start + i;
            }
            try queue.enqueueMany(batch_data[0..batch_size]);
        }

        // Dequeue in batches using dequeueMany
        batch_idx = 0;
        while (batch_idx < num_batches) : (batch_idx += 1) {
            var batch_buffer: [10000]u64 = undefined;
            _ = queue.dequeueMany(batch_buffer[0..batch_size]);
        }

        const end = std.time.nanoTimestamp();
        const elapsed_ns: u64 = @intCast(end - start);
        const elapsed_s = @as(f64, @floatFromInt(elapsed_ns)) / 1e9;
        const ops = total_items * 2;
        const throughput = @as(f64, @floatFromInt(ops)) / elapsed_s;

        std.debug.print("Batch size {d:5}: {d:.1} ops/sec\n", .{ batch_size, throughput });
    }

    std.debug.print("\n", .{});
}
