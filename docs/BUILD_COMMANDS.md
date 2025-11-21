# zig-beam Build Commands

This file summarizes the standardized `zig build` steps for this repository.
Run all commands from the repository root.

---

## Global

- Run full test matrix:

  ```bash
  zig build test
  ```

---

## Tagged Pointer (`beam-tagged-pointer`)

- Tests:

  ```bash
  zig build test-tagged
  ```

- Samples:

  ```bash
  zig build samples-tagged
  ```

---

## Thread-Local Cache (`beam-thread-local-cache`)

- Tests:

  ```bash
  zig build test-tlc
  ```

- Samples:

  ```bash
  zig build samples-tlc
  ```

- Benchmarks (writes timestamped results under `src/libs/beam-thread-local-cache/benchmarks/`):

  ```bash
  zig build bench-tlc
  ```

---

## Arc / ArcPool / Cycle Detector (`beam-arc`)

- Tests:

  ```bash
  zig build test-arc         # Arc core
  zig build test-arc-pool    # ArcPool
  zig build test-arc-cycle   # cycle-detector
  ```

- Samples:

  ```bash
  zig build samples-arc
  ```

- Benchmarks (write timestamped results under `src/libs/beam-arc/benchmarks/` and `src/libs/beam-arc/arc-pool/benchmarks/`):

  ```bash
  zig build bench-arc
  zig build bench-arc-pool
  ```

---

## DVyukov MPMC Queue (`beam-dvyukov-mpmc-queue`)

- Tests:

  ```bash
  zig build test-dvyukov
  ```

- Samples:

  ```bash
  zig build samples-dvyukov
  ```

- Benchmarks (results under `src/libs/beam-dvyukov-mpmc-queue/benchmarks/`):

  ```bash
  zig build bench-dvyukov
  zig build bench-dvyukov        # core DVyukov and sharded benchmarks
  ```

---

## BeamDeque / BeamDequeChannel (`beam-deque`)

- Tests:

  ```bash
  zig build test-beam-deque
  zig build test-beam-deque-channel
  ```

- Benchmarks:

  ```bash
  zig build bench-beam-deque
  zig build bench-beam-deque-channel
  zig build bench-beam-deque-channel-v2
  ```

---

## Bounded SPSC Queue (`spsc-queue`)

- Tests:

  ```bash
  zig build test-spsc-queue
  ```

- Benchmarks:

  ```bash
  zig build bench-spsc-queue
  ```

---

## SegmentedQueue + Beam-EBR (`beam-segmented-queue`, `beam-ebr`)

- Tests:

  ```bash
  zig build test-segmented-queue          # umbrella for SegmentedQueue tests
  zig build test-segmented-queue-ebr-unit # EBR unit tests
  zig build test-segmented-queue-integration
  ```

- Benchmarks:

  ```bash
  zig build bench-ebr                     # Beam-EBR core benchmarks
  zig build bench-segmented-queue         # SegmentedQueue throughput benchmarks
  zig build bench-segmented-queue-guard-api  # Guard API comparison benchmarks
  ```

- Additional benchmarks:

  ```bash
  zig build bench-ebr-shutdown      # EBR shutdown benchmark/diagnostic
  zig build bench-ebr-queue-pressure # EBR garbage queue pressure benchmark
  zig build bench-queue-util        # Queue utilization benchmark
  ```

---

## Beam-Task (`beam-task`)

- Tests:

  ```bash
  zig build test-beam-task
  ```

Samples live under `src/libs/beam-task/samples/` and can be run via direct `zig run` if needed.

---

## Cache-Padded (`beam-cache-padded`)

- Tests + samples:

  Currently there is no dedicated `zig build` step; run directly with:

  ```bash
  zig test src/libs/beam-cache-padded/tests/_cache_padded_unit_tests.zig
  zig test src/libs/beam-cache-padded/samples/_cache_padded_samples.zig
  ```
