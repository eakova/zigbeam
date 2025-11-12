# Zig-Beam: Reusable building blocks for concurrent programming

![Zig 0.15.x](https://img.shields.io/badge/Zig-0.15.x-blue)
![License](https://img.shields.io/badge/license-MIT_OR_Apache--2.0-blue.svg)
![CI](https://github.com/eakova/zig-beam/actions/workflows/ci.yml/badge.svg)

This repository hosts multiple Zig libraries under one roof. Each library can be used on its own or together via a common wrapper. The workspace is designed to be practical: every library ships with small samples, focused tests, and repeatable benchmarks.



<p><strong><span style="color:#d73a49"># NOTE:</span></strong> This repository is actively evolving and not yet
production‑ready. APIs and behavior may change without notice until the first tagged
release is published.</p>

Dependency graph/flow: [utils/docs/dependency_graph.md](utils/docs/dependency_graph.md)

#### Arc
- Atomic smart pointer with Small Value Optimization (SVO) and weak references
- Import: `zig_beam_utils.arc`
- Samples: `zig build samples-arc`
- Source: [utils/src/arc/arc.zig](utils/src/arc/arc.zig)
- Unit tests: [utils/src/arc/_arc_unit_tests.zig](utils/src/arc/_arc_unit_tests.zig)
- Integration tests: [utils/src/arc/_arc_integration_tests.zig](utils/src/arc/_arc_integration_tests.zig)
- Bench: `zig build bench-arc` [utils/docs/arc_benchmark_results.md](utils/docs/arc_benchmark_results.md)

#### Arc Pool
- Reuse `Arc(T).Inner` allocations; fronted by a ThreadLocalCache and a global Treiber stack
- Import: `zig_beam_utils.arc_pool`
- Samples: (covered in Arc samples)
- Source: [utils/src/arc/arc-pool/arc_pool.zig](utils/src/arc/arc-pool/arc_pool.zig)
- Unit tests: [utils/src/arc/arc-pool/_arc_pool_unit_tests.zig](utils/src/arc/arc-pool/_arc_pool_unit_tests.zig)
- Integration tests: [utils/src/arc/arc-pool/_arc_pool_integration_tests.zig](utils/src/arc/arc-pool/_arc_pool_integration_tests.zig)
- Bench: `zig build bench-arc` [utils/docs/arc_benchmark_results.md](utils/docs/arc_benchmark_results.md)

#### Thread‑Local Cache
- Per‑thread, lock‑free L1 pool to reduce allocator pressure and contention
- Import: `zig_beam_utils.thread_local_cache`
- Samples: `zig build samples-tlc`
- Source: [utils/src/thread-local-cache/thread_local_cache.zig](utils/src/thread-local-cache/thread_local_cache.zig)
- Unit tests: [utils/src/thread-local-cache/_thread_local_cache_unit_tests.zig](utils/src/thread-local-cache/_thread_local_cache_unit_tests.zig)
- Integration tests: [utils/src/thread-local-cache/_thread_local_cache_integration_test.zig](utils/src/thread-local-cache/_thread_local_cache_integration_test.zig)
- Bench: `zig build bench-tlc` [utils/docs/thread_local_cache_benchmark_results.md](utils/docs/thread_local_cache_benchmark_results.md)

#### Tagged Pointer
- Pack a small tag into a pointer’s low bits (common for lightweight flags)
- Import: `zig_beam_utils.tagged_pointer`
- Samples: `zig build samples-tagged`
- Source: [utils/src/tagged-pointer/tagged_pointer.zig](utils/src/tagged-pointer/tagged_pointer.zig)
- Unit tests: [utils/src/tagged-pointer/_tagged_pointer_unit_tests.zig](utils/src/tagged-pointer/_tagged_pointer_unit_tests.zig)
- Integration tests: [utils/src/tagged-pointer/_tagged_pointer_integration_tests.zig](utils/src/tagged-pointer/_tagged_pointer_integration_tests.zig)
- Bench: —

#### Cycle Detector
- Debug utility to find unreachable cycles of Arcs using a user‑provided trace function
- Import: `zig_beam_utils.arc_cycle_detector`
- Samples: —
- Source: [utils/src/arc/cycle-detector/arc_cycle_detector.zig](utils/src/arc/cycle-detector/arc_cycle_detector.zig)
- Unit tests: [utils/src/arc/cycle-detector/_arc_cycle_detector_unit_tests.zig](utils/src/arc/cycle-detector/_arc_cycle_detector_unit_tests.zig)
- Integration tests: [utils/src/arc/cycle-detector/_arc_cycle_detector_integration_tests.zig](utils/src/arc/cycle-detector/_arc_cycle_detector_integration_tests.zig)
- Bench: —

## Requirements

- Zig 0.15.x
- macOS, Linux, or Windows

## Libraries

- `utils/` — Foundational utilities
  - Arc smart pointer + pool + cycle detector
  - Thread-local cache (lock-free L1 pool)
  - Tagged pointer (bit-packed metadata)
  - Build targets: tests, samples, and benchmarks
- `zig-rcu/` — Reserved for future libraries (or your own)

Each library folder keeps its own `build.zig`, `src/`, and `docs/` (for reports).

## Usage

Run from inside a library folder (e.g., `utils/`). The commands below refer to `utils/` as an example.

```bash
cd utils
zig build test                      # run all tests for this library
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
const utils = @import("zig_beam_utils");
const TaggedPointer = utils.tagged_pointer.TaggedPointer;
const Ptr = TaggedPointer(*usize, 1);
var x: usize = 123;
const bits = (try Ptr.new(&x, 1)).toUnsigned();
const decoded = Ptr.fromUnsigned(bits);
// decoded.getPtr() == &x, decoded.getTag() == 1
```

Thread‑Local Cache (push/pop/clear):
```zig
const utils = @import("zig_beam_utils");
const Cache = utils.thread_local_cache.ThreadLocalCache(*usize, null);
var cache: Cache = .{};
var v: usize = 1;
_ = cache.push(&v);
_ = cache.pop();
cache.clear(null);
```

Arc (init/clone/release):
```zig
const utils = @import("zig_beam_utils");
const Arc = utils.arc.Arc(u64);
var gpa = std.heap.GeneralPurposeAllocator(.{}){}; defer _ = gpa.deinit();
const alloc = gpa.allocator();
var a = try Arc.init(alloc, 42); defer a.release();
var b = a.clone(); defer b.release();
// a.get().* == 42, b.get().* == 42
```

## Use These Libraries In Your Project

You can consume libraries from this repo via Zig’s package system (recommended) or by vendoring the code. Below shows the package approach with the `utils` library and its wrapper module `zig_beam_utils`.

1) Add the dependency to your `build.zig.zon`

```zig
// build.zig.zon (top-level of your app)
.{
    .name = "your-app",
    .version = "0.1.0",
    .dependencies = .{
        .zig_beam_utils = .{
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

    // Declare a dependency on the zig-beam utils package
    const beam_dep = b.dependency("zig_beam_utils", .{ .target = target, .optimize = optimize });
    const beam_utils = beam_dep.module("zig_beam_utils");

    // Example: an executable that imports zig_beam_utils
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

3) Import and use in your code

```zig
// src/main.zig
const std = @import("std");
const utils = @import("zig_beam_utils");

pub fn main() !void {
    // Tagged pointer
    const TaggedPointer = utils.tagged_pointer.TaggedPointer;

    // Thread-local cache
    const ThreadLocalCache = utils.thread_local_cache.ThreadLocalCache;

    // ARC core and pool
    const Arc = utils.arc.Arc;
    const ArcPool = utils.arc_pool.ArcPool;

    // minimal smoke check
    var gpa = std.heap.GeneralPurposeAllocator(.{}){}; defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    var arc_u64 = try Arc(u64).init(alloc, 42);
    defer arc_u64.release();
    std.debug.print("arc.get() = {}\n", .{arc_u64.get().*});
}
```

## Notes
- The `zig_beam_utils` wrapper re-exports all public modules so a single import covers Tagged Pointer, Thread-Local Cache, Arc,Arc Pool, and Cycle Detector.
- If you prefer, you can depend on sub-libraries when they become separate packages; the wrapper is a convenient default today.

## Library: utils

The `utils` library groups several building blocks used together or separately.

- Tagged Pointer
  - What: store a small tag in a pointer’s low bits
  - Files: `utils/src/tagged-pointer/tagged_pointer.zig`
  - Run: `zig build test-tagged`, `zig build samples-tagged`

- Thread-Local Cache
  - What: fixed-size, per-thread cache that frontloads a global pool
  - Files: `utils/src/thread-local-cache/thread_local_cache.zig`
  - Run: `zig build test-tlc`, `zig build samples-tlc`, `zig build bench-tlc`
  - Report: `utils/docs/thread_local_cache_benchmark_results.md`

- ARC (Atomic Reference Counted)
  - What: thread-safe smart pointers with SVO for small types, weak refs, and a pool
  - Files: `utils/src/arc/arc.zig`, `utils/src/arc/arc-pool/arc_pool.zig`, `utils/src/arc/cycle-detector/arc_cycle_detector.zig`
  - Run: `zig build test-arc`, `zig build test-arc-pool`, `zig build test-arc-cycle`, `zig build samples-arc`, `zig build bench-arc`
  - MT run: `ARC_BENCH_RUN_MT=1 zig build bench-arc`
  - Report: `utils/docs/arc_benchmark_results.md`

See `utils/README.md` for module-level details and commands.

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
