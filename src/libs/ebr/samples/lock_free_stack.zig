//! Lock-Free Stack with EBR
//!
//! A complete, production-ready lock-free stack using EBR for safe
//! memory reclamation. Demonstrates the classic use case for EBR.
//!
//! Run: zig build sample-stack

const std = @import("std");
const ebr = @import("ebr");

/// A node in the lock-free stack.
/// Must include allocator field for zero-allocation destruction.
const Node = struct {
    value: i32,
    next: std.atomic.Value(?*Node),
    allocator: std.mem.Allocator,
};

/// Lock-free stack with EBR-protected memory reclamation.
pub const LockFreeStack = struct {
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

    /// Push a value onto the stack (lock-free).
    pub fn push(self: *LockFreeStack, value: i32) !void {
        const node = try self.allocator.create(Node);
        node.* = .{
            .value = value,
            .next = undefined,
            .allocator = self.allocator,
        };

        // Pin to ensure consistent view of head pointer
        const guard = self.collector.pin();
        defer guard.unpin();

        // CAS loop to atomically update head
        var current = self.head.load(.monotonic);
        while (true) {
            node.next = std.atomic.Value(?*Node).init(current);
            if (self.head.cmpxchgWeak(current, node, .release, .monotonic)) |actual| {
                current = actual; // Retry with actual value
            } else {
                break; // Success
            }
        }
    }

    /// Pop a value from the stack (lock-free).
    /// Returns null if stack is empty.
    pub fn pop(self: *LockFreeStack) ?i32 {
        // Pin to protect nodes from reclamation during traversal
        const guard = self.collector.pin();
        defer guard.unpin();

        var current = self.head.load(.acquire);
        while (current) |node| {
            const next = node.next.load(.acquire);
            if (self.head.cmpxchgWeak(current, next, .release, .monotonic)) |actual| {
                current = actual; // Retry with actual value
            } else {
                // Success - node is now unlinked
                const value = node.value;

                // Defer destruction - node will be freed when all
                // readers have finished (3-epoch safety guarantee)
                self.collector.deferDestroy(Node, node);

                return value;
            }
        }
        return null; // Stack is empty
    }

    /// Check if stack is empty (may be stale immediately).
    pub fn isEmpty(self: *const LockFreeStack) bool {
        return self.head.load(.acquire) == null;
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== Lock-Free Stack Example ===\n\n", .{});

    // Create collector and register thread
    var collector = try ebr.Collector.init(allocator);
    defer collector.deinit();

    const handle = try collector.registerThread();
    defer collector.unregisterThread(handle);

    // Create stack
    var stack = LockFreeStack.init(&collector, allocator);

    // Push values
    std.debug.print("Pushing: 10, 20, 30, 40, 50\n", .{});
    try stack.push(10);
    try stack.push(20);
    try stack.push(30);
    try stack.push(40);
    try stack.push(50);

    // Pop and display (LIFO order)
    std.debug.print("Popping: ", .{});
    while (stack.pop()) |value| {
        std.debug.print("{} ", .{value});
    }
    std.debug.print("\n", .{});

    // Force garbage collection
    _ = collector.tryAdvanceEpoch();
    _ = collector.tryAdvanceEpoch();
    _ = collector.tryAdvanceEpoch();
    collector.collect();

    std.debug.print("\nAll nodes safely reclaimed!\n", .{});
}
