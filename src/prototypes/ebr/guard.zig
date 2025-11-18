// FILE: guard.zig
//! Guard for RAII-style epoch protection
//!
//! A Guard represents a pin operation. While the guard is alive,
//! the thread is pinned to an epoch and can safely access shared data.

const std = @import("std");
const ThreadState = @import("thread_state.zig").ThreadState;
const RetiredNode = @import("retired_list.zig").RetiredNode;
const EBR = @import("ebr.zig").EBR;

/// Guard for pinned epoch access
///
/// IMPORTANT: In Zig, you must manually call unpin() using defer.
/// There is no automatic destructor.
///
/// Example:
/// ```zig
/// var guard = pin(&thread_state, global);
/// defer guard.unpin();
/// // Safe to access shared data here
/// ```
pub const Guard = struct {
    thread_state: *ThreadState,
    global: *EBR,

    /// Unpin from epoch and trigger garbage collection
    pub fn unpin(self: *Guard) void {
        self.thread_state.unpin(.{ .global = self.global });
    }

    /// Retire a pointer for later reclamation
    pub fn retire(self: *Guard, opts: struct {
        ptr: *anyopaque,
        deleter: *const fn (*anyopaque) void,
    }) void {
        const current_epoch = self.global.global_epoch.load(.acquire);

        self.thread_state.addRetired(.{
            .node = .{
                .ptr = opts.ptr,
                .deleter = opts.deleter,
                .epoch = current_epoch,
            },
        });
    }

    /// Flush all retired objects (force garbage collection)
    pub fn flush(self: *Guard) void {
        self.thread_state.tryCollectGarbage(.{ .global = self.global });
    }
};

/// Pin current thread to current epoch
///
/// This must be called on a threadlocal ThreadState variable.
///
/// Example:
/// ```zig
/// threadlocal var thread_state: ThreadState = .{};
///
/// pub fn someFunction(global: *EBR, allocator: Allocator) !void {
///     try thread_state.ensureInitialized(.{ .global = global, .allocator = allocator });
///
///     var guard = pin(&thread_state, global);
///     defer guard.unpin();
///     // ... use guard ...
/// }
/// ```
pub fn pin(thread_state: *ThreadState, global: *EBR) Guard {
    thread_state.pin(.{ .global = global });
    return Guard{
        .thread_state = thread_state,
        .global = global,
    };
}
