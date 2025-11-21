# ThreadLocalCache Benchmark Results

## Legend
- iters/attempts/cycles: amount of work per measured run (scaled to target duration).
- repeats: number of measured runs; latency and throughput report median (IQR) across repeats.
- ns/op (or ns/item): latency per operation/item; lower is better.
- ops/s (or items/s): throughput; higher is better.
- Notes: very fast paths may report ~0ns due to timer granularity in ReleaseFast.

## Config
- repeats: 2
- target_ms (ST/MT): 100/150
- threads (MT): 4

## Machine
- OS: macos
- Arch: aarch64
- Zig: 0.15.2
- Build Mode: Debug
- Pointer Width: 64-bit
- Logical CPUs: 16

## push_pop_hits
- iters: 15,982,969
- repeats: 2
- ns/op median (IQR): 5 (5–6)
- pairs/s median: 168,200,405 (≈ 168 M/s)
- single-op ops/s median: 336,400,810 (≈ 336 M/s)

## pop_empty
- attempts: 50,000,000
- repeats: 2
- ns/attempt median (IQR): 1 (1–1)
- attempts/s median: 651,578,994 (≈ 651 M/s)

## push_overflow(full)
- attempts: 50,000,000
- repeats: 2
- ns/attempt median (IQR): 1 (1–1)
- attempts/s median: 635,370,391 (≈ 635 M/s)

