# Arc and ArcPool (Zig‑Beam)

Fast atomic reference counting with a reuse pool and optional cycle detection.

## Highlights
- Arc(T) smart pointer with Small Value Optimization (SVO) for tiny payloads
- ArcWeak(T) for downgrade/upgrade flows (no ownership)
- ArcPool(T) to recycle Arc inner allocations; reduces allocator pressure and contention
- Thread‑safe; scales across threads; stats off by default in production paths
- Samples, unit/integration tests, and benchmarks included

## Quick Start

Import via the wrapper module and use the `Libs` namespace:

```zig
const beam = @import("zigbeam");
const ArcU32 = beam.Libs.Arc(u32);
const Pool = beam.Libs.ArcPool([64]u8, false); // stats=false (default)

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Arc — SVO example
    var a = try ArcU32.init(allocator, 42);
    defer a.release();
    const b = a.clone();
    defer b.release();

    // ArcPool — create/recycle example
    var pool = Pool.init(allocator, .{});
    defer pool.deinit();
    const payload = [_]u8{0} ** 64;
    const p = try pool.create(payload);
    pool.recycle(p);
}
```

## Layout
- Source: `src/libs/arc/`
  - `arc.zig` (Arc core), `arc_weak.zig` (weak refs)
  - `arc-pool/arc_pool.zig` (ArcPool)
  - `cycle-detector/arc_cycle_detector.zig` (optional diagnostic)
- Samples: `src/libs/arc/_arc_samples.zig`
- Tests: `src/libs/arc/_arc_unit_tests.zig`, `src/libs/arc/_arc_integration_tests.zig`
- Benchmarks: `src/libs/arc/_arc_benchmarks.zig`, `src/libs/arc/arc-pool/_arc_pool_benchmarks.zig`

## Dependency & Interaction

Key corrections
- Arc<T>.storage is an extern union used for Small Value Optimization (SVO), not a tagged union.
- Pointer vs inline is distinguished by a 1‑bit tag carried inside a TaggedPointer over the Inner* (not a Zig tagged union).

High‑Level Relationships
- User application
  - Uses Arc<T> directly for shared ownership
  - Optionally allocates Arc<T> through ArcPool<T> for reuse
  - Optionally runs ArcCycleDetector<T> during debug/diagnostics
- ArcPool<T>
  - Fronted by a per‑thread ThreadLocalCache of pointers to Arc<T>.Inner
  - Falls back to global sharded lock‑free freelists (Treiber stacks)
  - Falls back to the allocator behind a mutex as a last tier
- ArcCycleDetector<T>
  - Tracks Inner* pointers to Arc<T> instances that might participate in cycles
  - Uses a user‑provided trace function to discover edges (children)
- Arc<T>
  - Owns either inline data (SVO) or a pointer to Inner
  - Differentiates “inline vs pointer” with a 1‑bit tag (via TaggedPointer over Inner*)

```
+--------------------------+
|      User Application    |
+--------------------------+
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

Notes
- ThreadLocalCache stores raw `*Inner` pointers (capacity fits in a cache line). It is strictly per‑thread and lock‑free.
- ArcPool<T>
  - Tier 1: try TLS cache
  - Tier 2: sharded Treiber freelists (global lock‑free) with batched pushes
  - Tier 3: allocator (+mutex)
- TaggedPointer is used only when Arc<T> is in pointer form. It packs a single tag bit into the pointer’s low bits (alignment‑guaranteed) to indicate “inline vs pointer”.
- ArcCycleDetector<T> is for debugging. It needs a `trace` function describing how to find children (outgoing edges) inside `T`.

When SVO triggers
- SVO is used when `T` is small and plain data (e.g., a few bytes, POD):
  - Arc<T>.storage = inline_data
  - No Inner allocation (no counters)
- Otherwise, Arc<T> stores Inner*, and the counters (strong/weak) live inside Inner.

Where to look in code
- Arc<T>: `src/libs/arc/arc.zig`
- ArcPool<T>: `src/libs/arc/arc-pool/arc_pool.zig`
- ThreadLocalCache: `src/libs/thread-local-cache/thread_local_cache.zig`
- TaggedPointer: `src/libs/tagged-pointer/tagged_pointer.zig`
- Cycle detector: `src/libs/arc/cycle-detector/arc_cycle_detector.zig`

Notes:
- ArcPool uses ThreadLocalCache (TLS) for L1 reuse and a global freelist for sharing.
- Cycle detector is optional and intended for debugging/self‑referential structures.

## Commands

From repo root:
- Build tests: `zig build test`
- Arc samples: `zig build samples-arc`
- Arc benchmarks: `zig build bench-arc` → `src/libs/arc/ARC_BENCHMARKS.md`
- ArcPool benchmarks: `zig build bench-arc-pool` → `src/libs/arc/ARC_POOL_BENCHMARKS.md`

Tip (local caches in constrained environments):
```bash
export ZIG_GLOBAL_CACHE_DIR=$PWD/.zig-global-cache
export ZIG_LOCAL_CACHE_DIR=$PWD/.zig-local-cache
```

## Benchmarks (Reports)
- Arc: `src/libs/arc/ARC_BENCHMARKS.md`
- ArcPool: `src/libs/arc/ARC_POOL_BENCHMARKS.md`

Benchmarks are iteration‑capped and report both ns/op (median) and throughput with human‑readable units.

## Compatibility
- Zig 0.15.x
- macOS, Linux, Windows

## Guidance
- Keep stats off on hot paths; enable only for explicit measurements.
- Favor SVO for tiny payloads; use pooled heap for medium/large ones.
- For bursty MT workloads, ArcPool typically offers the best allocator‑side performance.
