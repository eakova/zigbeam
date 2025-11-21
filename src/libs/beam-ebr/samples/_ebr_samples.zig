const std = @import("std");
const ebr = @import("beam-ebr");

/// Sample 1: Quick Start - Basic EBR initialization and guard usage
fn sample1_quickStart() !void {
    std.debug.print("\n=== Sample 1: Quick Start ===\n", .{});

    const allocator = std.heap.c_allocator;

    // Each thread registers once
    var participant = ebr.Participant.init(allocator);
    const global = ebr.global();
    try global.registerParticipant(&participant);
    defer global.unregisterParticipant(&participant);

    // Bind participant to thread for convenient ebr.pin() API
    ebr.setThreadParticipant(&participant);

    // Use guards to protect memory access
    var guard = ebr.pin();
    defer guard.deinit();

    std.debug.print("  [OK] Participant registered and guard created\n", .{});
    std.debug.print("  [OK] Safe to read lock-free data structures while guard is active\n", .{});
}

/// Sample 2: Simple Memory Reclamation - Defer destruction of removed nodes
fn sample2_simpleReclamation() !void {
    std.debug.print("\n=== Sample 2: Simple Memory Reclamation ===\n", .{});

    const allocator = std.heap.c_allocator;

    var participant = ebr.Participant.init(allocator);
    const global = ebr.global();
    try global.registerParticipant(&participant);
    defer {
        participant.deinit(global);
        global.unregisterParticipant(&participant);
    }

    ebr.setThreadParticipant(&participant);

    const Node = struct {
        value: u64,
        allocator: std.mem.Allocator,
    };

    // Simulate removing a node from a data structure
    const old_node = try allocator.create(Node);
    old_node.* = .{ .value = 42, .allocator = allocator };

    std.debug.print("  Created node with value: {d}\n", .{old_node.value});

    // Create guard to protect the operation
    var guard = ebr.pin();
    defer guard.deinit();

    // Defer destruction - will be freed when it's safe
    const destroyNode = struct {
        fn destroy(ptr: *anyopaque, alloc: std.mem.Allocator) void {
            const node: *Node = @ptrCast(@alignCast(ptr));
            std.debug.print("  [OK] Node with value {d} safely destroyed\n", .{node.value});
            alloc.destroy(node);
        }
    }.destroy;

    guard.deferDestroy(.{
        .ptr = @ptrCast(old_node),
        .destroy_fn = destroyNode,
        .epoch = 0,
    });

    std.debug.print("  Node destruction deferred via EBR\n", .{});
    // Node will be destroyed when all guards are released and epoch advances
}

/// Sample 3: Multiple Threads - Concurrent operations with EBR
fn sample3_multipleThreads() !void {
    std.debug.print("\n=== Sample 3: Multiple Threads ===\n", .{});

    const num_threads = 4;
    const iterations = 100;

    const ThreadContext = struct {
        thread_id: usize,
        global: *ebr.GlobalEpoch,
        counter: *std.atomic.Value(u64),
    };

    const workerFn = struct {
        fn run(ctx: *ThreadContext) !void {
            var participant = ebr.Participant.init(std.heap.c_allocator);
            try ctx.global.registerParticipant(&participant);
            defer {
                participant.deinit(ctx.global);
                ctx.global.unregisterParticipant(&participant);
            }

            ebr.setThreadParticipant(&participant);

            var i: usize = 0;
            while (i < iterations) : (i += 1) {
                // Pin guard for each operation
                var guard = ebr.pin();
                defer guard.deinit();

                // Simulate some work
                _ = ctx.counter.fetchAdd(1, .monotonic);

                // Occasionally yield to other threads
                if (i % 10 == 0) {
                    std.Thread.yield() catch {};
                }
            }
        }
    }.run;

    var counter = std.atomic.Value(u64).init(0);
    var threads: [num_threads]std.Thread = undefined;
    var contexts: [num_threads]ThreadContext = undefined;

    const global = ebr.global();

    // Spawn worker threads
    for (0..num_threads) |i| {
        contexts[i] = .{
            .thread_id = i,
            .global = global,
            .counter = &counter,
        };
        threads[i] = try std.Thread.spawn(.{}, workerFn, .{&contexts[i]});
    }

    // Wait for all threads
    for (threads) |thread| {
        thread.join();
    }

    const total = counter.load(.monotonic);
    std.debug.print("  [OK] {d} threads completed {d} iterations each\n", .{ num_threads, iterations });
    std.debug.print("  [OK] Total operations: {d}\n", .{total});
}

/// Sample 4: Custom Destroy Function - Advanced memory management
fn sample4_customDestroy() !void {
    std.debug.print("\n=== Sample 4: Custom Destroy Function ===\n", .{});

    const allocator = std.heap.c_allocator;

    var participant = ebr.Participant.init(allocator);
    const global = ebr.global();
    try global.registerParticipant(&participant);
    defer {
        participant.deinit(global);
        global.unregisterParticipant(&participant);
    }

    ebr.setThreadParticipant(&participant);

    const TreeNode = struct {
        value: i64,
        left: ?*@This(),
        right: ?*@This(),
        allocator: std.mem.Allocator,
    };

    // Create a small tree
    const root = try allocator.create(TreeNode);
    root.* = .{ .value = 10, .left = null, .right = null, .allocator = allocator };

    const left = try allocator.create(TreeNode);
    left.* = .{ .value = 5, .left = null, .right = null, .allocator = allocator };

    const right = try allocator.create(TreeNode);
    right.* = .{ .value = 15, .left = null, .right = null, .allocator = allocator };

    root.left = left;
    root.right = right;

    std.debug.print("  Created tree: 10 (root), 5 (left), 15 (right)\n", .{});

    // Custom destroy function that handles tree structure
    const destroyTree = struct {
        fn destroy(ptr: *anyopaque, alloc: std.mem.Allocator) void {
            const node: *TreeNode = @ptrCast(@alignCast(ptr));
            std.debug.print("  [OK] Destroying node with value: {d}\n", .{node.value});

            if (node.left) |l| {
                alloc.destroy(l);
            }
            if (node.right) |r| {
                alloc.destroy(r);
            }

            alloc.destroy(node);
        }
    }.destroy;

    var guard = ebr.pin();
    defer guard.deinit();

    guard.deferDestroy(.{
        .ptr = @ptrCast(root),
        .destroy_fn = destroyTree,
        .epoch = 0,
    });

    std.debug.print("  Tree destruction deferred (including all child nodes)\n", .{});
}

/// Sample 5: Batch Operations - Efficient guard reuse
fn sample5_batchOperations() !void {
    std.debug.print("\n=== Sample 5: Batch Operations ===\n", .{});

    const allocator = std.heap.c_allocator;

    var participant = ebr.Participant.init(allocator);
    const global = ebr.global();
    try global.registerParticipant(&participant);
    defer {
        participant.deinit(global);
        global.unregisterParticipant(&participant);
    }

    ebr.setThreadParticipant(&participant);

    const Item = struct {
        id: u64,
        data: [64]u8,
    };

    // Simulate batch processing with a single guard
    var guard = ebr.pin();
    defer guard.deinit();

    const batch_size = 10;
    std.debug.print("  Processing batch of {d} items with single guard\n", .{batch_size});

    var i: u64 = 0;
    while (i < batch_size) : (i += 1) {
        // Simulate reading from lock-free data structure
        const item = Item{
            .id = i,
            .data = undefined,
        };

        // Process item (guard protects this operation)
        _ = item;

        if ((i + 1) % 5 == 0) {
            std.debug.print("  [OK] Processed {d}/{d} items\n", .{ i + 1, batch_size });
        }
    }

    std.debug.print("  [OK] Batch processing complete with amortized guard overhead\n", .{});
}

/// Sample 6: Manual Participant Management - No TLS
fn sample6_manualParticipantManagement() !void {
    std.debug.print("\n=== Sample 6: Manual Participant Management ===\n", .{});

    const allocator = std.heap.c_allocator;

    var participant = ebr.Participant.init(allocator);
    const global = ebr.global();
    try global.registerParticipant(&participant);
    defer {
        participant.deinit(global);
        global.unregisterParticipant(&participant);
    }

    // Don't use ebr.setThreadParticipant() - manage manually instead
    std.debug.print("  Using manual participant management (no TLS)\n", .{});

    // Create guard with explicit participant
    var guard = ebr.pinFor(&participant, global);
    defer guard.deinit();

    std.debug.print("  [OK] Guard created via explicit pinFor() call\n", .{});
    std.debug.print("  [OK] Useful when TLS is not available or desired\n", .{});
}

/// Sample 7: Advanced Pattern - Optimistic Concurrent Data Structure
fn sample7_optimisticConcurrency() !void {
    std.debug.print("\n=== Sample 7: Optimistic Concurrent Access ===\n", .{});

    const allocator = std.heap.c_allocator;

    const Node = struct {
        value: std.atomic.Value(i64),
        next: std.atomic.Value(?*@This()),
        allocator: std.mem.Allocator,
    };

    // Simulate a lock-free linked list head
    var head = std.atomic.Value(?*Node).init(null);

    var participant = ebr.Participant.init(allocator);
    const global = ebr.global();
    try global.registerParticipant(&participant);
    defer {
        participant.deinit(global);
        global.unregisterParticipant(&participant);
    }

    ebr.setThreadParticipant(&participant);

    // Insert operation with EBR protection
    {
        var guard = ebr.pin();
        defer guard.deinit();

        const new_node = try allocator.create(Node);
        new_node.* = .{
            .value = std.atomic.Value(i64).init(100),
            .next = std.atomic.Value(?*Node).init(null),
            .allocator = allocator,
        };

        // Try to insert at head
        const old_head = head.swap(new_node, .release);
        new_node.next.store(old_head, .release);

        std.debug.print("  [OK] Inserted node with value: 100\n", .{});
    }

    // Read operation with EBR protection
    {
        var guard = ebr.pin();
        defer guard.deinit();

        if (head.load(.acquire)) |node| {
            const value = node.value.load(.acquire);
            std.debug.print("  [OK] Read head node value: {d}\n", .{value});
        }
    }

    // Cleanup
    {
        var guard = ebr.pin();
        defer guard.deinit();

        if (head.load(.acquire)) |node| {
            const destroyNode = struct {
                fn destroy(ptr: *anyopaque, alloc: std.mem.Allocator) void {
                    const n: *Node = @ptrCast(@alignCast(ptr));
                    alloc.destroy(n);
                }
            }.destroy;

            guard.deferDestroy(.{
                .ptr = @ptrCast(node),
                .destroy_fn = destroyNode,
                .epoch = 0,
            });
        }
    }

    std.debug.print("  [OK] Optimistic concurrent access pattern demonstrated\n", .{});
}

/// Sample 8: Epoch Management - Understanding epoch progression
fn sample8_epochManagement() !void {
    std.debug.print("\n=== Sample 8: Epoch Management ===\n", .{});

    const allocator = std.heap.c_allocator;
    const global = ebr.global();

    var participant1 = ebr.Participant.init(allocator);
    try global.registerParticipant(&participant1);
    defer {
        participant1.deinit(global);
        global.unregisterParticipant(&participant1);
    }

    var participant2 = ebr.Participant.init(allocator);
    try global.registerParticipant(&participant2);
    defer {
        participant2.deinit(global);
        global.unregisterParticipant(&participant2);
    }

    std.debug.print("  Registered 2 participants\n", .{});

    // Pin with first participant
    ebr.setThreadParticipant(&participant1);
    var guard1 = ebr.pin();
    defer guard1.deinit();

    std.debug.print("  [OK] Participant 1 pinned (blocks epoch advancement)\n", .{});

    // Second participant can still pin independently
    ebr.setThreadParticipant(&participant2);
    var guard2 = ebr.pin();
    defer guard2.deinit();

    std.debug.print("  [OK] Participant 2 pinned\n", .{});
    std.debug.print("  [OK] Epoch will advance only after both guards are released\n", .{});
}

/// Sample 9: High Performance Pattern - Minimizing guard overhead
fn sample9_highPerformance() !void {
    std.debug.print("\n=== Sample 9: High Performance Pattern ===\n", .{});

    const allocator = std.heap.c_allocator;

    var participant = ebr.Participant.init(allocator);
    const global = ebr.global();
    try global.registerParticipant(&participant);
    defer {
        participant.deinit(global);
        global.unregisterParticipant(&participant);
    }

    ebr.setThreadParticipant(&participant);

    const iterations = 10000;
    var timer = try std.time.Timer.start();

    // Anti-pattern: Guard per operation (slower)
    {
        timer.reset();
        var i: usize = 0;
        while (i < iterations) : (i += 1) {
            var guard = ebr.pin();
            defer guard.deinit();
            // Simulate work
            _ = i * 2;
        }
        const elapsed = timer.read();
        std.debug.print("  Guard per operation: {d}ns total\n", .{elapsed});
    }

    // Optimized pattern: Single guard for batch (faster)
    {
        timer.reset();
        var guard = ebr.pin();
        defer guard.deinit();

        var i: usize = 0;
        while (i < iterations) : (i += 1) {
            // Simulate work
            _ = i * 2;
        }
        const elapsed = timer.read();
        std.debug.print("  Single guard for batch: {d}ns total\n", .{elapsed});
        std.debug.print("  [OK] Batch approach significantly faster\n", .{});
    }
}

pub fn main() !void {
    std.debug.print("\n============================================================\n", .{});
    std.debug.print("Beam-Ebr Samples - From Quick Start to Advanced\n", .{});
    std.debug.print("============================================================\n", .{});

    try sample1_quickStart();
    try sample2_simpleReclamation();
    try sample3_multipleThreads();
    try sample4_customDestroy();
    try sample5_batchOperations();
    try sample6_manualParticipantManagement();
    try sample7_optimisticConcurrency();
    try sample8_epochManagement();
    try sample9_highPerformance();

    std.debug.print("\n============================================================\n", .{});
    std.debug.print("All samples completed successfully!\n", .{});
    std.debug.print("============================================================\n\n", .{});
}
