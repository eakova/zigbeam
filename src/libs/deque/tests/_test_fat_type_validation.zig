const std = @import("std");
const Deque = @import("deque").Deque;

// Test that small types work fine
test "Deque accepts u64" {
    const allocator = std.testing.allocator;
    var result = try Deque(u64).init(allocator, 64);
    defer result.worker.deinit();

    try result.worker.push(42);
    const value = result.worker.pop();
    try std.testing.expectEqual(@as(?u64, 42), value);
}

// Test that pointer types work fine (even if they point to large types)
test "Deque accepts pointer types" {
    const LargeType = struct {
        data: [128]u8,
    };

    const allocator = std.testing.allocator;
    var result = try Deque(*LargeType).init(allocator, 64);
    defer result.worker.deinit();

    var large_obj = LargeType{ .data = undefined };
    try result.worker.push(&large_obj);
    const value = result.worker.pop();
    try std.testing.expect(value != null);
}

// Test that small structs work fine
test "Deque accepts small structs" {
    const SmallStruct = struct {
        a: u32,
        b: u32,
    };

    const allocator = std.testing.allocator;
    var result = try Deque(SmallStruct).init(allocator, 64);
    defer result.worker.deinit();

    try result.worker.push(.{ .a = 1, .b = 2 });
    const value = result.worker.pop();
    try std.testing.expectEqual(@as(?SmallStruct, .{ .a = 1, .b = 2 }), value);
}

// Uncomment to test compile error for large types:
//
// test "Deque rejects large types" {
//     const LargeType = struct {
//         data: [128]u8,
//     };
//
//     const allocator = std.testing.allocator;
//     var result = try Deque(LargeType).init(allocator, 64);
//     defer result.worker.deinit();
// }
//
// Expected error:
// Deque: Type '_test_fat_type_validation.test.Deque rejects large types.LargeType'
// (128 bytes) exceeds cache line size (64 bytes). Use *_test_fat_type_validation.test.Deque
// rejects large types.LargeType instead for better performance and to avoid false sharing.
