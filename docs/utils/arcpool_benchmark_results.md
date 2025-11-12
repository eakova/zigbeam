### ArcPool - Single-Threaded - Create + Recycle - ([64]u8)
| Thread(s) | Iterations | ns/op (median) | Throughput (ops/s) |
| --- | --- | --- | --- |
| 1 | 5,000,000 | 5.24 | 190.99 M/s |

### ArcPool - Multi-Threaded - Create + Recycle - ([64]u8)
| Thread(s) | Iterations | ns/op (median) | Throughput (ops/s) |
| --- | --- | --- | --- |
| 1 | 5,000,000 | 4.37 | 228.95 M/s |
| 4 | 5,000,000 | 0.95 | 1.06 G/s |
| 8 | 5,000,000 | 0.57 | 1.75 G/s |

### ArcPool - TLS Capacity - Single-Threaded
| Capacity | Iterations | ns/op (median) | Throughput (ops/s) |
| --- | --- | --- | --- |
| 16 | 5,000,000 | 3.73 | 267.99 M/s |
| 32 | 5,000,000 | 3.65 | 274.34 M/s |
| 64 | 5,000,000 | 3.58 | 279.26 M/s |

### ArcPool - In-place Init vs Copy - Single-Threaded - ([64]u8)
| Thread(s) | Variant | Iterations | ns/op (median) | Throughput (ops/s) |
| --- | --- | --- | --- | --- |
| 1 | copy 64B | 5,000,000 | 3.59 | 278.27 M/s |
| 1 | in-place (memset) | 5,000,000 | 2.70 | 369.86 M/s |

