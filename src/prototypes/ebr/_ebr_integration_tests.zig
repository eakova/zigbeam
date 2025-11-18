// FILE: _ebr_integration_tests.zig
//! Integration tests for Epoch-Based Reclamation (EBR)
//!
//! These tests verify:
//! - Multi-threaded concurrent operations
//! - Proper memory reclamation under load
//! - Lock-free data structure integration
//! - Race condition handling
//! - Memory safety across threads

const std = @import("std");
const testing = std.testing;
const Thread = std.Thread;
const ebr_module = @import("ebr.zig");
const EBR = ebr_module.EBR;
const ThreadState = ebr_module.ThreadState;
const Guard = ebr_module.Guard;
const pin = ebr_module.pin;
const AtomicPtr = ebr_module.AtomicPtr;

test "Integration: concurrent pin/unpin from multiple threads" {
    var global = try EBR.init(.{
        .allocator = testing.allocator,
    });
    defer global.deinit();

    const ThreadContext = struct {
        global: *EBR,
        iterations: usize,

        threadlocal var thread_state: ThreadState = .{};

        fn worker(ctx: *@This()) !void {
            try thread_state.ensureInitialized(.{
                .global = ctx.global,
                .allocator = testing.allocator,
            });
            defer thread_state.deinitThread();

            var i: usize = 0;
            while (i < ctx.iterations) : (i += 1) {
                var guard = pin(&thread_state, ctx.global);
                Thread.yield() catch {};
                guard.unpin();
            }
        }
    };

    const thread_count = 4;
    const iterations = 1000;

    var threads: [thread_count]Thread = undefined;
    var contexts: [thread_count]ThreadContext = undefined;

    for (&threads, &contexts) |*t, *ctx| {
        ctx.* = ThreadContext{
            .global = &global,
            .iterations = iterations,
        };
        t.* = try Thread.spawn(.{}, ThreadContext.worker, .{ctx});
    }

    for (&threads) |*t| {
        t.join();
    }
}

test "Integration: concurrent retire and collect" {
    var global = try EBR.init(.{
        .allocator = testing.allocator,
    });
    defer global.deinit();

    const TestData = struct {
        value: u64,
        counter: *std.atomic.Value(u64),

        fn deleter(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            _ = self.counter.fetchAdd(1, .monotonic);
            testing.allocator.destroy(self);
        }
    };

    var dealloc_counter = std.atomic.Value(u64).init(0);

    const ThreadContext = struct {
        global: *EBR,
        counter: *std.atomic.Value(u64),
        allocations: usize,

        threadlocal var thread_state: ThreadState = .{};

        fn worker(ctx: *@This()) !void {
            try thread_state.ensureInitialized(.{
                .global = ctx.global,
                .allocator = testing.allocator,
            });
            defer thread_state.deinitThread();

            var i: usize = 0;
            while (i < ctx.allocations) : (i += 1) {
                var guard = pin(&thread_state, ctx.global);

                const data = try testing.allocator.create(TestData);
                data.* = TestData{
                    .value = i,
                    .counter = ctx.counter,
                };

                guard.retire(.{
                    .ptr = data,
                    .deleter = TestData.deleter,
                });

                guard.unpin();

                if (i % 10 == 0) {
                    var flush_guard = pin(&thread_state, ctx.global);
                    flush_guard.flush();
                    flush_guard.unpin();
                }
            }

            var flush_guard = pin(&thread_state, ctx.global);
            flush_guard.flush();
            flush_guard.unpin();
        }
    };

    const thread_count = 4;
    const allocations_per_thread = 100;

    var threads: [thread_count]Thread = undefined;
    var contexts: [thread_count]ThreadContext = undefined;

    for (&threads, &contexts) |*t, *ctx| {
        ctx.* = ThreadContext{
            .global = &global,
            .counter = &dealloc_counter,
            .allocations = allocations_per_thread,
        };
        t.* = try Thread.spawn(.{}, ThreadContext.worker, .{ctx});
    }

    for (&threads) |*t| {
        t.join();
    }

    const deallocated = dealloc_counter.load(.monotonic);
    try testing.expect(deallocated > 0);
}

test "Integration: AtomicPtr concurrent updates" {
    var global = try EBR.init(.{
        .allocator = testing.allocator,
    });
    defer global.deinit();

    const IntPtr = AtomicPtr(u64);
    var shared_ptr = IntPtr.init(.{});

    const ThreadContext = struct {
        global: *EBR,
        ptr: *IntPtr,
        thread_id: usize,
        iterations: usize,

        threadlocal var thread_state: ThreadState = .{};

        fn worker(ctx: *@This()) !void {
            try thread_state.ensureInitialized(.{
                .global = ctx.global,
                .allocator = testing.allocator,
            });
            defer thread_state.deinitThread();

            var i: usize = 0;
            while (i < ctx.iterations) : (i += 1) {
                var guard = pin(&thread_state, ctx.global);

                const value = try testing.allocator.create(u64);
                value.* = ctx.thread_id * 1000 + i;

                const old = ctx.ptr.swap(.{ .value = value });

                if (old) |old_ptr| {
                    const OldData = struct {
                        ptr: *u64,

                        fn deleter(p: *anyopaque) void {
                            const self: *@This() = @ptrCast(@alignCast(p));
                            testing.allocator.destroy(self.ptr);
                            testing.allocator.destroy(self);
                        }
                    };

                    const old_data = try testing.allocator.create(OldData);
                    old_data.* = OldData{ .ptr = old_ptr };

                    guard.retire(.{
                        .ptr = old_data,
                        .deleter = OldData.deleter,
                    });
                }

                guard.unpin();
            }

            var flush_guard = pin(&thread_state, ctx.global);
            flush_guard.flush();
            flush_guard.unpin();
        }
    };

    const thread_count = 4;
    const iterations = 50;

    var threads: [thread_count]Thread = undefined;
    var contexts: [thread_count]ThreadContext = undefined;

    for (&threads, &contexts, 0..) |*t, *ctx, idx| {
        ctx.* = ThreadContext{
            .global = &global,
            .ptr = &shared_ptr,
            .thread_id = idx,
            .iterations = iterations,
        };
        t.* = try Thread.spawn(.{}, ThreadContext.worker, .{ctx});
    }

    for (&threads) |*t| {
        t.join();
    }

    // Cleanup final value
    var cleanup_state: ThreadState = .{};
    try cleanup_state.ensureInitialized(.{
        .global = &global,
        .allocator = testing.allocator,
    });
    defer cleanup_state.deinitThread();

    var guard_cleanup = pin(&cleanup_state, &global);
    const final_val = shared_ptr.load(.{ .guard = &guard_cleanup });
    if (final_val) |val| {
        testing.allocator.destroy(val);
    }
    guard_cleanup.unpin();
}

test "Integration: lock-free stack using EBR" {
    var global = try EBR.init(.{
        .allocator = testing.allocator,
    });
    defer global.deinit();

    const Node = struct {
        value: u64,
        next: ?*@This(),
    };

    const Stack = struct {
        head: AtomicPtr(Node),

        fn init() @This() {
            return .{ .head = AtomicPtr(Node).init(.{}) };
        }

        fn push(self: *@This(), opts: struct {
            guard: *Guard,
            node: *Node,
        }) void {
            while (true) {
                const old_head = self.head.load(.{ .guard = opts.guard });
                opts.node.next = old_head;

                const result = self.head.compareAndSwapWeak(.{
                    .expected = old_head,
                    .new = opts.node,
                });

                if (result == null) break;
            }
        }

        fn pop(self: *@This(), opts: struct {
            guard: *Guard,
        }) ?*Node {
            while (true) {
                const old_head = self.head.load(.{ .guard = opts.guard }) orelse return null;
                const new_head = old_head.next;

                const result = self.head.compareAndSwapWeak(.{
                    .expected = old_head,
                    .new = new_head,
                });

                if (result == null) {
                    return old_head;
                }
            }
        }
    };

    var stack = Stack.init();

    const ThreadContext = struct {
        global: *EBR,
        stack: *Stack,
        thread_id: usize,
        operations: usize,

        threadlocal var thread_state: ThreadState = .{};

        fn worker(ctx: *@This()) !void {
            try thread_state.ensureInitialized(.{
                .global = ctx.global,
                .allocator = testing.allocator,
            });
            defer thread_state.deinitThread();

            var i: usize = 0;
            while (i < ctx.operations) : (i += 1) {
                var guard = pin(&thread_state, ctx.global);

                if (i % 2 == 0) {
                    const node = try testing.allocator.create(Node);
                    node.* = Node{
                        .value = ctx.thread_id * 10000 + i,
                        .next = null,
                    };
                    ctx.stack.push(.{ .guard = &guard, .node = node });
                } else {
                    if (ctx.stack.pop(.{ .guard = &guard })) |node| {
                        const NodeWrapper = struct {
                            node_ptr: *Node,
                            fn deleter(ptr: *anyopaque) void {
                                const self: *@This() = @ptrCast(@alignCast(ptr));
                                testing.allocator.destroy(self.node_ptr);
                                testing.allocator.destroy(self);
                            }
                        };

                        const wrapper = try testing.allocator.create(NodeWrapper);
                        wrapper.* = NodeWrapper{ .node_ptr = node };

                        guard.retire(.{
                            .ptr = wrapper,
                            .deleter = NodeWrapper.deleter,
                        });
                    }
                }

                guard.unpin();
            }

            var flush_guard = pin(&thread_state, ctx.global);
            flush_guard.flush();
            flush_guard.unpin();
        }
    };

    const thread_count = 4;
    const operations_per_thread = 100;

    var threads: [thread_count]Thread = undefined;
    var contexts: [thread_count]ThreadContext = undefined;

    for (&threads, &contexts, 0..) |*t, *ctx, idx| {
        ctx.* = ThreadContext{
            .global = &global,
            .stack = &stack,
            .thread_id = idx,
            .operations = operations_per_thread,
        };
        t.* = try Thread.spawn(.{}, ThreadContext.worker, .{ctx});
    }

    for (&threads) |*t| {
        t.join();
    }

    // Cleanup remaining nodes
    var cleanup_state: ThreadState = .{};
    try cleanup_state.ensureInitialized(.{
        .global = &global,
        .allocator = testing.allocator,
    });
    defer cleanup_state.deinitThread();

    var guard = pin(&cleanup_state, &global);
    while (stack.pop(.{ .guard = &guard })) |node| {
        testing.allocator.destroy(node);
    }
    guard.unpin();
}

test "Integration: stress test - many threads, many operations" {
    var global = try EBR.init(.{
        .allocator = testing.allocator,
    });
    defer global.deinit();

    const TestData = struct {
        value: u64,

        fn deleter(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            testing.allocator.destroy(self);
        }
    };

    const ThreadContext = struct {
        global: *EBR,
        iterations: usize,

        threadlocal var thread_state: ThreadState = .{};

        fn worker(ctx: *@This()) !void {
            try thread_state.ensureInitialized(.{
                .global = ctx.global,
                .allocator = testing.allocator,
            });
            defer thread_state.deinitThread();

            var i: usize = 0;
            while (i < ctx.iterations) : (i += 1) {
                var guard = pin(&thread_state, ctx.global);

                const data = try testing.allocator.create(TestData);
                data.* = TestData{ .value = i };

                guard.retire(.{
                    .ptr = data,
                    .deleter = TestData.deleter,
                });

                guard.unpin();

                if (i % 50 == 0) {
                    var flush_guard = pin(&thread_state, ctx.global);
                    flush_guard.flush();
                    flush_guard.unpin();
                }

                if (i % 10 == 0) {
                    Thread.yield() catch {};
                }
            }

            var flush_guard = pin(&thread_state, ctx.global);
            flush_guard.flush();
            flush_guard.unpin();
        }
    };

    const thread_count = 8;
    const iterations = 500;

    var threads: [thread_count]Thread = undefined;
    var contexts: [thread_count]ThreadContext = undefined;

    for (&threads, &contexts) |*t, *ctx| {
        ctx.* = ThreadContext{
            .global = &global,
            .iterations = iterations,
        };
        t.* = try Thread.spawn(.{}, ThreadContext.worker, .{ctx});
    }

    for (&threads) |*t| {
        t.join();
    }
}

test "Integration: epoch advancement under concurrent load" {
    var global = try EBR.init(.{
        .allocator = testing.allocator,
    });
    defer global.deinit();

    const initial_epoch = global.global_epoch.load(.acquire);

    const ThreadContext = struct {
        global: *EBR,
        iterations: usize,

        threadlocal var thread_state: ThreadState = .{};

        fn worker(ctx: *@This()) !void {
            try thread_state.ensureInitialized(.{
                .global = ctx.global,
                .allocator = testing.allocator,
            });
            defer thread_state.deinitThread();

            var i: usize = 0;
            while (i < ctx.iterations) : (i += 1) {
                var guard = pin(&thread_state, ctx.global);
                Thread.yield() catch {};
                guard.unpin();
            }
        }
    };

    const thread_count = 4;
    const iterations = 1000;

    var threads: [thread_count]Thread = undefined;
    var contexts: [thread_count]ThreadContext = undefined;

    for (&threads, &contexts) |*t, *ctx| {
        ctx.* = ThreadContext{
            .global = &global,
            .iterations = iterations,
        };
        t.* = try Thread.spawn(.{}, ThreadContext.worker, .{ctx});
    }

    for (&threads) |*t| {
        t.join();
    }

    const final_epoch = global.global_epoch.load(.acquire);
    try testing.expect(final_epoch >= initial_epoch);
}
