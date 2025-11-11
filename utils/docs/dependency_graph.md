## Arc/Pool/Cache Dependency & Interaction Graph

This document shows how the Arc family of utilities depend on and interact with each other. It also clarifies a couple of naming details used in the diagram.

Key corrections
- Arc<T>.storage is an extern union used for Small Value Optimization (SVO), not a tagged union.
- Pointer vs inline is distinguished by a 1‑bit tag carried inside a TaggedPointer over the Inner* (not a Zig tagged union).

## High‑Level Relationships

- User application
  - Uses Arc<T> directly for shared ownership
  - Optionally allocates Arc<T> through ArcPool<T> for reuse
  - Optionally runs ArcCycleDetector<T> during debug/diagnostics

- ArcPool<T>
  - Fronted by a per‑thread ThreadLocalCache of pointers to Arc<T>.Inner
  - Falls back to a global lock‑free freelist (Treiber stack)
  - Falls back to the allocator behind a mutex as a last tier

- ArcCycleDetector<T>
  - Tracks Inner* pointers to Arc<T> instances that might participate in cycles
  - Uses a user‑provided trace function to discover edges (children)

- Arc<T>
  - Owns either inline data (SVO) or a pointer to Inner
  - Differentiates “inline vs pointer” with a 1‑bit tag (via TaggedPointer over Inner*)

## Dependency / Interaction Diagram

```text
+--------------------------+
|      User Application    |
+--------------------------+
      |                  
      |                  
      v                  
+--------------------------+     +--------------------------+
|        ArcPool<T>        |     |     ArcCycleDetector<T>  |
+--------------------------+     +--------------------------+
      |                                |           |
 (Interacts with)                      | (Tracks)  |
      |                                |           |
      v                                v           v
+--------------------------+      +--------------------------+     +--------------------------+
|     ThreadLocalCache     |      |          Arc<T>          |     |        ArcWeak<T>        |
+--------------------------+      +--------------------------+     +--------------------------+
      |                                     |                                |
 (Holds array of                            | (Has)                          | (Holds Inner* or null)
  *Inner pointers)                          |                                |
      |                                     v                                v
      |                              +--------------------------+
      |                              |   storage (extern union) |
      |                              |  - inline_data: [N]u8    |
      |                              |  - ptr_with_tag: usize   |
      |                              +--------------------------+
      |                                     |
      |                                     | (When pointer form)
      |                                     v
      |                              +--------------------------+
      |                              |  TaggedPointer(Inner*)   |
      |                              |  (carries 1‑bit tag)     |
      |                              +--------------------------+
      |                                     |
      |                                     v
      |                              +--------------------------+
      |----------------------------> |        Arc::Inner        |
                                     +--------------------------+
                                      /         |           \
                                     /          |            \
                                    v           v             v
                     +------------------+ +-----------+ +-------------+
                     | next_in_freelist | | Counters  | |   data (T)  |
                     +------------------+ +-----------+ +-------------+
```

## Notes

- ThreadLocalCache stores raw `*Inner` pointers (capacity fits in a cache line). It is strictly per‑thread and lock‑free.
- ArcPool<T>
  - Tier 1: try TLS cache
  - Tier 2: Treiber stack (global lock‑free freelist)
  - Tier 3: allocator (+mutex)
- TaggedPointer is used only when Arc<T> is in pointer form. It packs a single tag bit into the pointer’s low bits (alignment‑guaranteed) to indicate “inline vs pointer”.
- ArcCycleDetector<T> is for debugging. It needs a `trace` function describing how to find children (outgoing edges) inside `T`.

## When SVO triggers

- SVO is used when `T` is small and plain data (e.g., a few bytes, POD):
  - Arc<T>.storage = inline_data
  - No Inner allocation
- No Arc counters involved
- Otherwise, Arc<T> stores Inner*, and the counters (strong/weak) live inside Inner.

## Where to look in code

- Arc<T>: `utils/src/arc/arc.zig`
- ArcPool<T>: `utils/src/arc/arc-pool/arc_pool.zig`
- ThreadLocalCache: `utils/src/thread-local-cache/thread_local_cache.zig`
- TaggedPointer: `utils/src/tagged-pointer/tagged_pointer.zig`
- Cycle detector: `utils/src/arc/cycle-detector/arc_cycle_detector.zig`
