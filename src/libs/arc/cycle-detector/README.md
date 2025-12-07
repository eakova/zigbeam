# Arc Cycle Detector (Zig‑Beam)

Optional diagnostic for finding strongly‑reachable cycles of Arc(T).

## What It Is
- Walks user data by calling a `trace(*T, emit: fn(*Inner) void)` function you provide
- Records edges between Arc<T> nodes (`Arc::Inner` pointers)
- Reports cycles that remain after simulated drops (debug aid)

## Quick Start
```zig
const std = @import("std");
const beam = @import("zigbeam");

const Arc = beam.Libs.Arc(u32);
const Detector = beam.Libs.ArcCycleDetector(u32);

fn trace_u32(_: *const u32, _: *const fn(*anyopaque) void) void {
    // Primitive example: no edges
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){}; defer _ = gpa.deinit();
    const A = gpa.allocator();

    var a = try Arc.init(A, 1);
    defer a.release();

    var det = try Detector.init(A, trace_u32);
    defer det.deinit();
    det.add(&a);
    const report = try det.run();
    defer report.deinit();
    // inspect report.nodes, report.cycles
}
```

## Notes
- For debugging only; not required in normal operation
- Needs a correct `trace` for your T to find children
- Works with heap arcs; SVO arcs participate via their inner relations when present

## Code & Commands
- Source: `src/libs/arc/cycle-detector/arc_cycle_detector.zig`
- Tests: `zig build test` (unit + integration)
