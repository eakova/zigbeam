## Implementation Plan: `DequeChannel` - High-Performance MPMC Channel with Work-Stealing

---

### **Part 1: Architectural Vision & Design Philosophy**

**1.1. The Goal: Scalable Multi-Producer Multi-Consumer Communication**
The objective is to provide a bounded MPMC channel that combines the benefits of local deques (low contention) with a shared global queue (overflow safety) and work-stealing (automatic load balancing).

**1.2. The Architectural Pattern: Three-Tier Work Distribution**
*   **Local Deques (Fast Path):** Each worker has a private bounded Deque for zero-contention send/recv.
*   **Global Queue (Safety Valve):** Shared DVyukovMPMCQueue absorbs overflow when local deques fill.
*   **Work-Stealing (Load Balancer):** Idle workers steal from busy workers' deques.
*   **Bounded with Back-Pressure:** Returns `error.Full` when system is saturated.

**1.3. The Core Components**
*   **DequeChannel:** Main struct holding stealers array, global queue, allocator.
*   **Worker:** Per-thread handle with local Deque, worker ID, RNG, channel reference.
*   **PaddedStealer:** Cache-line padded Stealer handle to prevent false sharing.
*   **InitResult:** Contains channel pointer and workers array.

**1.4. Performance Guarantees**
*   **Send Fast Path:** ~5-15ns (local deque push, zero contention).
*   **Send Slow Path:** ~50-100ns (batch offload to global queue).
*   **Recv Priority 1:** ~5-15ns (local pop, LIFO cache locality).
*   **Recv Priority 2:** ~30-60ns (global dequeue, FIFO).
*   **Recv Priority 3:** ~40-80ns (work-stealing, random victim).

---

### **Part 2: Core Design Decisions**

**2.1. Local-First Architecture**
*   **Decision:** Each worker sends to its own local deque first, only using global queue on overflow.
*   **Justification:** Eliminates contention in the common case. Workers operating on their own data hit the fast path 100% of the time.

**2.2. Batch Offload Strategy**
*   **Decision:** When local deque is full, offload 50% of items to global queue before retrying.
*   **Justification:** Amortizes the cost of global queue access. Creates headroom for future sends without repeated offloads.

**2.3. Three-Tier Recv Priority**
*   **Decision:** recv() checks local → global → steal, in that order.
*   **Justification:** Maximizes cache locality (local LIFO), fairness (global FIFO), then load balancing (steal).

**2.4. Random Victim Selection**
*   **Decision:** Work-stealing picks random victims (excluding self) with per-worker RNG.
*   **Justification:** Distributes stealing load evenly. Deterministic RNG seeded by worker_id ensures reproducibility for testing.

**2.5. Cache-Line Padded Stealers**
*   **Decision:** Stealer handles are padded to cache line size in the stealers array.
*   **Justification:** Prevents false sharing when multiple thieves access adjacent stealer entries.

**2.6. Adaptive Steal Backoff**
*   **Decision:** Spin-loop hint backoff between steal attempts, scaling with attempt number and worker count.
*   **Justification:** Reduces cache coherency traffic under high contention while keeping latency low when work is available.

**2.7. Explicit Worker Handles**
*   **Decision:** No thread-local storage; worker context passed explicitly via Worker struct.
*   **Justification:** Enables flexible thread-to-worker mapping, easier testing, and no hidden global state.

---

### **Part 3: Implementation Overview**

#### **Phase 1: Data Structures**

```
DequeChannel(T, local_cap, global_cap)
│
├── local_stealers: []PaddedStealer
│   └── [i]: PaddedStealer
│       ├── stealer: Deque(T).Stealer  ← for work-stealing
│       └── _padding: [cache_line - sizeof(Stealer)]u8
│
├── global_queue: *DVyukovMPMCQueue(T)  ← overflow + shared work
│
└── allocator: Allocator

Worker (per-thread handle)
├── deque_worker: Deque(T).Worker  ← local push/pop
├── worker_id: usize
├── rng: DefaultPrng              ← for random victim selection
└── channel: *DequeChannel        ← back-reference
```

#### **Phase 2: Core Operations**

| Operation | Path | Latency | Contention | Notes |
|-----------|------|---------|------------|-------|
| `send()` fast | Local push | ~5-15ns | None | Owner-only access |
| `send()` slow | Offload + retry | ~50-100ns | Global queue | Batch offload 50% |
| `recv()` P1 | Local pop | ~5-15ns | None | LIFO, cache-friendly |
| `recv()` P2 | Global dequeue | ~30-60ns | All workers | FIFO fairness |
| `recv()` P3 | Steal | ~40-80ns | Per-victim | Random victim, N attempts |

#### **Phase 3: Key Algorithms**

**send(item) - Fast Path with Offload Fallback:**
1. Try `local_deque.push(item)`
2. If success → return
3. If error.Full → call `handleOffload()`
4. Offload: Pop up to 50% items from local deque
5. Enqueue each to global queue
6. If global queue full → push item back, return error.Full
7. Retry original push

**recv() - Three-Tier Priority:**
1. Try `local_deque.pop()` → if success, return item
2. Try `global_queue.dequeue()` → if success, return item
3. For attempt in 0..num_workers:
   - Pick random victim (excluding self)
   - Try `victim.stealer.steal()` → if success, return item
   - Adaptive backoff (spin loop hints)
4. Return null

**Random Victim Selection (excluding self):**
1. Generate random in [0, num_workers-1]
2. If random >= worker_id → random += 1
3. Steal from stealers[random]

#### **Phase 4: Flow Diagrams**

**Channel Architecture:**
```
              Worker 0              Worker 1              Worker N
                 │                     │                     │
          ┌──────▼──────┐       ┌──────▼──────┐       ┌──────▼──────┐
          │ Local Deque │       │ Local Deque │       │ Local Deque │
          │   [items]   │       │   [items]   │       │   [items]   │
          └──────┬──────┘       └──────┬──────┘       └──────┬──────┘
                 │                     │                     │
                 │◄────── steal ───────┼─────── steal ──────►│
                 │                     │                     │
                 └─────────────────────┼─────────────────────┘
                                       │
                              ┌────────▼────────┐
                              │  Global Queue   │
                              │  (overflow +    │
                              │   shared work)  │
                              └─────────────────┘
```

**send() Flow:**
```
send(item)
    │
    ▼
┌───────────────────┐
│ local.push(item)  │
└─────────┬─────────┘
          │
    ┌─────┴─────┐
    │           │
  success    error.Full
    │           │
    ▼           ▼
  return   ┌────────────────────┐
           │ Offload 50% to     │
           │ global queue       │
           └─────────┬──────────┘
                     │
               ┌─────┴─────┐
               │           │
           success    global full
               │           │
               ▼           ▼
          retry push   error.Full
```

**recv() Flow:**
```
recv()
    │
    ▼
┌───────────────────┐
│ 1. local.pop()    │──── success ────► return item
└─────────┬─────────┘
          │ null
          ▼
┌───────────────────┐
│ 2. global.dequeue │──── success ────► return item
└─────────┬─────────┘
          │ null
          ▼
┌───────────────────┐
│ 3. for N attempts:│
│   pick random     │
│   victim.steal()  │──── success ────► return item
│   backoff         │
└─────────┬─────────┘
          │ all failed
          ▼
      return null
```

**Work-Stealing Load Balancing:**
```
    Busy Worker              Idle Worker
    (producing)              (consuming)
         │                        │
    ┌────▼────┐              ┌────▼────┐
    │ push()  │              │ pop()   │ ← empty
    │ push()  │              │         │
    │ push()  │              │ global? │ ← empty
    └────┬────┘              │         │
         │                   │ steal() │───────┐
    [A][B][C][D][E]          └─────────┘       │
     ▲           ▲                             │
   head        tail                            │
     │                                         │
     └─────────────────────────────────────────┘
            steals [A] (FIFO from victim)
```

---

### **Part 4: Verification & Testing Strategy**

**4.1. Unit Tests**
*   Basic send and recv (single worker).
*   LIFO ordering from local deque.
*   Overflow to global queue when local fills.
*   Back-pressure returns error.Full when system saturated.
*   No self-stealing (single worker returns null after local empty).

**4.2. Integration Tests (Multi-Threaded)**
*   Work-stealing between workers.
*   8P/8C stress test (1M items, verify no lost/duplicate).
*   1P/8C load balancing (verify even distribution).
*   Recv priority ordering (local → global → steal).

**4.3. Benchmarks**
*   Single-threaded send/recv throughput.
*   4P/4C throughput.
*   8P/8C throughput.
*   1P/8C load balancing latency.
*   Work-stealing overhead under imbalanced load.
*   Producer-consumer pattern (each worker is both).
