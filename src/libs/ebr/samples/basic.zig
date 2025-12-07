//! Basic EBR Usage Example
//!
//! Demonstrates the fundamental pattern for using EBR:
//! 1. Create a collector (one per application)
//! 2. Register threads
//! 3. Use guards to protect critical sections
//! 4. Defer destruction of shared objects
//!
//! Run: zig build sample-basic

const std = @import("std");
const ebr = @import("ebr");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== Basic EBR Example ===\n\n", .{});

    // Step 1: Create a collector (typically one per application)
    var collector = try ebr.Collector.init(allocator);
    defer collector.deinit();

    std.debug.print("1. Collector created\n", .{});

    // Step 2: Register this thread with the collector
    //         Each thread accessing shared data must register.
    const handle = try collector.registerThread();
    defer collector.unregisterThread(handle);

    std.debug.print("2. Thread registered\n", .{});

    // Step 3: Enter critical section with a guard
    //         While guard is held, protected pointers are safe to access.
    {
        const guard = collector.pin();
        defer guard.unpin();

        std.debug.print("3. Entered critical section (pinned)\n", .{});

        // Safe to access shared data here
        // Other threads cannot reclaim memory we might be reading
    }
    std.debug.print("4. Left critical section (unpinned)\n", .{});

    // Step 4: Defer destruction of objects
    //         Objects are safely reclaimed after all readers have finished.
    const Node = struct {
        value: u32,
        allocator: std.mem.Allocator,
    };

    const node = try allocator.create(Node);
    node.* = .{ .value = 42, .allocator = allocator };

    {
        const guard = collector.pin();
        defer guard.unpin();

        // Retire the node - will be destroyed when safe
        collector.deferDestroy(Node, node);
        std.debug.print("5. Node deferred for destruction\n", .{});
    }

    // Step 5: Force collection (normally happens automatically)
    _ = collector.tryAdvanceEpoch();
    _ = collector.tryAdvanceEpoch();
    _ = collector.tryAdvanceEpoch();
    collector.collect();

    std.debug.print("6. Garbage collected\n", .{});
    std.debug.print("\nDone!\n", .{});
}
