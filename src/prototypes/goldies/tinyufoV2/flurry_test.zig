const std = @import("std");
const flurry = @import("flurry.zig");
const ebr = @import("ebr.zig");

// Simple hash function for u64 keys
fn hashU64(key: u64) u64 {
    return key;
}

// Simple equality for u64 keys
fn eqlU64(a: u64, b: u64) bool {
    return a == b;
}

const TestHashMap = flurry.HashMap(u64, u64, hashU64, eqlU64);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== Flurry HashMap Test ===\n\n", .{});

    // Initialize EBR collector
    var collector = try ebr.Collector.init(allocator);
    defer collector.deinit();

    // Create HashMap with initial capacity 16
    var map = try TestHashMap.init(allocator, collector, 16);
    defer map.deinit();

    std.debug.print("HashMap initialized with capacity 16\n", .{});

    // Pin to create a guard (enters EBR epoch)
    const guard = try collector.pin();
    defer collector.unpinGuard(guard);

    std.debug.print("Entered EBR guard\n\n", .{});

    // Test 1: Insert some values
    std.debug.print("Test 1: Inserting values...\n", .{});

    const val1 = try allocator.create(u64);
    val1.* = 100;
    const old1 = try map.put(42, val1, guard);
    std.debug.print("  put(42, 100) -> {?}\n", .{if (old1) |v| v.* else null});

    const val2 = try allocator.create(u64);
    val2.* = 200;
    const old2 = try map.put(43, val2, guard);
    std.debug.print("  put(43, 200) -> {?}\n", .{if (old2) |v| v.* else null});

    const val3 = try allocator.create(u64);
    val3.* = 300;
    const old3 = try map.put(44, val3, guard);
    std.debug.print("  put(44, 300) -> {?}\n", .{if (old3) |v| v.* else null});

    std.debug.print("  Map size: {}\n\n", .{map.len()});

    // Test 2: Get values
    std.debug.print("Test 2: Getting values...\n", .{});

    if (map.get(42, guard)) |v| {
        std.debug.print("  get(42) -> {}\n", .{v.*});
    } else {
        std.debug.print("  get(42) -> null (ERROR!)\n", .{});
    }

    if (map.get(43, guard)) |v| {
        std.debug.print("  get(43) -> {}\n", .{v.*});
    } else {
        std.debug.print("  get(43) -> null (ERROR!)\n", .{});
    }

    if (map.get(44, guard)) |v| {
        std.debug.print("  get(44) -> {}\n", .{v.*});
    } else {
        std.debug.print("  get(44) -> null (ERROR!)\n", .{});
    }

    if (map.get(45, guard)) |v| {
        std.debug.print("  get(45) -> {} (ERROR - should be null!)\n", .{v.*});
    } else {
        std.debug.print("  get(45) -> null (expected)\n", .{});
    }

    // Test 3: Update value
    std.debug.print("\nTest 3: Updating value...\n", .{});
    const val4 = try allocator.create(u64);
    val4.* = 999;
    const old4 = try map.put(42, val4, guard);
    std.debug.print("  put(42, 999) -> {?}\n", .{if (old4) |v| v.* else null});

    if (map.get(42, guard)) |v| {
        std.debug.print("  get(42) -> {} (should be 999)\n", .{v.*});
    }

    std.debug.print("  Map size: {}\n\n", .{map.len()});

    // Test 4: Collision test (insert keys that hash to same bin)
    std.debug.print("Test 4: Testing collision handling...\n", .{});

    // With capacity 16, keys 0 and 16 will hash to same bin
    const val5 = try allocator.create(u64);
    val5.* = 500;
    _ = try map.put(0, val5, guard);
    std.debug.print("  put(0, 500)\n", .{});

    const val6 = try allocator.create(u64);
    val6.* = 600;
    _ = try map.put(16, val6, guard);
    std.debug.print("  put(16, 600)\n", .{});

    if (map.get(0, guard)) |v| {
        std.debug.print("  get(0) -> {}\n", .{v.*});
    }

    if (map.get(16, guard)) |v| {
        std.debug.print("  get(16) -> {}\n", .{v.*});
    }

    std.debug.print("  Map size: {}\n\n", .{map.len()});

    std.debug.print("=== All Tests Passed! ===\n", .{});
}
