const std = @import("std");

// Compact backend: sharded hash maps with coarse-grained mutex per shard.

pub fn BucketsCompact(comptime V: type) type {
    return struct {
        const Self = @This();
        const Shard = struct {
            map: std.AutoHashMap(u64, V),
            lock: std.Thread.Mutex = .{},
        };

        shards: []Shard,
        allocator: std.mem.Allocator,

        pub fn with_capacity(allocator: std.mem.Allocator, cap: usize) !Self {
            const n = @max(@as(usize, 4), std.math.ceilPowerOfTwo(usize, cap / 64) catch 4);
            const shards = try allocator.alloc(Shard, n);
            for (shards) |*s| s.* = .{ .map = std.AutoHashMap(u64, V).init(allocator) };
            return .{ .shards = shards, .allocator = allocator };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            for (self.shards) |*s| s.map.deinit();
            allocator.free(self.shards);
        }

        inline fn shard(self: *Self, key: u64) *Shard {
            const idx = @as(usize, @intCast(key & (@as(u64, self.shards.len - 1))));
            return &self.shards[idx];
        }

        pub fn get(self: *Self, key: u64) ?V {
            var s = self.shard(key);
            s.lock.lock();
            defer s.lock.unlock();
            if (s.map.get(key)) |v| return v else return null;
        }

        pub fn get_map(self: *Self, key: u64, func: fn (V) void) bool {
            var s = self.shard(key);
            s.lock.lock();
            defer s.lock.unlock();
            if (s.map.get(key)) |v| {
                func(v);
                return true;
            }
            return false;
        }

        pub fn insert(self: *Self, allocator: std.mem.Allocator, key: u64, value: V) !?V {
            _ = allocator;
            var s = self.shard(key);
            s.lock.lock();
            defer s.lock.unlock();
            if ((try s.map.fetchPut(key, value))) |old| return old.value else return null;
        }

        pub fn remove(self: *Self, key: u64) ?V {
            var s = self.shard(key);
            s.lock.lock();
            defer s.lock.unlock();
            if (s.map.fetchRemove(key)) |old| return old.value else return null;
        }
    };
}
