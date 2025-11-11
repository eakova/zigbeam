# Arc Benchmark Results

## Legend
- Iterations: number of clone+release pairs per measured run.
- ns/op: latency per pair (lower is better).
- ops/s: pairs per second (higher is better).

## Config
- iterations: 50000000
- threads (MT): 4

## Machine
- OS: macos
- Arch: aarch64
- Zig: 0.15.2
- Build Mode: ReleaseFast
- Pointer Width: 64-bit
- Logical CPUs: 0

## Single-Threaded
- Iterations: 50,000,000
- Latency (ns/op) median (IQR): 0 (0–0)
- Throughput: 1,204,994,192,799,070 (≈ 1,204,994 G/s)

## Multi-Threaded (4 threads)
- iters/thread: 50,000,000
- total pairs: 200,000,000
- ns/op median (IQR): 0 (0–0)
- ops/s median: 7,559,230,318,666 (≈ 7,559 G/s)

## ArcPool Multi-Threaded (4 threads)
- iters/thread: 404,015
- total pairs: 1,616,060
- ns/op median (IQR): 27 (25–30)
- ops/s median: 35,484,695 (≈ 35 M/s)

## SVO vs Heap Clone Throughput
| Variant | Iterations | ns/op (median) | ops/s (median) |
| --- | --- | --- | --- |
| SVO (u32) | 50,000,000 | 0 | 595,238,095,238,095 |
| Heap ([64]u8) | 15,169,060 | 3 | 270,717,608 |

## Downgrade + Upgrade Benchmark
| Operation | Iterations | ns/op (median) | ops/s (median) |
| --- | --- | --- | --- |
| downgrade+upgrade | 8,616,555 | 7 | 141,606,908 |

## Heap vs ArcPool Create/Recycle Benchmark
| Scenario | Iterations | ns/op (median) | ops/s (median) |
| --- | --- | --- | --- |
| direct heap | 17,025 | 3,687 | 271,535 |
| ArcPool recycle | 15,450,618 | 2 | 354,361,577 |
