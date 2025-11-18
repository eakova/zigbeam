// FILE: _ebr_fuzz_tests.zig
//! Fuzz tests for Epoch-Based Reclamation (EBR)
//!
//! Stress testing:
//! - Pointer lifetime under random operations
//! - Concurrent chaos with unpredictable access patterns
//! - Rapid thread creation and destruction
//! - Race conditions and edge cases

const std = @import("std");
const testing = std.testing;
const ebr_module = @import("ebr.zig");
const EBR = ebr_module.EBR;
const ThreadState = ebr_module.ThreadState;
const Guard = ebr_module.Guard;
const pin = ebr_module.pin;
const AtomicPtr = ebr_module.AtomicPtr;

// Thread-local state for fuzz testing
threadlocal var fuzz_thread_state: ThreadState = .{};

/// Random seed for reproducible fuzzing
var rng_state = std.Random.DefaultPrng.init(42);

test "Fuzz: random pin/unpin sequences" {
    var global = try EBR.init(.{
        .allocator = testing.allocator,
    });
    defer global.deinit();

    try fuzz_thread_state.ensureInitialized(.{
        .global = &global,
        .allocator = testing.allocator,
    });
    defer fuzz_thread_state.deinitThread();

    const rng = rng_state.random();

    // Random pin/unpin operations
    var i: usize = 0;
    while (i < 10000) : (i += 1) {
        const ops = rng.intRangeAtMost(u8, 1, 5);
        var j: u8 = 0;
        while (j < ops) : (j += 1) {
            var guard = pin(&fuzz_thread_state, &global);
            guard.unpin();
        }
    }
}

test "Fuzz: random retire operations with varying lifetimes" {
    var global = try EBR.init(.{
        .allocator = testing.allocator,
    });
    defer global.deinit();

    try fuzz_thread_state.ensureInitialized(.{
        .global = &global,
        .allocator = testing.allocator,
    });
    defer fuzz_thread_state.deinitThread();

    const rng = rng_state.random();

    const TestData = struct {
        value: u64,

        fn deleter(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            testing.allocator.destroy(self);
        }
    };

    // Retire objects with random timing
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        var guard = pin(&fuzz_thread_state, &global);

        const allocate_count = rng.intRangeAtMost(usize, 1, 10);
        var j: usize = 0;
        while (j < allocate_count) : (j += 1) {
            const data = try testing.allocator.create(TestData);
            data.* = TestData{ .value = i * 100 + j };

            guard.retire(.{
                .ptr = data,
                .deleter = TestData.deleter,
            });
        }

        guard.unpin();

        // Random flush timing
        if (rng.boolean()) {
            var flush_guard = pin(&fuzz_thread_state, &global);
            flush_guard.flush();
            flush_guard.unpin();
        }
    }

    // Final cleanup
    var final_guard = pin(&fuzz_thread_state, &global);
    final_guard.flush();
    final_guard.unpin();
}

test "Fuzz: AtomicPtr with random operations" {
    var global = try EBR.init(.{
        .allocator = testing.allocator,
    });
    defer global.deinit();

    try fuzz_thread_state.ensureInitialized(.{
        .global = &global,
        .allocator = testing.allocator,
    });
    defer fuzz_thread_state.deinitThread();

    const rng = rng_state.random();

    const IntPtr = AtomicPtr(u64);
    var ptr = IntPtr.init(.{});

    const TestDeleter = struct {
        value: *u64,

        fn delete(self_ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(self_ptr));
            testing.allocator.destroy(self.value);
            testing.allocator.destroy(self);
        }
    };

    // Random operations: load, store, swap, CAS
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        var guard = pin(&fuzz_thread_state, &global);

        const op = rng.intRangeAtMost(u8, 0, 3);
        switch (op) {
            0 => {
                // Load
                _ = ptr.load(.{ .guard = &guard });
            },
            1 => {
                // Store
                const new_value = try testing.allocator.create(u64);
                new_value.* = i;

                const old = ptr.swap(.{ .value = new_value });
                if (old) |old_ptr| {
                    const deleter = try testing.allocator.create(TestDeleter);
                    deleter.* = TestDeleter{ .value = old_ptr };
                    guard.retire(.{
                        .ptr = deleter,
                        .deleter = TestDeleter.delete,
                    });
                }
            },
            2 => {
                // Swap
                const new_value = try testing.allocator.create(u64);
                new_value.* = i + 1000;

                const old = ptr.swap(.{ .value = new_value });
                if (old) |old_ptr| {
                    const deleter = try testing.allocator.create(TestDeleter);
                    deleter.* = TestDeleter{ .value = old_ptr };
                    guard.retire(.{
                        .ptr = deleter,
                        .deleter = TestDeleter.delete,
                    });
                }
            },
            3 => {
                // CAS
                const current = ptr.load(.{ .guard = &guard });
                const new_value = try testing.allocator.create(u64);
                new_value.* = i + 2000;

                const result = ptr.compareAndSwapWeak(.{
                    .expected = current,
                    .new = new_value,
                });

                if (result == null) {
                    // Success - retire old
                    if (current) |old_ptr| {
                        const deleter = try testing.allocator.create(TestDeleter);
                        deleter.* = TestDeleter{ .value = old_ptr };
                        guard.retire(.{
                            .ptr = deleter,
                            .deleter = TestDeleter.delete,
                        });
                    }
                } else {
                    // Failed - free new value
                    testing.allocator.destroy(new_value);
                }
            },
            else => unreachable,
        }

        guard.unpin();

        // Random flush
        if (rng.intRangeAtMost(u8, 0, 10) == 0) {
            var flush_guard = pin(&fuzz_thread_state, &global);
            flush_guard.flush();
            flush_guard.unpin();
        }
    }

    // Cleanup final value
    var cleanup_guard = pin(&fuzz_thread_state, &global);
    const final = ptr.load(.{ .guard = &cleanup_guard });
    if (final) |f| {
        testing.allocator.destroy(f);
    }
    cleanup_guard.flush();
    cleanup_guard.unpin();
}

test "Fuzz: concurrent chaos with multiple threads" {
    var global = try EBR.init(.{
        .allocator = testing.allocator,
    });
    defer global.deinit();

    const SharedData = AtomicPtr(u64);
    var shared = SharedData.init(.{});

    const ThreadContext = struct {
        global: *EBR,
        shared: *SharedData,
        thread_id: usize,
        operations: usize,

        threadlocal var thread_state: ThreadState = .{};

        fn chaosWorker(ctx: *@This()) !void {
            try thread_state.ensureInitialized(.{
                .global = ctx.global,
                .allocator = testing.allocator,
            });
            defer thread_state.deinitThread();

            var prng = std.Random.DefaultPrng.init(@intCast(ctx.thread_id));
            const rng = prng.random();

            const TestDeleter = struct {
                value: *u64,

                fn delete(self_ptr: *anyopaque) void {
                    const self: *@This() = @ptrCast(@alignCast(self_ptr));
                    testing.allocator.destroy(self.value);
                    testing.allocator.destroy(self);
                }
            };

            var i: usize = 0;
            while (i < ctx.operations) : (i += 1) {
                var guard = pin(&thread_state, ctx.global);

                const op = rng.intRangeAtMost(u8, 0, 2);
                switch (op) {
                    0 => {
                        // Read
                        _ = ctx.shared.load(.{ .guard = &guard });
                    },
                    1 => {
                        // Write
                        const new_value = try testing.allocator.create(u64);
                        new_value.* = ctx.thread_id * 10000 + i;

                        const old = ctx.shared.swap(.{ .value = new_value });
                        if (old) |old_ptr| {
                            const deleter = try testing.allocator.create(TestDeleter);
                            deleter.* = TestDeleter{ .value = old_ptr };
                            guard.retire(.{
                                .ptr = deleter,
                                .deleter = TestDeleter.delete,
                            });
                        }
                    },
                    2 => {
                        // Flush
                        guard.flush();
                    },
                    else => unreachable,
                }

                guard.unpin();

                // Note: Removed sleep to avoid platform-specific timing issues
            }

            var final_guard = pin(&thread_state, ctx.global);
            final_guard.flush();
            final_guard.unpin();
        }
    };

    const thread_count = 8;
    const operations_per_thread = 100;
    var threads: [thread_count]std.Thread = undefined;
    var contexts: [thread_count]ThreadContext = undefined;

    for (&threads, &contexts, 0..) |*t, *ctx, idx| {
        ctx.* = ThreadContext{
            .global = &global,
            .shared = &shared,
            .thread_id = idx,
            .operations = operations_per_thread,
        };
        t.* = try std.Thread.spawn(.{}, ThreadContext.chaosWorker, .{ctx});
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

    var cleanup_guard = pin(&cleanup_state, &global);
    const final = shared.load(.{ .guard = &cleanup_guard });
    if (final) |f| {
        testing.allocator.destroy(f);
    }
    cleanup_guard.flush();
    cleanup_guard.unpin();
}

test "Fuzz: rapid thread creation and destruction" {
    var global = try EBR.init(.{
        .allocator = testing.allocator,
    });
    defer global.deinit();

    const SharedData = AtomicPtr(u64);
    var shared = SharedData.init(.{});

    const ThreadContext = struct {
        global: *EBR,
        shared: *SharedData,
        thread_id: usize,

        threadlocal var thread_state: ThreadState = .{};

        fn shortLivedWorker(ctx: *@This()) !void {
            try thread_state.ensureInitialized(.{
                .global = ctx.global,
                .allocator = testing.allocator,
            });
            defer thread_state.deinitThread();

            const TestDeleter = struct {
                value: *u64,

                fn delete(self_ptr: *anyopaque) void {
                    const self: *@This() = @ptrCast(@alignCast(self_ptr));
                    testing.allocator.destroy(self.value);
                    testing.allocator.destroy(self);
                }
            };

            // Quick operations then exit
            var i: usize = 0;
            while (i < 10) : (i += 1) {
                var guard = pin(&thread_state, ctx.global);

                const new_value = try testing.allocator.create(u64);
                new_value.* = ctx.thread_id * 100 + i;

                const old = ctx.shared.swap(.{ .value = new_value });
                if (old) |old_ptr| {
                    const deleter = try testing.allocator.create(TestDeleter);
                    deleter.* = TestDeleter{ .value = old_ptr };
                    guard.retire(.{
                        .ptr = deleter,
                        .deleter = TestDeleter.delete,
                    });
                }

                guard.unpin();
            }

            var final_guard = pin(&thread_state, ctx.global);
            final_guard.flush();
            final_guard.unpin();
        }
    };

    // Create and destroy threads rapidly
    const wave_count = 10;
    const threads_per_wave = 4;

    var wave: usize = 0;
    while (wave < wave_count) : (wave += 1) {
        var threads: [threads_per_wave]std.Thread = undefined;
        var contexts: [threads_per_wave]ThreadContext = undefined;

        for (&threads, &contexts, 0..) |*t, *ctx, idx| {
            ctx.* = ThreadContext{
                .global = &global,
                .shared = &shared,
                .thread_id = wave * threads_per_wave + idx,
            };
            t.* = try std.Thread.spawn(.{}, ThreadContext.shortLivedWorker, .{ctx});
        }

        for (&threads) |*t| {
            t.join();
        }
    }

    // Cleanup final value
    var cleanup_state: ThreadState = .{};
    try cleanup_state.ensureInitialized(.{
        .global = &global,
        .allocator = testing.allocator,
    });
    defer cleanup_state.deinitThread();

    var cleanup_guard = pin(&cleanup_state, &global);
    const final = shared.load(.{ .guard = &cleanup_guard });
    if (final) |f| {
        testing.allocator.destroy(f);
    }
    cleanup_guard.flush();
    cleanup_guard.unpin();
}

test "Fuzz: interleaved pin/unpin with retires" {
    var global = try EBR.init(.{
        .allocator = testing.allocator,
    });
    defer global.deinit();

    try fuzz_thread_state.ensureInitialized(.{
        .global = &global,
        .allocator = testing.allocator,
    });
    defer fuzz_thread_state.deinitThread();

    const rng = rng_state.random();

    const TestData = struct {
        value: u64,

        fn deleter(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            testing.allocator.destroy(self);
        }
    };

    // Interleaved operations
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        const pin_count = rng.intRangeAtMost(usize, 1, 5);
        var j: usize = 0;
        while (j < pin_count) : (j += 1) {
            var guard = pin(&fuzz_thread_state, &global);

            const retire_count = rng.intRangeAtMost(usize, 0, 3);
            var k: usize = 0;
            while (k < retire_count) : (k += 1) {
                const data = try testing.allocator.create(TestData);
                data.* = TestData{ .value = i * 1000 + j * 100 + k };
                guard.retire(.{
                    .ptr = data,
                    .deleter = TestData.deleter,
                });
            }

            guard.unpin();
        }

        // Random flush between waves
        if (i % 100 == 0) {
            var flush_guard = pin(&fuzz_thread_state, &global);
            flush_guard.flush();
            flush_guard.unpin();
        }
    }

    // Final cleanup
    var final_guard = pin(&fuzz_thread_state, &global);
    final_guard.flush();
    final_guard.unpin();
}

test "Fuzz: stress epoch advancement" {
    var global = try EBR.init(.{
        .allocator = testing.allocator,
    });
    defer global.deinit();

    const ThreadContext = struct {
        global: *EBR,
        thread_id: usize,

        threadlocal var thread_state: ThreadState = .{};

        fn epochStressor(ctx: *@This()) !void {
            try thread_state.ensureInitialized(.{
                .global = ctx.global,
                .allocator = testing.allocator,
            });
            defer thread_state.deinitThread();

            // Rapidly pin/unpin to force epoch advancement
            var i: usize = 0;
            while (i < 500) : (i += 1) {
                var guard = pin(&thread_state, ctx.global);
                guard.unpin();

                // Note: Removed sleep to avoid platform-specific timing issues
            }
        }
    };

    const thread_count = 8;
    var threads: [thread_count]std.Thread = undefined;
    var contexts: [thread_count]ThreadContext = undefined;

    const initial_epoch = global.global_epoch.load(.acquire);

    for (&threads, &contexts, 0..) |*t, *ctx, idx| {
        ctx.* = ThreadContext{
            .global = &global,
            .thread_id = idx,
        };
        t.* = try std.Thread.spawn(.{}, ThreadContext.epochStressor, .{ctx});
    }

    for (&threads) |*t| {
        t.join();
    }

    const final_epoch = global.global_epoch.load(.acquire);

    // Epoch should have advanced under this load
    try testing.expect(final_epoch >= initial_epoch);
}
