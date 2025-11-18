const std = @import("std");
const CP = @import("cache_padded.zig").CachePadded;

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    const allocator = std.heap.page_allocator;

    // ---------------------------------------------
    // 1) See what line size we decided on
    // ---------------------------------------------
    const line = CP.lineSize();
    try stdout.print("Detected cache line size (runtime): {d} bytes\n", .{line});

    // ---------------------------------------------
    // 2) Static padding (compile-time arch-based)
    //    Uses archLine() internally (64 / 128 / 32 ...)
    // ---------------------------------------------
    var static_val = CP.Static(u32).init(123);
    try stdout.print("Static padded value (u32): {d}\n", .{static_val.value});

    // You can still mutate the inner value
    static_val.value += 1;
    try stdout.print("Static padded value after +=1: {d}\n", .{static_val.value});

    // ---------------------------------------------
    // 3) Runtime Auto padding (allocator-based)
    //    Padding size is decided at runtime via sysfs (Linux) or arch fallback
    // ---------------------------------------------
    var auto_val = try CP.Auto(u32).init(allocator, 42);
    defer auto_val.deinit(allocator);

    try stdout.print("Auto padded value (u32): {d}\n", .{auto_val.value});
    auto_val.value = 100;
    try stdout.print("Auto padded value after set: {d}\n", .{auto_val.value});

    // ---------------------------------------------
    // 4) NUMA-style double padding with NumaAuto
    //    No need to pass a line size; uses archLine() internally.
    // ---------------------------------------------
    var numa_counter = CP.NumaAuto(u64).init(0);
    try stdout.print("NumaAuto counter initial: {d}\n", .{numa_counter.value});

    numa_counter.value += 5;
    try stdout.print("NumaAuto counter after +=5: {d}\n", .{numa_counter.value});

    // ---------------------------------------------
    // 5) AtomicAuto: cache-line isolated atomic counter
    //    This is what you plug into MPMC queues / Chase-Lev / S3-FIFO, etc.
    // ---------------------------------------------
    var atomic_counter = CP.AtomicAuto(i64).init(0);

    // Simulate a few increments (single-thread demo)
    _ = atomic_counter.fetchAdd(1, .relaxed);
    _ = atomic_counter.fetchAdd(10, .relaxed);
    const current = atomic_counter.load(.acquire);

    try stdout.print("AtomicAuto counter after two increments: {d}\n", .{current});

    // You can also store explicitly if needed
    atomic_counter.store(-5, .release);
    const after_store = atomic_counter.load(.acquire);
    try stdout.print("AtomicAuto counter after store(-5): {d}\n", .{after_store});

    // ---------------------------------------------
    // 6) Explicit line override (optional)
    //    If you KNOW you want 128-byte lines everywhere, you can do:
    // ---------------------------------------------
    const explicit_static = CP.StaticWithLine(u64, 128).init(999);
    try stdout.print("Explicit Static(128) value: {d}\n", .{explicit_static.value});
}
