const std = @import("std");
const Allocator = std.mem.Allocator;

/// Task abstraction - type-erased function + data
pub const Task = struct {
    runFn: *const fn (*anyopaque) void,
    data: *anyopaque,

    pub fn execute(self: Task) void {
        self.runFn(self.data);
    }

    /// Create task from function and arguments
    pub fn init(allocator: Allocator, comptime func: anytype, args: anytype) !Task {
        const Args = @TypeOf(args);
        const Closure = struct {
            args: Args,
            allocator: Allocator,

            fn run(ptr: *anyopaque) void {
                const self: *@This() = @alignCast(@ptrCast(ptr));
                defer self.allocator.destroy(self);
                @call(.auto, func, self.args);
            }
        };

        const closure = try allocator.create(Closure);
        closure.* = .{ .args = args, .allocator = allocator };

        return Task{
            .runFn = Closure.run,
            .data = closure,
        };
    }

    /// Create task from simple function (no cleanup needed)
    pub fn initSimple(comptime func: fn () void, data: *anyopaque) Task {
        const Wrapper = struct {
            fn run(ptr: *anyopaque) void {
                _ = ptr;
                func();
            }
        };

        return Task{
            .runFn = Wrapper.run,
            .data = data,
        };
    }
};
