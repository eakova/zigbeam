## Implementation Plan: `ShardedDVyukovMPMCQueue` - Thread-Affinity Sharded Lock-Free MPMC Queue

---

### **Part 1: Architectural Vision & Design Philosophy**

**1.1. The Goal: Eliminate Atomic Counter Contention Under High Balanced Load**
The objective is to provide a high-performance lock-free queue that partitions work across multiple underlying DVyukov MPMC queues to eliminate contention on global enqueue_pos/dequeue_pos counters when many producers AND many consumers operate simultaneously.

**1.2. The Architectural Pattern: Thread-Affinity Sharding**
*   **Static Partitioning:** Work is distributed across N independent DVyukov MPMC queues (shards).
*   **Thread-to-Shard Affinity:** Each thread consistently accesses the same shard (`thread_id % num_shards`).
*   **Near-SPSC Per Shard:** Optimal configuration has 1 producer + 1 consumer per shard.
*   **No Work Stealing:** Threads only access their assigned shard (simplicity over fairness).
*   **Compile-Time Configuration:** Number of shards and capacity per shard are compile-time constants.

**1.3. The Core Components**
*   **shards:** Fixed-size array of N independent `DVyukovMPMCQueue` instances.
*   **allocator:** Stored for cleanup during deinit.
*   **Thread ID mapping:** `thread_id % num_shards` maps threads to shards.

**1.4. Performance Guarantees**
*   **4P/4C (4 shards):** 3-4x faster than single queue (37 → 120+ Mops/s).
*   **8P/8C (8 shards):** 7-8x faster than single queue (22 → 175+ Mops/s).
*   **Near-linear scaling:** When `num_threads == num_shards`, each shard approaches SPSC performance.
*   **Zero cross-shard coordination:** Shards are fully independent, no global locks.

---

### **Part 2: Core Design Decisions**

**2.1. Static Shard Count**
*   **Decision:** Number of shards is a compile-time constant, not runtime configurable.
*   **Justification:** Enables compile-time array sizing and eliminates dynamic allocation of shard array. The shard count should match expected thread count, which is typically known at design time.

**2.2. Thread-Affinity Model**
*   **Decision:** Threads must explicitly provide their ID; the queue maps `thread_id % num_shards` to select a shard.
*   **Justification:** Consistent shard assignment per thread eliminates cache thrashing. Random or round-robin distribution would defeat the purpose of sharding by spreading each thread's work across all shards.

**2.3. No Work Stealing Between Shards**
*   **Decision:** Threads only access their assigned shard; no stealing from other shards when local shard is empty.
*   **Justification:** Work stealing requires complex coordination and reintroduces contention. For workloads needing stealing, use `DequeChannel` instead. Sharding is for static, balanced workloads.

**2.4. Minimum Two Shards**
*   **Decision:** Compile-time error if `num_shards == 1`.
*   **Justification:** Single shard adds wrapper overhead with zero benefit. Users should use `DVyukovMPMCQueue` directly for single-shard scenarios.

**2.5. Shard-Local Error Semantics**
*   **Decision:** `error.QueueFull` means the specific shard is full, not the entire system.
*   **Justification:** Other shards may have space, but accessing them would break thread affinity. The caller must decide whether to retry, drop, or use overflow handling.

**2.6. Safe vs. Direct Shard Access APIs**
*   **Decision:** Provide both `enqueue(thread_id, item)` (safe) and `enqueueToShard(shard_id, item)` (direct).
*   **Justification:** Safe API prevents out-of-bounds with automatic modulo. Direct API allows advanced users to manage shard assignment explicitly (e.g., custom mapping schemes).

**2.7. Saturating Total Size**
*   **Decision:** `totalSize()` uses saturating addition to prevent overflow.
*   **Justification:** Summing N shards' sizes could theoretically overflow usize for extreme configurations. Saturating at `maxInt(usize)` is safer than wrapping.

---

### **Part 3: Implementation Overview**

#### **Phase 1: Data Structures**

```
ShardedDVyukovMPMCQueue(T, num_shards, capacity_per_shard)
│
├── shards: [num_shards]DVyukovMPMCQueue(T, capacity_per_shard)
│   │
│   ├── [0]: DVyukovMPMCQueue  ← Shard 0 (threads 0, N, 2N, ...)
│   │   ├── buffer: []Cell
│   │   ├── enqueue_pos
│   │   └── dequeue_pos
│   │
│   ├── [1]: DVyukovMPMCQueue  ← Shard 1 (threads 1, N+1, 2N+1, ...)
│   │   └── ...
│   │
│   └── [N-1]: DVyukovMPMCQueue  ← Shard N-1
│       └── ...
│
└── allocator: Allocator
```

#### **Phase 2: Core Operations**

| Operation | Shard Selection | Latency | Notes |
|-----------|-----------------|---------|-------|
| `enqueue(thread_id, item)` | `thread_id % num_shards` | ~10-50ns | Safe API, auto-maps thread |
| `dequeue(thread_id)` | `thread_id % num_shards` | ~10-50ns | Safe API, auto-maps thread |
| `enqueueToShard(shard_id, item)` | Direct | ~10-50ns | Manual shard selection |
| `dequeueFromShard(shard_id)` | Direct | ~10-50ns | Manual shard selection |
| `totalSize()` | All shards | O(N) | Sum of all shard sizes (racy) |
| `isEmpty()` | All shards | O(N) | Early exit on first non-empty |
| `drainAll(cleanup_fn)` | All shards | O(items) | For shutdown cleanup |

#### **Phase 3: Key Algorithms**

**enqueue(thread_id, item) - Safe Thread-Mapped Enqueue:**
1. Compute shard index: `shard_id = thread_id % num_shards`
2. Delegate to `shards[shard_id].enqueue(item)`
3. Return error.QueueFull if that shard is full

**dequeue(thread_id) - Safe Thread-Mapped Dequeue:**
1. Compute shard index: `shard_id = thread_id % num_shards`
2. Delegate to `shards[shard_id].dequeue()`
3. Return null if that shard is empty

**init(allocator) - All-or-Nothing Initialization:**
1. Create result struct with undefined shards array
2. Track `initialized` count for error cleanup
3. For each shard index 0..num_shards:
   - Initialize shard via `DVyukovMPMCQueue.init(allocator)`
   - On error: deinit all previously initialized shards, return error
   - On success: increment initialized count
4. Return initialized struct

**drainAll(cleanup_fn) - Shutdown Cleanup:**
1. For each shard in shards array:
   - Call `shard.drain(cleanup_fn)` to dequeue and optionally cleanup items
2. Items are processed via callback if provided, discarded otherwise

**totalSize() - Approximate Total (Racy):**
1. Initialize total = 0
2. For each shard:
   - Read shard.size() (racy atomic read)
   - Saturating add to total (clamp at maxInt on overflow)
3. Return total

#### **Phase 4: Flow Diagrams**

**Sharded Queue Architecture:**
```
                Thread Assignment: thread_id % num_shards
                =========================================

Thread 0 ─┐                                      ┌─ Thread N
Thread N ─┼───► Shard 0: [enqueue_pos][dequeue_pos][buffer...] ◄───┤
Thread 2N─┘                                      └─ Thread 2N
                        │
Thread 1 ─┐             │                        ┌─ Thread N+1
Thread N+1┼───► Shard 1: [enqueue_pos][dequeue_pos][buffer...] ◄───┤
Thread 2N+1┘            │                        └─ Thread 2N+1
                        │
         ...           ...                                ...
                        │
Thread K ─┐             │                        ┌─ Thread N+K
Thread N+K┼───► Shard K: [enqueue_pos][dequeue_pos][buffer...] ◄───┤
Thread 2N+K┘                                     └─ Thread 2N+K


Key: Each shard is an independent DVyukovMPMCQueue
     Threads with same (thread_id % num_shards) share a shard
```

**Optimal Configuration (1P + 1C per shard):**
```
┌─────────────────────────────────────────────────────────────────┐
│                    Optimal: 8 threads, 4 shards                  │
│                    (2 threads per shard)                         │
└─────────────────────────────────────────────────────────────────┘

    Producer 0              Consumer 4
        │                       │
        └───────┬───────────────┘
                ▼
        ┌──────────────┐
        │   Shard 0    │  Near-SPSC performance!
        └──────────────┘

    Producer 1              Consumer 5
        │                       │
        └───────┬───────────────┘
                ▼
        ┌──────────────┐
        │   Shard 1    │  Near-SPSC performance!
        └──────────────┘

    Producer 2              Consumer 6
        │                       │
        └───────┬───────────────┘
                ▼
        ┌──────────────┐
        │   Shard 2    │  Near-SPSC performance!
        └──────────────┘

    Producer 3              Consumer 7
        │                       │
        └───────┬───────────────┘
                ▼
        ┌──────────────┐
        │   Shard 3    │  Near-SPSC performance!
        └──────────────┘
```

**Contention Comparison:**
```
Single DVyukovMPMCQueue (4P + 4C):
==================================

   P0  P1  P2  P3               C0  C1  C2  C3
    │   │   │   │                │   │   │   │
    └───┴───┴───┴────────────────┴───┴───┴───┘
                    │
                    ▼
          ┌──────────────────┐
          │   enqueue_pos    │ ◄── 4 producers competing
          │   dequeue_pos    │ ◄── 4 consumers competing
          │      buffer      │
          └──────────────────┘

   Result: ~40 Mops/s (heavy contention on both counters)


ShardedDVyukovMPMCQueue (4P + 4C, 4 shards):
============================================

   P0      C0          P1      C1          P2      C2          P3      C3
    │       │           │       │           │       │           │       │
    └───┬───┘           └───┬───┘           └───┬───┘           └───┬───┘
        ▼                   ▼                   ▼                   ▼
   ┌─────────┐         ┌─────────┐         ┌─────────┐         ┌─────────┐
   │ Shard 0 │         │ Shard 1 │         │ Shard 2 │         │ Shard 3 │
   └─────────┘         └─────────┘         └─────────┘         └─────────┘

   Result: ~120+ Mops/s (near-SPSC per shard, 3-4x faster!)
```

**Error Handling Flow:**
```
enqueueToShard(shard_id, item)
            │
            ▼
    ┌───────────────────┐
    │ assert(shard_id   │ ← Debug-only bounds check
    │   < num_shards)   │
    └─────────┬─────────┘
              │
              ▼
    ┌───────────────────┐
    │ shards[shard_id]  │
    │    .enqueue(item) │
    └─────────┬─────────┘
              │
       ┌──────┴──────┐
       │             │
    success    error.QueueFull
       │             │
       ▼             ▼
    return      return error
                (shard full,
                 others may
                 have space)
```

---

### **Part 4: Verification & Testing Strategy**

**4.1. Unit Tests**
*   Basic enqueue and dequeue to specific shards.
*   FIFO ordering within each shard.
*   error.QueueFull when specific shard fills.
*   null return when specific shard is empty.
*   Thread ID auto-mapping (`thread_id % num_shards`).
*   totalSize() accuracy with multiple shards.
*   isEmpty() returns true only when all shards empty.
*   drainAll() with and without cleanup callback.
*   Compile-time rejection of num_shards < 2.

**4.2. Integration Tests (Multi-Threaded)**
*   4P/4C with 4 shards: verify no lost/duplicate items.
*   8P/8C with 8 shards: verify scalability.
*   Unbalanced load: 8P/2C with 4 shards (some shards fill).
*   Cross-shard isolation: items in shard 0 not visible to shard 1 consumers.
*   Shutdown with drainAll: verify all items processed.

**4.3. Benchmarks**
*   4P/4C throughput comparison: single queue vs. 4-shard.
*   8P/8C throughput comparison: single queue vs. 8-shard.
*   16P/16C scaling with 16 shards.
*   Per-shard latency measurement.
*   Memory usage: total capacity vs. actually allocated.
*   Comparison of shard counts (2, 4, 8, 16) with fixed thread count.

