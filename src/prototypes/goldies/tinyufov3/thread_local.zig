const std = @import("std");
const thread_id = @import("thread_id.zig");

pub fn ThreadLocal(comptime T: type) type {
    return struct {
        const Self = @This();
        const Map = std.AutoHashMap(thread_id.Thread, *T);

        allocator: std.mem.Allocator,
        map: Map,
        lock: std.Thread.Mutex = .{},

        pub fn init(allocator: std.mem.Allocator, _: usize) !Self {
            return .{ .allocator = allocator, .map = Map.init(allocator) };
        }

        pub fn deinit(self: *Self) void {
            var it = self.map.iterator();
            while (it.next()) |e| {
                self.allocator.destroy(e.value_ptr.*);
            }
            self.map.deinit();
        }

        pub fn loadOr(self: *Self, key: thread_id.Thread, comptime init_fn: fn () T) !*T {
            self.lock.lock();
            defer self.lock.unlock();

            if (self.map.getPtr(key)) |p| return p.*;

            const ptr = try self.allocator.create(T);
            ptr.* = init_fn();
            try self.map.put(key, ptr);
            return ptr;
        }

        pub fn get(self: *Self, key: thread_id.Thread) ?*T {
            self.lock.lock();
            defer self.lock.unlock();
            if (self.map.getPtr(key)) |p| {
                return p.*;
            } else {
                return null;
            }
        }

        pub const Iterator = struct {
            inner: Map.Iterator,
            pub fn next(self: *Iterator) ?*T {
                if (self.inner.next()) |e| return e.value_ptr.* else return null;
            }
        };

        pub fn iter(self: *Self) Iterator {
            // Note: This iterator is not synchronized; callers should tolerate concurrent updates.
            return Iterator{ .inner = self.map.iterator() };
        }
    };
}
