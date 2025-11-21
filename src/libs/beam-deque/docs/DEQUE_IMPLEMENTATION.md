## Implementation Plan: `Deque` - Bounded Work-Stealing Deque (Chase-Lev Algorithm)

---

### **Part 1: Architectural Vision & Design Philosophy**

**1.1. The Goal: Enable Efficient Work-Stealing Parallelism**
The objective is to provide a high-performance bounded deque that enables the work-stealing pattern: one owner thread pushes/pops work (LIFO for cache locality), while multiple thief threads can steal work (FIFO for fair distribution).

**1.2. The Architectural Pattern: Chase-Lev with Bounded Capacity**
*   **Single-Owner, Multi-Thief:** One Worker thread owns push/pop, many Stealers can steal.
*   **Asymmetric Access:** Owner uses fast-path (no CAS for push), thieves use CAS.
*   **Cache-Line Isolation:** head/tail on separate cache lines to prevent false sharing.
*   **Fixed Capacity:** Bounded ring buffer (no dynamic resizing) for predictable memory.

**1.3. The Core Components**
*   **DequeStore:** Internal state (head, tail, buffer, mask, allocator).
*   **Worker:** Owner-thread handle with push(), pop(), deinit().
*   **Stealer:** Thief-thread handle with steal().
*   **InitResult:** Contains both Worker and Stealer handles.

**1.4. Performance Guarantees**
*   **Push:** O(1), ~2-5ns - no CAS, just release store.
*   **Pop:** O(1), ~3-10ns - CAS only when racing for last item.
*   **Steal:** O(1), ~20-50ns - acquire loads + CAS with exponential backoff.
*   **Zero False Sharing:** head/tail cache-line aligned with explicit padding.

---

### **Part 2: Core Design Decisions**

**2.1. Bounded Capacity (No Dynamic Resizing)**
*   **Decision:** Fixed-size ring buffer that returns `error.Full` when capacity reached.
*   **Justification:** Eliminates complex resize logic and memory reallocation during hot paths. Predictable memory footprint for real-time systems.

**2.2. Signed i64 Indices**
*   **Decision:** Use signed i64 for head/tail instead of unsigned integers.
*   **Justification:** Enables correct size calculation via `tail - head` even during wraparound, avoiding subtle overflow bugs.

**2.3. Power-of-Two Capacity**
*   **Decision:** Require capacity to be a power of two.
*   **Justification:** Enables fast modulo via bitwise AND (`index & mask`) instead of expensive division.

**2.4. Cache-Line Padding**
*   **Decision:** Explicit padding between head and tail using `std.atomic.cache_line`.
*   **Justification:** Prevents false sharing between owner (writes tail) and thieves (write head), critical for scalability.

**2.5. Exponential Backoff on Steal Contention**
*   **Decision:** Use `Backoff.snooze()` when CAS fails during steal.
*   **Justification:** Reduces cache coherency traffic when multiple thieves contend, improving throughput under high load.

**2.6. Type Size Enforcement**
*   **Decision:** Compile-time error for types larger than cache line (unless pointer).
*   **Justification:** Prevents accidental performance degradation from cache line splitting. Users must use pointers for large types.

**2.7. seq_cst for Last-Item Race**
*   **Decision:** Use `seq_cst` ordering in pop() when racing with thieves for the last item.
*   **Justification:** Required for correctness in the three-way race between owner pop and multiple thieves. Matches original Chase-Lev paper.

---

### **Part 3: Implementation Overview**

#### **Phase 1: Data Structures**

```
Deque(T)
├── DequeStore (internal, heap-allocated)
│   ├── head: Atomic(i64) align(cache_line)  ← thieves increment via CAS
│   ├── _padding: [cache_line - 8]u8          ← prevents false sharing
│   ├── tail: Atomic(i64) align(cache_line)  ← owner increments/decrements
│   ├── buffer: []T                           ← ring buffer
│   ├── mask: usize                           ← capacity - 1 (for fast &)
│   └── allocator: Allocator
│
├── Worker (owner handle)
│   └── deque: *DequeStore
│
├── Stealer (thief handle, cloneable)
│   └── deque: *DequeStore
│
└── InitResult { worker, stealer }
```

#### **Phase 2: Core Operations**

| Operation | Thread | Ordering | CAS? | Latency |
|-----------|--------|----------|------|---------|
| `push()` | Owner only | release store | No | ~2-5ns |
| `pop()` (>1 item) | Owner only | seq_cst load/store | No | ~3-10ns |
| `pop()` (last item) | Owner only | seq_cst | Yes | ~10-30ns |
| `steal()` | Any thief | seq_cst CAS | Yes | ~20-50ns |

#### **Phase 3: Key Algorithms**

**push(item) - Owner Fast Path:**
1. Load tail (monotonic)
2. Load head (acquire) - see latest steals
3. If `tail - head >= capacity` → return error.Full
4. Write item to `buffer[tail & mask]`
5. Store `tail + 1` (release) - publish write

**pop() - Owner with Last-Item Race:**
1. Load tail (monotonic)
2. Decrement tail speculatively: `tail -= 1`
3. Store new tail (seq_cst)
4. Load head (seq_cst)
5. If `tail < head` → empty, restore tail, return null
6. Read item from `buffer[tail & mask]`
7. If `tail > head` → more items, return item
8. Else (last item) → restore tail, CAS head to claim
9. CAS success → return item; failure → return null

**steal() - Thief with Backoff:**
1. Load head (acquire)
2. Load tail (acquire)
3. If `head >= tail` → empty, return null
4. Read item from `buffer[head & mask]`
5. CAS head to `head + 1` (seq_cst)
6. CAS success → return item
7. CAS failure → backoff.snooze(), goto 1

#### **Phase 4: Flow Diagrams**

**Memory Layout (Cache-Line Isolation):**
```
┌─────────────────────────────────────────────────────────────────┐
│ Cache Line 0 (64 bytes)                                         │
│ ┌────────────┬─────────────────────────────────────────────────┐│
│ │ head: i64  │              _padding (56 bytes)                ││
│ │ (thieves)  │                                                 ││
│ └────────────┴─────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────────┘
┌─────────────────────────────────────────────────────────────────┐
│ Cache Line 1 (64 bytes)                                         │
│ ┌────────────┬──────────┬──────────┬───────────────────────────┐│
│ │ tail: i64  │ buffer:  │ mask:    │ allocator:                ││
│ │ (owner)    │ []T ptr  │ usize    │ Allocator                 ││
│ └────────────┴──────────┴──────────┴───────────────────────────┘│
└─────────────────────────────────────────────────────────────────┘
```

**Work-Stealing Pattern:**
```
       Owner Thread                    Thief Threads
            │                               │
    ┌───────▼───────┐              ┌────────▼────────┐
    │   push(task)  │              │    steal()      │
    │   ──────────  │              │    ────────     │
    │ tail++ (rel)  │              │ CAS head++ (sc) │
    └───────┬───────┘              └────────┬────────┘
            │                               │
            ▼                               ▼
    ┌───────────────────────────────────────────────┐
    │     [ ][ ][ ][A][B][C][D][ ][ ]               │
    │              ▲           ▲                    │
    │            head        tail                   │
    │         (thieves)    (owner)                  │
    └───────────────────────────────────────────────┘
            │                               │
    ┌───────▼───────┐              ┌────────▼────────┐
    │    pop()      │              │   return item   │
    │   ────────    │              │   (FIFO order)  │
    │ tail-- (LIFO) │              └─────────────────┘
    └───────────────┘
```

**Last-Item Race Resolution:**
```
    tail == head + 1 (exactly one item)
                │
                ▼
    ┌───────────────────────┐
    │ Owner restores tail   │
    │ BEFORE CAS attempt    │
    └───────────┬───────────┘
                │
                ▼
    ┌───────────────────────┐
    │ Owner: CAS head++     │◄────┐
    │ Thief: CAS head++     │     │ Race!
    └───────────┬───────────┘     │
                │                 │
        ┌───────┴───────┐         │
        ▼               ▼         │
    CAS wins        CAS loses ────┘
    return item     return null
```

---

### **Part 4: Verification & Testing Strategy**

**4.1. Unit Tests**
*   Init with valid power-of-two capacity.
*   Init rejects non-power-of-two capacity.
*   Basic push/pop LIFO ordering.
*   Push returns error.Full when at capacity.
*   Pop returns null on empty deque.
*   Basic steal from single item.
*   Steal returns null on empty deque.
*   Size/isEmpty helper accuracy.

**4.2. Integration Tests (Multi-Threaded)**
*   Single-item race: owner pop vs thief steal.
*   Multi-thief contention: N thieves stealing concurrently.
*   Wraparound correctness: push/pop through index overflow.
*   1M items stress test: verify no lost/duplicate items.
*   Owner-only throughput: push/pop without thieves.

**4.3. Benchmarks**
*   Owner push latency (single-threaded).
*   Owner pop latency (single-threaded).
*   Steal latency under various contention levels.
*   Throughput: owner + N thieves scaling.
*   Comparison: with/without cache-line padding.
