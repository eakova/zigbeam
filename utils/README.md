## Utils Library Overview

This directory hosts standalone Zig modules that can be consumed individually or
all at once via `src/root.zig`. Each submodule ships with its own targeted test
suites and (where relevant) micro-benchmarks. Run the commands below from
`utils/`.

## Tagged Pointer
Purpose
- Pack a small tag into the low bits of a pointer (commonly used to flag variants)

Commands

```bash
zig test src/tagged-pointer/_tagged_pointer_unit_tests.zig
zig test src/tagged-pointer/_tagged_pointer_integration_tests.zig
zig test src/tagged-pointer/_tagged_pointer_samples.zig
zig build test-tagged
zig build samples-tagged
```

Minimal example
```zig
const TaggedPointer = @import("zig_beam_utils").tagged_pointer.TaggedPointer;
const Ptr = TaggedPointer(*usize, 1);
var v: usize = 0;
const bits = (try Ptr.new(&v, 1)).toUnsigned();
const tagged = Ptr.fromUnsigned(bits);
// tagged.getPtr() == &v, tagged.getTag() == 1
```

## Thread-Local Cache
Purpose
- Lock-free, per-thread L1 cache that reduces allocator pressure and contention.

Commands

```bash
zig test src/thread-local-cache/_thread_local_cache_unit_tests.zig
zig test src/thread-local-cache/_thread_local_cache_integration_test.zig
zig test src/thread-local-cache/_thread_local_cache_fuzz_tests.zig
zig test src/thread-local-cache/_thread_local_cache_samples.zig
zig build test-tlc
zig build samples-tlc
zig build bench-tlc   # runs _thread_local_cache_benchmarks.zig and updates docs
```

Docs
- Report: [`utils/docs/thread_local_cache_benchmark_results.md`](../docs/thread_local_cache_benchmark_results.md)

Minimal example
```zig
const Cache = @import("zig_beam_utils").thread_local_cache.ThreadLocalCache(*usize, null);
var cache: Cache = .{};
var x: usize = 1;
_ = cache.push(&x);
_ = cache.pop();
cache.clear(null);
```

## Arc Core
Purpose
- Atomic reference counting, SVO for small data, weak references, and pooling support.

Commands

```bash
zig test src/arc/_arc_unit_tests.zig
zig test src/arc/_arc_integration_tests.zig
zig test src/arc/_arc_fuzz_tests.zig
zig test src/arc/_arc_samples.zig
zig build test-arc
zig build samples-arc
zig build bench-arc                  # single-threaded benchmarks + report
ARC_BENCH_RUN_MT=1 zig build bench-arc  # also enables multi-thread benchmark
```

Docs
- Report: [`utils/docs/arc_benchmark_results.md`](../docs/arc_benchmark_results.md)
- Dependency & interaction: [`utils/docs/dependency_graph.md`](../docs/dependency_graph.md)

Minimal example
```zig
const Arc = @import("zig_beam_utils").arc.Arc(u64);
var gpa = std.heap.GeneralPurposeAllocator(.{}){}; defer _ = gpa.deinit();
const alloc = gpa.allocator();
var a = try Arc.init(alloc, 42); defer a.release();
var b = a.clone(); defer b.release();
// a.get().* == 42, b.get().* == 42
```

## Arc Pool
Multi-layer allocator (TLS cache + Treiber stack + allocator fallback) that
recycles `Arc.Inner` blocks for heap-backed payloads.

```bash
zig test src/arc/arc-pool/_arc_pool_unit_tests.zig
zig test src/arc/arc-pool/_arc_pool_integration_tests.zig
zig build test-arc-pool
```

## Arc Cycle Detector
Debug-only tracing utility to surface reference cycles in complex Arc graphs.

```bash
zig test src/arc/cycle-detector/_arc_cycle_detector_unit_tests.zig
zig test src/arc/cycle-detector/_arc_cycle_detector_integration_tests.zig
zig build test-arc-cycle
```

## Full Suite
```bash
zig build test
```

## Local caches (optional)

To avoid system cache permission issues, set local cache folders in the library root (`utils/`).

macOS/Linux (bash/zsh):
```bash
export ZIG_GLOBAL_CACHE_DIR=$PWD/.zig-global-cache
export ZIG_LOCAL_CACHE_DIR=$PWD/.zig-local-cache
```

Windows (PowerShell):
```powershell
$env:ZIG_GLOBAL_CACHE_DIR = "$PWD/.zig-global-cache"
$env:ZIG_LOCAL_CACHE_DIR  = "$PWD/.zig-local-cache"
```

## Compatibility

- OS: macOS, Linux, Windows
- Zig: 0.15.x
- Uses only standard library APIs (`std.Thread`, `std.time`, `std.fs`, `std.atomic`).

## Use `utils` In Your Project

Consume the `utils` library via Zig’s package system (recommended). This exposes the wrapper module `zig_beam_utils`, which re‑exports tagged pointer, thread‑local cache, Arc, pool, and cycle detector.

1) Add to your `build.zig.zon`

```zig
.{
    .name = "your-app",
    .version = "0.1.0",
    .dependencies = .{
        .zig_beam_utils = .{
            .url = "https://github.com/eakova/zig-beam/archive/refs/heads/main.tar.gz",
            // Fill with: zig fetch <url> --save
            .hash = "<fill-with-zig-fetch-output>",
        },
    },
}
```

2) Wire it in your `build.zig`

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const dep = b.dependency("zig_beam_utils", .{ .target = target, .optimize = optimize });
    const beam_utils = dep.module("zig_beam_utils");

    const exe = b.addExecutable(.{
        .name = "your-app",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("zig_beam_utils", beam_utils);
    b.installArtifact(exe);
}
```

3) Import and use

```zig
// src/main.zig
const std = @import("std");
const utils = @import("zig_beam_utils");

pub fn main() !void {
    // Examples
    const TaggedPointer = utils.tagged_pointer.TaggedPointer;
    const ThreadLocalCache = utils.thread_local_cache.ThreadLocalCache;
    const Arc = utils.arc.Arc;
    const ArcPool = utils.arc_pool.ArcPool;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){}; defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    var arc_u64 = try Arc(u64).init(alloc, 42);
    defer arc_u64.release();
    std.debug.print("arc.get() = {}\n", .{arc_u64.get().*});
}
```
