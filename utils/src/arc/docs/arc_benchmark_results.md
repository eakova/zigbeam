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
- Logical CPUs: 16

## Single-Threaded
- Iterations: 50,000,000
- Latency (ns/op) median (IQR): 0 (0–0)
- Throughput: 896,442,914,515,203 (≈ 896,442 G/s)

