# ZigBeam: Reusable building blocks for concurrent programming

![Zig 0.13.0+](https://img.shields.io/badge/Zig-0.13.0+-blue)
![License](https://img.shields.io/badge/license-MIT_OR_Apache--2.0-blue.svg)


This repository hosts multiple Zig libraries under one roof. Each library can be used on its own or together via a common wrapper. The workspace is designed to be practical: every library ships with small samples, focused tests, and repeatable benchmarks.

---

## Libraries

### Parallelism

#### Loom
- High-performance work-stealing thread pool with structured concurrency
- Rayon-like parallel iterators (`par_iter`, `par_range`), fork-join (`join`, `scope`)
- **Performance**: forEach ~2-3ns, reduce ~2ns, map ~0.6ns, count ~0.3ns per element
- Import: `@import("zigbeam").Loom`
- Samples: `zig build samples-loom`
- Source: [src/loom/loom.zig](src/loom/loom.zig)
- Tests: `zig build test-loom`
- Docs: [src/loom/README.md](src/loom/README.md)
- FAQ: [src/loom/docs/FAQ.md](src/loom/docs/FAQ.md)

---

### Concurrent Data Structures

#### Deque
- Bounded work-stealing deque for building task schedulers and thread pools
- **Performance**: Owner push ~2-5ns, Owner pop ~3-10ns, Steal ~20-50ns
- Import: `@import("zigbeam").Libs.Deque`
- Source: [src/libs/deque/deque.zig](src/libs/deque/deque.zig)
- Tests: `zig build test-deque`
- Benchmarks: `zig build bench-deque`
- Docs: [src/libs/deque/README.md](src/libs/deque/README.md)

#### DequeChannel
- MPMC work-stealing channel with automatic load balancing
- **Performance**: Send fast path ~5-15ns, Recv ~5-80ns depending on source
- Import: `@import("zigbeam").Libs.DequeChannel`
- Source: [src/libs/deque/deque_channel.zig](src/libs/deque/deque_channel.zig)
- Tests: `zig build test-deque-channel`
- Benchmarks: `zig build bench-deque-channel`

#### DVyukov MPMC Queue
- Lock-free bounded Multi-Producer Multi-Consumer queue (Dmitry Vyukov's algorithm)
- **Performance**: 20-100 Mops/s under high contention
- Import: `@import("zigbeam").Libs.DVyukovMPMCQueue`
- Samples: `zig build samples-dvyukov`
- Source: [src/libs/dvyukov-mpmc/dvyukov_mpmc_queue.zig](src/libs/dvyukov-mpmc/dvyukov_mpmc_queue.zig)
- Tests: `zig build test-dvyukov`

#### Sharded DVyukov MPMC Queue
- High-performance variant distributing contention across multiple independent queues
- **Performance**: 100-133 Mops/s (2.5-6x faster than non-sharded under high contention)
- **Use when**: 4+ producers AND 4+ consumers with balanced workload
- Import: `@import("zigbeam").Libs.ShardedDVyukovMPMCQueue`
- Source: [src/libs/dvyukov-mpmc/sharded_dvyukov_mpmc_queue.zig](src/libs/dvyukov-mpmc/sharded_dvyukov_mpmc_queue.zig)

#### SegmentedQueue
- Unbounded MPMC queue with dynamic growth using segmented memory
- Import: `@import("zigbeam").Libs.SegmentedQueue`
- Source: [src/libs/segmented-queue/segmented_queue.zig](src/libs/segmented-queue/segmented_queue.zig)
- Tests: `zig build test-segmented-queue`

---

### Memory Management

#### Arc
- Atomic smart pointer with Small Value Optimization (SVO) and weak references
- Import: `@import("zigbeam").Libs.Arc`
- Samples: `zig build samples-arc`
- Source: [src/libs/arc/arc.zig](src/libs/arc/arc.zig)
- Tests: `zig build test-arc`

#### Arc Pool
- Reuse `Arc(T).Inner` allocations; fronted by ThreadLocalCache and global Treiber stack
- Import: `@import("zigbeam").Libs.ArcPool`
- Source: [src/libs/arc/arc-pool/arc_pool.zig](src/libs/arc/arc-pool/arc_pool.zig)
- Tests: `zig build test-arc-pool`

#### Cycle Detector
- Debug utility to find unreachable Arc cycles using a user-provided trace function
- Import: `@import("zigbeam").Libs.ArcCycleDetector`
- Source: [src/libs/arc/cycle-detector/arc_cycle_detector.zig](src/libs/arc/cycle-detector/arc_cycle_detector.zig)
- Tests: `zig build test-arc-cycle`

#### Thread-Local Cache
- Per-thread, lock-free L1 pool to reduce allocator pressure and contention
- Import: `@import("zigbeam").Libs.ThreadLocalCache`
- Samples: `zig build samples-tlc`
- Source: [src/libs/thread-local-cache/thread_local_cache.zig](src/libs/thread-local-cache/thread_local_cache.zig)
- Tests: `zig build test-tlc`

#### EBR (Epoch-Based Reclamation)
- Lock-free memory reclamation for concurrent data structures
- Import: primarily used by `SegmentedQueue` as its EBR engine
- Samples: `zig build samples-ebr`
- Source: [src/libs/ebr/ebr.zig](src/libs/ebr/ebr.zig)
- Docs: [src/libs/ebr/README.md](src/libs/ebr/README.md)

---

### Threading

#### Task
- Cancellable OS-thread task abstraction (inspired by C#'s CancellationToken)
- Import: `@import("zigbeam").Libs.Task`
- Source: [src/libs/task/task.zig](src/libs/task/task.zig)
- Tests: `zig build test-task`
- Docs: [src/libs/task/README.md](src/libs/task/README.md)

---

### Core Primitives

#### Backoff
- Exponential/spin/snooze backoff helper for contention control and polling loops
- Source: [src/libs/backoff/backoff.zig](src/libs/backoff/backoff.zig)
- Samples: [src/libs/backoff/samples/_backoff_samples.zig](src/libs/backoff/samples/_backoff_samples.zig)

#### CachePadded
- Cache-line aware padding helpers for isolating hot fields and atomics
- Source: [src/libs/cache-padded/cache_padded.zig](src/libs/cache-padded/cache_padded.zig)
- Docs: [src/libs/cache-padded/docs/CACHE_PADDED_IMPLEMENTATION.md](src/libs/cache-padded/docs/CACHE_PADDED_IMPLEMENTATION.md)

#### Tagged Pointer
- Pack a small tag into a pointer's low bits (common for lightweight flags)
- Import: `@import("zigbeam").Libs.TaggedPointer`
- Samples: `zig build samples-tagged`
- Source: [src/libs/tagged-pointer/tagged_pointer.zig](src/libs/tagged-pointer/tagged_pointer.zig)
- Tests: `zig build test-tagged`

---

## Quick Start

### Installation

Add to your `build.zig.zon`:

```zig
.dependencies = .{
    .zigbeam = .{
        .url = "https://github.com/eakova/zigbeam/archive/refs/heads/main.tar.gz",
        .hash = "<run: zig fetch <url> --save>",
    },
},
```

Wire in `build.zig`:

```zig
const dep = b.dependency("zigbeam", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("zigbeam", dep.module("zigbeam"));
```

### Usage

```zig
const beam = @import("zigbeam");
const Loom = beam.Loom;

// Parallel iteration with Loom
Loom.par_iter(data).for_each(process);
const sum = Loom.par_iter(data).reduce(Loom.Reducer(i64).sum());

// Fork-join parallelism
const left, const right = Loom.join(taskA, .{}, taskB, .{});

// Concurrent data structures
const Deque = beam.Libs.Deque;
const DVyukovMPMCQueue = beam.Libs.DVyukovMPMCQueue;

// Memory management
const Arc = beam.Libs.Arc;
var arc = try Arc(u64).init(allocator, 42);
defer arc.release();

// Threading
const Task = beam.Libs.Task;
```

---

## Requirements

- **Zig**: 0.13.0 or later
- **OS**: macOS, Linux, Windows
- **Dependencies**: Standard library only (`std.Thread`, `std.atomic`, `std.time`)

---

## Layout

```
src/libs/
+-- loom/              # Parallelism (thread pool, parallel iterators)
+-- deque/             # Work-stealing deque and channel
+-- dvyukov-mpmc/      # Lock-free MPMC queues
+-- segmented-queue/   # Unbounded MPMC queue
+-- arc/               # Atomic reference counting + pool + cycle detector
+-- thread-local-cache/# Per-thread L1 cache
+-- ebr/               # Epoch-based reclamation
+-- task/              # Cancellable threads
+-- backoff/           # Contention backoff
+-- cache-padded/      # Cache-line padding
+-- tagged-pointer/    # Bit-packed pointers
```

---

## Benchmarks

| Library | Metric | Performance |
|---------|--------|-------------|
| Loom | forEach per element | ~2-3ns |
| Loom | reduce per element | ~2ns |
| Loom | map per element | ~0.6ns |
| Loom | count per element | ~0.3ns |
| DVyukov MPMC | High contention | 20-100 Mops/s |
| Sharded DVyukov | High contention | 100-133 Mops/s |
| Deque | Owner push | ~2-5ns |
| Deque | Steal | ~20-50ns |
| DequeChannel | Send fast path | ~5-15ns |

Detailed reports:
- [Loom](src/loom/README.md)
- [Arc](src/libs/arc/benchmarks/ARC_BENCHMARK_RESULTS.md)
- [DVyukov MPMC](src/libs/dvyukov-mpmc/benchmarks/DVYUKOV_MPMC_BENCHMARK_RESULTS.md)
- [Thread-Local Cache](src/libs/thread-local-cache/benchmarks/TLC_BENCHMARK_RESULTS.md)

---

## Contributing

Contributions are welcome in the form of issues, PRs, and feedback. Please include:
- Zig version
- OS/arch
- Exact build command
- A minimal snippet or path to a failing sample/test

File issues: https://github.com/eakova/zigbeam/issues/new

---

## License

Licensed under either of:

- Apache License, Version 2.0 ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
- MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)

at your option.

### Contribution

Unless you explicitly state otherwise, any contribution intentionally submitted for inclusion in the work by you, as defined in the Apache-2.0 license, shall be dual licensed as above, without any additional terms or conditions.
