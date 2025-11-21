## Implementation Plan: `Arc<T>` - Thread-Safe Atomic Reference Counting

---

### **Part 1: Architectural Vision & Design Philosophy**

**1.1. The Goal: A Production-Grade Smart Pointer**
The objective is to create a thread-safe, reference-counted smart pointer analogous to Rust's `std::sync::Arc`. It must provide safe shared ownership across multiple threads with minimal overhead, automatic memory management through reference counting, and support for weak references to break reference cycles.

**1.2. The Architectural Pattern: Layered Memory Management**
This architecture provides both performance and memory efficiency through a multi-layered approach:
*   **Small Value Optimization (SVO):** For tiny payloads (≤ `sizeof(usize)`), the data is stored inline within the Arc struct itself. This eliminates heap allocation entirely for small types.
*   **Heap-Allocated Inner Block:** For larger types, a cache-line-aligned `Inner` block is allocated on the heap containing reference counters and the payload.
*   **Tagged Pointer:** A 1-bit tag in the pointer distinguishes between inline (SVO) and heap-allocated storage without additional memory overhead.

**1.3. The Core Components**
*   **Arc<T>:** The primary strong reference-counted pointer with ownership semantics.
*   **ArcWeak<T>:** A non-owning weak reference that doesn't prevent deallocation.

**1.4. Memory Safety Guarantees**
*   **Thread-Safety:** All reference count operations use atomic instructions with appropriate memory ordering.
*   **No Use-After-Free:** The `Inner` block is only deallocated when both strong and weak counts reach zero.
*   **Automatic Cleanup:** The `release()` method automatically calls `T.deinit()` on last-strong-drop when present.

---

### **Part 2: Core Design Decisions**

This section codifies the critical implementation choices.

**2.1. Small Value Optimization (SVO) Threshold**
*   **Decision:** SVO is enabled when `@sizeOf(T) <= @sizeOf(usize)` AND `T` is "plain data" (no pointers, no tagged unions).
*   **Justification:** Values fitting in a machine word can be stored inline, eliminating heap allocation overhead. Plain data restriction ensures bitwise copying is safe. The implicit strong count of 1 for inline values means no atomic operations are needed for single-owner scenarios.

**2.2. Cache-Line Alignment for Inner Blocks**
*   **Decision:** The `InnerBlock` struct is aligned to 64-byte cache-line boundaries.
*   **Justification:** Cache-line alignment prevents false sharing between adjacent `Arc` allocations in concurrent scenarios. The counters are frequently accessed atomically, and false sharing would cause severe performance degradation.

**2.3. Separate Strong and Weak Counters**
*   **Decision:** Two separate atomic counters: `strong_count` and `weak_count`.
*   **Justification:** Separating the counters allows the data to be destroyed when strong count reaches zero (calling `T.deinit()`), while the `Inner` block itself survives until weak count also reaches zero. This enables weak references to safely detect when the data has been destroyed.

**2.4. Memory Ordering Strategy**
*   **Decision:**
    *   `fetchAdd` for clone: `.monotonic` (no synchronization needed, just counting)
    *   `fetchSub` for release: `.release` (ensure all writes are visible before potential deallocation)
    *   Load after decrement to zero: `.acquire` (synchronize with all prior releases)
*   **Justification:** This follows the standard Arc memory ordering pattern established by Rust and C++ `shared_ptr`. The release-acquire pair ensures that all operations on the data "happen-before" deallocation.

**2.5. Tagged Pointer Implementation**
*   **Decision:** Use a 1-bit tag in the low bit of the pointer to distinguish inline vs heap storage.
*   **Justification:** Pointers to `Inner` are guaranteed to be at least word-aligned (64-byte aligned in practice), leaving the low bits available for tagging. This eliminates the need for a separate discriminant field.

**2.6. Weak Reference Upgrade Strategy**
*   **Decision:** Use a CAS loop with `cmpxchgWeak` to atomically increment strong count only if it's > 0.
*   **Justification:** This ensures thread-safe promotion from weak to strong. If strong count is already 0, the data has been destroyed and upgrade must fail. The weak variant of CAS is used for performance in the retry loop.

**2.7. Cyclic Construction Support**
*   **Decision:** Provide `newCyclic` API that passes a temporary `ArcWeak` to the constructor.
*   **Justification:** This enables self-referential structures (like doubly-linked lists or graph nodes) to be constructed safely. The temporary weak reference is held during construction, preventing premature deallocation if the constructor stores it.

---

### **Part 3: Implementation Overview**

#### **Phase 1: Data Structures**

```
Arc<T>
├── storage: union { ptr_with_tag, inline_data }
│   ├── SVO path: data stored inline (no allocation)
│   └── Heap path: tagged pointer to Inner block
│
Inner<T> [cache-line aligned]
├── counters: { strong_count, weak_count }
├── data: T
├── allocator, on_drop, next_in_freelist
│
ArcWeak<T>
└── inner: ?*Inner<T>  (null = empty)
```

#### **Phase 2: Core Operations**

| Operation | SVO Path | Heap Path |
|-----------|----------|-----------|
| `init` | Copy value inline | Allocate Inner, set strong=1 |
| `clone` | Bitwise copy | Atomic fetchAdd on strong_count |
| `release` | No-op | Atomic fetchSub; destroy on last drop |
| `get` | Return inline ptr | Return &inner.data |

#### **Phase 3: Key Algorithms**

*   **`release()` - Last Strong Drop:**
    1. Decrement strong_count with `.release` ordering
    2. If was last (count == 1): acquire fence, call `on_drop` hook, call `T.deinit()`
    3. If weak_count == 0: deallocate Inner block

*   **`ArcWeak.upgrade()` - Weak to Strong:**
    1. CAS loop: increment strong_count only if > 0
    2. Return `null` if data already destroyed

#### **Phase 4: Flow Diagrams**

**Arc Lifecycle:**
```
  init(value)              clone()                  release()
       │                      │                         │
       v                      v                         v
  ┌─────────┐           ┌─────────┐              ┌─────────┐
  │ Allocate│           │ fetchAdd│              │ fetchSub│
  │ Inner   │           │ strong  │              │ strong  │
  │ strong=1│           │ count+1 │              │ count-1 │
  └────┬────┘           └────┬────┘              └────┬────┘
       │                     │                        │
       v                     v                        v
   [Arc<T>]              [Arc<T>]            count==0? ──no──> done
                                                  │
                                                 yes
                                                  │
                                                  v
                                          ┌──────────────┐
                                          │ call on_drop │
                                          │ call T.deinit│
                                          └──────┬───────┘
                                                 │
                                                 v
                                          weak==0? ──no──> done
                                                 │        (weak refs
                                                yes        remain)
                                                 │
                                                 v
                                          ┌──────────────┐
                                          │  Free Inner  │
                                          └──────────────┘
```

**Weak Reference Upgrade:**
```
  ArcWeak.upgrade()
        │
        v
  ┌─────────────┐
  │ inner==null?│──yes──> return null
  └──────┬──────┘
         │no
         v
  ┌─────────────┐
  │strong_count │──0──> return null (data destroyed)
  │    > 0 ?    │
  └──────┬──────┘
         │yes
         v
  ┌─────────────┐
  │ CAS: count  │──fail──> retry (spin loop)
  │  +1 if >0   │
  └──────┬──────┘
         │success
         v
    [Arc<T>]
```

---

### **Part 4: Verification & Testing Strategy**

**4.1. Unit Tests**
*   **SVO behavior:** Verify inline storage for small types, correct cloning semantics.
*   **Reference counting:** Test strong/weak count transitions, overflow detection.
*   **Memory ordering:** Verify release-acquire synchronization with TSAN.

**4.2. Integration Tests**
*   **Multi-threaded stress:** 8+ threads, millions of clone/release cycles, verify no leaks.
*   **Weak reference races:** Concurrent upgrade/release, verify no use-after-free.
*   **Cyclic structures:** Self-referential graphs via `newCyclic`, verify proper cleanup.

**4.3. Benchmarks**
*   **Single-threaded throughput:** init/clone/release/get operations.
*   **Multi-threaded contention:** 4P/4C shared Arc, measure scaling.
*   **SVO vs Heap:** Measure speedup for small value types.
