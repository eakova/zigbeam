const std = @import("std");
const SegQueue = @import("../seg_queue.zig").SegQueue;

test "seg_queue: multithreaded push/pop stress" {
    const gpa = std.testing.allocator;
    var q = try SegQueue(u64).init(gpa);
    defer q.deinit();

    const producers: usize = 4;
    const consumers: usize = 4;
    const per_producer: usize = 10_000;

    var prod_threads = try gpa.alloc(std.Thread, producers);
    defer gpa.free(prod_threads);

    var cons_threads = try gpa.alloc(std.Thread, consumers);
    defer gpa.free(cons_threads);

    // Spawn consumers first
    for (0..consumers) |i| {
        cons_threads[i] = try std.Thread.spawn(.{}, struct {
            fn run(qp: *SegQueue(u64)) void {
                var local: usize = 0;
                while (local < per_producer * producers / consumers) {
                    if (qp.pop()) |_| {
                        local += 1;
                    } else {
                        std.atomic.spinLoopHint();
                    }
                }
            }
        }.run, .{&q});
    }

    // Spawn producers
    for (0..producers) |pi| {
        prod_threads[pi] = try std.Thread.spawn(.{}, struct {
            fn run(qp: *SegQueue(u64), base: u64) void {
                var i: usize = 0;
                while (i < per_producer) : (i += 1) {
                    qp.push(base + @as(u64, @intCast(i))) catch unreachable;
                }
            }
        }.run, .{&q, @as(u64, @intCast(pi)) << 32});
    }

    for (prod_threads) |t| t.join();
    for (cons_threads) |t| t.join();
}

