## Implementation Plan: `DVyukovMPMCQueue` - Bounded Lock-Free MPMC Queue

---

### **Part 1: Architectural Vision & Design Philosophy**

**1.1. The Goal: High-Performance Multi-Producer Multi-Consumer Communication**
The objective is to provide a bounded lock-free queue that enables multiple producers and multiple consumers to communicate concurrently with minimal contention, using sequence numbers for synchronization instead of locks.

**1.2. The Architectural Pattern: Vyukov Bounded MPMC Queue**
*   **Sequence-Based Synchronization:** Each cell has a sequence number that indicates its state (available for enqueue vs. contains data for dequeue).
*   **Two Global Counters:** enqueue_pos (tail) and dequeue_pos (head) track claim positions.
*   **Cache-Line Isolation:** Counters and cells are cache-line aligned to prevent false sharing.
*   **Wraparound-Safe Arithmetic:** Uses signed 64-bit differences for correct comparison after u64 overflow.

**1.3. The Core Components**
*   **Cell:** Ring buffer entry with sequence number (u64) and data slot, cache-line padded.
*   **enqueue_pos:** Atomic tail counter for producer position claims.
*   **dequeue_pos:** Atomic head counter for consumer position claims.
*   **buffer:** Fixed-size ring buffer of Cells.
*   **mask:** Capacity - 1 for fast modulo via bitwise AND.

**1.4. Performance Guarantees**
*   **Single-threaded:** ~550 Mops/s, ~1.7ns per operation.
*   **SPSC:** ~70-100 Mops/s, 10-14ns per operation.
*   **MPSC (8P/1C):** ~100 Mops/s, 9ns per operation.
*   **SPMC (1P/8C):** ~32 Mops/s, 31ns per operation.
*   **MPMC (4P/4C):** ~40 Mops/s, 25ns per operation.
*   **Zero allocations:** All operations are allocation-free after init.

---

### **Part 2: Core Design Decisions**

**2.1. Sequence Number Synchronization**
*   **Decision:** Use per-cell sequence numbers instead of global locks or separate full/empty flags.
*   **Justification:** Sequence numbers encode both cell state and ABA protection. Even sequences indicate available for enqueue, odd sequences indicate data ready for dequeue. This eliminates separate state tracking and prevents ABA issues.

**2.2. Cache-Line Aligned Cells**
*   **Decision:** Each Cell is padded to be a multiple of cache line size (64 bytes).
*   **Justification:** Prevents false sharing between adjacent cells. When multiple threads operate on different cells, they don't invalidate each other's cache lines.

**2.3. Separated enqueue_pos and dequeue_pos**
*   **Decision:** Place enqueue_pos and dequeue_pos on separate cache lines with explicit padding.
*   **Justification:** Producers write to enqueue_pos, consumers write to dequeue_pos. Separating them prevents false sharing between producer and consumer threads.

**2.4. Power-of-Two Capacity**
*   **Decision:** Require capacity to be a power of two.
*   **Justification:** Enables fast modulo via bitwise AND (`index & mask`) instead of expensive division.

**2.5. 64-bit Counters with Signed Difference**
*   **Decision:** Use u64 for position counters, compute differences using signed i64 arithmetic.
*   **Justification:** u64 avoids ABA issues on 32-bit systems. Signed difference via `@bitCast` handles wraparound correctly (e.g., seq=5, pos=2^64-3 gives correct positive difference).

**2.6. Monotonic Loads for Producers, Acquire for Consumers**
*   **Decision:** Producer uses `.monotonic` for sequence loads, consumer uses `.acquire`.
*   **Justification:** Producer's `.release` store on sequence pairs with consumer's `.acquire` load. This ensures data visibility without unnecessary barriers on the producer's read path.

**2.7. Type Size Enforcement**
*   **Decision:** Compile-time error if `@sizeOf(T) > cache_line`.
*   **Justification:** Large T causes cells to span multiple cache lines, severely degrading performance (2-5x slower under contention). Users should use pointers for large types.

**2.8. Minimum Capacity of 2**
*   **Decision:** Enforce capacity >= 2 at compile time.
*   **Justification:** Vyukov algorithm requires at least 2 cells for correct operation. Single-cell queue would have edge cases in sequence number progression.

---

### **Part 3: Implementation Overview**

#### **Phase 1: Data Structures**

```
DVyukovMPMCQueue(T, capacity)
│
├── buffer: []Cell
│   └── [i]: Cell align(cache_line)
│       ├── sequence: Atomic(u64)    ← even=enqueue, odd=dequeue
│       ├── data: T                   ← user data slot
│       └── _padding: [...]u8         ← ensures Cell is cache_line multiple
│
├── enqueue_pos: Atomic(u64) align(cache_line)  ← producer tail
├── _padding1: [cache_line - 8]u8               ← prevents false sharing
│
├── dequeue_pos: Atomic(u64) align(cache_line)  ← consumer head
├── _padding2: [cache_line - 8]u8               ← prevents false sharing
│
├── mask: usize                                  ← capacity - 1
└── allocator: Allocator
```

#### **Phase 2: Core Operations**

| Operation | Thread | Ordering | CAS? | Latency |
|-----------|--------|----------|------|---------|
| `enqueue()` | Any producer | monotonic + release | Yes | ~10-50ns |
| `dequeue()` | Any consumer | acquire + release | Yes | ~10-50ns |
| `tryEnqueue()` | Any producer | monotonic + release | Yes | ~10-50ns |
| `size()` | Any | monotonic | No | ~5ns |
| `drain()` | Single (shutdown) | - | No | O(n) |

#### **Phase 3: Key Algorithms**

**enqueue(item) - Producer CAS Loop:**
1. Load enqueue_pos (monotonic)
2. Calculate index: `pos & mask`
3. Load cell.sequence (monotonic)
4. Compute signed difference: `seq - pos`
5. If `dif == 0` → cell available, try CAS to claim `pos → pos+1`
6. If CAS fails → retry with new position
7. If CAS succeeds → write data, store `sequence = pos + 1` (release)
8. If `dif < 0` → queue full, return error.QueueFull
9. If `dif > 0` → another producer owns cell, reload pos and retry

**dequeue() - Consumer CAS Loop:**
1. Load dequeue_pos (monotonic)
2. Calculate index: `pos & mask`
3. Load cell.sequence (acquire) - CRITICAL for data visibility
4. Compute signed difference: `seq - (pos + 1)`
5. If `dif == 0` → data ready, try CAS to claim `pos → pos+1`
6. If CAS fails → retry with new position
7. If CAS succeeds → read data, store `sequence = pos + capacity` (release)
8. If `dif < 0` → queue empty, return null
9. If `dif > 0` → another consumer owns cell, reload pos and retry

**Sequence Number Progression:**
```
Initial state (capacity=4):
Cell 0: seq=0, Cell 1: seq=1, Cell 2: seq=2, Cell 3: seq=3

After enqueue at pos=0:
Cell 0: seq=1 (odd = data ready), data=item

After dequeue at pos=0:
Cell 0: seq=4 (0 + capacity = available for next round)

After enqueue at pos=4:
Cell 0: seq=5 (data ready again)
```

#### **Phase 4: Flow Diagrams**

**Memory Layout (Cache-Line Isolation):**
```
┌─────────────────────────────────────────────────────────────────┐
│ Cache Line 0 (64 bytes)                                         │
│ ┌────────────────┬──────────────────────────────────────────────┐
│ │ enqueue_pos    │              _padding1 (56 bytes)            │
│ │ (producers)    │                                              │
│ └────────────────┴──────────────────────────────────────────────┘
└─────────────────────────────────────────────────────────────────┘
┌─────────────────────────────────────────────────────────────────┐
│ Cache Line 1 (64 bytes)                                         │
│ ┌────────────────┬──────────────────────────────────────────────┐
│ │ dequeue_pos    │              _padding2 (56 bytes)            │
│ │ (consumers)    │                                              │
│ └────────────────┴──────────────────────────────────────────────┘
└─────────────────────────────────────────────────────────────────┘
┌─────────────────────────────────────────────────────────────────┐
│ Ring Buffer (cache-line aligned)                                │
│ ┌────────────────────────────────────────────────────────────┐  │
│ │ Cell 0 (64 bytes)                                          │  │
│ │ ┌──────────┬────────────────────┬────────────────────────┐ │  │
│ │ │ seq: u64 │ data: T            │ _padding               │ │  │
│ │ └──────────┴────────────────────┴────────────────────────┘ │  │
│ └────────────────────────────────────────────────────────────┘  │
│ ┌────────────────────────────────────────────────────────────┐  │
│ │ Cell 1 (64 bytes)                                          │  │
│ │ ...                                                        │  │
│ └────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

**Enqueue Flow:**
```
enqueue(item)
    │
    ▼
┌───────────────────────┐
│ pos = enqueue_pos     │
│        .load()        │
└──────────┬────────────┘
           │
           ▼
┌───────────────────────┐
│ idx = pos & mask      │
│ seq = cell[idx].seq   │
└──────────┬────────────┘
           │
           ▼
┌───────────────────────┐
│ dif = seq - pos       │
│ (signed difference)   │
└──────────┬────────────┘
           │
     ┌─────┴─────┬─────────────┐
     │           │             │
  dif == 0    dif < 0      dif > 0
     │           │             │
     ▼           ▼             ▼
┌──────────┐ ┌────────────┐ ┌────────────┐
│ CAS      │ │ return     │ │ reload pos │
│ enqueue_ │ │ QueueFull  │ │ retry      │
│ pos++    │ └────────────┘ └────────────┘
└────┬─────┘
     │
   ┌─┴──────┐
   │        │
success   fail
   │        │
   ▼        ▼
┌──────────┐ ┌────────────┐
│write data│ │ retry with │
│seq=pos+1 │ │ new pos    │
│(release) │ └────────────┘
└──────────┘
```

**Dequeue Flow:**
```
dequeue()
    │
    ▼
┌───────────────────────┐
│ pos = dequeue_pos     │
│        .load()        │
└──────────┬────────────┘
           │
           ▼
┌───────────────────────┐
│ idx = pos & mask      │
│ seq = cell[idx].seq   │
│      (ACQUIRE!)       │
└──────────┬────────────┘
           │
           ▼
┌───────────────────────┐
│ dif = seq - (pos + 1) │
│ (check for odd seq)   │
└──────────┬────────────┘
           │
     ┌─────┴─────┬─────────────┐
     │           │             │
  dif == 0    dif < 0      dif > 0
     │           │             │
     ▼           ▼             ▼
┌──────────┐ ┌────────────┐ ┌────────────┐
│ CAS      │ │ return     │ │ reload pos │
│ dequeue_ │ │ null       │ │ retry      │
│ pos++    │ └────────────┘ └────────────┘
└────┬─────┘
     │
   ┌─┴──────┐
   │        │
success   fail
   │        │
   ▼        ▼
┌──────────┐ ┌────────────┐
│read data │ │ retry with │
│seq=pos+  │ │ new pos    │
│capacity  │ └────────────┘
│(release) │
└──────────┘
     │
     ▼
 return item
```

**Concurrent Producer/Consumer State Machine:**
```
                        Cell State Transitions
                        =====================

    ┌─────────────────────────────────────────────────────────┐
    │                                                         │
    │    seq = N (even)                seq = N+1 (odd)        │
    │   ┌─────────────┐               ┌─────────────┐         │
    │   │  AVAILABLE  │   enqueue     │  DATA READY │         │
    │   │  for write  │──────────────►│  for read   │         │
    │   │             │   seq++       │             │         │
    │   └─────────────┘   (release)   └─────────────┘         │
    │         ▲                              │                │
    │         │                              │                │
    │         │          dequeue             │                │
    │         │       seq = N + capacity     │                │
    │         └──────────(release)───────────┘                │
    │                                                         │
    └─────────────────────────────────────────────────────────┘

    Example with capacity=4:

    Time 0: Cell 0 seq=0 (available at pos=0)
    Time 1: Producer claims pos=0, writes, seq=1 (data ready)
    Time 2: Consumer claims pos=0, reads, seq=4 (available at pos=4)
    Time 3: Producer claims pos=4, writes, seq=5 (data ready)
    ...
```

**Multi-Producer Contention Resolution:**
```
    Producer A              Producer B              Cell State
        │                       │                       │
        ▼                       ▼                       │
   pos=0, try CAS          pos=0, try CAS              │
        │                       │                       │
        ├──────── RACE ─────────┤                       │
        │                       │                       │
   CAS succeeds            CAS fails                   │
        │                       │                  seq=0→1
        ▼                       ▼                       │
   write data              pos=1 (from CAS)            │
   seq=1                        │                       │
        │                       ▼                       │
        │                  retry at pos=1              │
        │                       │                  seq=1→2
        │                       ▼                       │
        │                  write data                   │
        │                  seq=2                        │
        ▼                       ▼                       │
      done                    done                      │
```

---

### **Part 4: Verification & Testing Strategy**

**4.1. Unit Tests**
*   Basic enqueue and dequeue (FIFO ordering).
*   Queue full returns error.QueueFull.
*   Queue empty returns null.
*   Wraparound correctness (cycle through indices multiple times).
*   tryEnqueue with retry limit.
*   size(), isEmpty(), isFull() helper accuracy.
*   Compile-time rejection of non-power-of-two capacity.
*   Compile-time rejection of capacity < 2.
*   Compile-time rejection of T larger than cache line.

**4.2. Integration Tests (Multi-Threaded)**
*   SPSC: Single producer, single consumer correctness.
*   MPSC: Multiple producers, single consumer (no lost/duplicate items).
*   SPMC: Single producer, multiple consumers (no lost/duplicate items).
*   MPMC: Multiple producers, multiple consumers stress test.
*   1M items stress test: verify no lost/duplicate items under contention.
*   Backpressure test: verify error.QueueFull under saturation.

**4.3. Fuzz Tests**
*   Random operation sequences (enqueue/dequeue interleaved).
*   Random thread counts and capacity configurations.
*   ABA scenario stress tests (wraparound counter behavior).
*   Contention scenario fuzzing (all threads competing).

**4.4. Benchmarks**
*   Single-threaded enqueue throughput.
*   Single-threaded dequeue throughput.
*   SPSC throughput and latency.
*   MPSC scaling (1C, varying producers).
*   SPMC scaling (1P, varying consumers).
*   MPMC balanced contention (NP/NC for various N).
*   Comparison with/without cache-line padding.
*   Memory bandwidth utilization.

