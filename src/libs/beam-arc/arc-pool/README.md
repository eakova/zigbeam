# ArcPool (Zig‑Beam)

High‑throughput reuse pool for Arc(T) heap allocations.

## What It Is
- L1: lock‑free ThreadLocalCache of `*Arc(T).Inner` per thread
- L2: sharded Treiber freelists (global); batched pushes to cut CAS traffic
- L3: allocator behind a mutex for safety with non‑thread‑safe allocators
- Applies only to heap Arc(T). Small Value Optimization (SVO) arcs bypass the pool

## Quick Start
```zig
const std = @import("std");
const beam = @import("zig_beam");

const Payload = [64]u8;
const Pool = beam.Libs.ArcPool(Payload, false); // stats=false (default)

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var pool = Pool.init(alloc, .{});
    defer pool.deinit();

    const payload = [_]u8{0} ** 64;
    const a = try pool.create(payload);
    pool.recycle(a);
}
```

## Keys
- Heap‑only: works with Arc(T) when T is not SVO‑eligible
- Sharded freelists: fewer hot‑spot collisions under MT
- TLS warm path: most hits never touch the global list
- Safe fallback: alloc behind a mutex for broad allocator support

## Code & Commands
- Source: `src/libs/arc/arc-pool/arc_pool.zig`
- Bench: `zig build bench-arc-pool` → `src/libs/arc/ARC_POOL_BENCHMARKS.md`
- Run all tests: `zig build test`

Tip (local caches):
```bash
export ZIG_GLOBAL_CACHE_DIR=$PWD/.zig-global-cache
export ZIG_LOCAL_CACHE_DIR=$PWD/.zig-local-cache
```
