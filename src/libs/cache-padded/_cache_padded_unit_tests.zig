const std = @import("std");
const cache_padded = @import("cache_padded.zig").CachePadded;

test "Static cache padding aligns and pads to at least cache line" {
    const line = std.atomic.cache_line;

    const StaticU32 = cache_padded.Static(u32);
    try std.testing.expect(@alignOf(StaticU32) >= line);
    try std.testing.expect(@sizeOf(StaticU32) >= line);

    var v = StaticU32.init(123);
    try std.testing.expectEqual(@as(u32, 123), v.value);
    v.value = 456;
    try std.testing.expectEqual(@as(u32, 456), v.value);
}

test "NumaAuto provides at least two cache lines of storage" {
    const line = std.atomic.cache_line;
    const NumaU64 = cache_padded.NumaAuto(u64);

    try std.testing.expect(@alignOf(NumaU64) >= line);
    try std.testing.expect(@sizeOf(NumaU64) >= 2 * line);

    var v = NumaU64.init(0);
    v.value += 5;
    try std.testing.expectEqual(@as(u64, 5), v.value);
}

test "AtomicAuto behaves as a cache-padded atomic counter" {
    const line = std.atomic.cache_line;
    const AtomicI64 = cache_padded.AtomicAuto(i64);

    try std.testing.expect(@alignOf(AtomicI64) >= line);
    try std.testing.expect(@sizeOf(AtomicI64) >= line);

    var counter = AtomicI64.init(0);
    _ = counter.fetchAdd(1, .relaxed);
    _ = counter.fetchAdd(10, .relaxed);
    const cur = counter.load(.acquire);
    try std.testing.expectEqual(@as(i64, 11), cur);

    counter.store(-5, .release);
    const after = counter.load(.acquire);
    try std.testing.expectEqual(@as(i64, -5), after);
}

test "Auto(T) allocates padding only when needed" {
    const allocator = std.testing.allocator;
    const AutoU32 = cache_padded.Auto(u32);

    var v = try AutoU32.init(allocator, 42);
    defer v.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 42), v.value);

    // We can't assert exact pad length (depends on runtime detection),
    // but we can assert that total size is at least cache_line.
    const line = std.atomic.cache_line;
    try std.testing.expect(@sizeOf(AutoU32) >= line);
}
