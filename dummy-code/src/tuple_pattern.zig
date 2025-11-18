const std = @import("std");

// =============================================================================
// How the tuple pattern works: queue(.{ op1, op2, op3 }, {})
// =============================================================================

// Example: A simple operation type
const Operation = struct {
    kind: Kind,
    value: i32,

    const Kind = enum { read, write, fsync };

    pub fn init(kind: Kind, value: i32) Operation {
        return .{ .kind = kind, .value = value };
    }
};

// Example: A queue that accepts tuples of operations
const WorkQueue = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    items: std.ArrayListUnmanaged(Operation),

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .items = .{},
        };
    }

    pub fn deinit(self: *Self) void {
        self.items.deinit(self.allocator);
    }

    // KEY: This method accepts a tuple of operations using 'anytype'
    // At comptime, it iterates over the tuple fields and adds them to the queue
    pub fn queue(self: *Self, ops: anytype, opts: anytype) !void {
        _ = opts; // Options can be used for configuration

        // Iterate over each field in the tuple at compile time
        // Tuples are anonymous structs in Zig
        inline for (std.meta.fields(@TypeOf(ops))) |field| {
            const operation = @field(ops, field.name);
            try self.items.append(self.allocator, operation);
        }
    }

    pub fn print(self: *const Self) void {
        std.debug.print("Queue has {} operations:\n", .{self.items.items.len});
        for (self.items.items, 0..) |operation, i| {
            std.debug.print("  [{}] {s} = {}\n", .{ i, @tagName(operation.kind), operation.value });
        }
    }
};

// Helper to create operations (like aio.op())
fn op(kind: Operation.Kind, value: i32) Operation {
    return Operation.init(kind, value);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var work = WorkQueue.init(allocator);
    defer work.deinit();

    // THE MAGIC: Pass multiple operations as a tuple!
    try work.queue(.{
        op(.read, 100),
        op(.write, 200),
        op(.fsync, 300),
    }, .{});

    work.print();

    std.debug.print("\n=== How It Works ===\n", .{});
    std.debug.print("1. Tuple syntax: .{{op1, op2, op3}}\n", .{});
    std.debug.print("2. 'anytype' parameter accepts tuples\n", .{});
    std.debug.print("3. std.meta.fields() gets struct fields\n", .{});
    std.debug.print("4. 'inline for' unrolls loops at comptime\n", .{});
    std.debug.print("5. @field() accesses struct fields dynamically\n", .{});
}
