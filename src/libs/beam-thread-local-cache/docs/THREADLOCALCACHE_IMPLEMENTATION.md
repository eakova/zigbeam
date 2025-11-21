## Implementation Plan: `ThreadLocalCache` - Per-Thread Lock-Free Object Reuse Cache

---

### **Part 1: Architectural Vision & Design Philosophy**

**1.1. The Goal: Eliminate Lock Contention for High-Frequency Allocations**
The objective is to provide an extremely fast, per-thread cache (L1) that sits in front of a larger, slower, potentially contended global pool (L2). The cache satisfies the vast majority of allocation/deallocation requests without touching locks, atomics, or shared resources.

**1.2. The Architectural Pattern: Two-Level Caching**
*   **L1 Cache (Thread-Local):** Fixed-size array per thread with O(1) push/pop, zero synchronization.
*   **L2 Pool (Global):** User-provided callback for overflow/drain to global pool.
*   **Stack Semantics:** LIFO order for cache-friendly access patterns.
*   **Compile-Time Configuration:** Capacity and options set at compile time for zero runtime overhead.
*   **Callback Decoupling:** Generic callback interface works with any global pool implementation.

**1.3. The Core Components (Three Factory Functions)**

| Factory | Capacity | Options | Use Case |
|---------|----------|---------|----------|
| `ThreadLocalCache` | Fixed 16 | Defaults | Simple usage, most common |
| `ThreadLocalCacheWithCapacity` | User-specified | Defaults | Custom capacity needed |
| `ThreadLocalCacheWithOptions` | Auto or specified | Full control | Advanced tuning |

*   **ThreadLocalCache(T, callback):** Simple factory with conservative default capacity (16). Best for most use cases.
*   **ThreadLocalCacheWithCapacity(T, callback, cap):** Explicit capacity parameter for when 16 is too small/large.
*   **ThreadLocalCacheWithOptions(T, callback, Options):** Full-featured factory with all configuration options.
*   **ThreadLocalCacheOptions:** Configuration struct for capacity, active_capacity, sanitization, batch hints.

**1.4. Performance Guarantees**
*   **pop()/push() (cache hit):** ~1-2 nanoseconds, zero overhead beyond array access.
*   **No Synchronization:** Each thread has its own instance; no locks or atomics.
*   **Predictable Memory:** Fixed-size array, no dynamic allocation.
*   **Inline Hot Paths:** Critical functions marked `inline` for compiler optimization.

---

### **Part 2: Core Design Decisions**

**2.1. Pointer Types Only**
*   **Decision:** Compile-time error if T is not a pointer type.
*   **Justification:** Caching value types would require copying, defeating the purpose. Pointers enable O(1) transfer. The cache stores references to pooled objects.

**2.2. Fixed-Size Array**
*   **Decision:** Use a compile-time sized array (`[capacity]?T`) instead of dynamic allocation.
*   **Justification:** Eliminates allocator dependency on hot paths. Predictable cache-line behavior. Zero runtime allocation overhead.

**2.3. Optional Callback Interface**
*   **Decision:** `recycle_callback` is optional (`?*const fn`); if null, items are simply dropped on clear.
*   **Justification:** Enables use cases where items don't need global pool return (e.g., arena-backed objects that will be freed in bulk).

**2.4. Context Pointer for Callbacks**
*   **Decision:** Callbacks receive `?*anyopaque` context parameter.
*   **Justification:** Supports both stateful pools (pass pool pointer) and stateless callbacks (pass null). Type-erased for generic compatibility.

**2.5. Heuristic Auto-Capacity**
*   **Decision:** When capacity is null, compute from pointee size: `clamp(4096 / max(pointee_size, 64), 8, 64)`.
*   **Justification:** Targets ~4KB footprint per cache. Larger objects get fewer slots, smaller objects get more, staying within reasonable memory bounds.

**2.6. Sanitize Slots Option**
*   **Decision:** Write null to freed slots in non-ReleaseFast builds by default.
*   **Justification:** Helps debuggers/sanitizers detect use-after-free. Zero overhead in release builds.

**2.7. Active Capacity Limit**
*   **Decision:** Separate `active_capacity` from physical `capacity`.
*   **Justification:** Allows runtime tuning without recompilation. Physical capacity sets array size; active_capacity limits actual usage.

---

### **Part 3: Implementation Overview**

#### **Phase 1: Data Structures**

**Factory Hierarchy:**
```
┌──────────────────────────────────────────────────────────────────────┐
│                     Factory Functions                                │
└──────────────────────────────────────────────────────────────────────┘

ThreadLocalCache(T, callback)              ← Simple API (capacity=16)
       │
       └──► ThreadLocalCacheWithOptions(T, callback, {.capacity=16})

ThreadLocalCacheWithCapacity(T, callback, N)  ← Custom capacity
       │
       └──► ThreadLocalCacheWithOptions(T, callback, {.capacity=N})

ThreadLocalCacheWithOptions(T, callback, Options)  ← Full control
       │
       └──► Generated Cache Struct
```

**Generated Cache Struct:**
```
Generated Struct (returned by all factories)
│
├── buffer: [capacity]?T
│   └── Fixed array of optional pointers (null = empty slot)
│
├── count: usize
│   └── Current number of items (top of stack index)
│
├── capacity: usize (comptime const)
│   └── Physical array size
│
└── active_capacity: usize (comptime const)
    └── Runtime limit on items (<= capacity)
```

**ThreadLocalCacheOptions:**
```
ThreadLocalCacheOptions
├── capacity: ?usize           ← Override auto-capacity (null = auto)
├── active_capacity: ?usize    ← Runtime limit (null = use capacity)
├── clear_batch: bool          ← Future batch optimization hint
├── flush_batch: ?usize        ← Batch size for clear
└── sanitize_slots: bool       ← Null-out freed slots (default: !ReleaseFast)
```

#### **Phase 2: Core Operations**

| Operation | Cost | Synchronization | Notes |
|-----------|------|-----------------|-------|
| `pop()` | ~1-2ns | None | Decrement count, return item |
| `push(item)` | ~1-2ns | None | Store item, increment count |
| `clear(ctx)` | O(n) | None (local only) | Invoke callback per item |
| `len()` | O(1) | None | Return count |
| `isEmpty()` | O(1) | None | count == 0 |
| `isFull()` | O(1) | None | count == capacity |

#### **Phase 3: Key Algorithms**

**pop() - Get Item from Cache:**
1. If `count == 0`: return null (cache empty)
2. Decrement count: `count -= 1`
3. Read item from `buffer[count]`
4. If sanitize_slots: write null to `buffer[count]`
5. Return item

**push(item) - Put Item in Cache:**
1. If `count >= active_capacity`: return false (cache full)
2. Write item to `buffer[count]`
3. Increment count: `count += 1`
4. Return true

**clear(context) - Drain Cache to Global Pool:**
1. If `count == 0`: return early
2. While `count > 0`:
   - Decrement count
   - Read item from `buffer[count]`
   - If recycle_callback not null: invoke with context and item
   - If sanitize_slots: write null to `buffer[count]`

**Auto-Capacity Computation:**
1. Get pointee size: `@sizeOf(Pointee)`
2. Compute slot size: `max(pointee_size, 64)` (minimum cache line)
3. Compute target count: `4096 / slot_size` (target ~4KB)
4. Clamp to range: `clamp(target, 8, 64)`

#### **Phase 4: Flow Diagrams**

**Two-Level Cache Architecture:**
```
┌─────────────────────────────────────────────────────────────────┐
│                     Per-Thread L1 Cache                         │
└─────────────────────────────────────────────────────────────────┘

    Thread 0                Thread 1                Thread N
        │                       │                       │
        ▼                       ▼                       ▼
┌───────────────┐       ┌───────────────┐       ┌───────────────┐
│ TLS Cache     │       │ TLS Cache     │       │ TLS Cache     │
│ [*][*][*][_]  │       │ [*][_][_][_]  │       │ [*][*][*][*]  │
│ count=3       │       │ count=1       │       │ count=4 FULL  │
└───────┬───────┘       └───────┬───────┘       └───────┬───────┘
        │                       │                       │
        │ overflow/drain        │                       │ overflow
        │                       │                       │
        └───────────────────────┴───────────────────────┘
                                │
                                ▼
                    ┌───────────────────────┐
                    │   Global Pool (L2)    │
                    │  (lock-free stack,    │
                    │   sharded freelist,   │
                    │   etc.)               │
                    └───────────────────────┘
```

**pop() Flow:**
```
pop()
  │
  ▼
┌─────────────────┐
│ count == 0?     │
└────────┬────────┘
         │
    ┌────┴────┐
    │         │
   yes        no
    │         │
    ▼         ▼
 return   ┌─────────────────┐
  null    │ count -= 1      │
          │ item = buf[cnt] │
          │ buf[cnt] = null │ (if sanitize)
          │ return item     │
          └─────────────────┘
```

**push() Flow:**
```
push(item)
  │
  ▼
┌─────────────────────────┐
│ count >= active_cap?    │
└────────────┬────────────┘
             │
       ┌─────┴─────┐
       │           │
      yes          no
       │           │
       ▼           ▼
   return      ┌─────────────────┐
   false       │ buf[count]=item │
   (caller     │ count += 1      │
   handles     │ return true     │
   overflow)   └─────────────────┘
```

**clear() Flow:**
```
clear(global_pool_context)
  │
  ▼
┌─────────────────┐
│ count == 0?     │
└────────┬────────┘
         │
    ┌────┴────┐
    │         │
   yes        no
    │         │
    ▼         ▼
 return   ┌─────────────────────────────┐
 early    │ while count > 0:            │
          │   count -= 1                │
          │   item = buf[count]         │
          │   recycle_callback(ctx,item)│
          │   buf[count] = null         │ (if sanitize)
          └─────────────────────────────┘
```

**Usage Pattern with Global Pool:**
```
┌─────────────────────────────────────────────────────────────────┐
│                   Allocation Request                            │
└─────────────────────────────────────────────────────────────────┘

          Request: "Give me an object"
                        │
                        ▼
              ┌─────────────────┐
              │ tls_cache.pop() │  ~1-2ns
              └────────┬────────┘
                       │
                 ┌─────┴─────┐
                 │           │
              hit (item)   miss (null)
                 │           │
                 ▼           ▼
             return     ┌──────────────────┐
              item      │ global_pool.get()│  ~20-100ns
                        └────────┬─────────┘
                                 │
                                 ▼
                            return item


┌─────────────────────────────────────────────────────────────────┐
│                   Deallocation Request                          │
└─────────────────────────────────────────────────────────────────┘

          Request: "Return this object"
                        │
                        ▼
              ┌──────────────────────┐
              │ tls_cache.push(item) │  ~1-2ns
              └────────┬─────────────┘
                       │
                 ┌─────┴─────┐
                 │           │
              true         false
           (accepted)    (cache full)
                 │           │
                 ▼           ▼
              done      ┌──────────────────────┐
                        │ global_pool.put(item)│  ~20-100ns
                        └──────────────────────┘
```

---

### **Part 4: Verification & Testing Strategy**

**4.1. Unit Tests**
*   pop() returns null when cache empty.
*   push() returns false when cache full.
*   pop() returns items in LIFO order.
*   push() increments count correctly.
*   clear() invokes callback for each item.
*   clear() with null callback doesn't crash.
*   len(), isEmpty(), isFull() accuracy.
*   Compile-time error for non-pointer types.
*   Auto-capacity heuristic produces values in [8, 64].
*   Sanitize slots writes null in debug builds.

**4.2. Integration Tests**
*   Thread-local usage: each thread has independent cache.
*   Integration with global lock-free pool (e.g., ArcPool).
*   Overflow handling: push fails, caller routes to global pool.
*   Drain on thread exit: clear() returns all items to global.
*   High-frequency allocation pattern: cache hit rate measurement.

**4.3. Benchmarks**
*   pop()/push() latency (single-threaded, cache hits).
*   clear() latency vs. item count.
*   Cache hit rate under various allocation patterns.
*   Comparison: with vs. without L1 cache (global pool direct).
*   Memory footprint vs. capacity configuration.
*   Throughput scaling with different capacity values.

