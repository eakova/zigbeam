// Tree Traverse - Parallel Tree Algorithms
//
// Demonstrates parallel tree traversal and aggregation.
// Uses work-stealing for unbalanced trees.
//
// Key concepts:
// - Parallel tree traversal
// - Work-stealing for unbalanced trees
// - Aggregate tree statistics
//
// Usage: zig build sample-tree-traverse

const std = @import("std");
const zigparallel = @import("loom");
const joinOnPool = zigparallel.joinOnPool;
const ThreadPool = zigparallel.ThreadPool;

const SEQUENTIAL_THRESHOLD = 100;

const TreeNode = struct {
    value: i64,
    left: ?*TreeNode,
    right: ?*TreeNode,
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("╔═══════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║           Parallel Tree Traversal & Aggregation           ║\n", .{});
    std.debug.print("╚═══════════════════════════════════════════════════════════╝\n\n", .{});

    const pool = try ThreadPool.init(allocator, .{ .num_threads = 8 });
    defer pool.deinit();
    std.debug.print("Thread pool: 8 workers\n\n", .{});

    // ========================================================================
    // Build test trees
    // ========================================================================
    const depths = [_]u32{ 10, 15, 18 };

    for (depths) |depth| {
        const node_count = (@as(usize, 1) << @as(u6, @intCast(depth))) - 1;
        std.debug.print("--- Binary Tree: depth={d}, nodes={d} ---\n", .{ depth, node_count });

        // Build complete binary tree
        const root = try buildTree(allocator, depth, 1);
        defer freeTree(allocator, root);

        // Parallel sum
        const par_start = std.time.nanoTimestamp();
        const par_sum = parallelTreeSum(pool, root);
        const par_end = std.time.nanoTimestamp();
        const par_ms = @as(f64, @floatFromInt(par_end - par_start)) / 1_000_000.0;

        // Sequential sum
        const seq_start = std.time.nanoTimestamp();
        const seq_sum = sequentialTreeSum(root);
        const seq_end = std.time.nanoTimestamp();
        const seq_ms = @as(f64, @floatFromInt(seq_end - seq_start)) / 1_000_000.0;

        const speedup = seq_ms / par_ms;

        std.debug.print("  Parallel:   {d:.3}ms (sum={d})\n", .{ par_ms, par_sum });
        std.debug.print("  Sequential: {d:.3}ms (sum={d})\n", .{ seq_ms, seq_sum });
        std.debug.print("  Speedup:    {d:.2}x\n", .{speedup});
        std.debug.print("  Match:      {}\n\n", .{par_sum == seq_sum});
    }

    // ========================================================================
    // Other tree operations
    // ========================================================================
    std.debug.print("--- Tree Operations (depth=15) ---\n", .{});
    {
        const root = try buildTree(allocator, 15, 1);
        defer freeTree(allocator, root);

        // Max value
        const max_val = parallelTreeMax(pool, root);
        std.debug.print("  Max value:  {d}\n", .{max_val});

        // Node count
        const count = parallelTreeCount(pool, root);
        std.debug.print("  Node count: {d}\n", .{count});

        // Tree height (should equal depth)
        const height = sequentialTreeHeight(root);
        std.debug.print("  Height:     {d}\n\n", .{height});
    }

    std.debug.print("╔═══════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║                    Sample Complete                         ║\n", .{});
    std.debug.print("╚═══════════════════════════════════════════════════════════╝\n", .{});
}

fn buildTree(allocator: std.mem.Allocator, depth: u32, value: i64) !*TreeNode {
    const node = try allocator.create(TreeNode);
    node.value = value;

    if (depth <= 1) {
        node.left = null;
        node.right = null;
    } else {
        node.left = try buildTree(allocator, depth - 1, value * 2);
        node.right = try buildTree(allocator, depth - 1, value * 2 + 1);
    }

    return node;
}

fn freeTree(allocator: std.mem.Allocator, node: ?*TreeNode) void {
    if (node) |n| {
        freeTree(allocator, n.left);
        freeTree(allocator, n.right);
        allocator.destroy(n);
    }
}

fn parallelTreeSum(pool: *ThreadPool, node: ?*const TreeNode) i64 {
    const n = node orelse return 0;

    // Check subtree size for threshold
    const left_count = countNodes(n.left);
    const right_count = countNodes(n.right);

    if (left_count + right_count < SEQUENTIAL_THRESHOLD) {
        return sequentialTreeSum(node);
    }

    // Fork-join for left and right subtrees
    const left_sum, const right_sum = joinOnPool(
        pool,
        struct {
            fn sumLeft(p: *ThreadPool, left: ?*const TreeNode) i64 {
                return parallelTreeSum(p, left);
            }
        }.sumLeft,
        .{ pool, n.left },
        struct {
            fn sumRight(p: *ThreadPool, right: ?*const TreeNode) i64 {
                return parallelTreeSum(p, right);
            }
        }.sumRight,
        .{ pool, n.right },
    );

    return n.value + left_sum + right_sum;
}

fn sequentialTreeSum(node: ?*const TreeNode) i64 {
    const n = node orelse return 0;
    return n.value + sequentialTreeSum(n.left) + sequentialTreeSum(n.right);
}

fn parallelTreeMax(pool: *ThreadPool, node: ?*const TreeNode) i64 {
    const n = node orelse return std.math.minInt(i64);

    const left_count = countNodes(n.left);
    const right_count = countNodes(n.right);

    if (left_count + right_count < SEQUENTIAL_THRESHOLD) {
        return sequentialTreeMax(node);
    }

    const left_max, const right_max = joinOnPool(
        pool,
        struct {
            fn maxLeft(p: *ThreadPool, left: ?*const TreeNode) i64 {
                return parallelTreeMax(p, left);
            }
        }.maxLeft,
        .{ pool, n.left },
        struct {
            fn maxRight(p: *ThreadPool, right: ?*const TreeNode) i64 {
                return parallelTreeMax(p, right);
            }
        }.maxRight,
        .{ pool, n.right },
    );

    return @max(n.value, @max(left_max, right_max));
}

fn sequentialTreeMax(node: ?*const TreeNode) i64 {
    const n = node orelse return std.math.minInt(i64);
    return @max(n.value, @max(sequentialTreeMax(n.left), sequentialTreeMax(n.right)));
}

fn parallelTreeCount(pool: *ThreadPool, node: ?*const TreeNode) usize {
    const n = node orelse return 0;

    const left_count = countNodes(n.left);
    const right_count = countNodes(n.right);

    if (left_count + right_count < SEQUENTIAL_THRESHOLD) {
        return countNodes(node);
    }

    const lc, const rc = joinOnPool(
        pool,
        struct {
            fn countLeft(p: *ThreadPool, left: ?*const TreeNode) usize {
                return parallelTreeCount(p, left);
            }
        }.countLeft,
        .{ pool, n.left },
        struct {
            fn countRight(p: *ThreadPool, right: ?*const TreeNode) usize {
                return parallelTreeCount(p, right);
            }
        }.countRight,
        .{ pool, n.right },
    );

    return 1 + lc + rc;
}

fn countNodes(node: ?*const TreeNode) usize {
    const n = node orelse return 0;
    return 1 + countNodes(n.left) + countNodes(n.right);
}

fn sequentialTreeHeight(node: ?*const TreeNode) usize {
    const n = node orelse return 0;
    return 1 + @max(sequentialTreeHeight(n.left), sequentialTreeHeight(n.right));
}
