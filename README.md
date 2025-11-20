# Zig-Beam: Reusable building blocks for concurrent programming

![Zig 0.13.0+](https://img.shields.io/badge/Zig-0.13.0+-blue)
![License](https://img.shields.io/badge/license-MIT_OR_Apache--2.0-blue.svg)
![CI](https://github.com/eakova/zig-beam/actions/workflows/ci.yml/badge.svg)

This repository hosts multiple Zig libraries under one roof. Each library can be used on its own or together via a common wrapper. The workspace is designed to be practical: every library ships with small samples, focused tests, and repeatable benchmarks.

#### Arc
- Atomic smart pointer with Small Value Optimization (SVO) and weak references
- Import: `@import("zig_beam").Libs.Arc`
- Samples: `zig build samples-arc`
- Source: [src/libs/arc/arc.zig](src/libs/arc/arc.zig)
- Tests: `zig build test-arc`

#### Arc Pool
- Reuse `Arc(T).Inner` allocations; fronted by ThreadLocalCache and global Treiber stack
- Import: `@import("zig_beam").Libs.ArcPool`
- Samples: (covered in Arc samples)
- Source: [src/libs/arc/arc-pool/arc_pool.zig](src/libs/arc/arc-pool/arc_pool.zig)
- Tests: `zig build test-arc-pool`

#### Cycle Detector
- Debug utility to find unreachable Arc cycles using a user-provided trace function
- Import: `@import("zig_beam").Libs.ArcCycleDetector`
- Source: [src/libs/arc/cycle-detector/arc_cycle_detector.zig](src/libs/arc/cycle-detector/arc_cycle_detector.zig)
- Tests: `zig build test-arc-cycle`

#### Thread-Local Cache
- Per-thread, lock-free L1 pool to reduce allocator pressure and contention
- Import: `@import("zig_beam").Libs.ThreadLocalCache`
- Samples: `zig build samples-tlc`
- Source: [src/libs/thread-local-cache/thread_local_cache.zig](src/libs/thread-local-cache/thread_local_cache.zig)
- Tests: `zig build test-tlc`

#### Tagged Pointer
- Pack a small tag into a pointer's low bits (common for lightweight flags)
- Import: `@import("zig_beam").Libs.TaggedPointer`
- Samples: `zig build samples-tagged`
- Source: [src/libs/tagged-pointer/tagged_pointer.zig](src/libs/tagged-pointer/tagged_pointer.zig)
- Tests: `zig build test-tagged`

#### Beam-Ebr (Epoch-Based Reclamation)
- Lock-free memory reclamation for concurrent data structures
- Import: `@import("zig_beam").Libs.BeamEbr`
- Samples: `zig build samples-ebr`
- Source: [src/libs/beam-ebr/ebr.zig](src/libs/beam-ebr/ebr.zig)
- Tests: `zig build test`
- Docs: [src/libs/beam-ebr/README.md](src/libs/beam-ebr/README.md)

#### DVyukov MPMC Queue
- Lock-free bounded Multi-Producer Multi-Consumer queue (Dmitry Vyukov's algorithm)
- **Performance**: 20-100 Mops/s under high contention (industry-standard)
- Import: `@import("zig_beam").Libs.DVyukovMPMCQueue`
- Samples: `zig build samples-dvyukov`
- Source: [src/libs/dvyukov-mpmc-queue/dvyukov_mpmc_queue.zig](src/libs/dvyukov-mpmc-queue/dvyukov_mpmc_queue.zig)
- Tests: `zig build test-dvyukov`

#### Sharded DVyukov MPMC Queue
- High-performance variant distributing contention across multiple independent queues
- **Performance**: 100-133 Mops/s (2.5-6x faster than non-sharded under high contention)
- **Use when**: 4+ producers AND 4+ consumers with balanced workload
- Import: `@import("zig_beam").Libs.ShardedDVyukovMPMCQueue`
- Samples: (covered in DVyukov samples)
- Source: [src/libs/dvyukov-mpmc-queue/sharded_dvyukov_mpmc_queue.zig](src/libs/dvyukov-mpmc-queue/sharded_dvyukov_mpmc_queue.zig)
- Tests: `zig build test-dvyukov`

#### BeamDeque
- Bounded work-stealing deque for building task schedulers and thread pools
- **Performance**: Owner push ~2-5ns, Owner pop ~3-10ns, Steal ~20-50ns
- Import: `@import("zig_beam").Libs.BeamDeque`
- Source: [src/libs/beam-deque/beam_deque.zig](src/libs/beam-deque/beam_deque.zig)
- Tests: `zig build test-beam-deque`
- Benchmarks: `zig build bench-beam-deque`
- Docs: [src/libs/beam-deque/README.md](src/libs/beam-deque/README.md)

#### BeamDequeChannel
- MPMC work-stealing channel with automatic load balancing
- **Performance**: Send fast path ~5-15ns, Recv ~5-80ns depending on source
- Import: `@import("zig_beam").Libs.BeamDequeChannel`
- Source: [src/libs/beam-deque/beam_deque_channel.zig](src/libs/beam-deque/beam_deque_channel.zig)
- Tests: `zig build test-beam-deque-channel`
- Benchmarks: `zig build bench-beam-deque-channel`
- Docs: [src/libs/beam-deque/README.md](src/libs/beam-deque/README.md)

#### BeamTask
- Cancellable OS-thread task abstraction (inspired by C#'s CancellationToken)
- Import: `@import("zig_beam").Libs.BeamTask`
- Source: [src/libs/beam-task/task.zig](src/libs/beam-task/task.zig)
- Tests: `zig build test-beam-task`
- Docs: [src/libs/beam-task/README.md](src/libs/beam-task/README.md)

#### BoundedSPSCQueue
- Lock-free bounded Single-Producer Single-Consumer queue
- Import: `@import("zig_beam").Libs.BoundedSPSCQueue`
- Source: [src/libs/spsc-queue/spsc_queue.zig](src/libs/spsc-queue/spsc_queue.zig)
- Tests: `zig build test-spsc-queue`
- Benchmarks: `zig build bench-spsc-queue`

#### SegmentedQueue
- Unbounded MPMC queue with dynamic growth using segmented memory
- Import: `@import("zig_beam").Libs.SegmentedQueue`
- Source: [src/libs/segmented-queue/segmented_queue.zig](src/libs/segmented-queue/segmented_queue.zig)
- Tests: `zig build test-segmented-queue`
- Benchmarks: `zig build bench-segmented-queue`

## Requirements

- Zig 0.13.0 or later
- macOS, Linux, or Windows

## Libraries

- `src/libs/` — Concurrent programming primitives and data structures
  - **Arc**: Smart pointer with Small Value Optimization + pool + cycle detector
  - **Thread-Local Cache**: Lock-free per-thread L1 pool
  - **Tagged Pointer**: Bit-packed metadata in pointer low bits
  - **Beam-Ebr**: Epoch-Based Reclamation for safe memory reclamation
  - **DVyukov MPMC Queue**: Lock-free bounded queue (20-133 Mops/s)
  - **BeamDeque**: Work-stealing deque for task schedulers
  - **BeamDequeChannel**: MPMC work-stealing channel with load balancing
  - **BeamTask**: Cancellable OS-thread task abstraction
  - **BoundedSPSCQueue**: Lock-free single-producer single-consumer queue
  - **SegmentedQueue**: Unbounded MPMC queue with dynamic growth
  - Build targets: tests, samples, and benchmarks


## Use These Libraries In Your Project

You can consume libraries from this repo via Zig's package system (recommended) or by vendoring the code. Below shows the package approach with the `zig_beam` wrapper module (which exposes all libraries under `Libs`).

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
    const TaggedPointer = beam.Libs.TaggedPointer;

    // Thread-local cache
    const ThreadLocalCache = beam.Libs.ThreadLocalCache;

    // Arc core and pool
    const Arc = beam.Libs.Arc;
    const ArcPool = beam.Libs.ArcPool;

    // Beam-Ebr (Epoch-Based Reclamation)
    const BeamEbr = beam.Libs.BeamEbr;

    // DVyukov MPMC Queue
    const DVyukovMPMCQueue = beam.Libs.DVyukovMPMCQueue;
    const ShardedDVyukovMPMCQueue = beam.Libs.ShardedDVyukovMPMCQueue;

    // Work-stealing deque and channel
    const BeamDeque = beam.Libs.BeamDeque;
    const BeamDequeChannel = beam.Libs.BeamDequeChannel;

    // Cancellable task abstraction
    const BeamTask = beam.Libs.BeamTask;

    // Lock-free queues
    const BoundedSPSCQueue = beam.Libs.BoundedSPSCQueue;
    const SegmentedQueue = beam.Libs.SegmentedQueue;

    // minimal smoke check
    var gpa = std.heap.GeneralPurposeAllocator(.{}){}; defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    var arc_u64 = try Arc(u64).init(alloc, 42);
    defer arc_u64.release();
    std.debug.print("arc.get() = {}\n", .{arc_u64.get().*});
}
```

## Notes
- The `zig_beam` wrapper re-exports all libraries under `Libs` for easy access: Arc, Arc Pool, Cycle Detector, Thread-Local Cache, Tagged Pointer, Beam-Ebr, DVyukov MPMC Queue, Sharded DVyukov, BeamDeque, BeamDequeChannel, BeamTask, BoundedSPSCQueue, and SegmentedQueue.
- Benchmark reports are in each library's directory:
  - Arc: [src/libs/arc/ARC_BENCHMARKS.md](src/libs/arc/ARC_BENCHMARKS.md)
  - Arc Pool: [src/libs/arc/ARC_POOL_BENCHMARKS.md](src/libs/arc/ARC_POOL_BENCHMARKS.md)
  - Thread-Local Cache: [src/libs/thread-local-cache/BENCHMARKS.md](src/libs/thread-local-cache/BENCHMARKS.md)
  - DVyukov MPMC Queue: [src/libs/dvyukov-mpmc-queue/BENCHMARKS.md](src/libs/dvyukov-mpmc-queue/BENCHMARKS.md)
  - Sharded DVyukov: [src/libs/dvyukov-mpmc-queue/BENCHMARKS_SHARDED.md](src/libs/dvyukov-mpmc-queue/BENCHMARKS_SHARDED.md)

## Compatibility

OS support: macOS, Linux, Windows
- Uses only Zig std APIs (`std.Thread`, `std.time`, `std.fs`, `std.atomic`).
- If system caches are locked down, use the local cache variables above (bash/zsh or PowerShell).
- Cross-compiling: use `-Dtarget` if you need artifacts for another OS/arch.

Zig version policy: Requires Zig 0.13.0 or later.

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

- Zig version: Requires 0.13.0 or later
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
