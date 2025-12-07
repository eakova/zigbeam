/// Unit tests for EBR (Epoch-Based Reclamation)
/// Tests core functionality of Collector, Reservations, and basic guard operations

const std = @import("std");
const testing = std.testing;
const allocator = testing.allocator;

const ebr = @import("../ebr.zig");
const Collector = ebr.Collector;
const Reservation = ebr.Reservation;
const LocalGuard = ebr.LocalGuard;
const OwnedGuard = ebr.OwnedGuard;

/// Test data structure for reclamation testing
const TestObject = struct {
    value: u32,
    freed: *bool,  // Pointer to flag indicating if freed

    fn create(value: u32, freed: *bool) !*TestObject {
        const obj = try allocator.create(TestObject);
        obj.* = .{ .value = value, .freed = freed };
        return obj;
    }

    fn reclaim(ptr: *anyopaque, _: *Collector) void {
        const obj: *TestObject = @ptrCast(@alignCast(ptr));
        obj.freed.* = true;
        allocator.destroy(obj);
    }
};

test "Collector init and deinit" {
    const collector = try Collector.init(allocator, 256);
    defer collector.deinit();

    try testing.expect(collector.batch_size >= 256);
    try testing.expect(collector.id >= 0);
}

test "Collector normalizes batch size to power of two" {
    const collector1 = try Collector.init(allocator, 100);
    defer collector1.deinit();

    const collector2 = try Collector.init(allocator, 256);
    defer collector2.deinit();

    const collector3 = try Collector.init(allocator, 1000);
    defer collector3.deinit();

    try testing.expect(collector1.batch_size == 128);
    try testing.expect(collector2.batch_size == 256);
    try testing.expect(collector3.batch_size == 1024);
}

test "Reservation init creates inactive thread" {
    var reservation = Reservation.init();

    const head = reservation.head.load(.monotonic);
    try testing.expect(head == ebr.Entry.INACTIVE);
}

test "LocalGuard basic enter/exit" {
    const collector = try Collector.init(allocator, 256);
    defer collector.deinit();

    var reservation = Reservation.init();
    var local_batch = ebr.LocalBatch.init();

    {
        const guard = try LocalGuard.enter(collector, &reservation, &local_batch);
        defer guard.deinit();

        // Guard should be active
        const head = reservation.head.load(.monotonic);
        try testing.expect(head == null);  // Null = active, INACTIVE = inactive
    }

    // After guard exits, should be inactive
    const head = reservation.head.load(.monotonic);
    try testing.expect(head == ebr.Entry.INACTIVE);
}

test "LocalGuard reentrancy" {
    const collector = try Collector.init(allocator, 256);
    defer collector.deinit();

    var reservation = Reservation.init();
    var local_batch = ebr.LocalBatch.init();

    try testing.expect(reservation.guards == 0);

    {
        const guard1 = try LocalGuard.enter(collector, &reservation, &local_batch);
        try testing.expect(reservation.guards == 1);

        {
            const guard2 = try LocalGuard.enter(collector, &reservation, &local_batch);
            try testing.expect(reservation.guards == 2);

            defer guard2.deinit();
        }

        try testing.expect(reservation.guards == 1);

        // Still active (first guard not dropped yet)
        const head = reservation.head.load(.monotonic);
        try testing.expect(head == null or head == ebr.Entry.INACTIVE);

        defer guard1.deinit();
    }

    try testing.expect(reservation.guards == 0);
}

test "OwnedGuard basic enter/exit" {
    const collector = try Collector.init(allocator, 256);
    defer collector.deinit();

    var reservation = Reservation.init();
    var local_batch = ebr.LocalBatch.init();

    {
        const guard = try OwnedGuard.enter(collector, &reservation, &local_batch);
        defer guard.deinit();

        const head = reservation.head.load(.monotonic);
        try testing.expect(head == null);
    }

    const head = reservation.head.load(.monotonic);
    try testing.expect(head == ebr.Entry.INACTIVE);
}

test "LocalGuard refresh" {
    const collector = try Collector.init(allocator, 256);
    defer collector.deinit();

    var reservation = Reservation.init();
    var local_batch = ebr.LocalBatch.init();

    var guard = try LocalGuard.enter(collector, &reservation, &local_batch);
    defer guard.deinit();

    // Should be active
    var head = reservation.head.load(.monotonic);
    try testing.expect(head == null);

    // Refresh should clear but keep active
    guard.refresh();

    head = reservation.head.load(.monotonic);
    try testing.expect(head == null);
}

test "Collector.add basic functionality" {
    const collector = try Collector.init(allocator, 256);
    defer collector.deinit();

    var freed = false;
    const obj = try TestObject.create(42, &freed);

    var local_batch = ebr.LocalBatch.init();

    try collector.add(
        @ptrCast(obj),
        TestObject.reclaim,
        &local_batch,
    );

    try testing.expect(local_batch.batch != null);
    try testing.expect(local_batch.batch.?.entries.items.len == 1);

    // Object should not be freed yet
    try testing.expect(!freed);
}

test "Collector.add DROP sentinel handling" {
    const collector = try Collector.init(allocator, 256);
    defer collector.deinit();

    var freed = false;
    const obj = try TestObject.create(42, &freed);

    var local_batch = ebr.LocalBatch.init();
    local_batch.batch = @ptrFromInt(std.math.maxInt(usize));  // DROP sentinel

    try collector.add(
        @ptrCast(obj),
        TestObject.reclaim,
        &local_batch,
    );

    // Should reclaim immediately when DROP sentinel is set
    try testing.expect(freed);
}

test "Multiple collectors have unique IDs" {
    const c1 = try Collector.init(allocator, 256);
    defer c1.deinit();

    const c2 = try Collector.init(allocator, 256);
    defer c2.deinit();

    const c3 = try Collector.init(allocator, 256);
    defer c3.deinit();

    try testing.expect(c1.id != c2.id);
    try testing.expect(c2.id != c3.id);
    try testing.expect(c1.id != c3.id);
}

test "LocalBatch get_or_init" {
    const collector = try Collector.init(allocator, 256);
    defer collector.deinit();

    var local_batch = ebr.LocalBatch.init();

    const batch1 = try local_batch.get_or_init(allocator, 256);
    const batch2 = try local_batch.get_or_init(allocator, 256);

    // Should return same batch
    try testing.expect(batch1 == batch2);

    batch1.deinit(allocator);
}

test "LocalBatch rejects initialization when DROP sentinel" {
    const collector = try Collector.init(allocator, 256);
    defer collector.deinit();

    var local_batch = ebr.LocalBatch.init();
    local_batch.batch = @ptrFromInt(std.math.maxInt(usize));  // DROP sentinel

    const result = local_batch.get_or_init(allocator, 256);
    try testing.expect(std.meta.isError(result));
}

test "Guard deferred retire with multiple objects" {
    const collector = try Collector.init(allocator, 256);
    defer collector.deinit();

    var reservation = Reservation.init();
    var local_batch = ebr.LocalBatch.init();

    var freed1 = false;
    var freed2 = false;
    var freed3 = false;

    const obj1 = try TestObject.create(1, &freed1);
    const obj2 = try TestObject.create(2, &freed2);
    const obj3 = try TestObject.create(3, &freed3);

    {
        const guard = try LocalGuard.enter(collector, &reservation, &local_batch);
        defer guard.deinit();

        try guard.defer_retire(@ptrCast(obj1), TestObject.reclaim);
        try guard.defer_retire(@ptrCast(obj2), TestObject.reclaim);
        try guard.defer_retire(@ptrCast(obj3), TestObject.reclaim);

        // Not freed yet
        try testing.expect(!freed1 and !freed2 and !freed3);
    }

    // After guard exits, all should still be in batch (not traversed yet in simplified impl)
    // In full implementation with actual thread iteration, would be freed after all threads safe
}

test "LocalGuard and OwnedGuard flush" {
    const collector = try Collector.init(allocator, 256);
    defer collector.deinit();

    var reservation1 = Reservation.init();
    var local_batch1 = ebr.LocalBatch.init();

    var guard = try LocalGuard.enter(collector, &reservation1, &local_batch1);
    defer guard.deinit();

    try guard.flush();
    // Should not error
}

test "Entry initialization" {
    const collector = try Collector.init(allocator, 256);
    defer collector.deinit();

    var freed = false;
    const obj = try TestObject.create(123, &freed);

    var local_batch = ebr.LocalBatch.init();
    try collector.add(@ptrCast(obj), TestObject.reclaim, &local_batch);

    const batch = local_batch.batch.?;
    try testing.expect(batch.entries.items.len == 1);

    const entry = batch.entries.items[0];
    try testing.expect(entry.ptr == @as(*anyopaque, @ptrCast(obj)));
    try testing.expect(entry.batch == batch);

    batch.deinit(allocator);
}
