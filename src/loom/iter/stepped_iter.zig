// stepped_iterator.zig - Stepped Iterator Implementation
//
// An iterator that yields every Nth element from the underlying data.
// Created by calling step_by() on a ParallelIterator.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// An iterator that yields every Nth element from the underlying data
/// Created by calling step_by() on a ParallelIterator
pub fn SteppedIterator(comptime T: type) type {
    return struct {
        const Self = @This();

        data: []T,
        step: usize,
        pos: usize,

        /// Get the next element, advancing by step size
        pub fn next(self: *Self) ?T {
            if (self.pos >= self.data.len) return null;
            const result = self.data[self.pos];
            self.pos += self.step;
            return result;
        }

        /// Reset iterator to beginning
        pub fn reset(self: *Self) void {
            self.pos = 0;
        }

        /// Collect all stepped elements into a slice
        pub fn collect(self: *Self, allocator: Allocator) ![]T {
            // Count elements
            var count: usize = 0;
            var p = self.pos;
            while (p < self.data.len) : (p += self.step) {
                count += 1;
            }

            const result = try allocator.alloc(T, count);
            var idx: usize = 0;
            while (self.next()) |item| {
                result[idx] = item;
                idx += 1;
            }
            return result;
        }

        /// Apply forEach to stepped elements
        pub fn forEach(self: *Self, comptime func: fn (*T) void) void {
            while (self.pos < self.data.len) {
                func(&self.data[self.pos]);
                self.pos += self.step;
            }
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

test "SteppedIterator basic" {
    var data = [_]i32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
    var iter = SteppedIterator(i32){
        .data = &data,
        .step = 3,
        .pos = 0,
    };

    try std.testing.expectEqual(@as(?i32, 1), iter.next());
    try std.testing.expectEqual(@as(?i32, 4), iter.next());
    try std.testing.expectEqual(@as(?i32, 7), iter.next());
    try std.testing.expectEqual(@as(?i32, 10), iter.next());
    try std.testing.expectEqual(@as(?i32, null), iter.next());
}

test "SteppedIterator reset" {
    var data = [_]i32{ 1, 2, 3, 4, 5 };
    var iter = SteppedIterator(i32){
        .data = &data,
        .step = 2,
        .pos = 0,
    };

    _ = iter.next();
    _ = iter.next();
    iter.reset();
    try std.testing.expectEqual(@as(?i32, 1), iter.next());
}

test "SteppedIterator collect" {
    var data = [_]i32{ 1, 2, 3, 4, 5, 6 };
    var iter = SteppedIterator(i32){
        .data = &data,
        .step = 2,
        .pos = 0,
    };

    const collected = try iter.collect(std.testing.allocator);
    defer std.testing.allocator.free(collected);

    try std.testing.expectEqualSlices(i32, &[_]i32{ 1, 3, 5 }, collected);
}
