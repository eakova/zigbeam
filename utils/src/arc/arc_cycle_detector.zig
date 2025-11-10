// FILE: cycle_detector.zig
//! A heavyweight, but correct, debugging tool for finding reference cycles in `Arc<T>`.
//!
//! This utility implements a "mark-and-sweep" garbage collection algorithm to
//! identify groups of `Arc`s that reference each other but are no longer reachable
//! from the main program ("leaked islands").
//!
//! USAGE:
//! 1. Create a `trace` function that knows how to find `Arc`s inside your `T`.
//! 2. Initialize the detector with an allocator and your trace function.
//! 3. `track()` every `Arc` you create that might be part of a cycle.
//! 4. Periodically call `detectCycles()` to get a list of leaked `Arc`s.
//!
//! WARNING:
//! - This is a DEBUGGING tool. Its `detectCycles` method is slow (O(N+M) where N is
//!   objects and M is references) and should NOT be called in performance-critical code.
//! - It requires you to correctly implement a `trace` function. An incorrect
//!   trace function will lead to incorrect results.

const std = @import("std");
const Allocator = std.mem.Allocator;

// Assuming `arc.zig` is in the same directory.
const Arc = @import("arc.zig").Arc;

/// A mark-and-sweep cycle detector for `Arc<T>`.
pub fn ArcCycleDetector(comptime T: type) type {
    const InnerType = Arc(T).Inner;
    const ArcPtr = *InnerType;

    return struct {
        const Self = @This();

        /// A function that can traverse the fields of `T` and report any `Arc<T>`
        /// it contains by appending their inner pointers to the `children` list.
        pub const TraceFn = *const fn (
            user_context: *anyopaque,
            data: *const T,
            children: *std.ArrayList(ArcPtr),
        ) void;

        allocator: Allocator,
        /// A list of all `Arc::Inner` pointers currently being tracked by the detector.
        tracked_arcs: std.ArrayList(ArcPtr),
        /// The user-provided function for traversing the object graph.
        trace_fn: TraceFn,
        /// An optional context pointer to pass to the trace function.
        trace_context: *anyopaque,

        /// Initializes a new `CycleDetector`.
        /// - `allocator`: Used for the detector's internal data structures.
        /// - `trace_fn`: The crucial user-provided function to traverse `T`.
        /// - `trace_context`: An optional context pointer for `trace_fn`.
        pub fn init(allocator: Allocator, trace_fn: TraceFn, trace_context: *anyopaque) Self {
            return .{
                .allocator = allocator,
                .tracked_arcs = std.ArrayList(ArcPtr).init(allocator),
                .trace_fn = trace_fn,
                .trace_context = trace_context,
            };
        }

        /// Deinitializes the detector, freeing its internal lists.
        pub fn deinit(self: *Self) void {
            self.tracked_arcs.deinit();
        }

        /// Registers a new `Arc` to be tracked by the detector.
        /// Inline (SVO) `Arc`s cannot be part of a heap-based cycle and are ignored.
        pub fn track(self: *Self, arc: Arc(T)) !void {
            if (arc.isInline()) {
                return; // Inline values cannot form heap cycles.
            }
            // Avoid adding duplicates. A HashMap would be more efficient for this
            // check, but an ArrayList is simpler for this debug tool.
            for (self.tracked_arcs.items) |tracked| {
                if (tracked == arc.asPtr()) return;
            }
            try self.tracked_arcs.append(arc.asPtr());
        }

        /// Runs the mark-and-sweep algorithm to find and return a list of `Arc`s
        /// that are part of unreachable reference cycles.
        pub fn detectCycles(self: *Self) !std.ArrayList(Arc(T)) {
            // First, remove any arcs that have already been deallocated naturally.
            self.pruneDeadArcs();

            // The set of all objects that are reachable from the program's "roots".
            var reachable = std.HashMap(ArcPtr, void, std.hash_map.PointerContext(ArcPtr), 80).init(self.allocator);
            defer reachable.deinit();

            // The list of objects to visit.
            var worklist = std.ArrayList(ArcPtr).init(self.allocator);
            defer worklist.deinit();

            // --- STEP 1: FIND ROOTS ---
            // A "root" is an object that is reachable from outside the graph of tracked objects.
            // Our heuristic: if an object has more strong references than weak ones,
            // it's likely held by an external `Arc` that is not part of an internal cycle.
            for (self.tracked_arcs.items) |arc_ptr| {
                const strong = arc_ptr.counters.strong_count.load(.monotonic);
                // The weak count includes one implicit reference for the strong count itself.
                const weak = arc_ptr.counters.weak_count.load(.monotonic);

                // This is a heuristic. A more robust system would require manual root registration.
                if (strong > weak) {
                    try worklist.append(arc_ptr);
                }
            }

            // --- STEP 2: MARK PHASE ---
            // Traverse the graph starting from the roots.
            while (worklist.popOrNull()) |*arc_ptr| {
                if (reachable.contains(arc_ptr)) {
                    continue; // Already visited.
                }
                try reachable.put(arc_ptr, {});

                // Use the user's trace function to find all children Arcs.
                var children = std.ArrayList(ArcPtr).init(self.allocator);
                defer children.deinit();
                self.trace_fn(self.trace_context, &arc_ptr.data, &children);

                // Add the children to the worklist to be visited.
                for (children.items) |child_ptr| {
                    try worklist.append(child_ptr);
                }
            }

            // --- STEP 3: SWEEP PHASE ---
            // Find any tracked object that was not marked as reachable.
            var cycles = std.ArrayList(Arc(T)).init(self.allocator);
            errdefer cycles.deinit();

            for (self.tracked_arcs.items) |arc_ptr| {
                // An object is part of a leaked cycle if:
                // 1. It was not reachable from any root.
                // 2. Its strong count is still greater than zero (kept alive by the cycle).
                if (!reachable.contains(arc_ptr) and arc_ptr.counters.strong_count.load(.monotonic) > 0) {
                    // We clone the Arc to return it to the user. This is safe because
                    // the cycle is keeping it alive.
                    const arc_clone = Arc(T).clone(&.{ .storage = .{ .tagged_ptr = try Arc(T).SvoPtr.new(arc_ptr, Arc(T).TAG_POINTER) } });
                    try cycles.append(arc_clone);
                }
            }

            return cycles;
        }

        /// Internal helper to remove pointers to deallocated `Inner` blocks from the tracking list.
        fn pruneDeadArcs(self: *Self) void {
            var i: usize = 0;
            while (i < self.tracked_arcs.items.len) {
                // An `Inner` block is dead if its strong count is 0 AND its weak count is 0.
                // A weak count of 0 is a strong indicator that the block is truly gone,
                // as `Arc::release` only destroys the block when weak count is 0.
                const inner = self.tracked_arcs.items[i];
                if (inner.counters.strong_count.load(.monotonic) == 0 and inner.counters.weak_count.load(.monotonic) == 0) {
                    _ = self.tracked_arcs.swapRemove(i);
                } else {
                    i += 1;
                }
            }
        }
    };
}
