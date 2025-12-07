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
- iters: 8,765,848
- repeats: 2
- ns/op median (IQR): 6 (6–7)
- pairs/s median: 151,017,534 (≈ 151 M/s)
- single-op ops/s median: 302,035,068 (≈ 302 M/s)

## pop_empty
- attempts: 50,000,000
- repeats: 2
- ns/attempt median (IQR): 1 (1–1)
- attempts/s median: 649,656,127 (≈ 649 M/s)

## push_overflow(full)
- attempts: 50,000,000
- repeats: 2
- ns/attempt median (IQR): 1 (1–1)
- attempts/s median: 649,740,013 (≈ 649 M/s)

## clear_no_callback
- cycles: 50,000,000 (items/cycle: 16)
- repeats: 2
- ns/item median (IQR): 0 (0–0)
- items/s median: 2,666,666,666,666,666 (≈ 2,666,666 M/s)

