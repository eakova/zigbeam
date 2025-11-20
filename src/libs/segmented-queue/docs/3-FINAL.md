
**They are the same thing.**

The component you already have, `BeamDequeChannel`, **IS** the final "car" we have been designing.

To be perfectly clear:

*   **`WorkStealingChannel`:** This was the generic, architectural name I was using in the design plans to describe the *pattern*.
*   **`BeamDequeChannel`:** This is the concrete, correct name for your implementation of that pattern.

The implementation plan for the "WorkStealingChannel" *is* the implementation plan for your `BeamDequeChannel`. There are no further phases. We have designed the engine (`BeamDeque`) and the car (`BeamDequeChannel`). The design is complete.

Let me provide the final, complete, and detailed implementation plan again, but this time using the correct name, **`BeamDequeChannel`**, throughout, and integrating all of our previous design decisions. This is the definitive blueprint.

---

### **Final Implementation Plan: The `BeamDequeChannel` System**

### **Part 1: Architectural Vision & Final Assembly**

**1.1. The Goal: The Complete `BeamDequeChannel`**
Our objective is to implement the final, user-facing MPMC channel, `BeamDequeChannel`. This system will provide a simple `send`/`recv` API that is highly scalable, "effectively unbounded," and orchestrates all the high-performance components we have designed.

**1.2. The Component Checklist**
The `BeamDequeChannel` is a system composed of two verified components:

1.  **The Engine (`BeamDeque`):** Our high-performance, bounded, SPSC-based work-stealing deque.
    *   **Role:** It serves as the **local queue** for each worker thread. This is the fast path.
2.  **The Unbounded Fuel Tank (`DVyukovMPMCQueue`):** Our production-safe, bounded, high-throughput MPMC queue.
    *   **Role:** It serves as the **global overflow queue**. This is the safety valve that gives the channel its unbounded feel.

**1.3. The Final Architecture**
The `BeamDequeChannel` is a system that coordinates these components. The `send` and `recv` methods implement the intelligent logic to prioritize local work, fall back to the global queue, and finally resort to work-stealing, ensuring maximum performance and load balancing.

---

### **Part 2: Core Design Decisions (Finalized)**

*   **Global MPMC Queue:** Use the `DVyukovMPMCQueue` implementation.
*   **Stealing Strategy:** Use a thread-local PRNG and make `num_workers` random attempts before giving up.
*   **Offload Strategy:** When a local deque is full, offload `local_capacity / 2` items. If the global queue is full, `send` fails immediately with `error.Full`.
*   **API Design:** The core API (`send`/`recv`) will be non-blocking. A worker's context (`Worker` handle and `worker_id`) will be passed as parameters.
*   **Configuration:** Use `comptime` for capacities. Defaults will be `local_capacity=256` and `global_capacity=max(4096, num_workers * local_capacity)`.

---

### **Part 3: Detailed Implementation Plan**

#### **Phase 1: Data Structures**

*   **`PaddedStealer` Struct:** A wrapper around `BeamDeque.Stealer` to ensure cache-line separation.
*   **The Main `BeamDequeChannel` Struct (Shared State):**
    ```pseudocode
    struct BeamDequeChannel<T> {
        local_stealers: Array<PaddedStealer<T>>;
        global_queue: DVyukovMPMCQueue<T>;
        allocator: Allocator;
    }
    ```
*   **The `WorkerHandle` Struct (Per-Thread Private State):**
    ```pseudocode
    struct WorkerHandle<T> {
        local_deque: BeamDeque<T>.Worker,
        channel: *BeamDequeChannel<T>,
        worker_id: usize,
        rng: std.rand.Random,
    }
    ```

#### **Phase 2: Lifecycle - `init` and `deinit`**

*   **`init(allocator, num_workers, local_capacity, global_capacity)`:**
    *   **Returns:** An array of `WorkerHandle`s.
    *   **Action:**
        1.  Initialize the `DVyukovMPMCQueue` to serve as the `global_queue`.
        2.  Allocate the main `BeamDequeChannel` struct.
        3.  Allocate the `local_stealers` array.
        4.  Loop `num_workers` times, calling `BeamDeque.init` for each slot, and distributing the `worker` and `stealer` handles into a new `WorkerHandle` and the `local_stealers` array, respectively.
        5.  Return the array of fully-formed `WorkerHandle`s.

*   **`deinit(channel, workers)`:**
    *   **Action:** Safely deinitializes all components in the reverse order of creation.

#### **Phase 3: Algorithms - The Final `send`/`recv` API**

*   **`send(worker_handle: *WorkerHandle, item: T) -> error{Full} | void`:**
    ```pseudocode
    function send(worker_handle, item) {
        // Fast Path: Push to this thread's private deque.
        if (worker_handle.local_deque.push(item) == SUCCESS) {
            return;
        }

        // Slow Path (Overflow): Offload to the global queue.
        const offload_count = worker_handle.local_deque.capacity() / 2;
        for (0..offload_count) {
            const offload_item = worker_handle.local_deque.pop().?;
            // If the global queue is full, fail immediately (back-pressure).
            try worker_handle.channel.global_queue.enqueue(offload_item);
        }

        // Retry the original push, which must now succeed.
        try worker_handle.local_deque.push(item);
    }
    ```

*   **`recv(worker_handle: *WorkerHandle) -> T | null`:**
    ```pseudocode
    function recv(worker_handle) {
        // Priority 1: Local Work (LIFO)
        if (worker_handle.local_deque.pop()) |item| {
            return item;
        }

        // Priority 2: Global Work (FIFO)
        if (worker_handle.channel.global_queue.dequeue()) |item| {
            return item;
        }

        // Priority 3: Work-Stealing (FIFO)
        const channel = worker_handle.channel;
        const num_workers = channel.local_stealers.length;
        const max_attempts = num_workers;

        for (0..max_attempts) {
            // Pick a random victim that is not yourself.
            var victim_id = worker_handle.rng.int_range(0, num_workers - 2);
            if (victim_id >= worker_handle.worker_id) { victim_id += 1; }

            const stealer = &channel.local_stealers[victim_id].stealer;

            if (stealer.steal()) |item| {
                return item;
            }
        }

        // All attempts failed.
        return null;
    }
    ```

### **Part 4: Final Verification Strategy**

1.  **End-to-End Stress Test:** 8P/8C, millions of items. Verify total count and uniqueness.
2.  **Overflow and Load Balancing Test:** 1P/8C, producer sends a massive burst. Verify all items are consumed and that consumers did most of the work, proving both global offload and stealing work correctly.
3.  **Performance Benchmark:** Measure throughput under 4P/4C and 8P/8C loads. The results should confirm near-linear scalability.