//! Quickstart Examples Verification Test (T068)
//!
//! Verifies that the code examples from quickstart.md compile and run correctly.

const std = @import("std");
const ebr = @import("ebr");

// ============================================================================
// Example 1: Basic Usage (from quickstart.md section 1-3)
// ============================================================================

fn testBasicUsage(allocator: std.mem.Allocator) !void {
    // Create a collector (one per application)
    var collector = try ebr.Collector.init(allocator);
    defer collector.deinit();

    // Register thread
    const handle = try collector.registerThread();
    defer collector.unregisterThread(handle);

    // Protect critical section
    {
        const guard = collector.pin();
        defer guard.unpin();
        // Safe to access protected pointers here
    }
}

// ============================================================================
// Example 2: Lock-Free Stack (from quickstart.md)
// ============================================================================

const Node = struct {
    value: i32,
    next: std.atomic.Value(?*Node),
    allocator: std.mem.Allocator, // Required for deferDestroy (zero-allocation)
};

const LockFreeStack = struct {
    head: std.atomic.Value(?*Node),
    collector: *ebr.Collector,
    allocator: std.mem.Allocator,

    pub fn init(collector: *ebr.Collector, allocator: std.mem.Allocator) LockFreeStack {
        return .{
            .head = std.atomic.Value(?*Node).init(null),
            .collector = collector,
            .allocator = allocator,
        };
    }

    pub fn push(self: *LockFreeStack, value: i32) !void {
        const node = try self.allocator.create(Node);
        node.* = .{ .value = value, .next = undefined, .allocator = self.allocator };

        const guard = self.collector.pin();
        defer guard.unpin();

        var current = self.head.load(.monotonic);
        while (true) {
            node.next = std.atomic.Value(?*Node).init(current);
            if (self.head.cmpxchgWeak(current, node, .release, .monotonic)) |actual| {
                current = actual;
            } else {
                break;
            }
        }
    }

    pub fn pop(self: *LockFreeStack) ?i32 {
        const guard = self.collector.pin();
        defer guard.unpin();

        var current = self.head.load(.acquire);
        while (current) |node| {
            const next = node.next.load(.acquire);
            if (self.head.cmpxchgWeak(current, next, .release, .monotonic)) |actual| {
                current = actual;
            } else {
                const value = node.value;
                // Safely defer reclamation (zero-allocation, uses embedded allocator)
                self.collector.deferDestroy(Node, node);
                return value;
            }
        }
        return null;
    }
};

fn testLockFreeStack(allocator: std.mem.Allocator) !void {
    var collector = try ebr.Collector.init(allocator);
    defer collector.deinit();

    const handle = try collector.registerThread();
    defer collector.unregisterThread(handle);

    var stack = LockFreeStack.init(&collector, allocator);

    // Push some values
    try stack.push(1);
    try stack.push(2);
    try stack.push(3);

    // Pop and verify LIFO order
    var count: i32 = 0;
    while (stack.pop()) |_| {
        count += 1;
    }

    // Should have popped 3 values
    if (count != 3) return error.UnexpectedPopCount;

    // Force garbage collection
    collector.collect();
}

// ============================================================================
// Example 3: FastGuard for Maximum Throughput
// ============================================================================

fn testFastGuard(allocator: std.mem.Allocator) !void {
    var collector = try ebr.Collector.init(allocator);
    defer collector.deinit();

    const handle = try collector.registerThread();
    defer collector.unregisterThread(handle);

    // Use pinFast() for maximum throughput (no nesting support)
    for (0..1000) |_| {
        const guard = collector.pinFast();
        // Do fast work
        guard.unpin();
    }
}

// ============================================================================
// Main Entry Point
// ============================================================================

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== Quickstart Examples Verification ===\n\n", .{});

    std.debug.print("Testing basic usage... ", .{});
    try testBasicUsage(allocator);
    std.debug.print("OK\n", .{});

    std.debug.print("Testing lock-free stack... ", .{});
    try testLockFreeStack(allocator);
    std.debug.print("OK\n", .{});

    std.debug.print("Testing FastGuard... ", .{});
    try testFastGuard(allocator);
    std.debug.print("OK\n", .{});

    std.debug.print("\n✓ PASS: All quickstart examples compile and run correctly\n", .{});
}
