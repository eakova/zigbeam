### Arc - SVO- (u32)
| Thread(s) |  Iterations | ns/op (median) | Throughput (ops/s) |
| --- | --- | --- | --- |
| 1 | 250,000,000 | <0.01 | 6,586.05 G/s |
| 4 | 250,000,000 | <0.01 | 12,320.73 G/s |
| 8 | 250,000,000 | <0.01 | 8,995.72 G/s |

### Arc - Heap - ([64]u8)
| Thread(s) |  Iterations | ns/op (median) | Throughput (ops/s) |
| --- | --- | --- | --- |
| 1 | 250,000,000 | 3.54 | 282.79 M/s |
| 4 | 250,000,000 | 16.87 | 59.29 M/s |
| 8 | 250,000,000 | 64.28 | 15.56 M/s |

### Arc - SVO Clone Throughput - (u32)
| Thread(s) |  Iterations | ns/op (median) | Throughput (ops/s) |
| --- | --- | --- | --- |
| 1 | 250,000,000 | <0.01 | 6,586.05 G/s |
| 4 | 250,000,000 | <0.01 | 12,320.73 G/s |
| 8 | 250,000,000 | <0.01 | 8,995.72 G/s |

### Arc - Heap Clone Throughput - ([64]u8)
| Thread(s) |  Iterations | ns/op (median) | Throughput (ops/s) |
| --- | --- | --- | --- |
| 1 | 250,000,000 | 3.54 | 282.79 M/s |
| 4 | 250,000,000 | 16.87 | 59.29 M/s |
| 8 | 250,000,000 | 64.28 | 15.56 M/s |

### Arc - SVO Downgrade + Upgrade Throughput - (u32)
| Thread(s) |  Iterations | ns/op (median) | Throughput (ops/s) |
| --- | --- | --- | --- |
| 1 | 250,000,000 | <0.01 | 13,543.53 G/s |
| 4 | 250,000,000 | <0.01 | 12,447.72 G/s |
| 8 | 250,000,000 | <0.01 | 8,968.61 G/s |

### Arc - Heap Downgrade + Upgrade Throughput - ([64]u8)
| Thread(s) |  Iterations | ns/op (median) | Throughput (ops/s) |
| --- | --- | --- | --- |
| 1 | 250,000,000 | 7.15 | 139.95 M/s |
| 4 | 250,000,000 | 67.81 | 14.75 M/s |
| 8 | 250,000,000 | 169.55 | 5.90 M/s |

