# ARC Benchmark Results

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

## Arc — Single-Threaded
- Iterations: 50,000,000
- Latency (ns/op) median (IQR): 0 (0–0)
- Throughput: 595,238,095,238,095 (≈ 595,238 G/s)

## Arc — Multi-Threaded (4 threads)
- iters/thread: 50,000,000
- total pairs: 200,000,000
- ns/op median (IQR): 0 (0–0)
- ops/s median: 17,885,976,897,279 (≈ 17,885 G/s)

## ArcPool Multi-Threaded (4 threads, stats=on)
- iters/thread: 777,843
- total pairs: 3,111,372
- ns/op median (IQR): 31 (31–32)
- ops/s median: 30,914,977 (≈ 30 M/s)

### ArcPool — Multi-Threaded (4 threads)
| Variant | Iterations | ns/op (median) | Throughput (ops/s) |
| --- | --- | --- | --- |
| stats=on (MT) | 3,649,500 | 31.74 | 31.54 M/s |
| stats=off (MT) | 77,575,760 | 1.03 | 970.57 M/s |

## ArcPool Multi-Threaded (4 threads, stats=off)
- iters/thread: 19,665,362
- total pairs: 78,661,448
- ns/op median (IQR): 1 (1–1)
- ops/s median: 983,510,539 (≈ 983 M/s)

## Arc — SVO vs Heap Clone Throughput
| Variant | Iterations | ns/op (median) | Throughput (ops/s) |
| --- | --- | --- | --- |
| SVO (u32) | 50,000,000 | <0.01 | 1,204,994.19 G/s |
| Heap ([64]u8) | 13,862,160 | 4.03 | 248.28 M/s |

## Arc — Downgrade + Upgrade
| Operation | Iterations | ns/op (median) | Throughput (ops/s) |
| --- | --- | --- | --- |
| downgrade+upgrade | 7,282,296 | 7.96 | 125.67 M/s |

## ArcPool — Heap vs Create/Recycle (stats=on)
| Scenario | Iterations | ns/op (median) | Throughput (ops/s) |
| --- | --- | --- | --- |
| direct heap | 15,054 | 4206.43 | 237.76 K/s |
| ArcPool recycle | 11,789,765 | 3.18 | 314.99 M/s |

## ArcPool — Stats Toggle
### Single-Threaded
| Variant | Iterations | ns/op (median) | Throughput (ops/s) |
| --- | --- | --- | --- |
| stats=on | 10,212,766 | 3.50 | 287.37 M/s |
| stats=off | 12,620,527 | 3.20 | 312.68 M/s |

## ArcPool — Cyclic Init (pool.createCyclic, stats=off)
| Operation | Iterations | ns/op (median) | Throughput (ops/s) |
| --- | --- | --- | --- |
| createCyclic(Node) | 14,035,088 | 4.40 | 227.31 M/s |

## ArcPool — In-place vs Copy (stats=off, ST)
| Variant | Iterations | ns/op (median) | Throughput (ops/s) |
| --- | --- | --- | --- |
| copy 64B | 13,693,378 | 3.16 | 317.01 M/s |
| in-place (memset) | 18,798,995 | 3.18 | 314.67 M/s |

## ArcPool — In-place vs Copy (stats=off, MT)
| Variant | Iterations | ns/op (median) | Throughput (ops/s) |
| --- | --- | --- | --- |
| copy 64B (MT) | 81,126,304 | 1.02 | 977.38 M/s |
| in-place (MT) | 85,081,496 | 0.78 | 1.28 G/s |

## ArcPool — TLS Capacity (stats=off) — TLS-heavy churn
| Capacity | Iterations | ns/op (median) | Throughput (ops/s) |
| --- | --- | --- | --- |
| 8 | 12,162,146 | 3.10 | 322.68 M/s |
| 16 | 19,807,341 | 3.19 | 313.63 M/s |
| 32 | 21,680,217 | 2.87 | 347.86 M/s |
| 64 | 20,460,359 | 2.89 | 346.65 M/s |

## ArcPool — TLS Capacity (stats=off) — Bursty cycles (burst=24)
| Capacity | Items | ns/item (median) | Throughput (items/s) |
| --- | --- | --- | --- |
| 8 | 590,064 | 111.57 | 8.96 M/s |
| 16 | 526,896 | 109.58 | 9.13 M/s |
| 32 | 587,352 | 112.18 | 8.92 M/s |
| 64 | 579,504 | 112.90 | 8.86 M/s |

## ArcPool — TLS Capacity (stats=off) — Bursty cycles (burst=72, no drain)
| Capacity | Items | ns/item (median) | Throughput (items/s) |
| --- | --- | --- | --- |
| 8 | 1,578,456 | 42.61 | 23.51 M/s |
| 16 | 1,368,216 | 42.30 | 23.64 M/s |
| 32 | 1,773,936 | 42.94 | 23.29 M/s |
| 64 | 1,392,408 | 41.49 | 24.13 M/s |

## ArcPool — Heap vs Create/Recycle (stats=off)
| Scenario | Iterations | ns/op (median) | Throughput (ops/s) |
| --- | --- | --- | --- |
| direct heap | 14,886 | 4012.12 | 249.28 K/s |
| ArcPool recycle | 14,070,701 | 3.17 | 315.97 M/s |

## ArcPool Split Scenarios (TLS / Global / Allocator)
| Scenario | Iterations | ns/op (median) | Throughput (ops/s) |
| --- | --- | --- | --- |
| TLS only | 11,707,318 | 3.32 | 300.98 M/s |
| Global only | 10,983,982 | 5.08 | 196.91 M/s |
| Allocator only | 1,937,047 | 14.38 | 69.53 M/s |

