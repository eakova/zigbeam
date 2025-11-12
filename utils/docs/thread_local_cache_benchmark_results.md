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
- iters: 42,712,227
- repeats: 2
- ns/op median (IQR): 2 (2–2)
- pairs/s median: 482,107,151 (≈ 482 M/s)
- single-op ops/s median: 964,214,302 (≈ 964 M/s)

## pop_empty
- attempts: 50,000,000
- repeats: 2
- ns/attempt median (IQR): 0 (0–0)
- attempts/s median: 0 (≈ 0 M/s)

## push_overflow(full)
- attempts: 50,000,000
- repeats: 2
- ns/attempt median (IQR): 0 (0–0)
- attempts/s median: 1,204,994,192,799,070 (≈ 1,204,994 M/s)

## clear_no_callback
- cycles: 50,000,000 (items/cycle: 8)
- repeats: 2
- ns/item median (IQR): 0 (0–0)
- items/s median: 4,761,904,761,904,761 (≈ 4,761,904 M/s)

## clear_with_callback
- cycles: 50,000,000 (items/cycle: 8)
- repeats: 2
- ns/item median (IQR): 0 (0–0)
- items/s median: 4,878,048,780,487,804 (≈ 4,878,048 M/s)

## Callback Toggle (Single-Threaded)
| Variant | Items | ns/item (median) | items/s (median) |
| --- | --- | --- | --- |
| clear(no-callback) | 400,000,000 | <1 | 4,761,904,761,904,761 |
| clear(callback) | 400,000,000 | 0 | 0 |

## mt_push_pop_hits
- threads: 4
- iters/thread: 50,000,000
- repeats: 2
- ns/iter median (IQR): 0 (0–0)
- pairs/s median: 2,226,540,991 (≈ 2 M/s)
- per-thread pairs/s median: 556 M/s
- per-thread single-op ops/s median: 1 M/s

## mt_fill_and_clear(shared_cb)
- threads: 4
- cycles/thread: 307,549
- repeats: 2
- ns/item median (IQR): 13 (13–13)
- items/s median: 75,393,151 (≈ 75 M/s)
- per-thread items/s median: 18 M/s

### Callback Toggle (Multi-Threaded)
| Variant | Items | ns/item (median) | items/s (median) |
| --- | --- | --- | --- |
| clear(callback) | 9,841,568 | 13 | 70,474,996 |
| clear(no-callback) | 9,841,568 | <1 | 1,727,958,309 |

