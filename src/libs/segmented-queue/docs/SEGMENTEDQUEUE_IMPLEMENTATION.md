## Implementation Plan: `SegmentedQueue` - Lock-Free Unbounded MPMC Queue with EBR-Protected Segments

---

### **Part 1: Architectural Vision & Design Philosophy**

**1.1. The Goal: Unbounded MPMC Queue with Bounded Segment Performance**
The objective is to provide an unbounded multi-producer, multi-consumer queue that combines the cache-efficiency of bounded queues with dynamic growth. Each segment is a high-performance DVyukovMPMCQueue; when full, new segments are allocated and linked via lock-free CAS operations.

**1.2. The Architectural Pattern: Segmented Linked List of Bounded Queues**
*   **Segment Chaining:** When a segment fills, a new segment is allocated and atomically linked.
*   **EBR Protection:** Epoch-Based Reclamation ensures safe segment deallocation after all threads have left the critical section.
*   **Cache-Line Alignment:** Head and tail segment pointers on separate cache lines prevent false sharing.
*   **Adaptive Backoff:** Crossbeam-style exponential backoff handles contention gracefully.
*   **Batch Operations:** Amortized EBR guard overhead via enqueueMany/dequeueMany.

**1.3. The Core Components**
*   **SegmentedQueue(T, segment_capacity):** Factory function producing queue types.
*   **Segment:** Internal node containing DVyukovMPMCQueue + next pointer.
*   **InnerQueue:** DVyukovMPMCQueue(T, segment_capacity) for each segment.
*   **Participant:** EBR participant handle for safe memory reclamation.
*   **GlobalEpoch:** Shared EBR epoch manager from beam-ebr.

**1.4. Performance Guarantees**
*   **Enqueue:** O(1) amortized (rare segment allocation).
*   **Dequeue:** O(1) amortized (rare segment advancement).
*   **Memory:** Dynamically grows; old segments reclaimed via EBR.
*   **Cache Efficiency:** Sequential access within segments.

---

### **Part 2: Core Design Decisions**

**2.1. DVyukovMPMCQueue as Segment Implementation**
*   **Decision:** Use DVyukovMPMCQueue for each segment rather than simple ring buffer.
*   **Justification:** DVyukov's algorithm provides excellent MPMC performance with minimal contention. Segments inherit proven lock-free properties.

**2.2. EBR for Segment Reclamation**
*   **Decision:** Use Epoch-Based Reclamation via beam-ebr for safe segment deallocation.
*   **Justification:** Segments may be accessed by multiple threads during dequeue operations. EBR ensures no thread accesses freed memory by deferring destruction until all threads have advanced past the epoch.

**2.3. Cache-Line Aligned Head/Tail Segment Pointers**
*   **Decision:** Align head_segment and tail_segment to cache line boundaries.
*   **Justification:** Producers primarily access tail_segment, consumers primarily access head_segment. Cache-line separation prevents false sharing between producer and consumer threads.

**2.4. Immediate Segment Advancement on Empty**
*   **Decision:** When segment appears empty and next exists, advance immediately without spinning.
*   **Justification:** Spinning on an empty segment wastes CPU cycles. If a next segment exists, items are likely there.

**2.5. Short Adaptive Backoff Before Returning Null**
*   **Decision:** Use reduced spin limit (4) before declaring queue empty.
*   **Justification:** Producers may be in the middle of enqueueing. Brief backoff allows in-flight operations to complete without excessive spinning.

**2.6. Batch Operations with Single Guard**
*   **Decision:** Provide enqueueMany/dequeueMany that use a single EBR guard for all operations.
*   **Justification:** Creating EBR guards has overhead. Amortizing across batch operations improves throughput for bulk transfers.

---

### **Part 3: Implementation Overview**

#### **Phase 1: Data Structures**

```
SegmentedQueue(T, segment_capacity)
│
├── head_segment: Atomic(*Segment) align(cache_line)
│   └── Points to segment for dequeue operations
│
├── tail_segment: Atomic(*Segment) align(cache_line)
│   └── Points to segment for enqueue operations
│
├── allocator: Allocator
│   └── For segment allocation/deallocation
│
└── ebr_global: *GlobalEpoch
    └── Shared EBR epoch manager

Segment
│
├── queue: *InnerQueue
│   └── DVyukovMPMCQueue(T, segment_capacity)
│
├── allocator: Allocator
│   └── For self-destruction via EBR
│
└── next: Atomic(?*Segment)
    └── Link to next segment (null if tail)

InnerQueue = DVyukovMPMCQueue(T, segment_capacity)
│
├── buffer: [segment_capacity]Slot
├── head: Atomic(u64) align(cache_line)
├── tail: Atomic(u64) align(cache_line)
└── mask: u64
```

#### **Phase 2: Core Operations**

| Operation | Thread-Safe | EBR Required | Notes |
|-----------|-------------|--------------|-------|
| `init(allocator)` | No | No | Creates first segment |
| `deinit()` | No | No | Frees all segments |
| `createParticipant()` | Yes | No | Register thread with EBR |
| `destroyParticipant(p)` | Yes | No | Unregister thread from EBR |
| `enqueue(item)` | Yes | External | Requires active guard |
| `enqueueWithAutoGuard(item)` | Yes | Auto | Creates/destroys guard |
| `dequeue(guard)` | Yes | External | Requires active guard |
| `dequeueWithAutoGuard()` | Yes | Auto | Creates/destroys guard |
| `enqueueMany(items)` | Yes | Internal | Single guard for batch |
| `dequeueMany(buffer)` | Yes | Internal | Single guard for batch |

#### **Phase 3: Key Algorithms**

**enqueue(item) - Add Item to Queue:**
1. Load tail_segment (acquire)
2. Try enqueue to tail_segment.queue
3. If success: return
4. If error.QueueFull:
   a. Check if next segment exists
   b. If yes: CAS advance tail_segment, retry
   c. If no: Allocate new segment + queue
   d. CAS link new segment to tail_segment.next
   e. If CAS failed: free new segment, retry
   f. CAS advance tail_segment to new segment
   g. Retry enqueue

**dequeue(guard) - Remove Item from Queue:**
1. Load head_segment (acquire)
2. Try dequeue from head_segment.queue
3. If success: return item
4. If null (empty):
   a. Check if next segment exists
   b. If yes: CAS advance head_segment, defer destroy old via EBR, retry
   c. If no: Enter adaptive backoff loop
   d. During backoff: retry dequeue, if success return
   e. After backoff: recheck for next segment
   f. If still no next: return null (queue truly empty)

**destroySegment(ptr) - EBR Callback:**
1. Cast ptr to *Segment
2. Call queue.deinit()
3. Free queue allocation
4. Free segment allocation

#### **Phase 4: Flow Diagrams**

**Memory Layout:**
```
┌─────────────────────────────────────────────────────────────────┐
│ Cache Line 0 (64 bytes)                                         │
│ ┌────────────────────┬──────────────────────────────────────────┐
│ │ head_segment: *Seg │            (padding)                     │
│ │    (consumer)      │                                          │
│ └────────────────────┴──────────────────────────────────────────┘
└─────────────────────────────────────────────────────────────────┘
┌─────────────────────────────────────────────────────────────────┐
│ Cache Line 1 (64 bytes)                                         │
│ ┌────────────────────┬─────────────┬────────────────────────────┐
│ │ tail_segment: *Seg │ allocator   │ ebr_global                 │
│ │    (producer)      │             │                            │
│ └────────────────────┴─────────────┴────────────────────────────┘
└─────────────────────────────────────────────────────────────────┘
```

**Segment Chain Structure:**
```
┌─────────────────────────────────────────────────────────────────┐
│                    Segmented Queue Structure                     │
└─────────────────────────────────────────────────────────────────┘

    head_segment                                      tail_segment
         │                                                 │
         ▼                                                 ▼
    ┌─────────┐     ┌─────────┐     ┌─────────┐     ┌─────────┐
    │Segment 0│────►│Segment 1│────►│Segment 2│────►│Segment 3│
    │ (empty) │     │ (empty) │     │(partial)│     │(filling)│
    └────┬────┘     └────┬────┘     └────┬────┘     └────┬────┘
         │               │               │               │
         ▼               ▼               ▼               ▼
    ┌─────────┐     ┌─────────┐     ┌─────────┐     ┌─────────┐
    │DVyukov  │     │DVyukov  │     │DVyukov  │     │DVyukov  │
    │MPMCQueue│     │MPMCQueue│     │MPMCQueue│     │MPMCQueue│
    └─────────┘     └─────────┘     └─────────┘     └─────────┘

    Dequeue ◄────────────────────────────────────────── Enqueue
```

**Enqueue Flow:**
```
enqueue(item)
      │
      ▼
┌─────────────────────┐
│ tail_seg = load()   │
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│ tail_seg.queue      │
│   .enqueue(item)?   │
└──────────┬──────────┘
           │
     ┌─────┴─────┐
     │           │
  success    QueueFull
     │           │
     ▼           ▼
  return    ┌─────────────────────┐
            │ next = tail_seg     │
            │   .next.load()      │
            └──────────┬──────────┘
                       │
                 ┌─────┴─────┐
                 │           │
              has next    no next
                 │           │
                 ▼           ▼
            ┌─────────┐  ┌─────────────────────┐
            │ CAS     │  │ Allocate new        │
            │ advance │  │ Segment + Queue     │
            │ tail    │  └──────────┬──────────┘
            └────┬────┘             │
                 │                  ▼
                 │           ┌─────────────────────┐
                 │           │ CAS link to         │
                 │           │ tail_seg.next       │
                 │           └──────────┬──────────┘
                 │                      │
                 │                ┌─────┴─────┐
                 │                │           │
                 │             success      failed
                 │                │           │
                 │                ▼           ▼
                 │           CAS advance   Free new
                 │           tail_segment  segment
                 │                │           │
                 └───────────────►│◄──────────┘
                                  │
                                  ▼
                              retry loop
```

**Dequeue Flow with EBR:**
```
dequeue(guard)
      │
      ▼
┌─────────────────────┐
│ head_seg = load()   │
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│ head_seg.queue      │
│   .dequeue()?       │
└──────────┬──────────┘
           │
     ┌─────┴─────┐
     │           │
   item        null
     │           │
     ▼           ▼
  return    ┌─────────────────────┐
  item      │ next = head_seg     │
            │   .next.load()      │
            └──────────┬──────────┘
                       │
                 ┌─────┴─────┐
                 │           │
              has next    no next
                 │           │
                 ▼           ▼
            ┌─────────┐  ┌─────────────────────┐
            │ CAS     │  │ Adaptive backoff    │
            │ advance │  │ (spin_limit=4)      │
            │ head    │  └──────────┬──────────┘
            └────┬────┘             │
                 │                  ▼
                 ▼           ┌─────────────────────┐
            ┌─────────┐      │ Retry dequeue       │
            │ Defer   │      │ during backoff      │
            │ destroy │      └──────────┬──────────┘
            │ via EBR │                 │
            └────┬────┘           ┌─────┴─────┐
                 │                │           │
                 │             item        completed
                 │                │           │
                 │                ▼           ▼
                 │             return    recheck next
                 │             item           │
                 │                      ┌─────┴─────┐
                 │                      │           │
                 │                   has next    no next
                 │                      │           │
                 └──────────────────────┘           ▼
                                               return null
```

**EBR Segment Reclamation:**
```
┌─────────────────────────────────────────────────────────────────┐
│              EBR-Protected Segment Destruction                   │
└─────────────────────────────────────────────────────────────────┘

Thread A advances head_segment from Seg0 to Seg1:

    Before:
    head_segment ──► Seg0 ──► Seg1 ──► Seg2
                      │
                  Thread B
                  reading

    After CAS:
    head_segment ──────────► Seg1 ──► Seg2
                      ↑
                     Seg0 (deferred destroy)
                      │
                  Thread B
                  still reading

    After epoch advance:
    head_segment ──────────► Seg1 ──► Seg2

                     Seg0 ✗ (destroyed)

    EBR ensures:
    1. Thread B completes its operation
    2. Thread B unpins (guard.deinit())
    3. Global epoch advances
    4. Seg0 is safely destroyed
```

---

### **Part 4: Verification & Testing Strategy**

**4.1. Unit Tests**
*   Basic enqueue and dequeue (single item).
*   FIFO ordering preserved across segments.
*   Queue grows when first segment fills.
*   Empty queue returns null.
*   Multiple enqueue/dequeue cycles.
*   deinit() frees all segments.

**4.2. Integration Tests (Multi-Threaded)**
*   MPMC: Multiple producers, multiple consumers.
*   1M items stress test: verify no lost/duplicate items.
*   Segment boundary crossing under contention.
*   EBR participant creation/destruction.
*   Burst patterns: rapid fill, then rapid drain.
*   Long-running test with many segment allocations.

**4.3. Batch Operation Tests**
*   enqueueMany with various batch sizes.
*   dequeueMany with buffer larger than queue size.
*   Mixed batch and single operations.
*   Guard amortization verification.

**4.4. Benchmarks**
*   Single-threaded enqueue/dequeue throughput.
*   MPMC throughput with varying producer/consumer counts.
*   Batch vs single operation comparison.
*   Comparison: SegmentedQueue vs single DVyukovMPMCQueue.
*   Memory allocation frequency measurement.
*   Segment reclamation latency impact.


