//! Fuzz tests for EBR library using Zig's built-in fuzzer.
//!
//! Run with: zig build fuzz -- --fuzz
//! Or directly: zig test --fuzz tests/fuzz/ebr_fuzz.zig

const std = @import("std");
const ebr = @import("ebr");

// Fuzz test for pin/unpin sequences.
// Tests that arbitrary sequences of pin/unpin operations don't crash or corrupt state.
test "fuzz pin/unpin sequences" {
    try std.testing.fuzz({}, struct {
        fn testOne(_: void, input: []const u8) !void {
            var collector = try ebr.Collector.init(std.testing.allocator);
            defer collector.deinit();

            const handle = try collector.registerThread();
            defer collector.unregisterThread(handle);

            var pin_depth: u32 = 0;
            var guards: [256]ebr.Guard = undefined;

            for (input) |byte| {
                const action = byte % 4;
                switch (action) {
                    0 => {
                        // Pin (if not at max depth)
                        if (pin_depth < 255) {
                            guards[pin_depth] = collector.pin();
                            pin_depth += 1;
                        }
                    },
                    1 => {
                        // Unpin (if pinned)
                        if (pin_depth > 0) {
                            pin_depth -= 1;
                            guards[pin_depth].unpin();
                        }
                    },
                    2 => {
                        // Try advance epoch
                        _ = collector.tryAdvanceEpoch();
                    },
                    3 => {
                        // Collect
                        collector.collect();
                    },
                    else => {},
                }
            }

            // Unwind remaining pins
            while (pin_depth > 0) {
                pin_depth -= 1;
                guards[pin_depth].unpin();
            }
        }
    }.testOne, .{});
}

// Fuzz test for defer/reclaim sequences.
// Tests that deferred objects are properly reclaimed.
test "fuzz defer/reclaim" {
    try std.testing.fuzz({}, struct {
        fn testOne(_: void, input: []const u8) !void {
            var collector = try ebr.Collector.init(std.testing.allocator);
            defer collector.deinit();

            const handle = try collector.registerThread();
            defer collector.unregisterThread(handle);

            const TestNode = struct {
                value: u64,
                allocator: std.mem.Allocator,
            };

            var allocated: usize = 0;

            for (input) |byte| {
                const action = byte % 5;
                switch (action) {
                    0 => {
                        // Allocate and defer
                        if (allocated < 1000) { // Limit to prevent OOM
                            const guard = collector.pin();
                            defer guard.unpin();

                            if (std.testing.allocator.create(TestNode)) |node| {
                                node.* = .{
                                    .value = byte,
                                    .allocator = std.testing.allocator,
                                };
                                collector.deferDestroy(TestNode, node);
                                allocated += 1;
                            } else |_| {}
                        }
                    },
                    1 => {
                        // Try advance epoch
                        _ = collector.tryAdvanceEpoch();
                    },
                    2 => {
                        // Collect
                        collector.collect();
                    },
                    3 => {
                        // Pin/unpin cycle
                        const guard = collector.pin();
                        guard.unpin();
                    },
                    4 => {
                        // Multiple epoch advances
                        _ = collector.tryAdvanceEpoch();
                        _ = collector.tryAdvanceEpoch();
                        _ = collector.tryAdvanceEpoch();
                        collector.collect();
                    },
                    else => {},
                }
            }

            // Final collection to reclaim everything
            _ = collector.tryAdvanceEpoch();
            _ = collector.tryAdvanceEpoch();
            _ = collector.tryAdvanceEpoch();
            collector.collect();
        }
    }.testOne, .{});
}

// Fuzz test for FastGuard operations.
test "fuzz fast guard" {
    try std.testing.fuzz({}, struct {
        fn testOne(_: void, input: []const u8) !void {
            var collector = try ebr.Collector.init(std.testing.allocator);
            defer collector.deinit();

            const handle = try collector.registerThread();
            defer collector.unregisterThread(handle);

            for (input) |byte| {
                const action = byte % 3;
                switch (action) {
                    0 => {
                        // Fast pin/unpin
                        const guard = collector.pinFast();
                        guard.unpin();
                    },
                    1 => {
                        // Try advance
                        _ = collector.tryAdvanceEpoch();
                    },
                    2 => {
                        // Collect
                        collector.collect();
                    },
                    else => {},
                }
            }
        }
    }.testOne, .{});
}

// Fuzz test for epoch bucket edge cases.
// Tests epoch wraparound and bucket selection.
test "fuzz epoch buckets" {
    try std.testing.fuzz({}, struct {
        fn testOne(_: void, input: []const u8) !void {
            var bag = ebr.reclaim.EpochBucketedBag.init(std.testing.allocator);
            defer bag.deinit();

            const noop_dtor = struct {
                fn noop(_: *anyopaque) void {}
            }.noop;

            var dummy: u64 = 0;
            var max_epoch: u64 = 0;

            for (input) |byte| {
                const action = byte % 3;
                switch (action) {
                    0 => {
                        // Append to current epoch
                        const epoch = @as(u64, byte) + max_epoch;
                        if (epoch > max_epoch) max_epoch = epoch;
                        bag.append(.{
                            .ptr = @ptrCast(&dummy),
                            .dtor = noop_dtor,
                        }, epoch) catch {};
                    },
                    1 => {
                        // Reclaim up to some epoch
                        if (max_epoch > 2) {
                            _ = bag.reclaimUpTo(max_epoch - 2);
                        }
                    },
                    2 => {
                        // Reclaim single bucket
                        if (max_epoch > 0) {
                            _ = bag.reclaimBucket(byte % 3);
                        }
                    },
                    else => {},
                }
            }

            // Final reclaim
            _ = bag.reclaimAll();
        }
    }.testOne, .{});
}
