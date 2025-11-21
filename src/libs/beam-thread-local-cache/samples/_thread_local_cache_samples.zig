//! Minimal example showing how to front a slow global pool with ThreadLocalCache.
//! The code mimics production patterns (create cache, push/pop, drain back to
//! the global pool) but stays tiny for readability.

const std = @import("std");
const cache_mod = @import("beam-thread-local-cache");

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

    const a = try allocator.create(Node);
    const b = try allocator.create(Node);
    a.* = .{ .value = 1 };
    b.* = .{ .value = 2 };

    // Push into the fast L1 cache
    _ = cache.push(a);
    _ = cache.push(b);

    // Pop is LIFO
    const n1 = cache.pop().?; // b
    const n2 = cache.pop().?; // a
    std.debug.assert(n1.value == 2 and n2.value == 1);

    // Return to cache so the next pop is still cheap.
    _ = cache.push(n1);
    _ = cache.push(n2);

    // Drain to global pool on shutdown. This is what production code would do
    // when a thread exits or a pool is destroyed.
    cache.clear(&pool);

    // Clean up nodes from the global pool in this sample
    while (pool.store.items.len > 0) {
        const node = pool.store.pop();
        allocator.destroy(node);
    }
}

pub fn main() !void {
    // Reuse the same helper so `zig run` mirrors the documented flow.
    try example();
}
