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
- Throughput: 1,190,476,190,476,190 (≈ 1,190,476 G/s)

## Arc — Multi-Threaded (4 threads)
- iters/thread: 50,000,000
- total pairs: 200,000,000
- ns/op median (IQR): 0 (0–0)
- ops/s median: 9,847,320,469,611 (≈ 9,847 G/s)

## ArcPool Multi-Threaded (4 threads, stats=on)
- iters/thread: 639,106
- total pairs: 2,556,424
- ns/op median (IQR): 31 (29–33)
- ops/s median: 31,985,058 (≈ 31 M/s)

### ArcPool — Multi-Threaded (4 threads)
| Variant | Iterations | ns/op (median) | Throughput (ops/s) |
| --- | --- | --- | --- |
| stats=on (MT) | 3,821,152 | 27.32 | 36.68 M/s |
| stats=off (MT) | 76,979,828 | 0.97 | 1.03 G/s |

## ArcPool Multi-Threaded (4 threads, stats=off)
- iters/thread: 20,907,381
- total pairs: 83,629,524
- ns/op median (IQR): 0 (0–0)
- ops/s median: 1,035,692,811 (≈ 1 G/s)

## Arc — SVO vs Heap Clone Throughput
| Variant | Iterations | ns/op (median) | Throughput (ops/s) |
| --- | --- | --- | --- |
| SVO (u32) | 50,000,000 | <0.01 | 0.00 /s |
| Heap ([64]u8) | 14,110,742 | 3.60 | 277.79 M/s |

## Arc — Downgrade + Upgrade
| Operation | Iterations | ns/op (median) | Throughput (ops/s) |
| --- | --- | --- | --- |
| downgrade+upgrade | 7,003,897 | 7.11 | 140.62 M/s |

## ArcPool — Heap vs Create/Recycle (stats=on)
| Scenario | Iterations | ns/op (median) | Throughput (ops/s) |
| --- | --- | --- | --- |
| direct heap | 15,779 | 3615.77 | 276.58 K/s |
| ArcPool recycle | 16,179,747 | 2.96 | 337.35 M/s |

## ArcPool — Stats Toggle
### Single-Threaded
| Variant | Iterations | ns/op (median) | Throughput (ops/s) |
| --- | --- | --- | --- |
| stats=on | 11,474,119 | 2.92 | 342.18 M/s |
| stats=off | 17,612,456 | 2.90 | 344.86 M/s |

## ArcPool — Cyclic Init (pool.createCyclic, stats=off)
| Operation | Iterations | ns/op (median) | Throughput (ops/s) |
| --- | --- | --- | --- |
| createCyclic(Node) | 15,937,949 | 3.87 | 258.11 M/s |

## ArcPool — In-place vs Copy (stats=off, ST)
| Variant | Iterations | ns/op (median) | Throughput (ops/s) |
| --- | --- | --- | --- |
| copy 64B | 13,076,682 | 2.93 | 341.24 M/s |
| in-place (memset) | 20,577,261 | 2.91 | 344.13 M/s |

## ArcPool — In-place vs Copy (stats=off, MT)
| Variant | Iterations | ns/op (median) | Throughput (ops/s) |
| --- | --- | --- | --- |
| copy 64B (MT) | 74,975,400 | 0.97 | 1.03 G/s |
| in-place (MT) | 76,392,372 | 0.76 | 1.31 G/s |

## ArcPool — TLS Capacity (stats=off) — TLS-heavy churn
| Capacity | Iterations | ns/op (median) | Throughput (ops/s) |
| --- | --- | --- | --- |
| 8 | 4,129,621 | 11.58 | 86.37 M/s |
| 16 | 22,893,424 | 2.65 | 377.13 M/s |
| 32 | 22,584,750 | 2.66 | 375.81 M/s |
| 64 | 22,641,510 | 2.66 | 376.26 M/s |

## ArcPool — TLS Capacity (stats=off) — Bursty cycles (burst=24)
| Capacity | Items | ns/item (median) | Throughput (items/s) |
| --- | --- | --- | --- |
| 8 | 682,872 | 99.88 | 10.01 M/s |
| 16 | 576,552 | 99.27 | 10.07 M/s |
| 32 | 653,544 | 100.69 | 9.93 M/s |
| 64 | 557,352 | 104.85 | 9.54 M/s |

## ArcPool — TLS Capacity (stats=off) — Bursty cycles (burst=72, no drain)
| Capacity | Items | ns/item (median) | Throughput (items/s) |
| --- | --- | --- | --- |
| 8 | 1,576,656 | 37.57 | 26.65 M/s |
| 16 | 1,763,280 | 37.47 | 26.69 M/s |
| 32 | 1,566,792 | 36.84 | 27.15 M/s |
| 64 | 1,510,560 | 36.35 | 27.52 M/s |

## ArcPool — Heap vs Create/Recycle (stats=off)
| Scenario | Iterations | ns/op (median) | Throughput (ops/s) |
| --- | --- | --- | --- |
| direct heap | 16,181 | 3762.93 | 266.01 K/s |
| ArcPool recycle | 18,172,677 | 2.90 | 345.11 M/s |

## ArcPool Split Scenarios (TLS / Global / Allocator)
| Scenario | Iterations | ns/op (median) | Throughput (ops/s) |
| --- | --- | --- | --- |
| TLS only | 14,900,687 | 2.92 | 342.19 M/s |
| Global only | 4,199,476 | 4.68 | 213.80 M/s |
| Allocator only | 3,538,112 | 12.43 | 80.44 M/s |

