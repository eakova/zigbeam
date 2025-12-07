// reducer.zig - Parallel Reduction Operations
//
// Provides associative reduction operations for parallel computation.
// Reducers define how partial results from parallel chunks are combined.
//
// Usage:
// ```zig
// const sum = Reducer(i64).sum();
// const result = items.par_iter().reduce(sum, |acc, x| acc + x);
// ```

const std = @import("std");

/// Reducer for parallel reduction operations
///
/// A reducer consists of:
/// - An identity value (starting point for reduction)
/// - A combine function (merges two partial results)
///
/// The combine function must be associative: combine(a, combine(b, c)) == combine(combine(a, b), c)
pub fn Reducer(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Identity value for the reduction
        identity: T,

        /// Combine function: (T, T) -> T
        /// Must be associative for correct parallel reduction
        combine: *const fn (T, T) T,

        /// Create a reducer with explicit identity and combine
        pub fn init(identity: T, combine_fn: *const fn (T, T) T) Self {
            return Self{
                .identity = identity,
                .combine = combine_fn,
            };
        }

        /// Create a sum reducer (identity: 0)
        pub fn sum() Self {
            return Self{
                .identity = @as(T, 0),
                .combine = struct {
                    fn add(a: T, b: T) T {
                        return a + b;
                    }
                }.add,
            };
        }

        /// Create a product reducer (identity: 1)
        pub fn product() Self {
            return Self{
                .identity = @as(T, 1),
                .combine = struct {
                    fn mul(a: T, b: T) T {
                        return a * b;
                    }
                }.mul,
            };
        }

        /// Create a min reducer
        pub fn min() Self {
            return Self{
                .identity = std.math.maxInt(T),
                .combine = struct {
                    fn minFn(a: T, b: T) T {
                        return @min(a, b);
                    }
                }.minFn,
            };
        }

        /// Create a max reducer
        pub fn max() Self {
            return Self{
                .identity = std.math.minInt(T),
                .combine = struct {
                    fn maxFn(a: T, b: T) T {
                        return @max(a, b);
                    }
                }.maxFn,
            };
        }

        /// Reduce a slice using this reducer
        pub fn reduceSlice(self: Self, data: []const T) T {
            var result = self.identity;
            for (data) |item| {
                result = self.combine(result, item);
            }
            return result;
        }

        /// Combine two partial results
        pub fn merge(self: Self, a: T, b: T) T {
            return self.combine(a, b);
        }
    };
}

/// Boolean reducer for logical operations
pub const BoolReducer = struct {
    const Self = @This();

    identity: bool,
    combine: *const fn (bool, bool) bool,

    /// Create an AND reducer (all must be true)
    pub fn all() Self {
        return Self{
            .identity = true,
            .combine = struct {
                fn andFn(a: bool, b: bool) bool {
                    return a and b;
                }
            }.andFn,
        };
    }

    /// Create an OR reducer (any must be true)
    pub fn any() Self {
        return Self{
            .identity = false,
            .combine = struct {
                fn orFn(a: bool, b: bool) bool {
                    return a or b;
                }
            }.orFn,
        };
    }

    pub fn reduceSlice(self: Self, data: []const bool) bool {
        var result = self.identity;
        for (data) |item| {
            result = self.combine(result, item);
        }
        return result;
    }

    pub fn merge(self: Self, a: bool, b: bool) bool {
        return self.combine(a, b);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Reducer.sum" {
    const reducer = Reducer(i32).sum();
    try std.testing.expectEqual(@as(i32, 0), reducer.identity);
    try std.testing.expectEqual(@as(i32, 7), reducer.combine(3, 4));

    const data = [_]i32{ 1, 2, 3, 4, 5 };
    try std.testing.expectEqual(@as(i32, 15), reducer.reduceSlice(&data));
}

test "Reducer.product" {
    const reducer = Reducer(i32).product();
    try std.testing.expectEqual(@as(i32, 1), reducer.identity);
    try std.testing.expectEqual(@as(i32, 12), reducer.combine(3, 4));

    const data = [_]i32{ 1, 2, 3, 4, 5 };
    try std.testing.expectEqual(@as(i32, 120), reducer.reduceSlice(&data));
}

test "Reducer.min" {
    const reducer = Reducer(i32).min();
    try std.testing.expectEqual(@as(i32, 3), reducer.combine(3, 5));

    const data = [_]i32{ 5, 2, 8, 1, 9 };
    try std.testing.expectEqual(@as(i32, 1), reducer.reduceSlice(&data));
}

test "Reducer.max" {
    const reducer = Reducer(i32).max();
    try std.testing.expectEqual(@as(i32, 5), reducer.combine(3, 5));

    const data = [_]i32{ 5, 2, 8, 1, 9 };
    try std.testing.expectEqual(@as(i32, 9), reducer.reduceSlice(&data));
}

test "BoolReducer.all" {
    const reducer = BoolReducer.all();
    const data1 = [_]bool{ true, true, true };
    const data2 = [_]bool{ true, false, true };

    try std.testing.expect(reducer.reduceSlice(&data1));
    try std.testing.expect(!reducer.reduceSlice(&data2));
}

test "BoolReducer.any" {
    const reducer = BoolReducer.any();
    const data1 = [_]bool{ false, false, false };
    const data2 = [_]bool{ false, true, false };

    try std.testing.expect(!reducer.reduceSlice(&data1));
    try std.testing.expect(reducer.reduceSlice(&data2));
}
