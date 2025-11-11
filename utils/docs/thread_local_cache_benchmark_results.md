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
- Build Mode: ReleaseFast
- Pointer Width: 64-bit
- Logical CPUs: 0

## push_pop_hits
- iters: 32,827,247
- repeats: 2
- ns/op median (IQR): 2 (2–2)
- pairs/s median: 432,009,960 (≈ 432 M/s)
- single-op ops/s median: 864,019,920 (≈ 864 M/s)

## pop_empty
- attempts: 50,000,000
- repeats: 2
- ns/attempt median (IQR): 0 (0–0)
- attempts/s median: 609,756,097,560,975 (≈ 609,756 M/s)

## push_overflow(full)
- attempts: 50,000,000
- repeats: 2
- ns/attempt median (IQR): 0 (0–0)
- attempts/s median: 595,238,095,238,095 (≈ 595,238 M/s)

## clear_no_callback
- cycles: 50,000,000 (items/cycle: 8)
- repeats: 2
- ns/item median (IQR): 0 (0–0)
- items/s median: 9,756,097,560,975,609 (≈ 9,756,097 M/s)

## clear_with_callback
- cycles: 50,000,000 (items/cycle: 8)
- repeats: 2
- ns/item median (IQR): 0 (0–0)
- items/s median: 9,639,953,542,392,566 (≈ 9,639,953 M/s)

## mt_push_pop_hits
- threads: 4
- iters/thread: 50,000,000
- repeats: 2
- ns/iter median (IQR): 0 (0–0)
- pairs/s median: 2,244,468,443 (≈ 2 M/s)
- per-thread pairs/s median: 561 M/s
- per-thread single-op ops/s median: 1 M/s

## mt_fill_and_clear(shared_cb)
- threads: 4
- cycles/thread: 359,796
- repeats: 2
- ns/item median (IQR): 12 (12–12)
- items/s median: 76,213,039 (≈ 76 M/s)
- per-thread items/s median: 19 M/s

