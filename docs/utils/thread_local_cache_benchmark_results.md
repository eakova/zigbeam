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
- iters: 48,810,251
- repeats: 2
- ns/op median (IQR): 1 (1–1)
- pairs/s median: 774,288,898 (≈ 774 M/s)
- single-op ops/s median: 1,548,577,796 (≈ 1 M/s)

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
- cycles: 50,000,000 (items/cycle: 16)
- repeats: 2
- ns/item median (IQR): 0 (0–0)
- items/s median: 9,523,809,523,809,523 (≈ 9,523,809 M/s)

## clear_with_callback
- cycles: 50,000,000 (items/cycle: 16)
- repeats: 2
- ns/item median (IQR): 0 (0–0)
- items/s median: 19,279,907,084,785,133 (≈ 19,279,907 M/s)

## Callback Toggle (Single-Threaded)
| Variant | Items | ns/item (median) | items/s (median) |
| --- | --- | --- | --- |
| clear(no-callback) | 800,000,000 | <1 | 9,523,809,523,809,523 |
| clear(callback) | 800,000,000 | <1 | 9,523,809,523,809,523 |

## mt_push_pop_hits
- threads: 4
- iters/thread: 50,000,000
- repeats: 2
- ns/iter median (IQR): 0 (0–0)
- pairs/s median: 2,891,996,012 (≈ 2 M/s)
- per-thread pairs/s median: 722 M/s
- per-thread single-op ops/s median: 1 M/s

## mt_fill_and_clear(shared_cb)
- threads: 4
- cycles/thread: 170,011
- repeats: 2
- ns/item median (IQR): 12 (12–12)
- items/s median: 78,362,228 (≈ 78 M/s)
- per-thread items/s median: 19 M/s

### Callback Toggle (Multi-Threaded)
| Variant | Items | ns/item (median) | items/s (median) |
| --- | --- | --- | --- |
| clear(callback) | 10,880,704 | 12 | 79,804,360 |
| clear(no-callback) | 10,880,704 | <1 | 3,964,880,155 |

