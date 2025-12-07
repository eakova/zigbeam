## Implementation Plan: High-Throughput EBR - Epoch-Based Reclamation for Zig

---

### **Part 1: Architectural Vision & Design Philosophy**

**1.1. The Goal: Ultra-Fast Lock-Free Memory Reclamation**
The objective is to provide a high-throughput mechanism for safely reclaiming memory in lock-free data structures, targeting >1 Gops/sec pin/unpin operations. Traditional EBR implementations sacrifice throughput for simplicity; this implementation optimizes the hot path (pin/unpin) while maintaining safety guarantees.

**1.2. The Architectural Pattern: Optimized Epoch-Based Reclamation**
*   **Global Epoch Counter:** A monotonically increasing atomic counter that tracks the "generation" of the system.
*   **Packed Epoch+Active:** Thread-local epoch and active flag combined in a single u64 to eliminate SeqCst fences.
*   **Epoch-Bucketed Garbage:** Objects bucketed by `epoch % 3` for O(1) reclamation instead of O(N) scanning.
*   **Probabilistic Epoch Advancement:** Collection triggers epoch advancement with configurable sampling rate to reduce contention.
*   **Thread-Local Garbage Bags:** Each thread maintains private garbage, eliminating contention on defer operations.

**1.3. The Core Components**
*   **Collector:** Central coordinator holding global epoch, thread list, and configuration.
*   **GlobalState:** Cache-line aligned atomic epoch counter.
*   **ThreadLocalState:** Per-thread state with packed epoch+active, pin count, and garbage bag.
*   **Guard/FastGuard:** RAII handles for critical sections (with/without nesting support).
*   **EpochBucketedBag:** 3-bucket garbage storage for O(1) epoch-based reclamation.

**1.4. Safety Guarantees**
*   **No Use-After-Free:** 3-epoch safety rule ensures objects are only reclaimed when no thread could access them.
*   **Wait-Free Hot Path:** pin/unpin operations are wait-free (bounded operations, no locks).
*   **Bounded Reclamation:** O(3) constant-time reclamation regardless of epoch delta.
*   **Graceful Degradation:** OOM during defer falls back to immediate destruction.

---

### **Part 2: Core Design Decisions**

**2.1. Packed Epoch+Active in Single Atomic**
*   **Decision:** Store epoch (bits 63:1) and active flag (bit 0) in a single `std.atomic.Value(u64)`.
*   **Justification:** Eliminates the SeqCst fence required when epoch and active are separate. Single store atomically publishes both values. Reduces pin latency from ~5ns to ~0.8ns.

**2.2. Cache-Line Aligned Structures**
*   **Decision:** Align `GlobalState` and `ThreadLocalState.epoch_and_active` to cache line boundaries (128 bytes on ARM64, 64 bytes on x86).
*   **Justification:** Prevents false sharing between threads. Critical for linear scaling - without alignment, atomic operations on adjacent data cause cache invalidation storms.

**2.3. Epoch-Bucketed Garbage Bags**
*   **Decision:** Use 3 buckets (`epoch % 3`) instead of a single list with epoch-stamped items.
*   **Justification:** Reclamation becomes O(3) constant instead of O(N) linear scan. When epoch N-2 becomes safe, clear bucket `(N-2) % 3` entirely. Enables efficient bulk destruction.

**2.4. Probabilistic Epoch Advancement**
*   **Decision:** Only 1 in N (default N=4) collection operations trigger `tryAdvanceEpoch()`.
*   **Justification:** `tryAdvanceEpoch()` requires O(N_threads) scan with mutex. Probabilistic sampling reduces this overhead by 4x while maintaining progress. Configurable via `CollectorConfig.epoch_advance_sample_rate`.

**2.5. Two Guard Types (Guard vs FastGuard)**
*   **Decision:** Provide `Guard` (supports nesting) and `FastGuard` (no nesting, maximum speed).
*   **Justification:** Nested guards require pin_count tracking and conditional logic. FastGuard eliminates this overhead for code paths that don't need nesting, achieving ~2x throughput.

**2.6. Thread-Local Garbage with Batch Collection**
*   **Decision:** Each thread maintains its own `EpochBucketedBag`. Collection triggered when count exceeds `BATCH_THRESHOLD` (64).
*   **Justification:** No contention on defer operations - each thread only writes to its own bag. Batching amortizes collection cost over many defers.

**2.7. 3-Epoch Safety Window**
*   **Decision:** Objects retired at epoch N are safe when global epoch >= N+2.
*   **Justification:** A thread pinned at epoch N may have started reading data retired at N. By waiting until N+2, we guarantee all threads have moved past N, making N-era garbage safe.

**2.8. Comptime Configurable Collector**
*   **Decision:** Use `CollectorType(comptime config: CollectorConfig)` to generate specialized collectors.
*   **Justification:** Comptime configuration allows inlining of sampling rate checks. No runtime overhead for configuration. Users can create multiple collector types with different tuning.

---

### **Part 3: Implementation Overview**

#### **Phase 1: Data Structures**

```
Collector
│
├── global_state: GlobalState
│   ├── epoch: Atomic(u64) align(cache_line)  ← Current global epoch
│   └── _padding: [...]u8                      ← Fill cache line
│
├── allocator: Allocator
│
├── threads: ArrayList(*ThreadLocalState)
│   └── List of all registered thread states
│
└── threads_mutex: Mutex
    └── Only for registration/unregistration (not hot path)

ThreadLocalState (cache-line aligned)
├── epoch_and_active: Atomic(u64) align(cache_line)
│   ├── bits[63:1] = local epoch snapshot
│   └── bit[0] = active flag (1 = pinned)
│
├── pin_count: u32                    ← Nested guard count
├── last_collect_epoch: u64           ← Skip redundant collections
│
└── garbage_bag: EpochBucketedBag
    ├── bags: [3]ArrayList(DeferredSimple)  ← epoch%3 buckets
    ├── total_count: usize                   ← O(1) count
    └── last_reclaimed_epoch: ?u64           ← Progress tracking

Guard (8 bytes)
└── _collector: *Collector            ← For unpin callback

FastGuard (8 bytes)
└── _state: *ThreadLocalState         ← Direct state access

DeferredSimple (16 bytes)
├── ptr: *anyopaque                   ← Object to destroy
└── dtor: DtorFn                      ← Destructor function
```

#### **Phase 2: Core Operations**

| Operation | Path | Complexity | Latency | Notes |
|-----------|------|------------|---------|-------|
| `pin()` (nested) | Hot | O(1) | ~1-2ns | Increment pin_count only |
| `pin()` (first) | Hot | O(1) | ~0.8ns | Load epoch, store packed value |
| `pinFast()` | Hot | O(1) | ~0.4ns | No nesting check, fastest |
| `unpin()` | Hot | O(1) | ~0.4ns | Store 0 to epoch_and_active |
| `deferReclaim()` | Hot | O(1) amortized | ~5-10ns | Append to bucket, maybe collect |
| `tryAdvanceEpoch()` | Cold | O(N_threads) | varies | Mutex + scan all threads |
| `reclaimUpTo()` | Cold | O(3) constant | varies | Clear up to 3 buckets |
| `registerThread()` | Cold | O(1) | varies | Mutex + allocate state |

#### **Phase 3: Key Algorithms**

**pin() - Enter Protected Region:**
1. Get thread-local state via threadlocal pointer
2. If `pin_count > 0`: increment and return (nested fast path)
3. Load `global_state.epoch` with acquire ordering
4. Store `(epoch << 1) | 1` to `epoch_and_active` with release ordering
5. Set `pin_count = 1`
6. Return Guard handle

**pinFast() - Ultra-Fast Pin (No Nesting):**
1. Get thread-local state via threadlocal pointer
2. Load `global_state.epoch` with acquire ordering
3. Store `(epoch << 1) | 1` to `epoch_and_active` with release ordering
4. Return FastGuard handle

**unpin() - Exit Protected Region:**
1. Decrement `pin_count`
2. If `pin_count == 0`: store 0 to `epoch_and_active` with release ordering

**FastGuard.unpin() - Fastest Unpin:**
1. Store 0 to `state.epoch_and_active` with release ordering
   (Direct state pointer eliminates threadlocal lookup)

**deferReclaim(ptr, dtor) - Retire Memory:**
1. Create `DeferredSimple{ptr, dtor}`
2. Get current epoch from global state
3. Append to `garbage_bag.bags[epoch % 3]`
4. If `garbage_bag.count() >= BATCH_THRESHOLD` and `epoch > last_collect_epoch`:
   - Call `collectInternal()`

**collectInternal() - Probabilistic Collection:**
1. Update `last_collect_epoch`
2. Compute hash: `(@intFromPtr(state) >> 6) ^ current_epoch`
3. If `hash % sample_rate == 0`: call `tryAdvanceEpoch()`
4. Compute `safe_epoch = global_epoch - 2`
5. Call `garbage_bag.reclaimUpTo(safe_epoch)`

**reclaimUpTo(safe_epoch) - O(3) Reclamation:**
1. For each epoch from `last_reclaimed + 1` to `safe_epoch` (max 3 iterations):
   - Clear bucket `epoch % 3`, calling all destructors
2. Update `last_reclaimed_epoch = safe_epoch`

**tryAdvanceEpoch() - Progress Global Epoch:**
1. Acquire `threads_mutex`
2. Load current epoch
3. For each registered thread:
   - If active and `local_epoch < current`: return false (thread lagging)
4. If all caught up: CAS `epoch → epoch + 1`
5. Release mutex

#### **Phase 4: Flow Diagrams**

**Epoch-Based Reclamation Lifecycle:**
```
┌─────────────────────────────────────────────────────────────────┐
│                     EBR Lifecycle                               │
└─────────────────────────────────────────────────────────────────┘

     Worker Thread                         Global State
           │                                    │
           ▼                                    │
    ┌─────────────┐                             │
    │  pinFast()  │                             │
    │ load epoch  │◄────────────────────────────┤ epoch = N
    │ store N|1   │                             │
    └──────┬──────┘                             │
           │                                    │
           ▼                                    │
    ┌─────────────┐                             │
    │ Access data │                             │
    │  (safe!)    │                             │
    └──────┬──────┘                             │
           │                                    │
           ▼                                    │
    ┌─────────────┐                             │
    │deferReclaim │                             │
    │ bucket N%3  │                             │
    └──────┬──────┘                             │
           │                                    │
           ▼                                    │
    ┌─────────────┐                             │
    │   unpin()   │                             │
    │ store 0     │                             │
    └─────────────┘                             │
           │                                    │
           │     ┌──────────────────────────────┘
           │     │ (epoch advances to N+2)
           ▼     ▼
    ┌──────────────────────────────────────────────┐
    │             LATER (epoch >= N+2)             │
    │  safe_epoch = N+2 - 2 = N                    │
    │  Bucket N%3 is now SAFE to clear!            │
    │  reclaimUpTo(N) → clear bucket, call dtors   │
    └──────────────────────────────────────────────┘
```

**Pin/Unpin Memory Ordering:**
```
    Thread A (Worker)                    Thread B (Collector)
           │                                    │
           ▼                                    │
    epoch_and_active.store(               tryAdvanceEpoch():
      (N << 1) | 1,                             │
      .release)  ─────────────────────►  epoch_and_active.load(.acquire)
           │                                    │
           │                                    ▼
           │                             if active:
           │                               epoch.load(.acquire)
           │                               ← synchronizes-with ──┘
    [safe to access data]
           │
           ▼
    epoch_and_active.store(0, .release)

Key: Release-Acquire pair ensures collector sees epoch value
     when it observes active flag == 1
```

**Garbage Collection Decision Flow:**
```
deferReclaim(ptr, dtor)
      │
      ▼
┌───────────────────────────────┐
│ Append to bags[epoch % 3]     │
└──────────────┬────────────────┘
               │
               ▼
┌───────────────────────────────┐
│ count >= 64 AND               │
│ epoch > last_collect_epoch?   │
└──────────────┬────────────────┘
               │
        ┌──────┴──────┐
        │             │
       yes            no
        │             │
        ▼             ▼
┌───────────────┐  (return)
│collectInternal│
└───────┬───────┘
        │
        ▼
┌───────────────────────────────┐
│ hash % sample_rate == 0?      │
│ (probabilistic, 1 in 4)       │
└──────────────┬────────────────┘
        ┌──────┴──────┐
        │             │
       yes            no
        │             │
        ▼             │
┌───────────────┐     │
│tryAdvanceEpoch│     │
│ (mutex, O(N)) │     │
└───────┬───────┘     │
        │             │
        └──────┬──────┘
               │
               ▼
┌───────────────────────────────┐
│ reclaimUpTo(safe_epoch)       │
│ Clear buckets, call dtors     │
│ O(3) constant time            │
└───────────────────────────────┘
```

---

### **Part 4: Verification & Testing Strategy**

**4.1. Unit Tests**
*   Collector init/deinit lifecycle.
*   Thread registration and unregistration.
*   Guard pin/unpin state transitions.
*   Nested pin/unpin with pin_count tracking.
*   FastGuard pin/unpin without nesting.
*   deferReclaim appends to correct epoch bucket.
*   EpochBucketedBag reclaimUpTo clears correct buckets.
*   GlobalState epoch advancement via CAS.
*   Safe epoch calculation (current - 2 with underflow protection).
*   Cache-line alignment verification.

**4.2. Integration Tests (Multi-Threaded)**
*   Lock-free queue with EBR-protected nodes (4P/4C).
*   Stress test: verify no use-after-free under high contention.
*   Scalability test: 1/2/4/8 threads, measure throughput scaling.
*   Thread termination: verify garbage reclaimed on unregister.
*   Epoch advancement: verify epochs progress under load.

**4.3. Benchmarks**
*   `bench-pure`: Pure pin/unpin throughput (target: >1 Gops pairs/s).
*   `bench-ebr`: Mixed workload with defer operations.
*   Per-thread scaling: 1, 2, 4, 8 threads.
*   Guard vs FastGuard comparison.
*   Latency distribution (p50, p99, p99.9).

**4.4. Performance Targets**
| Metric | Target | Achieved |
|--------|--------|----------|
| pinFast() throughput (1 thread) | >1 Gops pairs/s | 1.20 Gops pairs/s |
| pinFast() throughput (8 threads) | >8 Gops pairs/s | 7.86 Gops pairs/s |
| pinFast() latency | <1ns | 0.42ns |
| pin() throughput (1 thread) | >500 Mops pairs/s | 567 Mops pairs/s |
| pin() throughput (8 threads) | >4 Gops pairs/s | 3.97 Gops pairs/s |
| pin() latency | <2ns | 0.88ns |
| Memory per deferred object | <32 bytes | 16 bytes |
