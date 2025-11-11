// This code is part of `arc.zig` and comes after the `Arc<T>` definition.
const Arc = @import("arc.zig").Arc;
const builtin = @import("builtin");
const std = @import("std");
const atomic = std.atomic;
/// A non-owning, weak reference to an `Arc<T>`.
///
/// An `ArcWeak` pointer allows you to hold a non-owning reference to a value
/// managed by an `Arc`. It does not prevent the `Arc`'s data from being destroyed.
/// To access the data, you must first attempt to `upgrade` the `ArcWeak`
/// pointer to an `Arc`. This will succeed only if the data has not already
/// been deallocated.
///
/// This is useful for breaking reference cycles.
pub fn ArcWeak(comptime T: type) type {
    return struct {
        // A weak pointer holds a direct pointer to the `Inner` control block.
        // It is optional because an `ArcWeak` can be "empty" (pointing to nothing).
        inner: ?*Arc(T).Inner,

        const Self = @This();

        /// Creates a new, empty `ArcWeak` pointer that doesn't point to any allocation.
        pub fn empty() Self {
            return .{ .inner = null };
        }

        /// Clones the `ArcWeak` pointer.
        ///
        /// This creates another `ArcWeak` that points to the same allocation,
        /// increasing the weak reference count. This is a fast, non-blocking operation.
        pub fn clone(self: *const Self) Self {
            if (self.inner) |inner| {
                // We perform an overflow check in non-ReleaseFast modes as a safety measure,
                // although weak reference overflows are extremely rare in practice.
                if (comptime builtin.mode != .ReleaseFast) {
                    if (inner.counters.weak_count.load(.monotonic) > std.math.maxInt(usize) / 2) {
                        @panic("ArcWeak: Weak reference count overflow");
                    }
                }
                // Incrementing the weak count is a relaxed atomic operation because
                // it doesn't need to synchronize memory with any other operation.
                _ = inner.counters.weak_count.fetchAdd(1, .monotonic);
            }
            return self.*;
        }

        /// Releases a reference to the `ArcWeak` pointer.
        ///
        /// This decrements the weak reference count. If this is the last weak reference
        /// AND there are no strong references remaining, the underlying control block
        //  (`Arc.Inner`) is deallocated.
        pub fn release(self: Self) void {
            if (self.inner) |inner| {
                // The `.release` memory ordering ensures that this decrement happens-before
                // any potential deallocation in this thread.
                const old_count = inner.counters.weak_count.fetchSub(1, .release);

                // If the weak count was 1 before our decrement, it is now 0.
                // This means we might be the very last reference of any kind.
                if (old_count == 1) {
                    // We must check the strong count to see if the data has already been
                    // destroyed. The `.acquire` ordering is CRITICAL here. It synchronizes
                    // with the `.release` decrement in `Arc.release()`, ensuring we see
                    // the final, correct value of `strong_count`. Without this, we could
                    // have a race condition leading to a memory leak.
                    if (inner.counters.strong_count.load(.acquire) == 0) {
                        // Both strong and weak counts are now zero. We are the last
                        // one out. It is our responsibility to destroy the control block.
                        Arc(T).destroyInnerBlock(inner);
                    }
                }
            }
        }

        /// Attempts to upgrade the `ArcWeak` pointer to a strong `Arc<T>`.
        ///
        /// This will return a valid `Arc<T>` if the value has not already been
        /// deallocated. If the value has been deallocated (`strong_count` is 0),
        /// this will return `null`. This operation is thread-safe.
        pub fn upgrade(self: *const Self) ?Arc(T) {
            if (self.inner) |inner| {
                // Start by reading the strong count.
                var old_count = inner.counters.strong_count.load(.monotonic);

                // Loop as long as there is at least one strong reference.
                while (old_count > 0) {
                    // Attempt to atomically increment the strong count from `old_count`
                    // to `old_count + 1`. The `cmpxchgWeak` is used because it can be
                    // faster in contended loops on some architectures.
                    if (inner.counters.strong_count.cmpxchgWeak(
                        old_count,
                        old_count + 1,
                        .acquire, // On success, we need `.acquire` to see all writes before the last `release`.
                        .monotonic, // On failure, no memory ordering is needed.
                    )) |new_old_count| {
                        // The CAS failed. This means another thread changed the count
                        // (e.g., another clone, release, or upgrade). We update our
                        // `old_count` with the new value and retry the loop.
                        old_count = new_old_count;
                        std.atomic.spinLoopHint(); // Signal the CPU we're in a spin-wait loop.
                        continue;
                    }
                    // Success! We have atomically and safely incremented the strong count.
                    const tagged = Arc(T).InnerTaggedPtr.new(inner, Arc(T).TAG_POINTER) catch unreachable;
                    return Arc(T){ .storage = .{ .ptr_with_tag = tagged.toUnsigned() } };
                }
            }
            // If we're here, either `self.inner` was null or `strong_count` was 0.
            return null;
        }

        /// Returns the number of strong references (`Arc`s) to the value.
        /// Returns 0 if the `Arc` has been deallocated.
        pub fn strongCount(self: *const Self) usize {
            if (self.inner) |inner| {
                return inner.counters.strong_count.load(.monotonic);
            }
            return 0;
        }
    };
}
