const std = @import("std");

// Coarse-grained correctness-first Fast backend.
// Wraps a single mutex-protected hash map.

pub fn BucketsFast(comptime V: type) type {
    return struct {
        const Self = @This();
        const Map = std.AutoHashMap(u64, V);

        map: Map,
        lock: std.Thread.Mutex = .{},

        pub fn with_capacity(allocator: std.mem.Allocator, cap: usize) !Self {
            _ = cap;
            return .{ .map = Map.init(allocator) };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            _ = allocator;
            self.map.deinit();
        }

        pub fn get(self: *Self, key: u64) ?V {
            self.lock.lock();
            defer self.lock.unlock();
            if (self.map.get(key)) |v| return v else return null;
        }

        pub fn get_map(self: *Self, key: u64, func: fn (V) void) bool {
            self.lock.lock();
            defer self.lock.unlock();
            if (self.map.get(key)) |v| {
                func(v);
                return true;
            }
            return false;
        }

        pub fn insert(self: *Self, allocator: std.mem.Allocator, key: u64, value: V) !?V {
            _ = allocator;
            self.lock.lock();
            defer self.lock.unlock();
            if ((try self.map.fetchPut(key, value))) |old| return old.value else return null;
        }

        pub fn remove(self: *Self, key: u64) ?V {
            self.lock.lock();
            defer self.lock.unlock();
            if (self.map.fetchRemove(key)) |old| return old.value else return null;
        }
    };
}
