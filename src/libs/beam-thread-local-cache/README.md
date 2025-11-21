# Thread‑Local Cache (Zig‑Beam)

Per‑thread lock‑free L1 reuse cache with an opt‑in global return callback.

## What It Is
- Fixed‑capacity array per thread; O(1) push/pop with no locking
- When full, evicts via a user‑provided callback (e.g., return to a global pool)
- Used by ArcPool as the fast path before global sharded freelists

## Quick Start
```zig
const std = @import("std");
const beam = @import("zig_beam");

const Item = *usize;
fn on_evict(ctx: ?*anyopaque, it: Item) void {
    _ = ctx; _ = it; // return to global in real use
}

const Cache = beam.Libs.ThreadLocalCacheWithCapacity(Item, on_evict, 64);
threadlocal var tls: Cache = .{};

pub fn main() void {
    var x: usize = 0;
    _ = tls.push(&x);      // true if accepted
    if (tls.pop()) |p| { _ = p; }
}
```

## Notes
- Capacity is compile‑time; ArcPool computes an effective runtime limit on top
- No hidden synchronization across threads; each thread has its own instance
- Callback sees items evicted from the local cache (common: push to global pool)

## Code & Commands
- Source: `src/libs/thread-local-cache/thread_local_cache.zig`
- Bench: `zig build bench-tlc` → `src/libs/thread-local-cache/BENCHMARKS.md`
- Tests/Samples: `zig build test`, `zig build samples-tlc`
