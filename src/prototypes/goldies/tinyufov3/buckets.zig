const std = @import("std");

// Common buckets API surface, dispatching to Fast/Compact backends.

pub fn Buckets(comptime V: type) type {
    return struct {
        const Self = @This();
        const Fast = @import("buckets_fast.zig").BucketsFast(V);
        const Compact = @import("buckets_compact.zig").BucketsCompact(V);

        pub const Backend = enum { fast, compact };

        backend: Backend,
        fast: ?Fast = null,
        compact: ?Compact = null,

        pub fn with_capacity(allocator: std.mem.Allocator, backend: Backend, cap: usize) !Self {
            return switch (backend) {
                .fast => .{ .backend = .fast, .fast = try Fast.with_capacity(allocator, cap) },
                .compact => .{ .backend = .compact, .compact = try Compact.with_capacity(allocator, cap) },
            };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            switch (self.backend) {
                .fast => self.fast.?.deinit(allocator),
                .compact => self.compact.?.deinit(allocator),
            }
        }

        pub fn drain_destroy(self: *Self, allocator: std.mem.Allocator) void {
            switch (self.backend) {
                .fast => {
                    var it = self.fast.?.map.valueIterator();
                    while (it.next()) |vp| allocator.destroy(vp.*);
                },
                .compact => {
                    for (self.compact.?.shards) |*s| {
                        var it = s.map.valueIterator();
                        while (it.next()) |vp| allocator.destroy(vp.*);
                    }
                },
            }
        }

        pub fn get(self: *Self, key: u64) ?V {
            return switch (self.backend) {
                .fast => self.fast.?.get(key),
                .compact => self.compact.?.get(key),
            };
        }

        pub fn get_map(self: *Self, key: u64, func: fn (V) void) bool {
            return switch (self.backend) {
                .fast => self.fast.?.get_map(key, func),
                .compact => self.compact.?.get_map(key, func),
            };
        }

        pub fn insert(self: *Self, allocator: std.mem.Allocator, key: u64, value: V) !?V {
            return switch (self.backend) {
                .fast => self.fast.?.insert(allocator, key, value),
                .compact => self.compact.?.insert(allocator, key, value),
            };
        }

        pub fn remove(self: *Self, key: u64) ?V {
            return switch (self.backend) {
                .fast => self.fast.?.remove(key),
                .compact => self.compact.?.remove(key),
            };
        }
    };
}

test "buckets: fast basic" {
    const gpa = std.testing.allocator;
    var b = try Buckets(*usize).with_capacity(gpa, .fast, 64);
    defer b.deinit(gpa);
    try std.testing.expectEqual(@as(?*usize, null), b.get(1));
    const p = try gpa.create(usize);
    p.* = 42;
    try std.testing.expectEqual(@as(?*usize, null), try b.insert(gpa, 1, p));
    const got = b.get(1).?;
    try std.testing.expectEqual(@as(usize, 42), got.*);
    const r = b.remove(1).?;
    try std.testing.expectEqual(@as(usize, 42), r.*);
    gpa.destroy(r);
}
