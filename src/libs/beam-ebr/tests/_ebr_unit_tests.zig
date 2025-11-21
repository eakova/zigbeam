const std = @import("std");
const ebr = @import("beam-ebr");
const Atomic = std.atomic.Value;

test "EBR register/unregister basic" {
    const allocator = std.testing.allocator;
    var global_epoch = try ebr.GlobalEpoch.init(.{ .allocator = allocator });
    defer global_epoch.deinit();

    var p1 = ebr.Participant.init(allocator);
    var p2 = ebr.Participant.init(allocator);

    try global_epoch.registerParticipant(&p1);
    try global_epoch.registerParticipant(&p2);

    global_epoch.unregisterParticipant(&p1);
    global_epoch.unregisterParticipant(&p2);

    // No assertions here beyond "no crash"; getMinimumEpoch should be callable.
    _ = global_epoch.getMinimumEpoch();
}

test "EBR TooManyThreads error" {
    const allocator = std.testing.allocator;
    var global_epoch = try ebr.GlobalEpoch.init(.{ .allocator = allocator });
    defer global_epoch.deinit();

    var participants: [ebr.MAX_PARTICIPANTS]ebr.Participant = undefined;
    for (&participants) |*p| {
        p.* = ebr.Participant.init(allocator);
        try global_epoch.registerParticipant(p);
    }

    var extra = ebr.Participant.init(allocator);
    const err = global_epoch.registerParticipant(&extra);
    try std.testing.expectError(error.TooManyThreads, err);
}

test "EBR basic defer/collect sequence" {
    const allocator = std.testing.allocator;
    var global_epoch = try ebr.GlobalEpoch.init(.{ .allocator = allocator });
    defer global_epoch.deinit();

    var participant = ebr.Participant.init(allocator);
    try global_epoch.registerParticipant(&participant);

    var guard = ebr.pinFor(&participant, &global_epoch);

    var freed_count: usize = 0;
    const Freed = struct {
        fn destroy(ptr: *anyopaque, _alloc: std.mem.Allocator) void {
            _ = _alloc;
            const counter_ptr: *usize = @ptrCast(@alignCast(ptr));
            counter_ptr.* += 1;
        }
    };

    const gc_ptr: *usize = &freed_count;
    const garbage = ebr.Garbage{
        .ptr = @ptrCast(gc_ptr),
        .destroy_fn = Freed.destroy,
        .epoch = 0,
    };

    guard.deferDestroy(garbage);

    // Force collection on unpin by bumping the local counter.
    participant.garbage_count_since_last_check = ebr.COLLECTION_THRESHOLD;
    guard.deinit();

    // Clean up participant state to avoid leaks when using testing allocator.
    participant.deinit(&global_epoch);
    global_epoch.unregisterParticipant(&participant);

    try std.testing.expectEqual(@as(usize, 1), freed_count);
}

test "EBR thread termination orphan garbage" {
    const allocator = std.heap.c_allocator;

    var global_epoch = try ebr.GlobalEpoch.init(.{ .allocator = allocator });
    defer global_epoch.deinit();

    var freed = Atomic(usize).init(0);

    const Destroy = struct {
        fn destroy(ptr: *anyopaque, _alloc: std.mem.Allocator) void {
            _ = _alloc;
            const counter: *Atomic(usize) = @ptrCast(@alignCast(ptr));
            const prev = counter.load(.monotonic);
            counter.store(prev + 1, .monotonic);
        }
    };

    const ThreadArgs = struct {
        global_epoch: *ebr.GlobalEpoch,
        counter: *Atomic(usize),
    };

    const worker = struct {
        fn run(args: *ThreadArgs) !void {
            const allocator_local = std.heap.c_allocator;
            const p_ptr = try allocator_local.create(ebr.Participant);
            p_ptr.* = ebr.Participant.init(allocator_local);

            try args.global_epoch.registerParticipant(p_ptr);

            var guard = ebr.pinFor(p_ptr, args.global_epoch);

            const garbage = ebr.Garbage{
                .ptr = @ptrCast(args.counter),
                .destroy_fn = Destroy.destroy,
                .epoch = 0,
            };
            guard.deferDestroy(garbage);
            p_ptr.garbage_count_since_last_check = ebr.COLLECTION_THRESHOLD;
            guard.deinit();

            // Thread "terminates": flush local garbage to global queue and
            // properly unregister the participant to avoid dangling pointer.
            p_ptr.deinit(args.global_epoch);
            args.global_epoch.unregisterParticipant(p_ptr);
            allocator_local.destroy(p_ptr);
        }
    };

    var args = ThreadArgs{
        .global_epoch = &global_epoch,
        .counter = &freed,
    };

    var threads: [2]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, worker.run, .{&args});
    }
    for (threads) |t| {
        t.join();
    }

    // Create a reclaimer participant that stays alive.
    var reclaimer = ebr.Participant.init(allocator);
    try global_epoch.registerParticipant(&reclaimer);

    // Manually move the global epoch forward to ensure safe_epoch > 0.
    global_epoch.current_epoch.store(10, .release);

    // Drive reclamation from this active participant.
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        var guard = ebr.pinFor(&reclaimer, &global_epoch);
        reclaimer.garbage_count_since_last_check = 128;
        guard.deinit();
    }

    // Both worker threads' garbage should have been reclaimed.
    try std.testing.expectEqual(@as(usize, 2), freed.load(.monotonic));

    // Clean up the reclaimer participant.
    reclaimer.deinit(&global_epoch);
    global_epoch.unregisterParticipant(&reclaimer);
}

test "EBR sentinel correctness" {
    const allocator = std.testing.allocator;
    var global_epoch = try ebr.GlobalEpoch.init(.{ .allocator = allocator });
    defer global_epoch.deinit();

    var participant = ebr.Participant.init(allocator);
    try global_epoch.registerParticipant(&participant);

    const MagicNode = struct {
        magic: u64,
    };
    const MAGIC: u64 = 0x0123_4567_89AB_CDEF;

    var guard = ebr.pinFor(&participant, &global_epoch);

    const count: usize = 128;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const node_ptr = try allocator.create(MagicNode);
        node_ptr.* = .{ .magic = MAGIC };

        const garbage = ebr.Garbage{
            .ptr = @ptrCast(node_ptr),
            .destroy_fn = struct {
                fn destroy(ptr: *anyopaque, alloc: std.mem.Allocator) void {
                    const node_local: *MagicNode = @ptrCast(@alignCast(ptr));
                    std.debug.assert(node_local.magic == MAGIC);
                    alloc.destroy(node_local);
                }
            }.destroy,
            .epoch = 0,
        };
        guard.deferDestroy(garbage);
    }

    participant.garbage_count_since_last_check = 64;
    guard.deinit();

    participant.deinit(&global_epoch);
    global_epoch.unregisterParticipant(&participant);

    // If any sentinel was corrupted, the destroy function would have asserted.
}

test "EBR Participant size and layout" {
    std.debug.print(
        "\nParticipant size: {} bytes\nis_active offset: {}\nepoch offset: {}\n",
        .{
            @sizeOf(ebr.Participant),
            @offsetOf(ebr.Participant, "is_active"),
            @offsetOf(ebr.Participant, "epoch"),
        },
    );
}
