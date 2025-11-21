## Implementation Plan: `BoundedSPSCQueue` - Lock-Free Single-Producer Single-Consumer Queue

---

### **Part 1: Architectural Vision & Design Philosophy**

**1.1. The Goal: Maximum Throughput Point-to-Point Communication**
The objective is to provide the fastest possible queue for dedicated point-to-point communication between exactly two threads. By enforcing strict single-producer, single-consumer semantics, all CAS operations are eliminated from the hot path.

**1.2. The Architectural Pattern: Separated Producer/Consumer Handles**
*   **Role Separation:** Producer and Consumer are separate types, enforcing SPSC semantics at compile time.
*   **No CAS on Hot Path:** Each counter is written by only one thread, eliminating contention.
*   **Cache-Line Padding:** head and tail on separate cache lines prevent false sharing.
*   **Ring Buffer:** Power-of-two capacity enables fast modulo via bitwise AND.
*   **Acquire-Release Ordering:** Minimal memory barriers for maximum performance.

**1.3. The Core Components**
*   **BoundedSPSCQueue(T):** Factory function producing queue types for element type T.
*   **SPSCQueueImpl:** Internal state with head, tail, buffer, and mask.
*   **Producer:** Handle for enqueue operations (single owner).
*   **Consumer:** Handle for dequeue operations (single owner).
*   **InitResult:** Contains both Producer and Consumer handles.

**1.4. Performance Guarantees**
*   **Enqueue:** ~5-10ns per operation (100-200M ops/sec).
*   **Dequeue:** ~5-10ns per operation (100-200M ops/sec).
*   **Zero CAS:** No compare-and-swap on hot path.
*   **Zero False Sharing:** head and tail cache-line isolated.

---

### **Part 2: Core Design Decisions**

**2.1. Separate Producer and Consumer Types**
*   **Decision:** Return separate Producer and Consumer handles from init(), not a single queue reference.
*   **Justification:** Enforces SPSC contract at type level. Cannot accidentally call enqueue from consumer thread or dequeue from producer thread without explicit handle passing.

**2.2. Single-Writer Per Counter**
*   **Decision:** head is only written by Consumer, tail is only written by Producer.
*   **Justification:** Eliminates need for CAS operations. Simple store with release ordering is sufficient for publishing updates.

**2.3. Cache-Line Padding Between head and tail**
*   **Decision:** Insert explicit padding between head and tail to ensure they're on different cache lines.
*   **Justification:** Prevents false sharing. Producer writes tail, consumer writes head; without padding, these would ping-pong the same cache line.

**2.4. Power-of-Two Capacity**
*   **Decision:** Require capacity to be a power of two at runtime.
*   **Justification:** Enables fast ring buffer indexing via `index & mask` instead of expensive modulo division.

**2.5. Relaxed Ordering for Full/Empty Checks**
*   **Decision:** Use unordered/monotonic loads for advisory full/empty checks.
*   **Justification:** The check is advisory; even if stale, the subsequent acquire load in dequeue or the release store in enqueue provides correct synchronization.

**2.6. Type Size Enforcement**
*   **Decision:** Compile-time error if T exceeds cache line size (unless pointer).
*   **Justification:** Large T causes cache thrashing on every operation. Users should use pointers for large types.

---

### **Part 3: Implementation Overview**

#### **Phase 1: Data Structures**

```
BoundedSPSCQueue(T)
│
├── SPSCQueueImpl (heap-allocated, shared)
│   │
│   ├── head: Atomic(u64) align(cache_line)
│   │   └── Consumer's read position (only consumer writes)
│   │
│   ├── _padding: [cache_line - 8]u8
│   │   └── Prevents false sharing between head and tail
│   │
│   ├── tail: Atomic(u64) align(cache_line)
│   │   └── Producer's write position (only producer writes)
│   │
│   ├── buffer: []T
│   │   └── Ring buffer for items
│   │
│   ├── mask: u64
│   │   └── capacity - 1 (for fast & indexing)
│   │
│   └── allocator: Allocator
│
├── Producer
│   └── queue: *SPSCQueueImpl
│
├── Consumer
│   └── queue: *SPSCQueueImpl
│
└── InitResult
    ├── producer: Producer
    └── consumer: Consumer
```

#### **Phase 2: Core Operations**

| Operation | Thread | Ordering | CAS? | Latency |
|-----------|--------|----------|------|---------|
| `enqueue(item)` | Producer only | release store | No | ~5-10ns |
| `dequeue()` | Consumer only | acquire load + release store | No | ~5-10ns |
| `size()` | Either | monotonic + unordered | No | ~2-5ns |
| `isEmpty()` | Either | monotonic + unordered | No | ~2-5ns |

#### **Phase 3: Key Algorithms**

**enqueue(item) - Producer Only:**
1. Load tail (monotonic - we're the only writer)
2. Load head (unordered - advisory check)
3. If `tail - head >= capacity`: return error.Full
4. Compute index: `tail & mask`
5. Write item to `buffer[index]`
6. Store `tail + 1` (release - publishes write)

**dequeue() - Consumer Only:**
1. Load head (monotonic - we're the only writer)
2. Load tail (acquire - synchronizes with producer)
3. If `head == tail`: return null (empty)
4. Compute index: `head & mask`
5. Read item from `buffer[index]`
6. Store `head + 1` (release - publishes slot as free)
7. Return item

**init(allocator, capacity) - Setup:**
1. Validate capacity is power of two
2. Allocate SPSCQueueImpl on heap
3. Allocate buffer of size capacity
4. Initialize head=0, tail=0
5. Compute mask = capacity - 1
6. Return Producer and Consumer handles

#### **Phase 4: Flow Diagrams**

**Memory Layout (Cache-Line Isolation):**
```
┌─────────────────────────────────────────────────────────────────┐
│ Cache Line 0 (64 bytes)                                         │
│ ┌────────────┬──────────────────────────────────────────────────┐
│ │ head: u64  │              _padding (56 bytes)                 │
│ │ (consumer) │                                                  │
│ └────────────┴──────────────────────────────────────────────────┘
└─────────────────────────────────────────────────────────────────┘
┌─────────────────────────────────────────────────────────────────┐
│ Cache Line 1 (64 bytes)                                         │
│ ┌────────────┬──────────┬──────────┬───────────────────────────┐
│ │ tail: u64  │ buffer:  │ mask:    │ allocator:                │
│ │ (producer) │ []T ptr  │ u64      │ Allocator                 │
│ └────────────┴──────────┴──────────┴───────────────────────────┘
└─────────────────────────────────────────────────────────────────┘
```

**SPSC Data Flow:**
```
┌─────────────────────────────────────────────────────────────────┐
│                    SPSC Queue Operation                          │
└─────────────────────────────────────────────────────────────────┘

    Producer Thread                       Consumer Thread
         │                                     │
         │                                     │
    ┌────▼────┐                               │
    │enqueue()│                               │
    │ tail++  │                               │
    │(RELEASE)│ ────────────────────────────► │
    └────┬────┘                          ┌────▼────┐
         │                               │dequeue()│
         │                               │ head++  │
         │ ◄─────────────────────────────│(RELEASE)│
         │                               └────┬────┘
         ▼                                    ▼

    ┌───────────────────────────────────────────────┐
    │     [ ][A][B][C][ ][ ][ ][ ]                  │ Ring Buffer
    │        ▲        ▲                            │
    │      head     tail                           │
    │    (consumer) (producer)                     │
    └───────────────────────────────────────────────┘

    Key: Producer ONLY writes tail
         Consumer ONLY writes head
         No CAS needed - single writer per counter!
```

**enqueue() Flow:**
```
enqueue(item)
      │
      ▼
┌─────────────────────┐
│ tail = load(MONO)   │ ← We're the only writer
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│ head = load(UNORD)  │ ← Advisory check
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│ tail - head >= cap? │
└──────────┬──────────┘
           │
     ┌─────┴─────┐
     │           │
    yes          no
     │           │
     ▼           ▼
return      ┌─────────────────────┐
error.Full  │ buffer[tail & mask] │
            │     = item          │
            └──────────┬──────────┘
                       │
                       ▼
            ┌─────────────────────┐
            │ tail.store(tail+1,  │
            │   RELEASE)          │ ← Publishes write
            └─────────────────────┘
```

**dequeue() Flow:**
```
dequeue()
      │
      ▼
┌─────────────────────┐
│ head = load(MONO)   │ ← We're the only writer
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│ tail = load(ACQUIRE)│ ← Sync with producer
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│ head == tail?       │
└──────────┬──────────┘
           │
     ┌─────┴─────┐
     │           │
    yes          no
     │           │
     ▼           ▼
return      ┌─────────────────────┐
null        │ item = buffer[head  │
            │          & mask]    │
            └──────────┬──────────┘
                       │
                       ▼
            ┌─────────────────────┐
            │ head.store(head+1,  │
            │   RELEASE)          │ ← Frees slot
            └──────────┬──────────┘
                       │
                       ▼
                 return item
```

**Memory Ordering:**
```
Producer Thread                    Consumer Thread
      │                                  │
      ▼                                  │
buffer[idx] = item  ──────────────────►  │
      │                                  │
      ▼                                  │
tail.store(RELEASE) ═══════════════► tail.load(ACQUIRE)
      │                                  │
      │                                  ▼
      │                           item = buffer[idx]
      │                                  │
      │                                  ▼
      │  ◄════════════════════════ head.store(RELEASE)
      │                                  │

Key: RELEASE-ACQUIRE pair ensures:
     - Producer's buffer write visible to consumer
     - Consumer's slot free visible to producer
```

---

### **Part 4: Verification & Testing Strategy**

**4.1. Unit Tests**
*   Basic enqueue and dequeue (FIFO ordering).
*   Full queue returns error.Full.
*   Empty queue returns null.
*   Capacity must be power of two validation.
*   size() and isEmpty() accuracy.
*   Wraparound correctness (cycle through indices).
*   deinit() frees all memory.

**4.2. Integration Tests (Multi-Threaded)**
*   SPSC: One producer thread, one consumer thread.
*   1M items stress test: verify no lost/duplicate items.
*   Burst patterns: rapid enqueue, then rapid dequeue.
*   Interleaved: alternating enqueue/dequeue patterns.
*   Empty/full edge cases under concurrent access.

**4.3. Benchmarks**
*   Single-threaded enqueue throughput.
*   Single-threaded dequeue throughput.
*   SPSC ping-pong latency.
*   SPSC sustained throughput (1 producer, 1 consumer).
*   Comparison: with/without cache-line padding.
*   Comparison: BoundedSPSCQueue vs DVyukovMPMCQueue in SPSC mode.

