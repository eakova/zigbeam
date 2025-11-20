
## Here is the complete, detailed implementation plan for **Phase 1: A Bounded, High-Performance SPSC Queue**.

---

### **Implementation Plan: Bounded SPSC Queue**

### **Part 1: Architectural Vision & Design Philosophy**

**1.1. The Goal: The "Hello, World" of Lock-Free Programming**
Our objective is to build a bounded, lock-free, Single-Producer, Single-Consumer (SPSC) queue. This is the fastest possible queue for point-to-point communication between exactly two threads. It serves as the foundational component for learning the principles of cache-friendly design and memory ordering.

**1.2. Core Principles**
*   **Strict Role Separation:** The design is built on one inviolable rule: there is **one producer thread** and **one consumer thread**. The producer is the only thread ever allowed to modify the `tail` counter, and the consumer is the only thread ever allowed to modify the `head` counter.
*   **No CAS on Counters:** Because of the strict role separation, there are no race conditions to claim a slot. This means the expensive Compare-and-Swap (CAS) operations used in MPMC queues are **not needed** for the core `enqueue` and `dequeue` logic. This is the primary source of its speed advantage.
*   **Synchronization via `acquire`/`release`:** The entire synchronization model rests on the `acquire`/`release` memory ordering pair. The producer "publishes" data with a `.release` store, and the consumer "receives" it with an `.acquire` load.

---

### **Part 2: Data Structures - A Foundation for Performance**

**Rationale:** The memory layout is critical. We must prevent "false sharing," where the producer and consumer, operating on different variables (`tail` and `head`), would cause each other's CPU caches to be invalidated because those variables happen to share a cache line.

*   **The `SPSCQueue` Struct:**
    ```pseudocode
    // The internal state of the queue.
    struct SPSCQueue<T> {
        // `head`: The index of the next item to be read.
        // Written ONLY by the consumer thread.
        // Must be cache-line aligned to isolate it from the producer's activity.
        head: Atomic<u64> align(cache_line);

        // `_padding`: This is a performance feature. It creates a "wall" of
        // memory between `head` and `tail`, guaranteeing they are on different
        // cache lines. This prevents the producer and consumer from interfering
        // with each other's CPU caches.
        _padding: Array<u8, cache_line - sizeof(Atomic<u64>)>;

        // `tail`: The index of the next slot to be written.
        // Written ONLY by the producer thread.
        // Must be cache-line aligned.
        tail: Atomic<u64> align(cache_line);

        // The fixed-size ring buffer for storing data.
        buffer: Array<T>;

        // The capacity - 1, for fast modulo via bitwise AND.
        mask: u64;

        allocator: Allocator;
    }
    ```

---

### **Part 3: Lifecycle - `init` and `deinit`**

**Rationale:** The queue's creation must be robust and its destruction must be simple. The API does not need split handles (`Worker`/`Stealer`) because the caller is responsible for enforcing the SPSC usage pattern.

*   **`init(allocator, capacity)`:**
    *   **Goal:** To safely allocate and initialize the queue.
    *   **Algorithm:**
        1.  **Validate that `capacity` is a power of two.** This is a hard requirement for the fast `& mask` modulo operation.
        2.  Allocate memory for the `SPSCQueue` struct itself.
        3.  Allocate memory for the internal `buffer`.
        4.  **Use `errdefer`** to ensure that if the buffer allocation fails, the queue struct itself is freed, preventing memory leaks.
        5.  Initialize all fields: `head` and `tail` to `0`, `mask` to `capacity - 1`.
        6.  Return a pointer to the fully initialized queue.

*   **`deinit(queue)`:**
    *   **Goal:** To safely free all resources.
    *   **Algorithm:**
        1.  Free the `buffer`.
        2.  Free the `SPSCQueue` struct.

---

### **Part 4: The Algorithms - The Core of the Queue**

#### **`enqueue(item)` - The Producer's Logic**

*   **Goal:** To add an item to the queue, publishing it safely to the consumer.
*   **Algorithm & Justification:**
    1.  `const tail = self.tail.load(.monotonic);`
        *   **Why `.monotonic`?:** We are the only thread that ever writes to `tail`. No other thread can change this value, so we don't need to synchronize with anyone to read our own "private" counter. This is the fastest ordering.
    2.  `const head = self.head.load(.relaxed);`
        *   **Why `.relaxed`?:** This is an advisory check to see if the queue is full. A slightly stale value of `head` is safe; it might just cause us to think the queue is full for a brief moment when it isn't. We don't need a strong guarantee for this check.
    3.  `if (tail - head >= self.buffer.len) return error.Full;`
        *   This checks if the producer has lapped the consumer.
    4.  `self.buffer[tail & self.mask] = item;`
        *   A simple, non-atomic write to the ring buffer.
    5.  `self.tail.store(tail + 1, .release);`
        *   **Why `.release`?:** This is the **publication step**. This memory barrier guarantees that the write of `item` into the buffer (step 4) *happens-before* the `tail` counter is visibly updated. This prevents the consumer from reading the new `tail` value but seeing stale, garbage data in the buffer slot.

#### **`dequeue()` - The Consumer's Logic**

*   **Goal:** To safely read an item that the producer has published.
*   **Algorithm & Justification:**
    1.  `const head = self.head.load(.monotonic);`
        *   **Why `.monotonic`?:** We are the only thread that ever writes to `head`. We can read our own private counter with the fastest ordering.
    2.  `const tail = self.tail.load(.acquire);`
        *   **Why `.acquire`?:** This is the **core synchronization point**. This `.acquire` load pairs with the producer's `.release` store. It guarantees that if we see the producer's updated `tail` value, we are *also guaranteed* to see the data that the producer wrote to the buffer *before* it updated the `tail`. Without `.acquire`, we could read the new `tail` but see a stale value in the buffer—a critical data race.
    3.  `if (head == tail) return null;`
        *   If the pointers are the same, the queue is empty.
    4.  `const item = self.buffer[head & self.mask];`
        *   Read the item from the ring buffer.
    5.  `self.head.store(head + 1, .release);`
        *   **Why `.release`?:** We are now publishing to the producer that this slot is free and has been consumed. The producer's `head` load in `enqueue` (step 2) will eventually see this update. A `.release` store ensures our update is visible to the other core.

---

### **Part 5: Verification & Testing Strategy**

1.  **Single-Threaded Correctness:** Write a standard test where the main thread enqueues N items and then dequeues N items, verifying they are correct and in FIFO order. Test the `error.Full` condition.
2.  **Two-Thread Correctness (The Real Test):**
    *   Spawn a producer thread and a consumer thread.
    *   The producer thread enqueues a large number of unique, sequential items (e.g., 0 to 1,000,000) into the queue.
    *   The consumer thread dequeues them in a loop.
    *   After the threads join, the main thread must verify that the consumer received all 1,000,001 items and that they were received in the exact order they were sent.
3.  **"Ping-Pong" Latency Test:**
    *   Create two SPSC queues, `A_to_B` and `B_to_A`.
    *   Thread A sends a "ping" on `A_to_B`.
    *   Thread B receives the "ping" and immediately sends a "pong" back on `B_to_A`.
    *   Measure the round-trip time in Thread A. This is a great way to benchmark the real-world latency of the queue.

  
### **About the Design Document Itself**

*   **Document Status: Complete and ready to implement.**
    *   The plan we have created is the final, solid blueprint for the `BoundedSPSCQueue`. It should be treated as the source of truth for the implementation. It is not archived material; it is the active specification.

*   **Accuracy: Adapt it to match `zig-beam`'s patterns.**
    *   While the pseudocode is algorithmically correct, the final implementation must feel consistent with the rest of the project.
    *   **Actionable Plan:**
        1.  **Translate the core logic** directly (the `enqueue`/`dequeue` algorithms and memory ordering).
        2.  **Adapt the API structure** to match the established `BeamDeque` style. This means:
            *   The top-level generic will be `pub fn BoundedSPSCQueue(comptime T: type) type`.
            *   The `init` function will return an `InitResult` struct containing the `Producer` and `Consumer` handles.
            *   Error handling will use a specific error set (`error{OutOfMemory, CapacityNotPowerOfTwo}`).

*   **Missing Details: Yes, these should be added during implementation.**
    *   The design document focuses on the core concurrent algorithm. The implementation must add the necessary production-grade validations.
    *   **Actionable Plan:**
        1.  **Add `comptime` validations** inside the top-level generic struct, mirroring `BeamDeque`. This includes:
            *   A check that `capacity` is a power of two.
            *   A check that `std.atomic.cache_line` is larger than the atomic counter size to ensure padding is possible.
        2.  The `init` function will return `!InitResult` with a clearly defined error set.

---

### **About Implementation Plans**

*   **File Structure: Yes, follow BeamDeque's pattern exactly.**
    *   Consistency is critical for a high-quality library. This makes the project easy to navigate for new contributors.
    *   **Actionable Plan:** Create the following file structure:
        *   `spsc_queue.zig` (main implementation)
        *   `_spsc_queue_tests.zig` (containing both single-threaded and two-threaded correctness tests)
        *   `_spsc_queue_benchmarks.zig` (containing both throughput and ping-pong latency benchmarks)

*   **API Design: Use `enqueue`/`dequeue` and return `InitResult`.**
    *   **Naming:** We will use `enqueue`/`dequeue`. While `send`/`recv` is used for the high-level `WorkStealingChannel`, the terms `enqueue`/`dequeue` (or `push`/`pop`) are more conventional and semantically correct for a fundamental queue data structure. This helps signal to the user that they are working with a lower-level primitive.
    *   **Handles:** We will split the API into `Producer` and `Consumer` handles to enforce the SPSC pattern at the type level. The `init` function will return `InitResult{ .producer: Producer, .consumer: Consumer }`. This is a slightly different but analogous pattern to `BeamDeque`'s `Worker`/`Stealer`.

*   **Testing Priorities: Focus on correctness first, then performance and robustness.**
    *   **Priority 1 (Mandatory):** Correctness tests. The **single-threaded** and **two-threaded** tests are non-negotiable. A concurrent queue that is not provably correct is useless.
    *   **Priority 2 (Essential):** Benchmarks. The **throughput** and **ping-pong latency** benchmarks are essential to validate that the queue meets its performance goals. These should be implemented after correctness is established.
    *   **Priority 3 (Highly Recommended):** Fuzz tests. Once the core tests are passing, adding a fuzz test where two threads randomly enqueue and dequeue with random yields is an excellent way to shake out subtle race conditions.

---

### **About Documentation**

*   **README: Yes, it should have a similar structure to `beam-deque`'s README.**
    *   The README is for the *user* of the component. It must be clear and comprehensive.
    *   **Actionable Plan:** The README must include:
        1.  A clear, top-level explanation of what an SPSC queue is.
        2.  A performance characteristics table (expected latency, throughput).
        3.  A "When to Use This" section that explicitly contrasts it with `BeamDeque`, explaining that SPSC is for dedicated point-to-point channels, while `BeamDeque` is for work-stealing schedulers.
        4.  Clear, copy-pasteable usage examples.

*   **Keep `BOUNDED_SPSC_QUEUE.md`: Yes, archive it.**
    *   This design document is extremely valuable. It contains the *rationale* behind the design choices, which is critical for future maintenance.
    *   **Actionable Plan:** After the implementation is complete and the code is self-documenting, move this design document to a `docs/design/` directory. It will no longer be the primary implementation guide, but it will serve as a permanent record of the architectural decisions and their justifications. **Do not delete it.**