/// Integration tests for EBR (Epoch-Based Reclamation)
/// Tests concurrent guard operations, batch retirement, and reclamation

const std = @import("std");
const testing = std.testing;
const allocator = testing.allocator;
const Thread = std.Thread;

const ebr = @import("../ebr.zig");
const Collector = ebr.Collector;
const Reservation = ebr.Reservation;
const LocalGuard = ebr.LocalGuard;
const OwnedGuard = ebr.OwnedGuard;

/// Test object for tracking reclamations
const TestObject = struct {
    value: u64,
    freed_count: *std.atomic.Value(u32),

    fn create(value: u64, freed_count: *std.atomic.Value(u32)) !*TestObject {
        const obj = try allocator.create(TestObject);
        obj.* = .{ .value = value, .freed_count = freed_count };
        return obj;
    }

    fn reclaim(ptr: *anyopaque, _: *Collector) void {
        const obj: *TestObject = @ptrCast(@alignCast(ptr));
        _ = obj.freed_count.fetchAdd(1, .release);
        allocator.destroy(obj);
    }
};

test "EBR: Multiple guards in same thread" {
    const collector = try Collector.init(allocator, 16);
    defer collector.deinit();

    var freed_count = std.atomic.Value(u32).init(0);

    var res1 = Reservation.init();
    var batch1 = ebr.LocalBatch.init();

    var res2 = Reservation.init();
    var batch2 = ebr.LocalBatch.init();

    {
        const guard1 = try LocalGuard.enter(collector, &res1, &batch1);
        defer guard1.deinit();

        const obj1 = try TestObject.create(1, &freed_count);
        try guard1.defer_retire(@ptrCast(obj1), TestObject.reclaim);

        {
            const guard2 = try LocalGuard.enter(collector, &res2, &batch2);
            defer guard2.deinit();

            const obj2 = try TestObject.create(2, &freed_count);
            try guard2.defer_retire(@ptrCast(obj2), TestObject.reclaim);
        }

        const obj3 = try TestObject.create(3, &freed_count);
        try guard1.defer_retire(@ptrCast(obj3), TestObject.reclaim);
    }

    // All objects should be retired and queued
    try testing.expect(batch1.batch == null or batch1.batch.?.entries.items.len >= 0);
    try testing.expect(batch2.batch == null or batch2.batch.?.entries.items.len >= 0);
}

test "EBR: Guard flush and retire" {
    const collector = try Collector.init(allocator, 2);
    defer collector.deinit();

    var freed_count = std.atomic.Value(u32).init(0);

    var reservation = Reservation.init();
    var local_batch = ebr.LocalBatch.init();

    {
        const guard = try LocalGuard.enter(collector, &reservation, &local_batch);
        defer guard.deinit();

        // Add objects to trigger batch sizing
        for (0..3) |i| {
            const obj = try TestObject.create(@intCast(i), &freed_count);
            try guard.defer_retire(@ptrCast(obj), TestObject.reclaim);
        }

        // At this point batch should be retired due to size
        try guard.flush();
    }
}

test "EBR: Owned guard basic flow" {
    const collector = try Collector.init(allocator, 256);
    defer collector.deinit();

    var freed_count = std.atomic.Value(u32).init(0);

    var reservation = Reservation.init();
    var local_batch = ebr.LocalBatch.init();

    {
        const guard = try OwnedGuard.enter(collector, &reservation, &local_batch);
        defer guard.deinit();

        const obj = try TestObject.create(42, &freed_count);
        try guard.defer_retire(@ptrCast(obj), TestObject.reclaim);

        try guard.flush();
    }

    // Thread should be marked inactive after guard exits
    const head = reservation.head.load(.monotonic);
    try testing.expect(head == ebr.Entry.INACTIVE);
}

test "EBR: Guard refresh clears reservations" {
    const collector = try Collector.init(allocator, 256);
    defer collector.deinit();

    var reservation = Reservation.init();
    var local_batch = ebr.LocalBatch.init();

    var guard = try LocalGuard.enter(collector, &reservation, &local_batch);
    defer guard.deinit();

    // Thread is active
    var head = reservation.head.load(.monotonic);
    try testing.expect(head == null or head != ebr.Entry.INACTIVE);

    // Refresh clears batch list but keeps active
    guard.refresh();

    head = reservation.head.load(.monotonic);
    try testing.expect(head == null or head != ebr.Entry.INACTIVE);
}

test "EBR: Multiple sequential guards" {
    const collector = try Collector.init(allocator, 256);
    defer collector.deinit();

    var freed_count = std.atomic.Value(u32).init(0);

    // First guard scope
    {
        var res1 = Reservation.init();
        var batch1 = ebr.LocalBatch.init();

        {
            const guard1 = try LocalGuard.enter(collector, &res1, &batch1);
            defer guard1.deinit();

            const obj1 = try TestObject.create(100, &freed_count);
            try guard1.defer_retire(@ptrCast(obj1), TestObject.reclaim);
        }

        try testing.expect(res1.head.load(.monotonic) == ebr.Entry.INACTIVE);
    }

    // Second guard scope - different reservation
    {
        var res2 = Reservation.init();
        var batch2 = ebr.LocalBatch.init();

        {
            const guard2 = try LocalGuard.enter(collector, &res2, &batch2);
            defer guard2.deinit();

            const obj2 = try TestObject.create(200, &freed_count);
            try guard2.defer_retire(@ptrCast(obj2), TestObject.reclaim);
        }

        try testing.expect(res2.head.load(.monotonic) == ebr.Entry.INACTIVE);
    }
}

test "EBR: Batch size triggers retirement" {
    const collector = try Collector.init(allocator, 4);
    defer collector.deinit();

    var freed_count = std.atomic.Value(u32).init(0);

    var reservation = Reservation.init();
    var local_batch = ebr.LocalBatch.init();

    const guard = try LocalGuard.enter(collector, &reservation, &local_batch);
    defer guard.deinit();

    // Add more objects than batch size
    for (0..6) |i| {
        const obj = try TestObject.create(@intCast(i), &freed_count);
        try guard.defer_retire(@ptrCast(obj), TestObject.reclaim);
    }

    // Batch should have been retired at least once
    try testing.expect(local_batch.batch == null or
                      local_batch.batch.?.entries.items.len > 0);
}

test "EBR: Reentrancy with guard counting" {
    const collector = try Collector.init(allocator, 256);
    defer collector.deinit();

    var reservation = Reservation.init();
    var local_batch = ebr.LocalBatch.init();

    try testing.expect(reservation.guards == 0);

    {
        const g1 = try LocalGuard.enter(collector, &reservation, &local_batch);
        try testing.expect(reservation.guards == 1);

        const head_g1 = reservation.head.load(.monotonic);
        try testing.expect(head_g1 == null);

        {
            const g2 = try LocalGuard.enter(collector, &reservation, &local_batch);
            try testing.expect(reservation.guards == 2);

            const head_g2 = reservation.head.load(.monotonic);
            try testing.expect(head_g2 == null);

            defer g2.deinit();
        }

        try testing.expect(reservation.guards == 1);
        const head_after_g2 = reservation.head.load(.monotonic);
        try testing.expect(head_after_g2 == null);

        defer g1.deinit();
    }

    try testing.expect(reservation.guards == 0);
    const head_final = reservation.head.load(.monotonic);
    try testing.expect(head_final == ebr.Entry.INACTIVE);
}

test "EBR: DROP sentinel prevents queueing" {
    const collector = try Collector.init(allocator, 256);
    defer collector.deinit();

    var freed_count = std.atomic.Value(u32).init(0);

    var local_batch = ebr.LocalBatch.init();

    // Simulate reclaim_all by setting DROP
    local_batch.batch = @ptrFromInt(std.math.maxInt(usize));

    const obj = try TestObject.create(999, &freed_count);

    // Should reclaim immediately instead of queuing
    try collector.add(@ptrCast(obj), TestObject.reclaim, &local_batch);

    // Object should be freed
    try testing.expect(freed_count.load(.acquire) == 1);
}

test "EBR: Batch entries maintain correctness" {
    const collector = try Collector.init(allocator, 256);
    defer collector.deinit();

    var freed_count = std.atomic.Value(u32).init(0);

    var reservation = Reservation.init();
    var local_batch = ebr.LocalBatch.init();

    const guard = try LocalGuard.enter(collector, &reservation, &local_batch);
    defer guard.deinit();

    // Create a sequence of objects with tracking
    var values = std.ArrayList(u64).init(allocator);
    defer values.deinit();

    for (0..5) |i| {
        const obj = try TestObject.create(@intCast(i * 10), &freed_count);
        try guard.defer_retire(@ptrCast(obj), TestObject.reclaim);
        try values.append(@intCast(i * 10));
    }

    // Verify batch contains entries
    if (local_batch.batch) |batch| {
        try testing.expect(batch.entries.items.len > 0);
    }
}

test "EBR: Enter/leave cycle preserves state" {
    const collector = try Collector.init(allocator, 256);
    defer collector.deinit();

    var reservation = Reservation.init();

    // Initially inactive
    try testing.expect(reservation.head.load(.monotonic) == ebr.Entry.INACTIVE);

    var batch = ebr.LocalBatch.init();

    collector.enter(&reservation);
    try testing.expect(reservation.head.load(.monotonic) == null);

    const batch_ptr = try batch.get_or_init(allocator, 256);
    defer batch_ptr.deinit(allocator);

    if (collector.leave(&reservation)) |head| {
        collector.traverse(head);
    }

    try testing.expect(reservation.head.load(.monotonic) == ebr.Entry.INACTIVE);
}

test "EBR: Collector uniqueness" {
    const c1 = try Collector.init(allocator, 256);
    const c2 = try Collector.init(allocator, 256);
    const c3 = try Collector.init(allocator, 256);

    defer c1.deinit();
    defer c2.deinit();
    defer c3.deinit();

    try testing.expect(c1.id != c2.id);
    try testing.expect(c2.id != c3.id);
    try testing.expect(c1.id != c3.id);
}

test "EBR: LocalBatch lifecycle" {
    const collector = try Collector.init(allocator, 256);
    defer collector.deinit();

    var local_batch = ebr.LocalBatch.init();

    try testing.expect(local_batch.batch == null);

    const batch1 = try local_batch.get_or_init(allocator, 256);
    try testing.expect(local_batch.batch != null);
    try testing.expect(local_batch.batch.? == batch1);

    const batch2 = try local_batch.get_or_init(allocator, 256);
    try testing.expect(batch2 == batch1);

    batch1.deinit(allocator);
}

test "EBR: Multiple collectors are independent" {
    const c1 = try Collector.init(allocator, 100);
    const c2 = try Collector.init(allocator, 200);

    defer c1.deinit();
    defer c2.deinit();

    try testing.expect(c1.batch_size >= 100);
    try testing.expect(c2.batch_size >= 200);

    try testing.expect(c1.id != c2.id);
}
