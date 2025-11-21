## Implementation Plan: `GlobalEpoch` - Epoch-Based Reclamation (EBR) for Lock-Free Data Structures

---

### **Part 1: Architectural Vision & Design Philosophy**

**1.1. The Goal: Safe Deferred Memory Reclamation for Lock-Free Algorithms**
The objective is to provide a mechanism for safely reclaiming memory in lock-free data structures where traditional reference counting or immediate deallocation is unsafe due to concurrent readers. EBR tracks when all threads have passed a "safe point" before freeing deferred garbage.

**1.2. The Architectural Pattern: Epoch-Based Reclamation**
*   **Global Epoch Counter:** A monotonically increasing counter that advances when all participants have observed the current epoch.
*   **Participant Registration:** Each thread registers as a participant with its own local epoch and active flag.
*   **Guard/Pin Protocol:** Threads "pin" before accessing shared data, recording the current epoch, and "unpin" when done.
*   **Deferred Destruction:** Garbage is stamped with the epoch when retired; it's only freed when all threads have advanced past that epoch.
*   **Background Reclaimer:** A dedicated thread periodically advances the global epoch to reduce overhead on hot paths.

**1.3. The Core Components**
*   **GlobalEpoch:** Central coordinator holding the global epoch, participant slots, and orphan garbage queue.
*   **Participant:** Per-thread state including local epoch, active flag, and local garbage list.
*   **Guard:** RAII handle representing a pinned critical section.
*   **Garbage:** Tuple of (pointer, destructor callback, epoch) for deferred items.

**1.4. Safety Guarantees**
*   **No Use-After-Free:** Garbage is only reclaimed when no thread could be accessing it.
*   **Bounded Memory:** Collection threshold and global queue capacity bound deferred garbage.
*   **Progress Guarantee:** Background reclaimer ensures epochs advance even under load.
*   **Graceful Degradation:** OOM fallback to emergency collection or controlled leaking.

---

### **Part 2: Core Design Decisions**

**2.1. Fixed Maximum Participants**
*   **Decision:** Support up to 64 participants (MAX_PARTICIPANTS = 64) in a fixed-size array.
*   **Justification:** Avoids dynamic allocation for participant management. 64 covers typical hardware (32P + 32C). Fixed array enables cache-friendly scanning.

**2.2. Cache-Line Aligned Hot Fields**
*   **Decision:** Align `current_epoch`, `cached_min_epoch`, and `highest_used_index` to cache lines.
*   **Justification:** Prevents false sharing between the background reclaimer (writes epoch) and workers (read epoch). Critical for scalability.

**2.3. Cached Minimum Epoch**
*   **Decision:** Cache the minimum epoch result for fast reads via `getMinimumEpochFast()`.
*   **Justification:** Full participant scan is expensive (64 atomic loads). Cache is conservative (may be stale/higher), ensuring safety while enabling fast-path reads.

**2.4. Background Reclaimer Thread**
*   **Decision:** Spawn a dedicated thread that periodically calls `tryAdvanceEpoch()`.
*   **Justification:** Moves expensive participant scanning off hot paths (pin/unpin). Adaptive backoff (1ms-50ms) balances responsiveness with CPU usage.

**2.5. Two-Epoch Safety Buffer**
*   **Decision:** Reclaim garbage only when `epoch < min_epoch - 2`.
*   **Justification:** Provides safety margin for epoch transition races. A thread pinned at epoch N may have started reading data retired at N-1, so we wait until N+2.

**2.6. Highest Used Index Optimization**
*   **Decision:** Track `highest_used_index` to skip empty trailing participant slots.
*   **Justification:** When only a few threads are registered, scanning all 64 slots is wasteful. Index tracking reduces scan cost proportionally.

**2.7. Global Orphan Queue**
*   **Decision:** Use DVyukovMPMCQueue for garbage orphaned when participants terminate.
*   **Justification:** When a participant terminates mid-epoch, its garbage must survive. Lock-free queue allows any thread to later reclaim orphaned items.

**2.8. Collection Threshold**
*   **Decision:** Trigger collection when local garbage count reaches `MAX_PARTICIPANTS * 8` (512).
*   **Justification:** Balances timely reclamation against collection overhead. Each collection requires a full participant scan, so reducing frequency improves throughput.

---

### **Part 3: Implementation Overview**

#### **Phase 1: Data Structures**

```
GlobalEpoch
│
├── current_epoch: Atomic(u64) align(CACHE_LINE)
│   └── Global epoch counter, advanced by background reclaimer
│
├── participant_slots: [64]Atomic(?*Participant)
│   └── Fixed array of registered participants (null = empty slot)
│
├── cached_min_epoch: Atomic(u64) align(CACHE_LINE)
│   └── Cached result of getMinimumEpoch() for fast reads
│
├── highest_used_index: Atomic(usize) align(CACHE_LINE)
│   └── Optimization: skip scanning empty trailing slots
│
├── global_garbage_queue: DVyukovMPMCQueue(Garbage, 4096)
│   └── Orphaned garbage from terminated participants
│
├── shutdown_requested: Atomic(bool)
│   └── Signal for graceful reclaimer thread shutdown
│
└── allocator: Allocator

Participant
├── is_active: Atomic(bool)        ← true when pinned
├── epoch: Atomic(u64)             ← snapshot of global epoch when pinned
├── garbage_list: ArrayList(Garbage)  ← local deferred garbage
├── garbage_count_since_last_check: usize
└── allocator: Allocator

Guard (RAII)
├── participant: *Participant
└── global: *GlobalEpoch

Garbage
├── ptr: *anyopaque               ← pointer to deallocate
├── destroy_fn: fn(*anyopaque, Allocator) void
└── epoch: u64                    ← epoch when retired
```

#### **Phase 2: Core Operations**

| Operation | Thread | Frequency | Cost | Notes |
|-----------|--------|-----------|------|-------|
| `pin()` | Worker | Per access | ~5-10ns | Load epoch, store active=true |
| `Guard.deinit()` | Worker | Per access | ~5ns + collection | Store active=false, maybe collect |
| `deferDestroy()` | Worker | Per retire | ~10-30ns | Append to local list |
| `tryAdvanceEpoch()` | Reclaimer | Periodic | O(N) | Scan all participants |
| `getMinimumEpoch()` | Collector | On threshold | O(N) | Scan active participants |
| `getMinimumEpochFast()` | Any | Hot path | O(1) | Read cached value |
| `registerParticipant()` | Worker | Once/thread | O(N) worst | CAS into empty slot |

#### **Phase 3: Key Algorithms**

**pin() - Enter Protected Region:**
1. Get thread-local participant (panic if not registered)
2. Load current global epoch (unordered - any value is safe)
3. Store epoch to participant.epoch (monotonic)
4. Store `is_active = true` (release - publishes epoch write)
5. Return Guard handle

**Guard.deinit() - Exit Protected Region:**
1. Store `is_active = false` (release)
2. If `garbage_count_since_last_check >= COLLECTION_THRESHOLD`:
   - Call `tryCollectGarbage()`
   - Reset counter to 0

**deferDestroy(garbage) - Retire Memory:**
1. Stamp garbage with current participant epoch
2. Append to participant's local garbage_list
3. On OOM: emergency collection, retry, or leak with warning
4. Increment garbage count

**tryCollectGarbage() - Reclaim Safe Garbage:**
1. Call `getMinimumEpoch()` to scan all participants
2. Compute safe_epoch = `min_epoch - 2` (safety buffer)
3. For each item in local garbage_list:
   - If `item.epoch < safe_epoch`: destroy and remove
4. Drain up to `dynamic_limit` items from global orphan queue:
   - If safe to reclaim: destroy
   - Else: re-enqueue or push to local list

**tryAdvanceEpoch() - Progress Global Epoch:**
1. Load current epoch (monotonic)
2. For each participant slot:
   - If active and `local_epoch < current`: abort (thread lagging)
3. If all caught up: CAS `current_epoch → current + 1`

**getMinimumEpoch() - Find Oldest Reader:**
1. Initialize `min_epoch = maxInt(u64)`
2. For each slot up to `highest_used_index`:
   - Load participant pointer
   - If active (acquire load): read its epoch (acquire)
   - Track minimum
3. Update `cached_min_epoch` (release)
4. Return minimum (or maxInt if no active participants)

#### **Phase 4: Flow Diagrams**

**Epoch-Based Reclamation Lifecycle:**
```
┌─────────────────────────────────────────────────────────────────┐
│                     EBR Lifecycle                               │
└─────────────────────────────────────────────────────────────────┘

     Worker Thread                    Background Reclaimer
           │                                  │
           ▼                                  │
    ┌─────────────┐                           │
    │   pin()     │                           │
    │ epoch = N   │                           │
    │ active=true │                           │
    └──────┬──────┘                           │
           │                                  │
           ▼                                  │
    ┌─────────────┐                   ┌──────▼──────┐
    │ Access data │                   │tryAdvance() │
    │  (safe!)    │                   │ if all at N │
    └──────┬──────┘                   │ epoch → N+1 │
           │                          └──────┬──────┘
           ▼                                 │
    ┌─────────────┐                          │
    │deferDestroy │                          │
    │ stamp = N   │                          │
    └──────┬──────┘                          │
           │                                 │
           ▼                                 │
    ┌─────────────┐                          │
    │Guard.deinit │                          │
    │active=false │                          │
    │  collect?   │                          │
    └─────────────┘                          │
           │                                 │
           │     ┌───────────────────────────┘
           │     │
           ▼     ▼
    ┌──────────────────────────────────────────────┐
    │             LATER (epoch >= N+2)             │
    │  getMinimumEpoch() returns M where M > N+1   │
    │  safe_epoch = M - 2 >= N                     │
    │  Garbage with epoch N is now SAFE to free!   │
    └──────────────────────────────────────────────┘
```

**Participant Registration and Slot Management:**
```
registerParticipant(participant):
    │
    ▼
┌─────────────────────────────┐
│ for idx in 0..64:           │
│   if CAS(slot[idx],         │
│          null → participant)│
│      success                │
└──────────┬──────────────────┘
           │
     ┌─────┴─────┐
     │           │
  success     all full
     │           │
     ▼           ▼
┌─────────┐  ┌─────────────────┐
│ Update  │  │return error.    │
│ highest │  │TooManyThreads   │
│ _used_  │  └─────────────────┘
│ index   │
└─────────┘
```

**Garbage Collection Decision Flow:**
```
Guard.deinit()
      │
      ▼
┌───────────────────────────────┐
│ is_active.store(false)        │
└──────────────┬────────────────┘
               │
               ▼
┌───────────────────────────────┐
│ garbage_count >= THRESHOLD?   │
│        (512 items)            │
└──────────────┬────────────────┘
               │
        ┌──────┴──────┐
        │             │
       yes            no
        │             │
        ▼             ▼
┌───────────────┐  (return)
│getMinimumEpoch│
│ scan all slots│
└───────┬───────┘
        │
        ▼
┌───────────────────────────────┐
│ For each local garbage:       │
│   if epoch < safe_epoch:      │
│     destroy & remove          │
└───────────────┬───────────────┘
                │
                ▼
┌───────────────────────────────┐
│ Drain global orphan queue     │
│ (up to dynamic_limit items)   │
│   if safe: destroy            │
│   else: re-enqueue or local   │
└───────────────────────────────┘
```

**Memory Ordering in Pin/Unpin:**
```
    pin()                                 Reclaimer
      │                                      │
      ▼                                      │
  epoch.store(N, monotonic)                  │
      │                                      │
      ▼                                      │
  is_active.store(true, RELEASE) ──────────► is_active.load(ACQUIRE)
      │                                      │
      │                                      ▼
      │                              epoch.load(ACQUIRE)
      │                                      │
      │                              ← synchronizes-with ──┘
      │
  [safe to access data]
      │
      ▼
  is_active.store(false, RELEASE)

Key: RELEASE-ACQUIRE pair ensures reclaimer sees epoch write
     when it observes is_active == true
```

---

### **Part 4: Verification & Testing Strategy**

**4.1. Unit Tests**
*   GlobalEpoch init/deinit lifecycle.
*   Participant registration and unregistration.
*   getMinimumEpoch with 0, 1, N active participants.
*   Cached minimum epoch consistency.
*   Guard pin/unpin state transitions.
*   deferDestroy appends to local list with correct epoch stamp.
*   Collection threshold triggers garbage collection.
*   Global orphan queue enqueue/dequeue.
*   error.TooManyThreads when slots exhausted.

**4.2. Integration Tests (Multi-Threaded)**
*   Single producer, single consumer with EBR-protected queue.
*   4P/4C stress test: verify no use-after-free under load.
*   8P/8C stress test: verify memory is eventually reclaimed.
*   Participant termination mid-epoch: verify orphan queue handles garbage.
*   Background reclaimer: verify epoch advances over time.
*   Shutdown sequence: verify graceful termination and final collection.

**4.3. Fuzz Tests**
*   Random pin/unpin sequences across threads.
*   Random deferDestroy interleaved with collections.
*   OOM simulation: verify emergency collection paths.
*   Rapid participant registration/unregistration.

**4.4. Benchmarks**
*   pin/unpin latency (single-threaded).
*   deferDestroy latency distribution.
*   Collection cycle duration vs. garbage count.
*   Throughput scaling with participant count.
*   Memory footprint under steady-state load.
*   Background reclaimer CPU overhead.

