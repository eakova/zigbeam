## Implementation Plan: `ArcPool<T>` - High-Performance Memory Pool for Arc Allocations

---

### **Part 1: Architectural Vision & Design Philosophy**

**1.1. The Goal: Reduce Allocator Pressure Under High Concurrency**
The objective is to provide a memory pool that recycles `Arc::Inner` allocations, significantly reducing allocator calls and contention in high-throughput concurrent scenarios. This is critical for workloads with frequent Arc creation/destruction cycles.

**1.2. The Architectural Pattern: Three-Tier Caching**
*   **L1 - Thread-Local Cache:** Per-thread array of `*Inner` pointers for zero-contention fast path.
*   **L2 - Sharded Freelists:** Global lock-free Treiber stacks, sharded by CPU count to reduce CAS contention.
*   **L3 - Allocator Fallback:** Mutex-protected system allocator for fresh allocations.

**1.3. The Core Components**
*   **ArcPool<T, EnableStats>:** The main pool struct managing tiered caches.
*   **ThreadLocalCache:** Per-thread L1 cache (from beam-thread-local-cache).
*   **Sharded Freelists:** Array of atomic Treiber stack heads for L2.

**1.4. Performance Guarantees**
*   **Lock-Free Fast Path:** L1 and L2 operations are lock-free.
*   **Bounded TLS Retention:** Configurable capacity prevents excessive per-thread memory hoarding.
*   **Batched L2 Pushes:** Reduces CAS contention by pushing multiple nodes at once.

---

### **Part 2: Core Design Decisions**

**2.1. Trivially Destructible T Requirement**
*   **Decision:** ArcPool only accepts types without `deinit` methods (compile-time check).
*   **Justification:** `recycle()` does not call `T.deinit()`. Types with cleanup requirements would leak resources when recycled.

**2.2. Sharded Freelists**
*   **Decision:** 8-32 shards (next power-of-two of CPU count), each a Treiber stack.
*   **Justification:** Sharding distributes CAS contention across multiple atomic variables. Power-of-two enables fast modulo via bitwise AND.

**2.3. Dynamic TLS Capacity**
*   **Decision:** TLS capacity (8-32) chosen based on `@sizeOf(Inner)` and shard count.
*   **Justification:** Smaller Inner blocks can afford larger TLS caches. More shards allow larger TLS without risking global starvation.

**2.4. Batched Freelist Pushes**
*   **Decision:** Buffer nodes in TLS flush buffer, push as a linked chain with single CAS.
*   **Justification:** Reduces L2 CAS operations from N to 1 when returning multiple nodes.

**2.5. Shard Selection Strategy**
*   **Decision:** XOR of pool address and TLS cache address, masked by shard count.
*   **Justification:** Combines per-pool and per-thread entropy for even distribution without requiring thread IDs.

**2.6. Mutex-Protected L3**
*   **Decision:** Fresh allocations go through a mutex-protected allocator call.
*   **Justification:** Ensures safety with non-thread-safe allocators (e.g., ArenaAllocator). L3 is the cold path, so mutex cost is acceptable.

**2.7. Optional Statistics**
*   **Decision:** `EnableStats` comptime parameter controls counter updates.
*   **Justification:** Statistics (allocs, reuses, TLS hits/misses) are useful for tuning but add atomic overhead. Disabled by default.

**2.8. Pool Warm-Up**
*   **Decision:** `init()` pre-creates and recycles 2 nodes.
*   **Justification:** Seeds L2 freelist to smooth initial burst allocations.

---

### **Part 3: Implementation Overview**

#### **Phase 1: Data Structures**

```
ArcPool<T, EnableStats>
├── freelists: [MAX_SHARDS]Atomic(?*Inner)  (L2 sharded Treiber stacks)
├── active_shards: usize                     (actual shard count used)
├── tls_active_capacity: usize               (effective TLS size)
├── flush_batch: usize                       (batch size for L2 push)
├── allocator: Allocator                     (L3 fallback)
├── alloc_mutex: Mutex                       (protects L3)
└── stats_*: PaddedCounter                   (optional, cache-line aligned)

threadlocal tls_cache: ThreadLocalCache(*Inner)
threadlocal tls_flush: FlushBuf              (batch buffer for L2)

Inner (from Arc<T>)
├── counters: { strong_count, weak_count }
├── data: T
├── allocator: Allocator
└── next_in_freelist: ?*Inner                (intrusive list pointer)
```

#### **Phase 2: Core Operations**

| Operation | L1 (TLS) | L2 (Sharded) | L3 (Allocator) |
|-----------|----------|--------------|----------------|
| `create()` | Pop from tls_cache | Pop from shard (round-robin steal) | Mutex + allocator.create |
| `recycle()` | Push to tls_cache | Batch-push to shard | N/A |
| Contention | Zero | Low (sharded CAS) | Mutex serialized |
| Latency | ~5ns | ~20-50ns | ~100ns+ |

#### **Phase 3: Key Algorithms**

*   **`create(value)` - Tiered Allocation:**
    1. Try `tls_cache.pop()` → if hit, reinitialize and return
    2. Try `popBatchOne(shard)` from L2 → if hit, reinitialize and return
    3. If L2 empty, round-robin steal from other shards
    4. Lock mutex, call `Arc<T>.init(allocator, value)`

*   **`recycle(arc)` - Tiered Return:**
    1. If SVO arc, return (not pooled)
    2. Reset counters to 0
    3. If `tls_cache.count < tls_active_capacity`: push to TLS
    4. Else: add to `tls_flush` buffer
    5. If buffer near full: link nodes into chain, push to shard with single CAS

*   **`popBatchOne(shard)` - L2 Pop with Stealing:**
    1. Try Treiber pop from `shard`
    2. If empty, try next shard (round-robin)
    3. Repeat up to `active_shards` attempts
    4. Return node or null

*   **`pushChain(shard, head, tail)` - Batched L2 Push:**
    1. Load current head of freelist
    2. Set `tail.next = current_head`
    3. CAS freelist head from current to new head
    4. Retry on CAS failure

#### **Phase 4: Flow Diagrams**

**create() Flow:**
```
  create(value)
       │
       v
  ┌─────────────┐
  │ TLS cache   │──hit──> reinit node ──> [Arc<T>]
  │ pop()       │
  └──────┬──────┘
         │miss
         v
  ┌─────────────┐
  │ L2 shard    │──hit──> reinit node ──> [Arc<T>]
  │ pop + steal │
  └──────┬──────┘
         │miss (all shards empty)
         v
  ┌─────────────┐
  │ L3 mutex +  │
  │ allocator   │──────> [Arc<T>]
  └─────────────┘
```

**recycle() Flow:**
```
  recycle(arc)
       │
       v
  ┌─────────────┐
  │ SVO check   │──yes──> return (no-op)
  └──────┬──────┘
         │no (heap arc)
         v
  ┌─────────────┐
  │ reset       │
  │ counters    │
  └──────┬──────┘
         │
         v
  ┌─────────────┐
  │ TLS cache   │──space──> push ──> done
  │ has space?  │
  └──────┬──────┘
         │full
         v
  ┌─────────────┐
  │ flush buffer│──not full──> buffer node ──> done
  │ has space?  │
  └──────┬──────┘
         │near full
         v
  ┌─────────────┐
  │ link chain  │
  │ CAS push L2 │──> done
  └─────────────┘
```

**Sharded L2 Architecture:**
```
  Pool
    │
    ├──> Shard 0: [head] -> Inner -> Inner -> null
    ├──> Shard 1: [head] -> Inner -> null
    ├──> Shard 2: [head] -> null (empty)
    ├──> ...
    └──> Shard N: [head] -> Inner -> Inner -> Inner -> null

  Thread A (shard = hash(pool, tls) & mask)
       │
       v
    Shard 2 ──empty──> steal from Shard 3, 4, 5...
```

---

### **Part 4: Verification & Testing Strategy**

**4.1. Unit Tests**
*   **Tier transitions:** Verify L1 → L2 → L3 fallback behavior.
*   **Shard distribution:** Check nodes spread across shards.
*   **Capacity limits:** Confirm TLS respects `tls_active_capacity`.
*   **Compile-time check:** Verify `deinit` types rejected.

**4.2. Integration Tests**
*   **Multi-threaded stress:** 8+ threads, high-churn create/recycle.
*   **TLS isolation:** Verify no cross-thread contamination.
*   **Drain correctness:** `drainThreadCache()` returns all nodes to L2.
*   **Pool deinit:** All nodes freed, no leaks.

**4.3. Benchmarks**
*   **L1 hit rate:** Measure TLS cache effectiveness.
*   **L2 contention:** Compare sharded vs single freelist.
*   **Pool vs Direct:** Throughput comparison with raw `Arc.init/release`.
*   **Scaling:** Measure throughput at 1, 4, 8, 16 threads.
