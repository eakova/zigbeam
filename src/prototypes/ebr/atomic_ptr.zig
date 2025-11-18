// FILE: atomic_ptr.zig
//! Lock-free atomic pointer wrapper with EBR integration
//!
//! AtomicPtr provides safe atomic operations on pointers when used with Guards.

const std = @import("std");
const Atomic = std.atomic.Value;
const Guard = @import("guard.zig").Guard;

/// Lock-free atomic pointer wrapper
///
/// All pointer accesses must be protected by a Guard to ensure safety.
pub fn AtomicPtr(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Internal atomic pointer storage
        ptr: Atomic(?*T),

        /// Initialize with a value
        pub fn init(opts: struct {
            value: ?*T = null,
        }) Self {
            return Self{
                .ptr = Atomic(?*T).init(opts.value),
            };
        }

        /// Load pointer with guard protection
        ///
        /// The guard ensures the pointer remains valid during access.
        pub fn load(self: *const Self, opts: struct {
            guard: *const Guard,
        }) ?*T {
            _ = opts.guard; // Guard ensures we're in a protected epoch
            return self.ptr.load(.acquire);
        }

        /// Store pointer
        ///
        /// No guard required for store-only operations.
        pub fn store(self: *Self, opts: struct {
            value: ?*T,
        }) void {
            self.ptr.store(opts.value, .release);
        }

        /// Swap pointer atomically
        ///
        /// Returns the old value. The old value should be retired using guard.retire().
        pub fn swap(self: *Self, opts: struct {
            value: ?*T,
        }) ?*T {
            return self.ptr.swap(opts.value, .acq_rel);
        }

        /// Compare-and-swap (weak version)
        ///
        /// Returns null on success, or the actual current value on failure.
        pub fn compareAndSwapWeak(self: *Self, opts: struct {
            expected: ?*T,
            new: ?*T,
        }) ?*T {
            if (self.ptr.cmpxchgWeak(
                opts.expected,
                opts.new,
                .acq_rel,
                .acquire,
            )) |actual| {
                // Failed - return actual value
                return actual;
            } else {
                // Success - return null
                return null;
            }
        }

        /// Compare-and-swap (strong version)
        ///
        /// Returns null on success, or the actual current value on failure.
        pub fn compareAndSwapStrong(self: *Self, opts: struct {
            expected: ?*T,
            new: ?*T,
        }) ?*T {
            if (self.ptr.cmpxchgStrong(
                opts.expected,
                opts.new,
                .acq_rel,
                .acquire,
            )) |actual| {
                // Failed - return actual value
                return actual;
            } else {
                // Success - return null
                return null;
            }
        }
    };
}
