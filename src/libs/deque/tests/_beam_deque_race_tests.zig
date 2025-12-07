const std = @import("std");
const testing = std.testing;
const Thread = std.Thread;
const Atomic = std.atomic.Value;
const Deque = @import("deque").Deque;

// =============================================================================
// Multi-Threaded Race Condition and Stress Tests
// =============================================================================

test "Deque: single item race (owner pop vs thief steal)" {
    // Test the critical race condition many times to increase probability
    // of hitting the tail == head case
    const iterations = 1000;
    var i: usize = 0;

    while (i < iterations) : (i += 1) {
        var result = try Deque(u32).init(testing.allocator, 8);
        defer result.worker.deinit();

        // Push exactly one item
        try result.worker.push(42);

        // Spawn thief thread to steal
        const thief_handle = try Thread.spawn(.{}, struct {
            fn run(stealer: *Deque(u32).Stealer) void {
                _ = stealer.steal();
            }
        }.run, .{&result.stealer});

        // Owner tries to pop
        _ = result.worker.pop();

        // Wait for thief
        thief_handle.join();

        // Verify deque is empty - exactly one thread got the item
        try testing.expect(result.worker.isEmpty());
        try testing.expectEqual(@as(?u32, null), result.worker.pop());
        try testing.expectEqual(@as(?u32, null), result.stealer.steal());
    }
}

test "Deque: concurrent push and steal" {
    var result = try Deque(usize).init(testing.allocator, 1024);
    defer result.worker.deinit();

    const num_items: usize = 10000;
    const num_thieves: usize = 4;

    // Counter for stolen items
    var stolen = Atomic(usize).init(0);
    var done = Atomic(bool).init(false);

    // Spawn thieves
    var thieves: [num_thieves]Thread = undefined;
    for (&thieves) |*thief| {
        thief.* = try Thread.spawn(.{}, struct {
            fn run(stealer: *Deque(usize).Stealer, counter: *Atomic(usize), done_flag: *Atomic(bool)) void {
                var count: usize = 0;
                while (!done_flag.load(.acquire) or !stealer.isEmpty()) {
                    if (stealer.steal()) |_| {
                        count += 1;
                    } else {
                        Thread.yield() catch {};
                    }
                }
                _ = counter.fetchAdd(count, .monotonic);
            }
        }.run, .{ &result.stealer, &stolen, &done });
    }

    // Owner pushes items
    var pushed: usize = 0;
    while (pushed < num_items) : (pushed += 1) {
        // Retry on Full (thieves are draining concurrently)
        while (true) {
            result.worker.push(pushed) catch |err| {
                if (err == error.Full) {
                    Thread.yield() catch {};
                    continue;
                }
                return err;
            };
            break; // Success
        }
    }

    // Signal thieves that pushing is done
    done.store(true, .release);

    // Wait for thieves to finish
    for (thieves) |thief| {
        thief.join();
    }

    // Owner pops remaining items
    var popped: usize = 0;
    while (result.worker.pop()) |_| {
        popped += 1;
    }

    // Verify all items accounted for
    const total = stolen.load(.monotonic) + popped;
    try testing.expectEqual(num_items, total);
}

test "Deque: multi-threaded stress test (1M items)" {
    var result = try Deque(u64).init(testing.allocator, 4096);
    defer result.worker.deinit();

    const num_items: usize = 1_000_000;
    const num_thieves: usize = 8;

    // Track all consumed items to verify uniqueness
    const allocator = testing.allocator;
    var consumed_items = try allocator.alloc(Atomic(bool), num_items);
    defer allocator.free(consumed_items);
    for (consumed_items) |*item| {
        item.* = Atomic(bool).init(false);
    }

    var stolen = Atomic(usize).init(0);
    var done = Atomic(bool).init(false);

    // Spawn thieves
    var thieves: [num_thieves]Thread = undefined;
    for (&thieves) |*thief| {
        thief.* = try Thread.spawn(.{}, struct {
            fn run(stealer: *Deque(u64).Stealer, counter: *Atomic(usize), items: []Atomic(bool), done_flag: *Atomic(bool)) void {
                var count: usize = 0;
                while (!done_flag.load(.acquire) or !stealer.isEmpty()) {
                    if (stealer.steal()) |value| {
                        count += 1;
                        // Mark as consumed
                        _ = items[@intCast(value)].swap(true, .monotonic);
                    } else {
                        Thread.yield() catch {};
                    }
                }
                _ = counter.fetchAdd(count, .monotonic);
            }
        }.run, .{ &result.stealer, &stolen, consumed_items, &done });
    }

    // Owner pushes all items
    var pushed: usize = 0;
    while (pushed < num_items) : (pushed += 1) {
        // Retry on Full
        while (true) {
            result.worker.push(@intCast(pushed)) catch |err| {
                if (err == error.Full) {
                    Thread.yield() catch {};
                    continue;
                }
                return err;
            };
            break; // Success
        }
    }

    // Signal thieves that pushing is done
    done.store(true, .release);

    // Wait for thieves
    for (thieves) |thief| {
        thief.join();
    }

    // Owner pops remaining items
    var popped: usize = 0;
    while (result.worker.pop()) |value| {
        popped += 1;
        _ = consumed_items[@intCast(value)].swap(true, .monotonic);
    }

    // Verify total count
    const total = stolen.load(.monotonic) + popped;
    try testing.expectEqual(num_items, total);

    // Verify all items consumed exactly once
    for (consumed_items) |*item| {
        try testing.expect(item.load(.monotonic));
    }
}

test "Deque: multiple thieves contention" {
    var result = try Deque(u32).init(testing.allocator, 1024);
    defer result.worker.deinit();

    const num_items: usize = 1000;
    const num_thieves: usize = 16; // High contention

    var stolen_counts: [num_thieves]Atomic(usize) = undefined;
    for (&stolen_counts) |*count| {
        count.* = Atomic(usize).init(0);
    }

    // Owner pushes all items first
    var i: usize = 0;
    while (i < num_items) : (i += 1) {
        try result.worker.push(@intCast(i));
    }

    // Spawn many thieves to create contention
    var thieves: [num_thieves]Thread = undefined;
    for (&thieves, 0..) |*thief, idx| {
        thief.* = try Thread.spawn(.{}, struct {
            fn run(stealer: *Deque(u32).Stealer, counter: *Atomic(usize)) void {
                var count: usize = 0;
                while (stealer.steal()) |_| {
                    count += 1;
                }
                counter.store(count, .monotonic);
            }
        }.run, .{ &result.stealer, &stolen_counts[idx] });
    }

    // Wait for all thieves
    for (thieves) |thief| {
        thief.join();
    }

    // Sum stolen counts
    var total_stolen: usize = 0;
    for (&stolen_counts) |*count| {
        total_stolen += count.load(.monotonic);
    }

    // Verify all items stolen
    try testing.expectEqual(num_items, total_stolen);
    try testing.expect(result.worker.isEmpty());
}

test "Deque: multiple thieves contention-128" {
    var result = try Deque(u32).init(testing.allocator, 128);
    defer result.worker.deinit();

    const num_items: usize = 1000;
    const num_thieves: usize = 16; // High contention

    var stolen_counts: [num_thieves]Atomic(usize) = undefined;
    for (&stolen_counts) |*count| {
        count.* = Atomic(usize).init(0);
    }

    var done = Atomic(bool).init(false);

    // Spawn many thieves BEFORE pushing (so they can drain concurrently)
    var thieves: [num_thieves]Thread = undefined;
    for (&thieves, 0..) |*thief, idx| {
        thief.* = try Thread.spawn(.{}, struct {
            fn run(stealer: *Deque(u32).Stealer, counter: *Atomic(usize), done_flag: *Atomic(bool)) void {
                var count: usize = 0;
                while (!done_flag.load(.acquire) or !stealer.isEmpty()) {
                    if (stealer.steal()) |_| {
                        count += 1;
                    } else {
                        Thread.yield() catch {};
                    }
                }
                counter.store(count, .monotonic);
            }
        }.run, .{ &result.stealer, &stolen_counts[idx], &done });
    }

    // Owner pushes items with retry on Full
    var i: usize = 0;
    while (i < num_items) : (i += 1) {
        while (true) {
            result.worker.push(@intCast(i)) catch |err| {
                if (err == error.Full) {
                    Thread.yield() catch {};
                    continue;
                }
                return err;
            };
            break; // Success
        }
    }

    // Signal done
    done.store(true, .release);

    // Wait for all thieves
    for (thieves) |thief| {
        thief.join();
    }

    // Sum stolen counts
    var total_stolen: usize = 0;
    for (&stolen_counts) |*count| {
        total_stolen += count.load(.monotonic);
    }

    // Verify all items stolen
    try testing.expectEqual(num_items, total_stolen);
}

test "Deque: concurrent push/pop by owner, steal by thieves" {
    var result = try Deque(u64).init(testing.allocator, 256);
    defer result.worker.deinit();

    const num_items: usize = 50000;
    const num_thieves: usize = 4;

    var owner_popped = Atomic(usize).init(0);
    var stolen = Atomic(usize).init(0);
    var done = Atomic(bool).init(false);

    // Spawn thieves
    var thieves: [num_thieves]Thread = undefined;
    for (&thieves) |*thief| {
        thief.* = try Thread.spawn(.{}, struct {
            fn run(stealer: *Deque(u64).Stealer, counter: *Atomic(usize), done_flag: *Atomic(bool)) void {
                var count: usize = 0;
                while (!done_flag.load(.acquire) or !stealer.isEmpty()) {
                    if (stealer.steal()) |_| {
                        count += 1;
                    } else {
                        Thread.yield() catch {};
                    }
                }
                _ = counter.fetchAdd(count, .monotonic);
            }
        }.run, .{ &result.stealer, &stolen, &done });
    }

    // Owner pushes and occasionally pops
    var pushed: usize = 0;
    var local_popped: usize = 0;
    while (pushed < num_items) : (pushed += 1) {
        // Push
        while (true) {
            result.worker.push(pushed) catch |err| {
                if (err == error.Full) {
                    Thread.yield() catch {};
                    continue;
                }
                return err;
            };
            break; // Success
        }

        // Occasionally pop
        if (pushed % 10 == 0) {
            if (result.worker.pop()) |_| {
                local_popped += 1;
            }
        }
    }

    // Signal done
    done.store(true, .release);

    // Wait for thieves
    for (thieves) |thief| {
        thief.join();
    }

    // Pop remaining
    while (result.worker.pop()) |_| {
        local_popped += 1;
    }

    owner_popped.store(local_popped, .monotonic);

    // Verify accounting
    const total = owner_popped.load(.monotonic) + stolen.load(.monotonic);
    try testing.expectEqual(num_items, total);
}

test "Deque: wraparound with concurrent access" {
    var result = try Deque(u32).init(testing.allocator, 16);
    defer result.worker.deinit();

    const cycles = 100;
    var stolen = Atomic(usize).init(0);
    var done = Atomic(bool).init(false);

    // Spawn thief
    const thief = try Thread.spawn(.{}, struct {
        fn run(stealer: *Deque(u32).Stealer, counter: *Atomic(usize), done_flag: *Atomic(bool)) void {
            var count: usize = 0;
            while (!done_flag.load(.acquire)) {
                if (stealer.steal()) |_| {
                    count += 1;
                }
            }
            _ = counter.fetchAdd(count, .monotonic);
        }
    }.run, .{ &result.stealer, &stolen, &done });

    // Owner fills and drains multiple times to test wraparound
    var cycle: usize = 0;
    var total_pushed: usize = 0;
    while (cycle < cycles) : (cycle += 1) {
        var i: usize = 0;
        while (i < 12) : (i += 1) {
            while (true) {
                result.worker.push(@intCast(i)) catch |err| {
                    if (err == error.Full) {
                        Thread.yield() catch {};
                        continue;
                    }
                    return err;
                };
                break; // Success
            }
            total_pushed += 1;
        }

        // Pop some
        var popped: usize = 0;
        while (popped < 4) : (popped += 1) {
            _ = result.worker.pop();
        }
    }

    // Signal done
    done.store(true, .release);
    thief.join();

    // Items may still be in queue, that's okay
    // Just verify no crashes during wraparound
}
