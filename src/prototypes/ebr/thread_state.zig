// FILE: thread_state.zig
//! Thread-local state for EBR
//!
//! This module defines the ThreadState struct which should be used as a threadlocal var.
//! Each thread gets its own independent instance.

const std = @import("std");
const Atomic = std.atomic.Value;
const Allocator = std.mem.Allocator;
const RetiredList = @import("retired_list.zig").RetiredList;
const RetiredNode = @import("retired_list.zig").RetiredNode;
const EBR = @import("ebr.zig").EBR;

const CACHE_LINE: usize = 64;
const GC_EPOCH_THRESHOLD: u64 = 2;

/// Thread-local state for EBR
///
/// USAGE: Declare as `threadlocal var thread_state: ThreadState = .{};`
pub const ThreadState = struct {
    /// Local copy of epoch when pinned (cache-line aligned)
    local_epoch: Atomic(u64) align(CACHE_LINE) = Atomic(u64).init(0),

    /// Whether thread is currently pinned
    is_pinned: Atomic(bool) = Atomic(bool).init(false),

    /// List of retired objects awaiting reclamation
    retired_list: ?RetiredList = null,

    /// Counter for epoch advancement attempts
    advance_counter: usize = 0,

    /// Whether this thread state has been registered
    registered: bool = false,

    /// Lock-free intrusive list pointer for registry
    /// Points to the next thread state in the global registry list
    next: Atomic(?*ThreadState) = Atomic(?*ThreadState).init(null),

    /// Initialize thread state (called once per thread)
    pub fn ensureInitialized(self: *ThreadState, opts: struct {
        global: *EBR,
        allocator: Allocator,
    }) !void {
        if (self.registered) return;

        self.retired_list = RetiredList.init(.{ .allocator = opts.allocator });

        // Lock-free registration - pass entire thread state pointer
        opts.global.registry.registerThread(self);

        self.registered = true;
    }

    /// Clean up thread state (called on thread exit)
    pub fn deinitThread(self: *ThreadState) void {
        if (self.retired_list) |*list| {
            list.deinit();
            self.retired_list = null;
        }
        self.registered = false;
    }

    /// Pin to current epoch
    pub fn pin(self: *ThreadState, opts: struct {
        global: *EBR,
    }) void {
        const current_epoch = opts.global.global_epoch.load(.acquire);
        self.local_epoch.store(current_epoch, .release);
        self.is_pinned.store(true, .release);
    }

    /// Unpin from epoch
    pub fn unpin(self: *ThreadState, opts: struct {
        global: *EBR,
    }) void {
        self.is_pinned.store(false, .release);

        // Try to collect garbage
        self.tryCollectGarbage(.{ .global = opts.global });

        // Occasionally try to advance global epoch
        if (self.shouldTryAdvanceEpoch()) {
            opts.global.tryAdvanceEpoch();
        }
    }

    /// Add retired node
    pub fn addRetired(self: *ThreadState, opts: struct {
        node: RetiredNode,
    }) void {
        if (self.retired_list) |*list| {
            list.add(.{ .node = opts.node });
        }
    }

    /// Flush all retired nodes
    pub fn flushRetired(self: *ThreadState) void {
        if (self.retired_list) |*list| {
            list.flushAll();
        }
    }

    /// Try to collect garbage
    pub fn tryCollectGarbage(self: *ThreadState, opts: struct {
        global: *EBR,
    }) void {
        if (self.retired_list) |*list| {
            const min_epoch = opts.global.getMinimumEpoch();

            const safe_epoch = if (min_epoch > GC_EPOCH_THRESHOLD)
                min_epoch - GC_EPOCH_THRESHOLD
            else
                0;

            list.collectGarbage(.{ .safe_epoch = safe_epoch });
        }
    }

    /// Check if we should try to advance the epoch
    fn shouldTryAdvanceEpoch(self: *ThreadState) bool {
        self.advance_counter +%= 1;
        return (self.advance_counter & 0xFF) == 0; // Every 256 unpins
    }
};
