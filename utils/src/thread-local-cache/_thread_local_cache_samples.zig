const std = @import("std");
const cache_mod = @import("thread_local_cache.zig");

const Node = struct {
    value: usize,
};

const GlobalPool = struct {
    // A trivial freelist for demonstration only
    store: std.ArrayList(*Node),

    pub fn init(allocator: std.mem.Allocator) GlobalPool {
        return .{ .store = std.ArrayList(*Node).init(allocator) };
    }

    pub fn deinit(self: *GlobalPool) void {
        self.store.deinit();
    }
};

fn recycleToGlobal(ctx: ?*anyopaque, n: *Node) void {
    const gp: *GlobalPool = @ptrCast(@alignCast(ctx.?));
    gp.store.append(n) catch unreachable; // sample-only
}

// Bind a cache type that knows how to recycle back
const NodeCache = cache_mod.ThreadLocalCache(*Node, recycleToGlobal);

// Example usage helper (can be used from docs or ad-hoc testing)
pub fn example() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var pool = GlobalPool.init(allocator);
    defer pool.deinit();

    var cache: NodeCache = .{};

    var a = try allocator.create(Node);
    var b = try allocator.create(Node);
    a.* = .{ .value = 1 };
    b.* = .{ .value = 2 };

    // Push into the fast L1 cache
    _ = cache.push(a);
    _ = cache.push(b);

    // Pop is LIFO
    const n1 = cache.pop().?; // b
    const n2 = cache.pop().?; // a
    std.debug.assert(n1.value == 2 and n2.value == 1);

    // Return to cache
    _ = cache.push(n1);
    _ = cache.push(n2);

    // Drain to global pool on shutdown
    cache.clear(&pool);

    // Clean up nodes from the global pool in this sample
    while (pool.store.items.len > 0) {
        const node = pool.store.pop();
        allocator.destroy(node);
    }
}
