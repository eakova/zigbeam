## This is the final step: a complete, solid, lean, and detailed implementation plan that integrates the answers to your excellent questions. This document serves as the definitive blueprint for building the `BeamDequeChannel`.

---

### **Implementation Plan: `BeamDequeChannel`**

### **Part 1: Architectural Vision & Design Philosophy**

**1.1. The Goal: An Ergonomic, Scalable MPMC Channel**
The objective is to create a high-level concurrent channel with a simple `send`/`recv` API that scales gracefully under high contention. It will be built using our high-performance, bounded `BeamDeque` as the core engine.

**1.2. The Architectural Pattern: Distributed Deques with a Global Overflow**
This architecture provides scalability and an "effectively unbounded" behavior without the complexity of dynamically growing the core deques.
*   **Local Deques (The Fast Path):** Each worker thread is assigned its own private, bounded `BeamDeque`. This eliminates producer-producer contention.
*   **Global Queue (The Safety Valve):** A single, shared, concurrent MPMC queue acts as an overflow buffer.
*   **Work-Stealing (The Load Balancer):** When a worker is idle, it actively steals work from the local deques of other, busier workers.

**1.3. Bounded Nature and Back-Pressure**
The channel is **bounded**. If a worker's local deque is full and its attempt to offload to the global queue also fails (because it, too, is full), the `send` operation will fail. This provides robust, system-wide back-pressure.

---

### **Part 2: Core Design Decisions**

This section codifies the answers to the critical implementation questions.

**2.1. Global MPMC Queue Implementation**
*   **Decision:** We will use the `DVyukovMPMCQueue` implementation we have already designed and verified.
*   **Justification:** It is a high-performance, bounded, lock-free MPMC queue. A bounded queue is essential for providing back-pressure, and a lock-free design is necessary to avoid re-introducing a global bottleneck.

**2.2. Random Stealing Strategy**
*   **Decision:**
    1.  Each thread will use its own **thread-local PRNG** (e.g., `std.rand.Xoshiro256`) to choose victims.
    2.  An idle thread will make **`num_workers`** random attempts to steal before giving up and returning `null`.
*   **Justification:** A thread-local PRNG avoids contention on a shared random number generator. Random probing distributes the stealing load evenly. A fixed number of attempts prevents idle threads from burning 100% CPU on a quiet system.

**2.3. Offload Strategy Details**
*   **Decision:**
    1.  When a local deque is full, the worker will offload exactly **`local_capacity / 2`** items.
    2.  If the global queue becomes full during this batch offload, the `send` operation will **stop immediately and return `error.Full`**.
*   **Justification:** Offloading half the deque is a proven heuristic to create significant space while moving a meaningful batch of work. The "fail fast" model for partial failure is the simplest and most robust way to handle system-wide back-pressure without complex state restoration logic.

**2.4. API Design Decisions**
*   **Decision:**
    1.  The core `send`/`recv` API will be **non-blocking**.
    2.  A worker's context will be passed as a parameter to the functions: `send(worker: Worker, ...)` and `recv(worker: Worker, worker_id: usize, ...)`.
*   **Justification:** A non-blocking API is the most fundamental primitive, upon which blocking or timed operations can be built by the application. Passing parameters is explicit, fast, and avoids the complexity and overhead of thread-local storage. The `worker_id` is required in `recv` to prevent a worker from attempting to steal from itself.

**2.5. Configuration Defaults**
*   **Decision:**
    *   `local_capacity`: **256**
    *   `global_capacity`: **`max(4096, num_workers * local_capacity)`**
    *   `max_steal_attempts`: **`num_workers`**
*   **Justification:** These are sensible defaults for server-side workloads. `256` provides a good local buffer. The `global_capacity` formula ensures the overflow queue is large enough to handle bursts from multiple workers. Probing each other worker once (`num_workers` attempts) is a reasonable heuristic for finding work.

---

### **Part 3: Detailed Implementation Plan**

#### **Phase 1: Data Structures**

*   **Internal `PaddedStealer` Struct:**
    ```pseudocode
    struct PaddedStealer<T> {
        stealer: BeamDeque<T>.Stealer,
        _padding: Array<u8, cache_line - sizeof(BeamDeque<T>.Stealer)>;
    }
    ```*   **The Main `Channel` Struct:**
    ```pseudocode
    struct Channel<T> {
        local_stealers: Array<PaddedStealer<T>>;
        global_queue: DVyukovMPMCQueue<T>;
        allocator: Allocator;
    }
    ```

#### **Phase 2: Lifecycle - `init` and `deinit`**

*   **`init(allocator, num_workers, local_capacity, global_capacity)`:**
    *   Returns `{channel: *Channel, workers: []BeamDeque.Worker}`.
    *   Allocates the `Channel` struct.
    *   Initializes `global_queue` using `DVyukovMPMCQueue.init`.
    *   Allocates the `local_stealers` and `workers` arrays.
    *   Loops `num_workers` times, calling `BeamDeque.init` and distributing the returned handles into the `local_stealers` and `workers` arrays.
    *   Uses `errdefer` throughout for exception safety.

*   **`deinit(channel, workers)`:**
    *   Loops through `workers`, calling `BeamDeque.deinit()` on each.
    *   Calls `deinit()` on the `global_queue`.
    *   Frees all allocated arrays and the `Channel` struct.

#### **Phase 3: Algorithms - The User-Facing API (`send`/`recv`)**

*   **`send(worker: BeamDeque.Worker, channel: *Channel, item: T) -> error{Full} | void`:**
    ```pseudocode
    function send(worker, channel, item) {
        // Fast Path
        if (worker.push(item) == SUCCESS) {
            return;
        }

        // Slow Path (Overflow)
        const offload_count = worker.capacity() / 2;
        for (0..offload_count) {
            // Pop from the bottom of our own deque. It cannot be empty.
            const offload_item = worker.pop().?;
            // If the global queue is full, we fail immediately.
            try channel.global_queue.enqueue(offload_item);
        }

        // Retry the original push, which must now succeed.
        try worker.push(item);
    }
    ```

*   **`recv(worker: BeamDeque.Worker, channel: *Channel, worker_id: usize, rng: *Rand) -> T | null`:**
    ```pseudocode
    function recv(worker, channel, worker_id, rng) {
        // Priority 1: Local Work (LIFO)
        if (worker.pop()) |item| {
            return item;
        }

        // Priority 2: Global Work (FIFO)
        if (channel.global_queue.dequeue()) |item| {
            return item;
        }

        // Priority 3: Work-Stealing (FIFO)
        const num_workers = channel.local_stealers.length;
        const max_attempts = num_workers; // From our design decisions

        for (0..max_attempts) {
            // Pick a random victim, ensuring it's not ourself.
            var victim_id = rng.int_range(0, num_workers - 1);
            if (victim_id >= worker_id) { victim_id += 1; }
            if (victim_id >= num_workers) { victim_id = 0; }

            const stealer = &channel.local_stealers[victim_id].stealer;

            if (stealer.steal()) |item| {
                return item;
            }
        }

        // All attempts failed.
        return null;
    }
    ```

### **Part 4: Verification & Testing Strategy**

1.  **End-to-End Stress Test:** 8P/8C, millions of items, verify total count and uniqueness.
2.  **Overflow and Load Balancing Test:** 1P/8C, producer sends a massive burst, verify all items are consumed and that consumers did most of the work.
3.  **Performance Benchmark:** Measure throughput under 4P/4C and 8P/8C loads, confirming scalability.