/// Integration tests for Estimator and TinyLFU
/// Tests realistic workloads and patterns

const std = @import("std");
const testing = std.testing;
const allocator = testing.allocator;

const estimator_mod = @import("../estimator.zig");
const Estimator = estimator_mod.Estimator;
const TinyLFU = estimator_mod.TinyLFU;
const compare_freq = estimator_mod.compare_freq;

test "Estimator: frequency ordering" {
    const est = try Estimator.init(allocator, 4, 1024);
    defer est.deinit();

    const keys = [_]u64{ 1, 2, 3, 4, 5 };
    const counts = [_]usize{ 1, 5, 10, 3, 8 };

    // Create frequencies
    for (keys, 0..) |key, i| {
        for (0..counts[i]) |_| {
            est.incr(key);
        }
    }

    // Verify ordering (with some tolerance for estimation error)
    for (0..keys.len - 1) |i| {
        const freq_i = est.get(keys[i]);
        const freq_j = est.get(keys[i + 1]);

        // Rough ordering should hold
        if (counts[i] * 2 < counts[i + 1]) {
            try testing.expect(freq_i < freq_j);
        }
    }
}

test "Estimator: rapid aging" {
    const est = try Estimator.init(allocator, 4, 256);
    defer est.deinit();

    const key = 111;

    // Build frequency
    for (0..30) |_| {
        est.incr(key);
    }

    const freq1 = est.get(key);

    // Rapid aging
    for (0..5) |_| {
        est.age(1);
    }

    const freq_after = est.get(key);

    try testing.expect(freq_after < freq1);
}

test "TinyLFU: stress with hot keys" {
    const lfu = try TinyLFU.new(allocator, 100);
    defer lfu.deinit();

    const hot_key = 1000;
    const warm_key = 2000;
    const cold_key = 3000;

    // Generate realistic pattern
    for (0..500) |i| {
        if (i % 10 == 0) {
            lfu.incr(hot_key);
        } else if (i % 5 == 0) {
            lfu.incr(warm_key);
        } else if (i % 20 == 0) {
            lfu.incr(cold_key);
        }
    }

    const hot_freq = lfu.get(hot_key);
    const warm_freq = lfu.get(warm_key);
    const cold_freq = lfu.get(cold_key);

    try testing.expect(hot_freq > warm_freq);
    try testing.expect(warm_freq > cold_freq);
}

test "TinyLFU: window aging simulation" {
    const lfu = try TinyLFU.new(allocator, 10);
    defer lfu.deinit();

    // window_limit = 80

    const key1 = 111;
    const key2 = 222;

    // Fill to 50 operations
    for (0..50) |_| {
        lfu.incr(key1);
    }

    const freq1_initial = lfu.get(key1);

    // Trigger aging by going past window_limit
    for (0..100) |_| {
        lfu.incr(key2);
    }

    const freq1_aged = lfu.get(key1);

    // After aging, freq should decrease
    try testing.expect(freq1_aged < freq1_initial);
}

test "TinyLFU: compare_freq utility" {
    const lfu = try TinyLFU.new(allocator, 100);
    defer lfu.deinit();

    const hot = 1111;
    const cold = 2222;

    for (0..30) |_| {
        lfu.incr(hot);
    }

    for (0..3) |_| {
        lfu.incr(cold);
    }

    // Hot should be greater than cold
    try testing.expect(compare_freq(lfu, hot, cold));

    // Cold should be less than hot
    try testing.expect(!compare_freq(lfu, cold, hot));
}

test "Estimator: large dataset" {
    const est = try Estimator.init(allocator, 4, 4096);
    defer est.deinit();

    const N = 500;

    // Create 500 keys with varying frequencies
    for (0..N) |i| {
        const key = i * 13 + 7; // Pseudo-random
        const count = (i % 50) + 1;

        for (0..count) |_| {
            est.incr(@intCast(key));
        }
    }

    // Verify highest frequency key is identifiable
    var max_freq: u8 = 0;
    var max_key: usize = 0;

    for (0..N) |i| {
        const key = i * 13 + 7;
        const freq = est.get(@intCast(key));

        if (freq > max_freq) {
            max_freq = freq;
            max_key = key;
        }
    }

    try testing.expect(max_freq > 0);
}

test "TinyLFU: admission decision pattern" {
    const lfu = try TinyLFU.new(allocator, 100);
    defer lfu.deinit();

    // Simulate cache admission decisions
    var admitted = std.ArrayList(u64).init(allocator);
    defer admitted.deinit();

    const candidates = [_]u64{ 100, 200, 300, 400, 500 };

    // 100 and 200 are hot
    for (0..100) |_| {
        lfu.incr(100);
        lfu.incr(200);
    }

    // 300 and 400 are warm
    for (0..20) |_| {
        lfu.incr(300);
        lfu.incr(400);
    }

    // 500 is cold
    lfu.incr(500);

    // Admission should prefer hot candidates
    const freq_100 = lfu.get(100);
    const freq_500 = lfu.get(500);

    try testing.expect(freq_100 > freq_500);
}

test "Estimator: collision handling" {
    const est = try Estimator.init(allocator, 4, 16); // Very small to force collisions

    for (0..100) |i| {
        est.incr(@intCast(i));
    }

    // Even with collisions, should estimate non-zero frequencies
    for (0..100) |i| {
        const freq = est.get(@intCast(i));
        try testing.expect(freq > 0);
    }

    est.deinit();
}

test "TinyLFU: workload pattern separation" {
    const lfu = try TinyLFU.new(allocator, 200);
    defer lfu.deinit();

    // Two distinct workload patterns
    const pattern_a = [_]u64{ 1000, 1001, 1002, 1003 };
    const pattern_b = [_]u64{ 2000, 2001, 2002, 2003 };

    // Pattern A gets heavy traffic
    for (0..200) |_| {
        for (pattern_a) |key| {
            lfu.incr(key);
        }
    }

    // Pattern B gets light traffic
    for (0..10) |_| {
        for (pattern_b) |key| {
            lfu.incr(key);
        }
    }

    // Verify pattern A is hotter
    const freq_a = lfu.get(pattern_a[0]);
    const freq_b = lfu.get(pattern_b[0]);

    try testing.expect(freq_a > freq_b);
}

test "Estimator: age multiple shifts" {
    const est = try Estimator.init(allocator, 4, 256);
    defer est.deinit();

    const key = 555;

    // Build frequency
    for (0..100) |_| {
        est.incr(key);
    }

    const freq_initial = est.get(key);

    // Age by 2 (divide by 4)
    est.age(2);

    const freq_after = est.get(key);

    try testing.expect(freq_after < freq_initial);
    try testing.expect(freq_after > 0); // Should still be non-zero
}

test "TinyLFU: reset consistency" {
    const lfu = try TinyLFU.new(allocator, 100);
    defer lfu.deinit();

    const key = 777;

    // Build frequency
    for (0..50) |_| {
        lfu.incr(key);
    }

    try testing.expect(lfu.get(key) > 0);

    // Reset
    lfu.reset();

    try testing.expect(lfu.get(key) == 0);
    try testing.expect(lfu.window_counter.load(.relaxed) == 0);
}

test "TinyLFU: mixed operations workload" {
    const lfu = try TinyLFU.new(allocator, 150);
    defer lfu.deinit();

    // Realistic mixed workload
    var rng = std.Random.DefaultPrng.init(12345);
    const rand = rng.random();

    for (0..1000) |_| {
        const key = rand.intRangeAtMost(u64, 0, 100);

        lfu.incr(key);

        if (rand.float(f32) < 0.1) {
            // Occasionally check frequency
            _ = lfu.get(key);
        }

        if (rand.float(f32) < 0.05) {
            // Rarely reset (but not zero since window_limit = 8×capacity)
            if (lfu.window_counter.load(.relaxed) > 10000) {
                lfu.reset();
            }
        }
    }
}

test "Estimator: distribution preservation" {
    const est = try Estimator.init(allocator, 4, 2048);
    defer est.deinit();

    // Create Zipfian-like distribution (power law)
    const keys = [_]u64{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
    const counts = [_]usize{ 100, 50, 33, 25, 20, 16, 14, 12, 11, 10 };

    for (keys, 0..) |key, i| {
        for (0..counts[i]) |_| {
            est.incr(key);
        }
    }

    // Verify distribution is mostly preserved
    var prev_freq: u8 = 255;

    for (keys) |key| {
        const freq = est.get(key);
        try testing.expect(freq <= prev_freq); // Non-increasing
        prev_freq = freq;
    }
}

test "TinyLFU: window boundary behavior" {
    const lfu = try TinyLFU.new(allocator, 10);
    defer lfu.deinit();

    const key = 999;

    // Incr near window_limit boundary
    for (0..75) |_| {
        lfu.incr(key);
    }

    const freq_before = lfu.get(key);

    // Cross window boundary (will trigger aging)
    for (0..50) |_| {
        lfu.incr(key);
    }

    const freq_after = lfu.get(key);

    // After aging, frequency should decrease or stay same
    try testing.expect(freq_after <= freq_before);
}
