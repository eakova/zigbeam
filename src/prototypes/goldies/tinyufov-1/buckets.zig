/// Buckets interface and implementations (Fast/Compact backends)
/// Provides pluggable HashMap backends for TinyUFO

const std = @import("std");
const Atomic = std.atomic.Value;

const model = @import("model.zig");
const ebr = @import("ebr.zig");

pub const Key = u64;

/// Buckets trait - common interface for Fast/Compact backends
pub const BucketsInterface = struct {
    pub const VTable = struct {
        get: *const fn (ctx: *anyopaque, key: Key) ?*anyopaque,
        get_map: *const fn (ctx: *anyopaque, key: Key, f: *const fn (*anyopaque) *anyopaque) ?*anyopaque,
        insert: *const fn (ctx: *anyopaque, key: Key, value: *anyopaque) std.mem.Allocator.Error!?*anyopaque,
        remove: *const fn (ctx: *anyopaque, key: Key) ?*anyopaque,
        len: *const fn (ctx: *anyopaque) usize,
        clear: *const fn (ctx: *anyopaque) void,
    };

    ctx: *anyopaque,
    vtable: *const VTable,

    pub fn get(self: *const BucketsInterface, key: Key) ?*anyopaque {
        return self.vtable.get(self.ctx, key);
    }

    pub fn get_map(self: *const BucketsInterface, key: Key, f: *const fn (*anyopaque) *anyopaque) ?*anyopaque {
        return self.vtable.get_map(self.ctx, key, f);
    }

    pub fn insert(self: *BucketsInterface, key: Key, value: *anyopaque) !?*anyopaque {
        return self.vtable.insert(self.ctx, key, value);
    }

    pub fn remove(self: *BucketsInterface, key: Key) ?*anyopaque {
        return self.vtable.remove(self.ctx, key);
    }

    pub fn len(self: *const BucketsInterface) usize {
        return self.vtable.len(self.ctx);
    }

    pub fn clear(self: *BucketsInterface) void {
        self.vtable.clear(self.ctx);
    }
};

/// ============================================================================
/// FAST BACKEND - Concurrent HashMap (Flurry-compatible design)
/// ============================================================================

pub const BucketsFast = struct {
    allocator: std.mem.Allocator,
    map: std.AutoHashMap(Key, *anyopaque),
    lock: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator, capacity: u64) !*BucketsFast {
        const buckets = try allocator.create(BucketsFast);
        buckets.* = .{
            .allocator = allocator,
            .map = std.AutoHashMap(Key, *anyopaque).init(allocator),
            .lock = .{},
        };

        // Pre-allocate approximate capacity
        try buckets.map.ensureTotalCapacity(@intCast(@min(capacity / 4, 100000)));

        return buckets;
    }

    pub fn deinit(self: *BucketsFast) void {
        self.map.deinit();
        self.allocator.destroy(self);
    }

    pub fn get(self: *BucketsFast, key: Key) ?*anyopaque {
        self.lock.lock();
        defer self.lock.unlock();

        return self.map.get(key);
    }

    pub fn get_map(
        self: *BucketsFast,
        key: Key,
        f: *const fn (*anyopaque) *anyopaque,
    ) ?*anyopaque {
        self.lock.lock();
        defer self.lock.unlock();

        if (self.map.get(key)) |value| {
            return f(value);
        }

        return null;
    }

    pub fn insert(self: *BucketsFast, key: Key, value: *anyopaque) !?*anyopaque {
        self.lock.lock();
        defer self.lock.unlock();

        const result = try self.map.fetchPut(key, value);
        if (result) |old| {
            return old.value;
        }

        return null;
    }

    pub fn remove(self: *BucketsFast, key: Key) ?*anyopaque {
        self.lock.lock();
        defer self.lock.unlock();

        if (self.map.fetchRemove(key)) |kv| {
            return kv.value;
        }
        return null;
    }

    pub fn len(self: *BucketsFast) usize {
        self.lock.lock();
        defer self.lock.unlock();

        return self.map.count();
    }

    pub fn clear(self: *BucketsFast) void {
        self.lock.lock();
        defer self.lock.unlock();

        self.map.clearRetainingCapacity();
    }

    /// Convert to BucketsInterface VTable
    pub fn as_interface(self: *BucketsFast) BucketsInterface {
        return .{
            .ctx = self,
            .vtable = &BucketsFast.vtable,
        };
    }

    const vtable = BucketsInterface.VTable{
        .get = get_impl,
        .get_map = get_map_impl,
        .insert = insert_impl,
        .remove = remove_impl,
        .len = len_impl,
        .clear = clear_impl,
    };

    fn get_impl(ctx: *anyopaque, key: Key) ?*anyopaque {
        const self: *BucketsFast = @ptrCast(@alignCast(ctx));
        return self.get(key);
    }

    fn get_map_impl(ctx: *anyopaque, key: Key, f: *const fn (*anyopaque) *anyopaque) ?*anyopaque {
        const self: *BucketsFast = @ptrCast(@alignCast(ctx));
        return self.get_map(key, f);
    }

    fn insert_impl(ctx: *anyopaque, key: Key, value: *anyopaque) !?*anyopaque {
        const self: *BucketsFast = @ptrCast(@alignCast(ctx));
        return self.insert(key, value);
    }

    fn remove_impl(ctx: *anyopaque, key: Key) ?*anyopaque {
        const self: *BucketsFast = @ptrCast(@alignCast(ctx));
        return self.remove(key);
    }

    fn len_impl(ctx: *anyopaque) usize {
        const self: *BucketsFast = @ptrCast(@alignCast(ctx));
        return self.len();
    }

    fn clear_impl(ctx: *anyopaque) void {
        const self: *BucketsFast = @ptrCast(@alignCast(ctx));
        self.clear();
    }
};

/// ============================================================================
/// COMPACT BACKEND - Sharded SkipList (simplified ordered map)
/// ============================================================================

pub const SHARD_COUNT = 16;

pub const BucketsCompact = struct {
    allocator: std.mem.Allocator,
    shards: [SHARD_COUNT]ShardedMap,

    const ShardedMap = struct {
        map: std.AutoHashMap(Key, *anyopaque),
        lock: std.Thread.Mutex,

        fn init(allocator: std.mem.Allocator) !ShardedMap {
            return .{
                .map = std.AutoHashMap(Key, *anyopaque).init(allocator),
                .lock = .{},
            };
        }

        fn deinit(self: *ShardedMap) void {
            self.map.deinit();
        }
    };

    fn shard_index(key: Key) usize {
        return @intCast((key >> 1) % SHARD_COUNT);
    }

    pub fn init(allocator: std.mem.Allocator, capacity: u64) !*BucketsCompact {
        const buckets = try allocator.create(BucketsCompact);

        var shards_initialized: usize = 0;
        errdefer {
            for (0..shards_initialized) |i| {
                buckets.shards[i].deinit();
            }
        }

        for (0..SHARD_COUNT) |i| {
            buckets.shards[i] = try ShardedMap.init(allocator);
            shards_initialized += 1;
        }

        buckets.allocator = allocator;
        _ = capacity;

        return buckets;
    }

    pub fn deinit(self: *BucketsCompact) void {
        for (0..SHARD_COUNT) |i| {
            self.shards[i].deinit();
        }

        self.allocator.destroy(self);
    }

    pub fn get(self: *BucketsCompact, key: Key) ?*anyopaque {
        const idx = shard_index(key);
        var shard = &self.shards[idx];

        shard.lock.lock();
        defer shard.lock.unlock();

        return shard.map.get(key);
    }

    pub fn get_map(
        self: *BucketsCompact,
        key: Key,
        f: *const fn (*anyopaque) *anyopaque,
    ) ?*anyopaque {
        const idx = shard_index(key);
        var shard = &self.shards[idx];

        shard.lock.lock();
        defer shard.lock.unlock();

        if (shard.map.get(key)) |value| {
            return f(value);
        }

        return null;
    }

    pub fn insert(self: *BucketsCompact, key: Key, value: *anyopaque) !?*anyopaque {
        const idx = shard_index(key);
        var shard = &self.shards[idx];

        shard.lock.lock();
        defer shard.lock.unlock();

        const result = try shard.map.fetchPut(key, value);
        if (result) |old| {
            return old.value;
        }

        return null;
    }

    pub fn remove(self: *BucketsCompact, key: Key) ?*anyopaque {
        const idx = shard_index(key);
        var shard = &self.shards[idx];

        shard.lock.lock();
        defer shard.lock.unlock();

        if (shard.map.fetchRemove(key)) |kv| {
            return kv.value;
        }
        return null;
    }

    pub fn len(self: *BucketsCompact) usize {
        var total: usize = 0;

        for (0..SHARD_COUNT) |i| {
            var shard = &self.shards[i];
            shard.lock.lock();
            defer shard.lock.unlock();

            total += shard.map.count();
        }

        return total;
    }

    pub fn clear(self: *BucketsCompact) void {
        for (0..SHARD_COUNT) |i| {
            var shard = &self.shards[i];
            shard.lock.lock();
            defer shard.lock.unlock();

            shard.map.clearRetainingCapacity();
        }
    }

    pub fn as_interface(self: *BucketsCompact) BucketsInterface {
        return .{
            .ctx = self,
            .vtable = &BucketsCompact.vtable,
        };
    }

    const vtable = BucketsInterface.VTable{
        .get = get_impl,
        .get_map = get_map_impl,
        .insert = insert_impl,
        .remove = remove_impl,
        .len = len_impl,
        .clear = clear_impl,
    };

    fn get_impl(ctx: *anyopaque, key: Key) ?*anyopaque {
        const self: *BucketsCompact = @ptrCast(@alignCast(ctx));
        return self.get(key);
    }

    fn get_map_impl(ctx: *anyopaque, key: Key, f: *const fn (*anyopaque) *anyopaque) ?*anyopaque {
        const self: *BucketsCompact = @ptrCast(@alignCast(ctx));
        return self.get_map(key, f);
    }

    fn insert_impl(ctx: *anyopaque, key: Key, value: *anyopaque) !?*anyopaque {
        const self: *BucketsCompact = @ptrCast(@alignCast(ctx));
        return self.insert(key, value);
    }

    fn remove_impl(ctx: *anyopaque, key: Key) ?*anyopaque {
        const self: *BucketsCompact = @ptrCast(@alignCast(ctx));
        return self.remove(key);
    }

    fn len_impl(ctx: *anyopaque) usize {
        const self: *BucketsCompact = @ptrCast(@alignCast(ctx));
        return self.len();
    }

    fn clear_impl(ctx: *anyopaque) void {
        const self: *BucketsCompact = @ptrCast(@alignCast(ctx));
        self.clear();
    }
};

/// ============================================================================
/// TESTS
/// ============================================================================

const testing = std.testing;
const test_allocator = testing.allocator;

test "BucketsFast: init and deinit" {
    const buckets = try BucketsFast.init(test_allocator, 1000);
    defer buckets.deinit();

    try testing.expect(buckets.len() == 0);
}

test "BucketsFast: insert and get" {
    const buckets = try BucketsFast.init(test_allocator, 1000);
    defer buckets.deinit();

    const key = 123;
    const value = @as(*u32, @ptrFromInt(42));

    _ = try buckets.insert(key, @ptrCast(value));
    try testing.expect(buckets.get(key) != null);
}

test "BucketsFast: remove" {
    const buckets = try BucketsFast.init(test_allocator, 1000);
    defer buckets.deinit();

    const key = 456;
    const value = @as(*u32, @ptrFromInt(99));

    _ = try buckets.insert(key, @ptrCast(value));
    try testing.expect(buckets.remove(key) != null);
    try testing.expect(buckets.get(key) == null);
}

test "BucketsCompact: init and deinit" {
    const buckets = try BucketsCompact.init(test_allocator, 1000);
    defer buckets.deinit();

    try testing.expect(buckets.len() == 0);
}

test "BucketsCompact: sharding" {
    const buckets = try BucketsCompact.init(test_allocator, 1000);
    defer buckets.deinit();

    for (0..100) |i| {
        const value = @as(*u32, @ptrFromInt(i));
        _ = try buckets.insert(@intCast(i), @ptrCast(value));
    }

    try testing.expect(buckets.len() == 100);

    for (0..100) |i| {
        try testing.expect(buckets.get(@intCast(i)) != null);
    }
}

test "BucketsCompact: remove" {
    const buckets = try BucketsCompact.init(test_allocator, 1000);
    defer buckets.deinit();

    const key = 789;
    const value = @as(*u32, @ptrFromInt(77));

    _ = try buckets.insert(key, @ptrCast(value));
    try testing.expect(buckets.remove(key) != null);
    try testing.expect(buckets.get(key) == null);
}

test "BucketsInterface: Fast backend" {
    const buckets = try BucketsFast.init(test_allocator, 1000);
    defer buckets.deinit();

    var iface = buckets.as_interface();

    const key = 555;
    const value = @as(*u32, @ptrFromInt(111));

    _ = try iface.insert(key, @ptrCast(value));
    try testing.expect(iface.get(key) != null);
}

test "BucketsInterface: Compact backend" {
    const buckets = try BucketsCompact.init(test_allocator, 1000);
    defer buckets.deinit();

    var iface = buckets.as_interface();

    const key = 666;
    const value = @as(*u32, @ptrFromInt(222));

    _ = try iface.insert(key, @ptrCast(value));
    try testing.expect(iface.get(key) != null);
}
