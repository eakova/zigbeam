// FILE: ebr.zig
//! Epoch-Based Reclamation (EBR) - Main implementation
//!
//! A production-ready, lock-free memory reclamation scheme following crossbeam-epoch semantics.
//!
//! ## Overview
//!
//! Epoch-Based Reclamation enables safe memory reclamation in lock-free data structures.
//! Instead of immediately freeing memory, objects are retired and freed only when it's
//! provably safe (no thread can possibly hold a reference).
//!
//! ## How It Works
//!
//! 1. **Global Epoch**: A monotonically increasing counter shared by all threads
//! 2. **Pin**: Threads announce they're accessing shared data by pinning to current epoch
//! 3. **Retire**: Memory is marked for deletion but tagged with current epoch
//! 4. **Garbage Collection**: Memory freed when all threads have moved past retirement epoch
//!
//! ## Architecture
//!
//! - **Global**: Global state with epoch counter and thread registry
//! - **ThreadState**: Per-thread state (use as `threadlocal var`)
//! - **Guard**: RAII-style protection for pinned access
//! - **AtomicPtr**: Lock-free atomic pointer wrapper
//! - **RetiredList**: Per-thread list of retired objects
//!
//! ## Thread Safety
//!
//! - Lock-free: No mutexes in critical paths
//! - Cache-efficient: 64-byte aligned structures prevent false sharing
//! - Per-thread retired lists: No contention on retirement
//! - Safe reclamation: Guaranteed no use-after-free
//!
//! ## Performance
//!
//! - Pin/Unpin: O(1) - thread-local operation
//! - Retire: O(1) - append to thread-local list
//! - GC: O(threads + retired_objects)
//! - Epoch advancement: Infrequent (every 256 unpins)
//!
//! ## Usage Example
//!
//! ```zig
//! const ebr = @import("epoch-based-reclamation");
//! const EBR = ebr.EpochBasedReclamation;
//!
//! // Global state (one per application)
//! var global = try EBR.Global.init(.{ .allocator = allocator });
//! defer global.deinit();
//!
//! // Thread-local state (one per thread, as threadlocal var)
//! threadlocal var thread_state: EBR.ThreadState = .{};
//!
//! pub fn myFunction() !void {
//!     // Ensure thread is registered
//!     try thread_state.ensureInitialized(.{
//!         .global = &global,
//!         .allocator = allocator,
//!     });
//!
//!     // Pin to access shared data
//!     var guard = EBR.pin(&thread_state, &global);
//!     defer guard.unpin();
//!
//!     // Use atomic pointers with guard
//!     const value = atomic_ptr.load(.{ .guard = &guard });
//!
//!     // Retire old memory
//!     guard.retire(.{ .ptr = old_ptr, .deleter = myDeleter });
//! }
//! ```
//!
//! ## Memory Model
//!
//! - Global epoch: Acquire/Release ordering
//! - Thread states: Acquire/Release for synchronization
//! - AtomicPtr ops: Acquire for loads, Release for stores, Acq_Rel for RMW
//! - All structures: 64-byte cache-line aligned
//!
//! ## Differences vs Hazard Pointers
//!
//! - EBR: Lower overhead, periodic GC, global epoch coordination
//! - HP: Per-pointer protection, immediate reclamation
//! - EBR typically faster but may delay reclamation longer
//!
//! ## Differences vs RCU
//!
//! - EBR: Explicit pin/unpin, portable, deterministic
//! - RCU: Implicit grace periods, OS-dependent
//! - EBR provides more control and works anywhere
//!
//! ## Limitations
//!
//! - Manual pin/unpin required (no RAII in Zig without defer)
//! - Pinned threads can delay GC for all threads
//! - Memory usage grows with retired object count
//! - u64 epoch wraps after 2^64 advancements (not a practical concern)

const std = @import("std");
const Atomic = std.atomic.Value;
const Allocator = std.mem.Allocator;

const CACHE_LINE: usize = 64;

// Re-export component modules
pub const ThreadState = @import("thread_state.zig").ThreadState;
pub const Guard = @import("guard.zig").Guard;
pub const pin = @import("guard.zig").pin;
pub const AtomicPtr = @import("atomic_ptr.zig").AtomicPtr;
pub const RetiredNode = @import("retired_list.zig").RetiredNode;
pub const RetiredList = @import("retired_list.zig").RetiredList;

// ============================================================================
// Global EBR State - Core Implementation
// ============================================================================

/// Global EBR state - shared across all threads
pub const EBR = struct {
    /// Global epoch counter (cache-line aligned)
    global_epoch: Atomic(u64) align(CACHE_LINE),

    /// Thread registry for GC coordination
    registry: Registry,

    /// Allocator for internal structures
    allocator: Allocator,

    /// Initialize global EBR state
    pub fn init(opts: struct {
        allocator: Allocator,
    }) !EBR {
        return EBR{
            .global_epoch = Atomic(u64).init(0),
            .registry = Registry.init(.{ .allocator = opts.allocator }),
            .allocator = opts.allocator,
        };
    }

    /// Clean up global state
    pub fn deinit(self: *EBR) void {
        self.registry.deinit();
    }

    /// Try to advance the global epoch
    pub fn tryAdvanceEpoch(self: *EBR) void {
        const current = self.global_epoch.load(.acquire);

        // Check if all threads have caught up
        if (self.registry.canAdvanceEpoch(current)) {
            // Try to advance (may fail due to race, that's ok)
            _ = self.global_epoch.cmpxchgWeak(
                current,
                current +% 1,
                .release,
                .acquire,
            );
        }
    }

    /// Get minimum epoch across all pinned threads (for GC)
    pub fn getMinimumEpoch(self: *EBR) u64 {
        return self.registry.getMinimumEpoch();
    }
};

/// Thread registry - lock-free intrusive linked list of thread states
///
/// Each ThreadState has a `next` pointer forming an intrusive singly-linked list.
/// Threads register by atomically pushing themselves to the head of the list.
const Registry = struct {
    /// Atomic head pointer of the intrusive list (lock-free)
    head: Atomic(?*ThreadState) align(CACHE_LINE),

    allocator: Allocator,

    fn init(opts: struct {
        allocator: Allocator,
    }) Registry {
        return Registry{
            .head = Atomic(?*ThreadState).init(null),
            .allocator = opts.allocator,
        };
    }

    fn deinit(self: *Registry) void {
        // No cleanup needed - thread states are owned by threads, not registry
        _ = self;
    }

    /// Register a thread's state (lock-free atomic push to head)
    pub fn registerThread(self: *Registry, state: *ThreadState) void {
        // Atomic push to head of intrusive list
        var current_head = self.head.load(.acquire);
        while (true) {
            // Set our next pointer to current head
            state.next.store(current_head, .release);

            // Try to CAS the head to point to us
            if (self.head.cmpxchgWeak(
                current_head,
                state,
                .release,
                .acquire,
            )) |actual| {
                // CAS failed, retry with actual value
                current_head = actual;
            } else {
                // Success! We're now in the list
                break;
            }
        }
    }

    /// Check if epoch can advance (lock-free traversal)
    fn canAdvanceEpoch(self: *Registry, current_epoch: u64) bool {
        // Lock-free traversal of intrusive list
        var node = self.head.load(.acquire);

        while (node) |state| {
            if (state.is_pinned.load(.acquire)) {
                const local = state.local_epoch.load(.acquire);
                if (local < current_epoch) {
                    return false;
                }
            }
            // Move to next node in list
            node = state.next.load(.acquire);
        }

        return true;
    }

    /// Get minimum epoch across pinned threads (lock-free traversal)
    fn getMinimumEpoch(self: *Registry) u64 {
        var min_epoch: u64 = std.math.maxInt(u64);
        var found_pinned = false;

        // Lock-free traversal of intrusive list
        var node = self.head.load(.acquire);

        while (node) |state| {
            if (state.is_pinned.load(.acquire)) {
                const local = state.local_epoch.load(.acquire);
                if (local < min_epoch) {
                    min_epoch = local;
                    found_pinned = true;
                }
            }
            // Move to next node in list
            node = state.next.load(.acquire);
        }

        return if (found_pinned) min_epoch else std.math.maxInt(u64);
    }
};

// Run tests
test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(EBR);
}
