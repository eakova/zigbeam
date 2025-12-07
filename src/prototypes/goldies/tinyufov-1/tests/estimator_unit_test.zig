/// Unit tests for Estimator and TinyLFU
/// Tests frequency estimation, windowing, and aging

const std = @import("std");
const testing = std.testing;
const allocator = testing.allocator;

const estimator_mod = @import("../estimator.zig");
const Estimator = estimator_mod.Estimator;
const TinyLFU = estimator_mod.TinyLFU;

test "Estimator init and deinit" {
    const est = try Estimator.init(allocator, 4, 1024);
    defer est.deinit();

    try testing.expect(est.hashes == 4);
    try testing.expect(est.slots == 1024);
}

test "Estimator optimal_paras small cache" {
    const paras = try Estimator.optimal_paras(allocator, 1000);

    try testing.expect(paras.hashes >= 4);
    try testing.expect(paras.slots >= 65536);
}

test "Estimator optimal_paras medium cache" {
    const paras = try Estimator.optimal_paras(allocator, 100_000);

    try testing.expect(paras.hashes >= 4);
    try testing.expect(paras.slots >= 65536);
}

test "Estimator optimal_paras large cache" {
    const paras = try Estimator.optimal_paras(allocator, 1_000_000);

    try testing.expect(paras.hashes >= 5);
    try testing.expect(paras.slots >= 131072);
}

test "Estimator incr single key" {
    const est = try Estimator.init(allocator, 4, 256);
    defer est.deinit();

    const key = 12345;

    est.incr(key);
    try testing.expect(est.get(key) >= 1);
}

test "Estimator incr multiple increments" {
    const est = try Estimator.init(allocator, 4, 256);
    defer est.deinit();

    const key = 99999;

    for (0..5) |_| {
        est.incr(key);
    }

    const freq = est.get(key);
    try testing.expect(freq >= 4);
}

test "Estimator get returns reasonable estimate" {
    const est = try Estimator.init(allocator, 4, 1024);
    defer est.deinit();

    const key1 = 111;
    const key2 = 222;

    // Increment key1 much more
    for (0..10) |_| {
        est.incr(key1);
    }

    for (0..2) |_| {
        est.incr(key2);
    }

    const freq1 = est.get(key1);
    const freq2 = est.get(key2);

    try testing.expect(freq1 > freq2);
}

test "Estimator zero frequency for unseen key" {
    const est = try Estimator.init(allocator, 4, 256);
    defer est.deinit();

    const unseen = 999999;
    const freq = est.get(unseen);

    try testing.expect(freq == 0);
}

test "Estimator saturation at 255" {
    const est = try Estimator.init(allocator, 4, 256);
    defer est.deinit();

    const key = 555;

    // Increment many times
    for (0..300) |_| {
        est.incr(key);
    }

    const freq = est.get(key);
    try testing.expect(freq <= 255);
}

test "Estimator age reduces frequencies" {
    const est = try Estimator.init(allocator, 4, 256);
    defer est.deinit();

    const key = 777;

    // Build up frequency
    for (0..20) |_| {
        est.incr(key);
    }

    const freq_before = est.get(key);

    // Age by 1 (divide by 2)
    est.age(1);

    const freq_after = est.get(key);

    try testing.expect(freq_after < freq_before);
}

test "Estimator reset clears all" {
    const est = try Estimator.init(allocator, 4, 256);
    defer est.deinit();

    const key = 888;

    for (0..10) |_| {
        est.incr(key);
    }

    try testing.expect(est.get(key) > 0);

    est.reset();

    try testing.expect(est.get(key) == 0);
}

test "TinyLFU init" {
    const lfu = try TinyLFU.new(allocator, 1000);
    defer lfu.deinit();

    try testing.expect(lfu.cache_size == 1000);
    try testing.expect(lfu.window_limit == 8000);
}

test "TinyLFU new_compact" {
    const lfu = try TinyLFU.new_compact(allocator, 1000);
    defer lfu.deinit();

    try testing.expect(lfu.cache_size == 1000);
    try testing.expect(lfu.window_limit == 4000);
}

test "TinyLFU incr" {
    const lfu = try TinyLFU.new(allocator, 100);
    defer lfu.deinit();

    const key = 42;

    lfu.incr(key);

    const freq = lfu.get(key);
    try testing.expect(freq >= 1);
}

test "TinyLFU get frequency" {
    const lfu = try TinyLFU.new(allocator, 100);
    defer lfu.deinit();

    const key = 555;

    for (0..5) |_| {
        lfu.incr(key);
    }

    const freq = lfu.get(key);
    try testing.expect(freq >= 4);
}

test "TinyLFU compare frequencies" {
    const lfu = try TinyLFU.new(allocator, 100);
    defer lfu.deinit();

    const hot_key = 1000;
    const cold_key = 2000;

    // Make hot_key hotter
    for (0..20) |_| {
        lfu.incr(hot_key);
    }

    for (0..3) |_| {
        lfu.incr(cold_key);
    }

    const freq_hot = lfu.get(hot_key);
    const freq_cold = lfu.get(cold_key);

    try testing.expect(freq_hot > freq_cold);
}

test "TinyLFU window counter" {
    const lfu = try TinyLFU.new(allocator, 10);
    defer lfu.deinit();

    const counter_before = lfu.window_counter.load(.relaxed);

    lfu.incr(111);

    const counter_after = lfu.window_counter.load(.relaxed);

    try testing.expect(counter_after > counter_before);
}

test "TinyLFU reset" {
    const lfu = try TinyLFU.new(allocator, 100);
    defer lfu.deinit();

    const key = 777;

    for (0..10) |_| {
        lfu.incr(key);
    }

    try testing.expect(lfu.get(key) > 0);

    lfu.reset();

    try testing.expect(lfu.get(key) == 0);
}

test "TinyLFU aging on window limit" {
    const lfu = try TinyLFU.new(allocator, 10);
    defer lfu.deinit();

    // With window_limit = 80, each incr should trigger age at 80 ops

    const key = 999;

    // Do operations to trigger aging
    for (0..100) |_| {
        lfu.incr(key);
    }

    // Frequency should have aged but still be > 0
    const freq = lfu.get(key);
    try testing.expect(freq > 0);
}

test "TinyLFU multiple keys" {
    const lfu = try TinyLFU.new(allocator, 100);
    defer lfu.deinit();

    const keys = [_]u64{ 111, 222, 333, 444, 555 };

    // Different frequencies
    for (keys, 0..) |key, i| {
        for (0..i + 1) |_| {
            lfu.incr(key);
        }
    }

    // Verify ordering
    for (keys, 0..) |key, i| {
        const freq = lfu.get(key);
        try testing.expect(freq >= i + 1 - 2); // Allow some estimation error
    }
}

test "TinyLFU hot vs cold keys" {
    const lfu = try TinyLFU.new(allocator, 100);
    defer lfu.deinit();

    const hot = 9999;
    const cold = 1111;

    // Hot key: many increments
    for (0..50) |_| {
        lfu.incr(hot);
    }

    // Cold key: few increments
    for (0..2) |_| {
        lfu.incr(cold);
    }

    const hot_freq = lfu.get(hot);
    const cold_freq = lfu.get(cold);

    try testing.expect(hot_freq > cold_freq);
}

test "Estimator independence across hashes" {
    const est = try Estimator.init(allocator, 4, 1024);
    defer est.deinit();

    const key = 54321;

    est.incr(key);

    // All hashes should have seen the key
    const freq = est.get(key);
    try testing.expect(freq > 0);
}

test "TinyLFU compact vs standard" {
    const lfu_std = try TinyLFU.new(allocator, 1000);
    defer lfu_std.deinit();

    const lfu_compact = try TinyLFU.new_compact(allocator, 1000);
    defer lfu_compact.deinit();

    try testing.expect(lfu_std.window_limit == 8000);
    try testing.expect(lfu_compact.window_limit == 4000);
}

test "Estimator many keys stress" {
    const est = try Estimator.init(allocator, 4, 4096);
    defer est.deinit();

    // Add 100 different keys
    for (0..100) |i| {
        const key = @as(u64, @intCast(i)) * 17; // Spread out keys
        est.incr(key);
        est.incr(key);
    }

    // All should have some frequency
    for (0..100) |i| {
        const key = @as(u64, @intCast(i)) * 17;
        const freq = est.get(key);
        try testing.expect(freq >= 1);
    }
}
