# Zig-Beam: Reusable building blocks for concurrent programming

![Zig 0.15.x](https://img.shields.io/badge/Zig-0.15.x-blue)
![License](https://img.shields.io/badge/license-MIT_OR_Apache--2.0-blue.svg)
![CI](https://github.com/eakova/zig-beam/actions/workflows/ci.yml/badge.svg)

This repository hosts multiple Zig libraries under one roof. Each library can be used on its own or together via a common wrapper. The workspace is designed to be practical: every library ships with small samples, focused tests, and repeatable benchmarks.

Dependency graph/flow: [docs/utils/dependency_graph.md](docs/utils/dependency_graph.md)

#### Arc
- Atomic smart pointer with Small Value Optimization (SVO) and weak references
- Import: `@import("zig_beam").Utils.Arc`
- Samples: `zig build samples-arc`
- Source: [src/libs/arc/arc.zig](src/libs/arc/arc.zig)
- Tests: `zig build test-arc`
- Bench: `zig build bench-arc` → [ARC_BENCHMARKS.md](src/libs/arc/ARC_BENCHMARKS.md)

#### Arc Pool
- Reuse `Arc(T).Inner` allocations; fronted by ThreadLocalCache and global Treiber stack
- Import: `@import("zig_beam").Utils.ArcPool`
- Samples: (covered in Arc samples)
- Source: [src/libs/arc/arc-pool/arc_pool.zig](src/libs/arc/arc-pool/arc_pool.zig)
- Tests: `zig build test-arc-pool`
- Bench: `zig build bench-arc-pool` → [ARC_POOL_BENCHMARKS.md](src/libs/arc/ARC_POOL_BENCHMARKS.md)

#### Cycle Detector
- Debug utility to find unreachable Arc cycles using a user-provided trace function
- Import: `@import("zig_beam").Utils.ArcCycleDetector`
- Source: [src/libs/arc/cycle-detector/arc_cycle_detector.zig](src/libs/arc/cycle-detector/arc_cycle_detector.zig)
- Tests: `zig build test-arc-cycle`

#### Thread-Local Cache
- Per-thread, lock-free L1 pool to reduce allocator pressure and contention
- Import: `@import("zig_beam").Utils.ThreadLocalCache`
- Samples: `zig build samples-tlc`
- Source: [src/libs/thread-local-cache/thread_local_cache.zig](src/libs/thread-local-cache/thread_local_cache.zig)
- Tests: `zig build test-tlc`
- Bench: `zig build bench-tlc` → [BENCHMARKS.md](src/libs/thread-local-cache/BENCHMARKS.md)

#### Tagged Pointer
- Pack a small tag into a pointer's low bits (common for lightweight flags)
- Import: `@import("zig_beam").Utils.TaggedPointer`
- Samples: `zig build samples-tagged`
- Source: [src/libs/tagged-pointer/tagged_pointer.zig](src/libs/tagged-pointer/tagged_pointer.zig)
- Tests: `zig build test-tagged`

#### Epoch-Based Reclamation (EBR)
- Lock-free memory reclamation for concurrent data structures
- Import: `@import("zig_beam").Utils.EBR`
- Samples: `zig build samples-ebr`
- Source: [src/libs/ebr/ebr.zig](src/libs/ebr/ebr.zig)
- Tests: `zig build test-ebr`
- Bench: `zig build bench-ebr`

#### DVyukov MPMC Queue
- Lock-free bounded Multi-Producer Multi-Consumer queue (Dmitry Vyukov's algorithm)
- **Performance**: 20-100 Mops/s under high contention (industry-standard)
- Import: `@import("zig_beam").Utils.DVyukovMPMCQueue`
- Samples: `zig build samples-dvyukov`
- Source: [src/libs/dvyukov-mpmc-queue/dvyukov_mpmc_queue.zig](src/libs/dvyukov-mpmc-queue/dvyukov_mpmc_queue.zig)
- Tests: `zig build test-dvyukov`
- Bench: `zig build bench-dvyukov` → [BENCHMARKS.md](src/libs/dvyukov-mpmc-queue/BENCHMARKS.md)

#### Sharded DVyukov MPMC Queue
- High-performance variant distributing contention across multiple independent queues
- **Performance**: 100-133 Mops/s (2.5-6x faster than non-sharded under high contention)
- **Use when**: 4+ producers AND 4+ consumers with balanced workload
- Import: `@import("zig_beam").Utils.ShardedDVyukovMPMCQueue`
- Samples: (covered in DVyukov samples)
- Source: [src/libs/dvyukov-mpmc-queue/sharded_dvyukov_mpmc_queue.zig](src/libs/dvyukov-mpmc-queue/sharded_dvyukov_mpmc_queue.zig)
- Tests: `zig build test-dvyukov`
- Bench: `zig build bench-dvyukov` → [BENCHMARKS_SHARDED.md](src/libs/dvyukov-mpmc-queue/BENCHMARKS_SHARDED.md)

## Requirements

- Zig 0.15.x
- macOS, Linux, or Windows

## Libraries

- `src/libs/` — Foundational utilities
  - **Arc**: Smart pointer with Small Value Optimization + pool + cycle detector
  - **Thread-Local Cache**: Lock-free per-thread L1 pool
  - **Tagged Pointer**: Bit-packed metadata in pointer low bits
  - **EBR**: Epoch-Based Reclamation for safe memory reclamation
  - **DVyukov MPMC Queue**: Lock-free bounded queue (20-133 Mops/s)
  - Build targets: tests, samples, and benchmarks

## Usage

Run from repo root. The commands below target the utils library steps exposed at the top level.

```bash
zig build test                      # run all utils tests
zig build samples-arc               # run ARC samples
zig build samples-tlc               # run thread-local cache samples
zig build samples-tagged            # run tagged pointer samples
zig build bench-tlc                 # run thread-local cache benchmarks
zig build bench-arc                 # ARC benchmarks (single-thread)
ARC_BENCH_RUN_MT=1 zig build bench-arc   # ARC benchmarks (multi-thread)
```

For sandboxed or permission-limited environments, set local caches:

```bash
export ZIG_GLOBAL_CACHE_DIR=$PWD/.zig-global-cache
export ZIG_LOCAL_CACHE_DIR=$PWD/.zig-local-cache
```

Windows (PowerShell):
```powershell
$env:ZIG_GLOBAL_CACHE_DIR = "$PWD/.zig-global-cache"
$env:ZIG_LOCAL_CACHE_DIR  = "$PWD/.zig-local-cache"
```

## Examples

TaggedPointer (encode/decode):
```zig
const beam = @import("zig_beam");
const TaggedPointer = beam.Utils.TaggedPointer;
const Ptr = TaggedPointer(*usize, 1);
var x: usize = 123;
const bits = (try Ptr.new(&x, 1)).toUnsigned();
const decoded = Ptr.fromUnsigned(bits);
// decoded.getPtr() == &x, decoded.getTag() == 1
```

Thread‑Local Cache (push/pop/clear):
```zig
const beam = @import("zig_beam");
const Cache = beam.Utils.ThreadLocalCache(*usize, null);
var cache: Cache = .{};
var v: usize = 1;
_ = cache.push(&v);
_ = cache.pop();
cache.clear(null);
```

Arc (init/clone/release):
```zig
const beam = @import("zig_beam");
const Arc = beam.Utils.Arc(u64);
var gpa = std.heap.GeneralPurposeAllocator(.{}){}; defer _ = gpa.deinit();
const alloc = gpa.allocator();
var a = try Arc.init(alloc, 42); defer a.release();
var b = a.clone(); defer b.release();
// a.get().* == 42, b.get().* == 42
```

DVyukov MPMC Queue (enqueue/dequeue):
```zig
const beam = @import("zig_beam");
const DVyukovMPMCQueue = beam.Utils.DVyukovMPMCQueue;
const Queue = DVyukovMPMCQueue(u64, 1024); // u64 items, capacity 1024
var gpa = std.heap.GeneralPurposeAllocator(.{}){}; defer _ = gpa.deinit();
var queue = try Queue.init(gpa.allocator()); defer queue.deinit();

// Producer: enqueue items
queue.enqueue(42) catch |err| {
    // Handle QueueFull error
};

// Consumer: dequeue items
if (queue.dequeue()) |item| {
    // Process item
} else {
    // Queue was empty
}
```

## Use These Libraries In Your Project

You can consume libraries from this repo via Zig’s package system (recommended) or by vendoring the code. Below shows the package approach with the `zig_beam` wrapper module (which exposes the utils library under `Utils`).

1) Add the dependency to your `build.zig.zon`

```zig
// build.zig.zon (top-level of your app)
.{
    .name = "your-app",
    .version = "0.1.0",
    .dependencies = .{
        .zig_beam = .{
            // Track a tag or commit tarball (recommended)
            .url = "https://github.com/eakova/zig-beam/archive/refs/heads/main.tar.gz",
            // Compute and fill the content hash:
            //   zig fetch https://github.com/eakova/zig-beam/archive/refs/heads/main.tar.gz --save
            .hash = "<fill-with-zig-fetch-output>",
        },
    },
}
```

Tip: run `zig fetch <url> --save` to automatically compute and insert the `hash`.

2) Wire the dependency in your `build.zig`

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Declare a dependency on zig-beam package
    const beam_dep = b.dependency("zig_beam", .{ .target = target, .optimize = optimize });
    const beam = beam_dep.module("zig_beam");

    // Example: an executable that imports zig_beam
    const exe = b.addExecutable(.{
        .name = "your-app",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("zig_beam", beam);
    b.installArtifact(exe);
}
```

3) Import and use in your code

```zig
// src/main.zig
const std = @import("std");
const beam = @import("zig_beam");

pub fn main() !void {
    // Tagged pointer
    const TaggedPointer = beam.Utils.TaggedPointer;

    // Thread-local cache
    const ThreadLocalCache = beam.Utils.ThreadLocalCache;

    // Arc core and pool
    const Arc = beam.Utils.Arc;
    const ArcPool = beam.Utils.ArcPool;

    // EBR (Epoch-Based Reclamation)
    const EBR = beam.Utils.EBR;

    // DVyukov MPMC Queue
    const DVyukovMPMCQueue = beam.Utils.DVyukovMPMCQueue;
    const ShardedDVyukovMPMCQueue = beam.Utils.ShardedDVyukovMPMCQueue;

    // minimal smoke check
    var gpa = std.heap.GeneralPurposeAllocator(.{}){}; defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    var arc_u64 = try Arc(u64).init(alloc, 42);
    defer arc_u64.release();
    std.debug.print("arc.get() = {}\n", .{arc_u64.get().*});
}
```

## Notes
- The `zig_beam` wrapper re-exports all libraries under `Utils` for easy access: Tagged Pointer, Thread-Local Cache, Arc, Arc Pool, Cycle Detector, EBR, and DVyukov MPMC Queue.
- Benchmark reports are in each library's directory:
  - Arc: [src/libs/arc/ARC_BENCHMARKS.md](src/libs/arc/ARC_BENCHMARKS.md)
  - Arc Pool: [src/libs/arc/ARC_POOL_BENCHMARKS.md](src/libs/arc/ARC_POOL_BENCHMARKS.md)
  - Thread-Local Cache: [src/libs/thread-local-cache/BENCHMARKS.md](src/libs/thread-local-cache/BENCHMARKS.md)
  - DVyukov MPMC Queue: [src/libs/dvyukov-mpmc-queue/BENCHMARKS.md](src/libs/dvyukov-mpmc-queue/BENCHMARKS.md)
  - Sharded DVyukov: [src/libs/dvyukov-mpmc-queue/BENCHMARKS_SHARDED.md](src/libs/dvyukov-mpmc-queue/BENCHMARKS_SHARDED.md)

## Library Details

All libraries are in `src/libs/` and accessed via `@import("zig_beam").Utils`.

- **Tagged Pointer**: Store a small tag in pointer's low bits
  - Files: `src/libs/tagged-pointer/tagged_pointer.zig`
  - Run: `zig build test-tagged`, `zig build samples-tagged`

- **Thread-Local Cache**: Fixed-size, per-thread cache that frontloads a global pool
  - Files: `src/libs/thread-local-cache/thread_local_cache.zig`
  - Run: `zig build test-tlc`, `zig build samples-tlc`, `zig build bench-tlc`
  - Report: [BENCHMARKS.md](src/libs/thread-local-cache/BENCHMARKS.md)

- **Arc (Atomic Reference Counted)**: Thread-safe smart pointers with SVO, weak refs, and pool
  - Files: `src/libs/arc/arc.zig`, `src/libs/arc/arc-pool/arc_pool.zig`, `src/libs/arc/cycle-detector/arc_cycle_detector.zig`
  - Run: `zig build test-arc`, `zig build test-arc-pool`, `zig build test-arc-cycle`, `zig build samples-arc`, `zig build bench-arc`
  - Reports: [ARC_BENCHMARKS.md](src/libs/arc/ARC_BENCHMARKS.md), [ARC_POOL_BENCHMARKS.md](src/libs/arc/ARC_POOL_BENCHMARKS.md)

- **EBR (Epoch-Based Reclamation)**: Lock-free memory reclamation for concurrent data structures
  - Files: `src/libs/ebr/ebr.zig`
  - Run: `zig build test-ebr`, `zig build samples-ebr`, `zig build bench-ebr`

- **DVyukov MPMC Queue**: Lock-free bounded queue with sharded variant for high contention
  - Files: `src/libs/dvyukov-mpmc-queue/dvyukov_mpmc_queue.zig`, `src/libs/dvyukov-mpmc-queue/sharded_dvyukov_mpmc_queue.zig`
  - Run: `zig build test-dvyukov`, `zig build samples-dvyukov`, `zig build bench-dvyukov`
  - Reports: [BENCHMARKS.md](src/libs/dvyukov-mpmc-queue/BENCHMARKS.md), [BENCHMARKS_SHARDED.md](src/libs/dvyukov-mpmc-queue/BENCHMARKS_SHARDED.md)

## Benchmarks

- Default build: ReleaseFast
- Iterations scale to keep total runtime under ~1 minute
- Reports include machine info (OS, arch, build mode, pointer width, CPU count)
- Console prints a short summary with a link to the Markdown report
- Multi-thread runs are opt-in via an environment variable (e.g., `ARC_BENCH_RUN_MT=1`)
  and use only standard library threading (`std.Thread`).

## Compatibility

OS support: macOS, Linux, Windows
- Uses only Zig std APIs (`std.Thread`, `std.time`, `std.fs`, `std.atomic`).
- If system caches are locked down, use the local cache variables above (bash/zsh or PowerShell).
- Cross-compiling: use `-Dtarget` if you need artifacts for another OS/arch.

Zig version policy: pinned to 0.15.x.

## Layout Conventions

- `src/` — library code (keep public API in files imported by the library’s `build.zig`)
- `docs/` — generated benchmark reports and diagrams
- Samples — `_..._samples.zig` with `pub fn main() !void` so they can run via `zig run`
- Tests — `_..._unit_tests.zig`, `_..._integration_tests.zig`, `_..._fuzz_tests.zig` (as applicable)
- Benchmarks — `_..._benchmarks.zig`, write to `docs/` and print a short console summary

## Adding a New Library

1. Create `/<lib>/src/` and `/<lib>/docs/`
2. Add a `/<lib>/build.zig` with targets for:
   - `zig build test-<lib>`
   - `zig build samples-<lib>`
   - `zig build bench-<lib>` (write a Markdown report)
3. Provide:
   - One small sample (`_..._samples.zig`) with `main()`
   - Focused unit tests (and an integration/fuzz test if needed)
   - A short `/<lib>/README.md` with description and commands

## Releases & Compatibility

- Zig version: pinned to 0.15.x for this workspace
- Upgrades: document in this file when bumping Zig or making breaking API changes
- Versioning: each library can tag releases independently

## CI

- Build matrix: Zig (pinned + next), OS (macOS, Linux)
- Jobs:
  - Build + test for each library
  - Run samples (smoke check)
- Run benchmarks (ReleaseFast, quick mode) and publish Markdown reports

## Contributing

Contributions are welcome in the form of issues, PRs, and feedback. Please include:
- Zig version
- OS/arch
- Exact build command
- A minimal snippet or path to a failing sample/test

Good first steps:
- File a bug or feature request: https://github.com/eakova/zig-beam/issues/new
- Propose improvements to samples/bench docs or add a new small sample

## License

Licensed under either of

* Apache License, Version 2.0 ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
* MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)

at your option.

### Contribution

Unless you explicitly state otherwise, any contribution intentionally submitted
for inclusion in the work by you, as defined in the Apache-2.0 license, shall be
dual licensed as above, without any additional terms or conditions.

## Support

Issues and PRs are welcome. Please include:
- Zig version
- OS/arch
- Exact build command
- A short snippet or a link to a failing sample/test
