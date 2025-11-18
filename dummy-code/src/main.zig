const std = @import("std");

// =============================================================================
// Rayon-like Chaining Pattern for Zig
// =============================================================================
// Eager evaluation with automatic memory management
// Intermediate operations (map, filter) panic on OOM for clean chaining syntax
// Final operation (collect) returns error union for proper error handling
fn ParallelChain(comptime T: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        items: []const T,
        owns_items: bool, // Track if we need to free items

        pub fn init(allocator: std.mem.Allocator, items: []const T) Self {
            return .{
                .allocator = allocator,
                .items = items,
                .owns_items = false, // Input slice not owned
            };
        }

        // Map operation - executes eagerly (panic on OOM)
        pub fn map(self: Self, comptime mapFn: fn (T) T) Self {
            const result = self.allocator.alloc(T, self.items.len) catch @panic("OOM in map");
            for (self.items, 0..) |item, i| {
                result[i] = mapFn(item);
            }

            // Free the old items if we owned them
            if (self.owns_items) {
                self.allocator.free(self.items);
            }

            return Self{
                .allocator = self.allocator,
                .items = result,
                .owns_items = true,
            };
        }

        // Filter operation - executes eagerly (panic on OOM)
        pub fn filter(self: Self, comptime filterFn: fn (T) bool) Self {
            var result = std.ArrayListUnmanaged(T){};

            for (self.items) |item| {
                if (filterFn(item)) {
                    result.append(self.allocator, item) catch @panic("OOM in filter");
                }
            }

            // Free the old items if we owned them
            if (self.owns_items) {
                self.allocator.free(self.items);
            }

            return Self{
                .allocator = self.allocator,
                .items = result.toOwnedSlice(self.allocator) catch @panic("OOM in filter"),
                .owns_items = true,
            };
        }

        // Collect - returns final result (returns error)
        pub fn collect(self: Self) ![]T {
            const result = try self.allocator.alloc(T, self.items.len);
            @memcpy(result, self.items);

            // Free our items if we owned them
            if (self.owns_items) {
                self.allocator.free(self.items);
            }

            return result;
        }

        // Cleanup intermediate allocations
        pub fn deinit(self: Self) void {
            if (self.owns_items) {
                self.allocator.free(self.items);
            }
        }
    };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const input = [_]i32{ -5, 3, 8, 12, -2, 15, 7 };

    // Helper functions
    const isPositive = struct {
        fn f(x: i32) bool {
            return x > 0;
        }
    }.f;

    const greaterThan10 = struct {
        fn f(x: i32) bool {
            return x > 10;
        }
    }.f;

    const double = struct {
        fn f(x: i32) i32 {
            return x * 2;
        }
    }.f;

    const addOne = struct {
        fn f(x: i32) i32 {
            return x + 1;
        }
    }.f;

    std.debug.print("\n=== Rayon-like Chaining Pattern ===\n", .{});
    std.debug.print("Input: {any}\n\n", .{input});

    // Simple chain: filter -> map
    {
        const result = try ParallelChain(i32)
            .init(allocator, &input)
            .filter(isPositive)
            .map(double)
            .collect();
        defer allocator.free(result);

        std.debug.print("After filter(>0).map(double): {any}\n", .{result});
    }

    // Complex chain: filter -> map -> filter -> map
    {
        const result = try ParallelChain(i32)
            .init(allocator, &input)
            .filter(isPositive)
            .map(double)
            .filter(greaterThan10)
            .map(addOne)
            .collect();
        defer allocator.free(result);

        std.debug.print("Complex chain (filter->map->filter->map): {any}\n", .{result});
    }
}
