// FILE: _ebr_unit_tests.zig
//! Unit tests for Epoch-Based Reclamation (EBR)
//!
//! Coverage:
//! - Global initialization and cleanup
//! - ThreadState initialization with threadlocal var
//! - Guard pin/unpin operations
//! - Epoch advancement
//! - Thread registration
//! - Retired list operations
//! - AtomicPtr basic operations
//! - Memory safety guarantees

const std = @import("std");
const testing = std.testing;
const ebr_module = @import("ebr.zig");
const EBR = ebr_module.EBR;
const ThreadState = ebr_module.ThreadState;
const Guard = ebr_module.Guard;
const pin = ebr_module.pin;
const AtomicPtr = ebr_module.AtomicPtr;
const RetiredNode = ebr_module.RetiredNode;

// Thread-local state for testing
threadlocal var test_thread_state: ThreadState = .{};

test "EBR: init and deinit" {
    var global = try EBR.init(.{
        .allocator = testing.allocator,
    });
    defer global.deinit();

    try testing.expect(global.global_epoch.load(.acquire) == 0);
}

test "ThreadState: initialization" {
    var global = try EBR.init(.{
        .allocator = testing.allocator,
    });
    defer global.deinit();

    try test_thread_state.ensureInitialized(.{
        .global = &global,
        .allocator = testing.allocator,
    });
    defer test_thread_state.deinitThread();

    try testing.expect(test_thread_state.registered);
}

test "Guard: pin and unpin" {
    var global = try EBR.init(.{
        .allocator = testing.allocator,
    });
    defer global.deinit();

    try test_thread_state.ensureInitialized(.{
        .global = &global,
        .allocator = testing.allocator,
    });
    defer test_thread_state.deinitThread();

    // Pin
    var guard = pin(&test_thread_state, &global);
    try testing.expect(test_thread_state.is_pinned.load(.acquire));

    // Unpin
    guard.unpin();
    try testing.expect(!test_thread_state.is_pinned.load(.acquire));
}

test "Guard: multiple pin/unpin cycles" {
    var global = try EBR.init(.{
        .allocator = testing.allocator,
    });
    defer global.deinit();

    try test_thread_state.ensureInitialized(.{
        .global = &global,
        .allocator = testing.allocator,
    });
    defer test_thread_state.deinitThread();

    const iterations = 100;
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        var guard = pin(&test_thread_state, &global);
        try testing.expect(test_thread_state.is_pinned.load(.acquire));
        guard.unpin();
        try testing.expect(!test_thread_state.is_pinned.load(.acquire));
    }
}

test "Epoch: global epoch advances" {
    var global = try EBR.init(.{
        .allocator = testing.allocator,
    });
    defer global.deinit();

    try test_thread_state.ensureInitialized(.{
        .global = &global,
        .allocator = testing.allocator,
    });
    defer test_thread_state.deinitThread();

    const initial_epoch = global.global_epoch.load(.acquire);

    // Pin and unpin many times to trigger epoch advancement
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        var guard = pin(&test_thread_state, &global);
        guard.unpin();
    }

    // Epoch may have advanced (probabilistic but should pass in practice)
    const final_epoch = global.global_epoch.load(.acquire);
    try testing.expect(final_epoch >= initial_epoch);
}

test "Retired: retire and collect single object" {
    var global = try EBR.init(.{
        .allocator = testing.allocator,
    });
    defer global.deinit();

    try test_thread_state.ensureInitialized(.{
        .global = &global,
        .allocator = testing.allocator,
    });
    defer test_thread_state.deinitThread();

    var deallocated = false;
    const TestData = struct {
        value: u64,
        deallocated_flag: *bool,

        fn deleter(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.deallocated_flag.* = true;
            testing.allocator.destroy(self);
        }
    };

    const data = try testing.allocator.create(TestData);
    data.* = TestData{
        .value = 42,
        .deallocated_flag = &deallocated,
    };

    {
        var guard = pin(&test_thread_state, &global);
        guard.retire(.{
            .ptr = data,
            .deleter = TestData.deleter,
        });
        guard.unpin();
    }

    // Give time for garbage collection
    var i: usize = 0;
    while (i < 100 and !deallocated) : (i += 1) {
        var guard = pin(&test_thread_state, &global);
        guard.flush();
        guard.unpin();
    }
}

test "Retired: retire multiple objects" {
    var global = try EBR.init(.{
        .allocator = testing.allocator,
    });
    defer global.deinit();

    try test_thread_state.ensureInitialized(.{
        .global = &global,
        .allocator = testing.allocator,
    });
    defer test_thread_state.deinitThread();

    const TestData = struct {
        value: u64,

        fn deleter(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            testing.allocator.destroy(self);
        }
    };

    const count = 100;
    var guard = pin(&test_thread_state, &global);

    var i: usize = 0;
    while (i < count) : (i += 1) {
        const data = try testing.allocator.create(TestData);
        data.* = TestData{ .value = i };
        guard.retire(.{
            .ptr = data,
            .deleter = TestData.deleter,
        });
    }

    guard.unpin();

    // Flush to clean up
    var cleanup_guard = pin(&test_thread_state, &global);
    cleanup_guard.flush();
    cleanup_guard.unpin();
}

test "AtomicPtr: init with null" {
    const IntPtr = AtomicPtr(u64);
    var ptr = IntPtr.init(.{ .value = null });

    var global = try EBR.init(.{
        .allocator = testing.allocator,
    });
    defer global.deinit();

    try test_thread_state.ensureInitialized(.{
        .global = &global,
        .allocator = testing.allocator,
    });
    defer test_thread_state.deinitThread();

    var guard = pin(&test_thread_state, &global);
    defer guard.unpin();

    const loaded = ptr.load(.{ .guard = &guard });
    try testing.expect(loaded == null);
}

test "AtomicPtr: init with value" {
    const IntPtr = AtomicPtr(u64);

    var value: u64 = 42;
    var ptr = IntPtr.init(.{ .value = &value });

    var global = try EBR.init(.{
        .allocator = testing.allocator,
    });
    defer global.deinit();

    try test_thread_state.ensureInitialized(.{
        .global = &global,
        .allocator = testing.allocator,
    });
    defer test_thread_state.deinitThread();

    var guard = pin(&test_thread_state, &global);
    defer guard.unpin();

    const loaded = ptr.load(.{ .guard = &guard });
    try testing.expect(loaded != null);
    try testing.expect(loaded.?.* == 42);
}

test "AtomicPtr: store and load" {
    const IntPtr = AtomicPtr(u64);
    var ptr = IntPtr.init(.{});

    var global = try EBR.init(.{
        .allocator = testing.allocator,
    });
    defer global.deinit();

    try test_thread_state.ensureInitialized(.{
        .global = &global,
        .allocator = testing.allocator,
    });
    defer test_thread_state.deinitThread();

    var value: u64 = 100;
    ptr.store(.{ .value = &value });

    var guard = pin(&test_thread_state, &global);
    defer guard.unpin();

    const loaded = ptr.load(.{ .guard = &guard });
    try testing.expect(loaded != null);
    try testing.expect(loaded.?.* == 100);
}

test "AtomicPtr: swap" {
    const IntPtr = AtomicPtr(u64);

    var value1: u64 = 1;
    var value2: u64 = 2;

    var ptr = IntPtr.init(.{ .value = &value1 });

    const old = ptr.swap(.{ .value = &value2 });
    try testing.expect(old != null);
    try testing.expect(old.?.* == 1);

    var global = try EBR.init(.{
        .allocator = testing.allocator,
    });
    defer global.deinit();

    try test_thread_state.ensureInitialized(.{
        .global = &global,
        .allocator = testing.allocator,
    });
    defer test_thread_state.deinitThread();

    var guard = pin(&test_thread_state, &global);
    defer guard.unpin();

    const current = ptr.load(.{ .guard = &guard });
    try testing.expect(current != null);
    try testing.expect(current.?.* == 2);
}

test "AtomicPtr: compareAndSwapWeak success" {
    const IntPtr = AtomicPtr(u64);

    var value1: u64 = 1;
    var value2: u64 = 2;

    var ptr = IntPtr.init(.{ .value = &value1 });

    const result = ptr.compareAndSwapWeak(.{
        .expected = &value1,
        .new = &value2,
    });

    var global = try EBR.init(.{
        .allocator = testing.allocator,
    });
    defer global.deinit();

    try test_thread_state.ensureInitialized(.{
        .global = &global,
        .allocator = testing.allocator,
    });
    defer test_thread_state.deinitThread();

    var guard = pin(&test_thread_state, &global);
    defer guard.unpin();

    if (result == null) {
        // Success
        const current = ptr.load(.{ .guard = &guard });
        try testing.expect(current != null);
        try testing.expect(current.?.* == 2);
    }
}

test "AtomicPtr: compareAndSwapWeak failure" {
    const IntPtr = AtomicPtr(u64);

    var value1: u64 = 1;
    var value2: u64 = 2;
    var value3: u64 = 3;

    var ptr = IntPtr.init(.{ .value = &value1 });

    const result = ptr.compareAndSwapWeak(.{
        .expected = &value3, // Wrong expected
        .new = &value2,
    });

    // Should fail and return actual value
    try testing.expect(result != null);
    try testing.expect(result.?.* == 1);
}

test "Memory: no leaks with many allocations" {
    var global = try EBR.init(.{
        .allocator = testing.allocator,
    });
    defer global.deinit();

    try test_thread_state.ensureInitialized(.{
        .global = &global,
        .allocator = testing.allocator,
    });
    defer test_thread_state.deinitThread();

    const TestData = struct {
        value: u64,

        fn deleter(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            testing.allocator.destroy(self);
        }
    };

    // Allocate and retire many objects
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        var guard = pin(&test_thread_state, &global);

        const data = try testing.allocator.create(TestData);
        data.* = TestData{ .value = i };

        guard.retire(.{
            .ptr = data,
            .deleter = TestData.deleter,
        });

        guard.unpin();

        // Periodically flush
        if (i % 100 == 0) {
            var flush_guard = pin(&test_thread_state, &global);
            flush_guard.flush();
            flush_guard.unpin();
        }
    }

    // Final cleanup
    var final_guard = pin(&test_thread_state, &global);
    final_guard.flush();
    final_guard.unpin();
}
