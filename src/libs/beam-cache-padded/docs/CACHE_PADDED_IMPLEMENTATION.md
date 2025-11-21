## Implementation Plan: `CachePadded` - Cache-Line Alignment and Padding Utilities

---

### **Part 1: Architectural Vision & Design Philosophy**

**1.1. The Goal: Eliminate False Sharing**
The objective is to provide utilities that ensure data structures are isolated to their own cache lines, preventing false sharing in concurrent algorithms. False sharing occurs when unrelated data on the same cache line causes unnecessary cache invalidations across CPU cores.

**1.2. The Architectural Pattern: Multi-Strategy Padding**
*   **Static Padding:** Compile-time alignment and padding using architecture-tuned cache line size.
*   **Auto Padding:** Runtime-detected padding (size only) for dynamic scenarios.
*   **NUMA Padding:** Double cache-line isolation for NUMA architectures.
*   **Atomic Wrapper:** Pre-padded atomic integers for common concurrent patterns.

**1.3. The Core Components**
*   **CachePadded.Static<T>:** Compile-time padded wrapper with alignment.
*   **CachePadded.Auto<T>:** Runtime-padded wrapper (requires allocator).
*   **CachePadded.Numa<T>:** Double cache-line padding for NUMA.
*   **CachePadded.Atomic<T>:** Cache-line isolated atomic integer.

**1.4. Performance Guarantees**
*   **Zero Runtime Cost (Static):** All padding computed at compile-time.
*   **Architecture-Aware:** Uses `std.atomic.cache_line` as source of truth.
*   **Power-of-Two Validation:** Compile-time check prevents invalid line sizes.

---

### **Part 2: Core Design Decisions**

**2.1. std.atomic.cache_line as Source of Truth**
*   **Decision:** Use Zig's built-in `std.atomic.cache_line` for the architectural cache line size.
*   **Justification:** Provides consistent, compiler-verified values across platforms without runtime overhead.

**2.2. Alignment + Padding (Static)**
*   **Decision:** Static types use both `align(LINE)` on the value AND trailing padding bytes.
*   **Justification:** Alignment ensures the struct starts on a cache line boundary. Padding ensures the next element in an array doesn't share the same cache line.

**2.3. Padding-Only for Auto**
*   **Decision:** Auto type adds padding bytes but does NOT change alignment.
*   **Justification:** Runtime-determined alignment isn't possible in Zig's type system. Users needing strict array isolation should use Static variants.

**2.4. Double-Line for NUMA**
*   **Decision:** NUMA variants use 2× cache line padding.
*   **Justification:** NUMA systems may have adjacent cache lines prefetched together. Double padding prevents cross-socket interference.

**2.5. Integer-Only for Atomic**
*   **Decision:** Atomic wrapper only accepts integer types (compile-time check).
*   **Justification:** `fetchAdd`/`fetchSub` semantics are only defined for integers. Other types should use Static wrapper with manual atomic operations.

**2.6. Thread-Local Cached Line Size**
*   **Decision:** Runtime-detected line size is cached in thread-local storage.
*   **Justification:** Avoids repeated sysfs reads on Linux. Thread-local prevents cross-thread races during initialization.

---

### **Part 3: Implementation Overview**

#### **Phase 1: Data Structures**

```
CachePadded (namespace)
├── Static<T>           → struct { value: T align(LINE), pad: [N]u8 }
├── StaticWithLine<T,L> → explicit line size override
├── Auto<T>             → struct { value: T, pad: []u8 }  (runtime alloc)
├── Numa<T>             → struct { value: T align(LINE), pad: [2*LINE - sizeof(T)]u8 }
├── NumaWithLine<T,L>   → explicit line size override
├── Atomic<T>           → struct { atom: atomic.Value(T) align(LINE), pad: [N]u8 }
└── AtomicWithLine<T,L> → explicit line size override

LINE = std.atomic.cache_line (typically 64 bytes)
```

#### **Phase 2: Core Operations**

| Variant | Alignment | Padding | Allocator | Use Case |
|---------|-----------|---------|-----------|----------|
| `Static<T>` | Yes (LINE) | LINE - sizeof(T) | No | Arrays, struct fields |
| `Auto<T>` | No | Runtime-computed | Yes | Dynamic/unknown line size |
| `Numa<T>` | Yes (LINE) | 2×LINE - sizeof(T) | No | NUMA-sensitive data |
| `Atomic<T>` | Yes (LINE) | LINE - sizeof(atomic) | No | Counters, flags |

#### **Phase 3: Key Algorithms**

*   **`Static<T>.init(value)` - Compile-Time Padding:**
    1. Compute padding: `LINE - @sizeOf(T)` (0 if T >= LINE)
    2. Return struct with aligned value and padding array

*   **`Auto<T>.init(allocator, value)` - Runtime Padding:**
    1. Get line size via `detectLineSizeRuntime()`
    2. Compute needed padding: `line - @sizeOf(T)` (0 if T >= line)
    3. If padding needed, allocate byte slice
    4. Return struct with value and padding slice

*   **`Auto<T>.deinit()` - Cleanup:**
    1. If padding slice is non-empty, free it

*   **`detectLineSizeRuntime()` - Cached Detection:**
    1. If `g_cached_line_size != 0`, return cached value
    2. Use `archLine()` (std.atomic.cache_line)
    3. Cache and return

#### **Phase 4: Flow Diagrams**

**Memory Layout Comparison:**
```
  Without padding (FALSE SHARING):
  ┌────────────────────────────────────────────────────────────────┐
  │ Cache Line 0 (64 bytes)                                        │
  │ ┌──────────┬──────────┬──────────┬──────────┐                  │
  │ │ counter_a│ counter_b│ counter_c│ counter_d│  ← All 4 share!  │
  │ └──────────┴──────────┴──────────┴──────────┘                  │
  └────────────────────────────────────────────────────────────────┘

  With CachePadded.Static (NO FALSE SHARING):
  ┌────────────────────────────────────────────────────────────────┐
  │ Cache Line 0                                                   │
  │ ┌──────────┬──────────────────────────────────────────────────┐│
  │ │ counter_a│                    padding                       ││
  │ └──────────┴──────────────────────────────────────────────────┘│
  └────────────────────────────────────────────────────────────────┘
  ┌────────────────────────────────────────────────────────────────┐
  │ Cache Line 1                                                   │
  │ ┌──────────┬──────────────────────────────────────────────────┐│
  │ │ counter_b│                    padding                       ││
  │ └──────────┴──────────────────────────────────────────────────┘│
  └────────────────────────────────────────────────────────────────┘
```

**Variant Selection Flow:**
```
  Need cache-line isolation?
       │
       v
  ┌─────────────┐
  │ Know line   │──no──> Auto<T> (runtime padding)
  │ at compile? │
  └──────┬──────┘
         │yes
         v
  ┌─────────────┐
  │ NUMA system │──yes──> Numa<T> (2× padding)
  │ concerns?   │
  └──────┬──────┘
         │no
         v
  ┌─────────────┐
  │ Integer     │──yes──> Atomic<T> (with load/store/fetchAdd)
  │ atomic?     │
  └──────┬──────┘
         │no
         v
      Static<T>
```

**Static vs Auto:**
```
  Static<T>                          Auto<T>
  ┌────────────────────┐             ┌────────────────────┐
  │ value: T align(64) │             │ value: T           │
  │ pad: [56]u8        │             │ pad: []u8 (heap)   │
  └────────────────────┘             └────────────────────┘
       │                                  │
       │ sizeof = 64 (fixed)              │ sizeof = 16 + alloc
       │ alignment = 64                   │ alignment = @alignOf(T)
       v                                  v
  Arrays: each element               Arrays: may still share
  on own cache line                  cache lines (no align)
```

---

### **Part 4: Verification & Testing Strategy**

**4.1. Unit Tests**
*   **Size validation:** Verify `@sizeOf(Static<u8>) == 64`.
*   **Alignment check:** Verify `@alignOf(Static<u8>) == 64`.
*   **Padding calc:** Verify large T (>= LINE) gets 0 padding.
*   **Power-of-two:** Verify compile error on invalid line sizes.
*   **Atomic integer-only:** Verify compile error on non-integer Atomic.

**4.2. Integration Tests**
*   **Array isolation:** Verify adjacent Static<T> elements don't share cache lines.
*   **Auto allocation:** Verify init/deinit doesn't leak.
*   **NUMA double-padding:** Verify `@sizeOf(Numa<u8>) == 128`.

**4.3. Benchmarks**
*   **False sharing test:** N threads incrementing adjacent counters with/without padding.
*   **Throughput comparison:** Measure contention reduction with cache padding.
*   **Memory overhead:** Measure padding waste for various T sizes.
