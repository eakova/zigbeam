// FILE: _ebr_samples.zig
//! Sample usage code for Epoch-Based Reclamation (EBR)
//!
//! Demonstrates practical usage patterns and common scenarios.

const std = @import("std");
const ebr_module = @import("ebr.zig");
const EBR = ebr_module.EBR;
const ThreadState = ebr_module.ThreadState;
const Guard = ebr_module.Guard;
const pin = ebr_module.pin;
const AtomicPtr = ebr_module.AtomicPtr;

/// Sample 1: Basic pin/unpin usage
pub fn sample_basic_pin_unpin() !void {
    const allocator = std.heap.page_allocator;

    var global = try EBR.init(.{ .allocator = allocator });
    defer global.deinit();

    var thread_state: ThreadState = .{};
    try thread_state.ensureInitialized(.{
        .global = &global,
        .allocator = allocator,
    });
    defer thread_state.deinitThread();

    var guard = pin(&thread_state, &global);
    defer guard.unpin();

    std.debug.print("Thread is pinned to epoch\n", .{});
}

/// Sample 2: Using AtomicPtr with EBR
pub fn sample_atomic_ptr() !void {
    const allocator = std.heap.page_allocator;

    var global = try EBR.init(.{ .allocator = allocator });
    defer global.deinit();

    var thread_state: ThreadState = .{};
    try thread_state.ensureInitialized(.{
        .global = &global,
        .allocator = allocator,
    });
    defer thread_state.deinitThread();

    const IntPtr = AtomicPtr(u64);
    var shared_ptr = IntPtr.init(.{});

    const initial = try allocator.create(u64);
    initial.* = 42;
    shared_ptr.store(.{ .value = initial });

    {
        var guard = pin(&thread_state, &global);
        defer guard.unpin();

        const value = shared_ptr.load(.{ .guard = &guard });
        if (value) |v| {
            std.debug.print("Current value: {}\n", .{v.*});
        }
    }

    {
        var guard = pin(&thread_state, &global);
        defer guard.unpin();

        const new_value = try allocator.create(u64);
        new_value.* = 100;

        const old = shared_ptr.swap(.{ .value = new_value });

        if (old) |old_ptr| {
            const Deleter = struct {
                ptr: *u64,
                alloc: std.mem.Allocator,

                fn delete(self_ptr: *anyopaque) void {
                    const self: *@This() = @ptrCast(@alignCast(self_ptr));
                    self.alloc.destroy(self.ptr);
                    self.alloc.destroy(self);
                }
            };

            const deleter = try allocator.create(Deleter);
            deleter.* = Deleter{
                .ptr = old_ptr,
                .alloc = allocator,
            };

            guard.retire(.{
                .ptr = deleter,
                .deleter = Deleter.delete,
            });
        }
    }

    {
        var guard = pin(&thread_state, &global);
        defer guard.unpin();

        const final = shared_ptr.load(.{ .guard = &guard });
        if (final) |f| {
            allocator.destroy(f);
        }
    }
}

/// Sample 3: Lock-free stack using EBR
pub fn sample_lock_free_stack() !void {
    const allocator = std.heap.page_allocator;

    const Node = struct {
        value: u64,
        next: ?*@This(),
    };

    const Stack = struct {
        head: AtomicPtr(Node),
        global: *EBR,
        allocator: std.mem.Allocator,

        fn init(opts: struct {
            global: *EBR,
            allocator: std.mem.Allocator,
        }) @This() {
            return .{
                .head = AtomicPtr(Node).init(.{}),
                .global = opts.global,
                .allocator = opts.allocator,
            };
        }

        fn push(self: *@This(), opts: struct {
            guard: *Guard,
            value: u64,
        }) !void {
            const node = try self.allocator.create(Node);
            node.* = Node{
                .value = opts.value,
                .next = null,
            };

            while (true) {
                const old_head = self.head.load(.{ .guard = opts.guard });
                node.next = old_head;

                const result = self.head.compareAndSwapWeak(.{
                    .expected = old_head,
                    .new = node,
                });

                if (result == null) break;
            }
        }

        fn pop(self: *@This(), opts: struct {
            guard: *Guard,
        }) !?u64 {
            while (true) {
                const old_head = self.head.load(.{ .guard = opts.guard }) orelse return null;
                const new_head = old_head.next;

                const result = self.head.compareAndSwapWeak(.{
                    .expected = old_head,
                    .new = new_head,
                });

                if (result == null) {
                    const value = old_head.value;

                    const Deleter = struct {
                        node: *Node,
                        allocator: std.mem.Allocator,

                        fn delete(ptr: *anyopaque) void {
                            const deleter_self: *@This() = @ptrCast(@alignCast(ptr));
                            deleter_self.allocator.destroy(deleter_self.node);
                            deleter_self.allocator.destroy(deleter_self);
                        }
                    };

                    const deleter = try self.allocator.create(Deleter);
                    deleter.* = Deleter{
                        .node = old_head,
                        .allocator = self.allocator,
                    };

                    opts.guard.retire(.{
                        .ptr = deleter,
                        .deleter = Deleter.delete,
                    });

                    return value;
                }
            }
        }
    };

    var global = try EBR.init(.{ .allocator = allocator });
    defer global.deinit();

    var thread_state: ThreadState = .{};
    try thread_state.ensureInitialized(.{
        .global = &global,
        .allocator = allocator,
    });
    defer thread_state.deinitThread();

    var stack = Stack.init(.{
        .global = &global,
        .allocator = allocator,
    });

    {
        var guard = pin(&thread_state, &global);
        defer guard.unpin();

        try stack.push(.{ .guard = &guard, .value = 1 });
        try stack.push(.{ .guard = &guard, .value = 2 });
        try stack.push(.{ .guard = &guard, .value = 3 });
    }

    {
        var guard = pin(&thread_state, &global);
        defer guard.unpin();

        while (try stack.pop(.{ .guard = &guard })) |value| {
            std.debug.print("Popped: {}\n", .{value});
        }
    }

    {
        var guard = pin(&thread_state, &global);
        guard.flush();
        guard.unpin();
    }
}

/// Sample 4: Multi-threaded usage pattern
pub fn sample_multi_threaded() !void {
    const allocator = std.heap.page_allocator;

    var global = try EBR.init(.{ .allocator = allocator });
    defer global.deinit();

    const SharedData = AtomicPtr(u64);
    var shared = SharedData.init(.{});

    const ThreadContext = struct {
        global: *EBR,
        shared: *SharedData,
        thread_id: usize,

        threadlocal var thread_state: ThreadState = .{};

        fn worker(ctx: *@This()) !void {
            try thread_state.ensureInitialized(.{
                .global = ctx.global,
                .allocator = std.heap.page_allocator,
            });
            defer thread_state.deinitThread();

            var i: usize = 0;
            while (i < 10) : (i += 1) {
                var guard = pin(&thread_state, ctx.global);
                defer guard.unpin();

                const current = ctx.shared.load(.{ .guard = &guard });
                if (current) |c| {
                    std.debug.print("Thread {} read: {}\n", .{ ctx.thread_id, c.* });
                }

                const new_value = try std.heap.page_allocator.create(u64);
                new_value.* = ctx.thread_id * 100 + i;

                const old = ctx.shared.swap(.{ .value = new_value });

                if (old) |old_ptr| {
                    const Deleter = struct {
                        ptr: *u64,

                        fn delete(self_ptr: *anyopaque) void {
                            const self: *@This() = @ptrCast(@alignCast(self_ptr));
                            std.heap.page_allocator.destroy(self.ptr);
                            std.heap.page_allocator.destroy(self);
                        }
                    };

                    const deleter = try std.heap.page_allocator.create(Deleter);
                    deleter.* = Deleter{ .ptr = old_ptr };

                    guard.retire(.{
                        .ptr = deleter,
                        .deleter = Deleter.delete,
                    });
                }
            }

            var guard = pin(&thread_state, ctx.global);
            guard.flush();
            guard.unpin();
        }
    };

    const thread_count = 4;
    var threads: [thread_count]std.Thread = undefined;
    var contexts: [thread_count]ThreadContext = undefined;

    for (&threads, &contexts, 0..) |*t, *ctx, idx| {
        ctx.* = ThreadContext{
            .global = &global,
            .shared = &shared,
            .thread_id = idx,
        };
        t.* = try std.Thread.spawn(.{}, ThreadContext.worker, .{ctx});
    }

    for (&threads) |*t| {
        t.join();
    }

    var cleanup_state: ThreadState = .{};
    try cleanup_state.ensureInitialized(.{
        .global = &global,
        .allocator = allocator,
    });
    defer cleanup_state.deinitThread();

    var guard = pin(&cleanup_state, &global);
    defer guard.unpin();

    const final = shared.load(.{ .guard = &guard });
    if (final) |f| {
        allocator.destroy(f);
    }

    std.debug.print("All threads completed\n", .{});
}

pub fn main() !void {
    std.debug.print("\n=== EBR Sample 1: Basic Pin/Unpin ===\n", .{});
    try sample_basic_pin_unpin();

    std.debug.print("\n=== EBR Sample 2: Atomic Pointer ===\n", .{});
    try sample_atomic_ptr();

    std.debug.print("\n=== EBR Sample 3: Lock-Free Stack ===\n", .{});
    try sample_lock_free_stack();

    std.debug.print("\n=== EBR Sample 4: Multi-Threaded ===\n", .{});
    try sample_multi_threaded();

    std.debug.print("\n=== All samples completed successfully ===\n", .{});
}
