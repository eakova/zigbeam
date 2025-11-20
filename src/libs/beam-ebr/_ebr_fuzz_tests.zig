const std = @import("std");
const ebr = @import("beam-ebr");

const Atomic = std.atomic.Value;

inline fn generateSeed(offset: u64) u64 {
    const timestamp = std.time.nanoTimestamp();
    return @as(u64, @truncate(@as(u128, @bitCast(timestamp)))) +% offset;
}

test "EBR fuzz - random pin/retire with yields" {
    const allocator = std.testing.allocator;
    var global_epoch = try ebr.GlobalEpoch.init(.{ .allocator = allocator });
    defer global_epoch.deinit();

    const ThreadArgs = struct {
        global_epoch: *ebr.GlobalEpoch,
        seed: u64,
    };

    const worker = struct {
        fn run(args: *ThreadArgs) !void {
            var prng = std.Random.DefaultPrng.init(args.seed);
            const random = prng.random();

            var participant = ebr.Participant.init(std.heap.c_allocator);
            try args.global_epoch.registerParticipant(&participant);

            const MagicNode = struct {
                magic: u64,
                allocator: std.mem.Allocator,
            };

            const MAGIC: u64 = 0xDEADC0DECAFEBABE;

            const iterations: usize = 2_000;
            var i: usize = 0;
            while (i < iterations) : (i += 1) {
                var guard = ebr.pinFor(&participant, args.global_epoch);

                if (random.boolean()) {
                    const node_alloc = std.heap.c_allocator;
                    const node = try node_alloc.create(MagicNode);
                    node.* = .{
                        .magic = MAGIC,
                        .allocator = node_alloc,
                    };

                    const garbage = ebr.Garbage{
                        .ptr = @ptrCast(node),
                        .destroy_fn = struct {
                            fn destroy(ptr: *anyopaque, _alloc: std.mem.Allocator) void {
                                _ = _alloc;
                                const node_local: *MagicNode = @ptrCast(@alignCast(ptr));
                                std.debug.assert(node_local.magic == MAGIC);
                                node_local.allocator.destroy(node_local);
                            }
                        }.destroy,
                        .epoch = 0,
                    };

                    guard.deferDestroy(garbage);
                }

                if (random.intRangeAtMost(u8, 0, 10) == 0) {
                    std.Thread.yield() catch {};
                }

                participant.garbage_count_since_last_check = 64;
                guard.deinit();
            }

            participant.deinit(args.global_epoch);
            args.global_epoch.unregisterParticipant(&participant);

            // If any sentinel was corrupted, the destroy assertion would have fired.
        }
    };

    var threads: [4]std.Thread = undefined;
    var args_array: [4]ThreadArgs = undefined;

    var t_idx: usize = 0;
    while (t_idx < threads.len) : (t_idx += 1) {
        args_array[t_idx] = .{
            .global_epoch = &global_epoch,
            .seed = generateSeed(@intCast(t_idx + 1)),
        };
        threads[t_idx] = try std.Thread.spawn(.{}, worker.run, .{&args_array[t_idx]});
    }

    for (threads) |t| {
        t.join();
    }
}
