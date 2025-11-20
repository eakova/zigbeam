
### **Implementation Plan: Phase 3 - A Segmented MPMC Queue**

**Objective:** To implement an unbounded, lock-free MPMC queue by creating a concurrent linked list of bounded `DVyukovMPMCQueue` instances. This phase intentionally omits safe memory reclamation for emptied segments to focus solely on the unbounded growth and traversal logic.

---

### **Part 1: Data Structures**

1.  **`Segment<T>` Struct:** A node in the concurrent linked list.
    ```pseudocode
    struct Segment<T> {
        // A fully functional, bounded MPMC queue. This is the component
        // from Phase 2. Its capacity defines the segment size.
        queue: DVyukovMPMCQueue<T>,

        // Atomic pointer to the next segment. `null` if it's the last one.
        next: Atomic<pointer<Segment<T>>>,
    }
    ```

2.  **`SegQueue<T>` Struct:** The main queue controller.
    ```pseudocode
    struct SegQueue<T> {
        // Points to the segment from which consumers dequeue.
        head_segment: Atomic<pointer<Segment<T>>> align(cache_line),

        _padding1: Array<u8, cache_line_size>,

        // Points to the segment to which producers enqueue.
        tail_segment: Atomic<pointer<Segment<T>>> align(cache_line),

        // The fixed capacity for each new segment.
        segment_capacity: usize,

        allocator: Allocator,
    }
    ```

---

### **Part 2: Lifecycle**

1.  **`init(allocator, segment_capacity)` -> `!*SegQueue<T>`:**
    *   **Action:**
        1.  Allocate a new `Segment<T>`. Use `errdefer` for cleanup.
        2.  Call `DVyukovMPMCQueue.init(allocator, segment_capacity)` to initialize the `queue` field within the new `Segment`.
        3.  Initialize the `next` field of the `Segment` to `null`.
        4.  Allocate the main `SegQueue<T>` struct.
        5.  Initialize its `head_segment` and `tail_segment` atomic pointers to point to the newly created segment.
        6.  Store `segment_capacity` and `allocator`.
    *   **Returns:** A pointer to the initialized `SegQueue`.

2.  **`deinit(queue: *SegQueue<T>)`:**
    *   **Note:** This version is not thread-safe and is for this phase only.
    *   **Action:**
        1.  Load the initial `head_segment`.
        2.  Loop through the linked list via the `next` pointers.
        3.  In each iteration:
            a. Get a handle to the next segment before destroying the current one.
            b. Call `deinit()` on the `queue` field of the current segment.
            c. Free the current `Segment` struct.
        4.  Finally, free the `SegQueue` struct itself.

---

### **Part 3: Core Algorithms**

1.  **`enqueue(queue: *SegQueue<T>, item: T) -> !void`:**
    *   **Action:**
        1.  Start a `while (true)` loop for retries.
        2.  Load the current tail segment: `tail_seg = queue.tail_segment.load(acquire)`.
        3.  Attempt to enqueue to this segment: `result = tail_seg.queue.enqueue(item)`.
        4.  **If `result` is SUCCESS:** `return`. The operation is complete.
        5.  **If `result` is `error.Full`:** The segment is full. We must grow the list.
            a. Check if another thread has already linked a new segment: `next_seg = tail_seg.next.load(acquire)`.
            b. **If `next_seg != null`:** Another thread won the race to grow.
                i. We must help update the global `tail_segment` pointer to point to this new segment. Attempt `queue.tail_segment.cmpxchg(tail_seg, next_seg, release, relaxed)`.
                ii. `continue` the `while` loop to retry the whole `enqueue` operation.
            c. **If `next_seg == null`:** We must attempt to grow the list ourselves.
                i. Allocate and `init` a `new_segment`. If allocation fails, return the error.
                ii. Atomically link the new segment: `cas_success = tail_seg.next.cmpxchg(null, new_segment, release, relaxed)`.
                iii. **If `cas_success`:** We won the race. We are responsible for swinging the global `tail_segment` pointer forward: `queue.tail_segment.cmpxchg(tail_seg, new_segment, release, relaxed)`. `continue` the `while` loop to retry the original `enqueue`.
                iv. **If `!cas_success`:** We lost the race. Another thread linked a segment while we were allocating ours. We must `deinit` and `destroy` our `new_segment` to prevent a memory leak, then `continue` the `while` loop.

2.  **`dequeue(queue: *SegQueue<T>) -> ?T`:**
    *   **Action:**
        1.  Start a `while (true)` loop for retries.
        2.  Load the current head segment: `head_seg = queue.head_segment.load(acquire)`.
        3.  Attempt to dequeue from this segment: `result = head_seg.queue.dequeue()`.
        4.  **If `result` is an `item`:** `return item`. The operation is complete.
        5.  **If `result` is `null`:** The current head segment is empty.
            a. Check if there is a next segment: `next_seg = head_seg.next.load(acquire)`.
            b. **If `next_seg == null`:** The entire queue is empty. `return null`.
            c. **If `next_seg != null`:** The current segment is empty, but more segments exist. We must try to advance the global `head_segment` pointer.
                i. Atomically advance the pointer: `cas_success = queue.head_segment.cmpxchg(head_seg, next_seg, release, relaxed)`.
                ii. **If `cas_success`:** We have successfully unlinked the old `head_seg`. **This is the memory leak point for this phase.** `continue` the `while` loop to try dequeueing from the new head segment.
                iii. **If `!cas_success`:** Another consumer already advanced the pointer. `continue` the `while` loop.

---

### **Part 4: Verification Strategy**

1.  **Single-Segment Correctness:** Run existing MPMC stress tests with a number of items less than `segment_capacity` to verify the new indirection logic.
2.  **Growth and Traversal Test:** Run a 4P/4C stress test with a small `segment_capacity` (e.g., 64) and a large number of items (e.g., 10,000) to force frequent segment creation and traversal. Verify that all enqueued items are eventually dequeued correctly.
3.  **Memory Leak Confirmation:** Use a memory profiler during the Growth and Traversal Test to observe that memory usage increases and does not decrease as segments are consumed. This validates our understanding of the current design's limitation and sets the stage for Phase 4.