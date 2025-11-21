# Tagged Pointer (Zig‑Beam)

Pack a small tag into a pointer’s low bits (alignment‑safe).

## What It Is
- `TaggedPointer(*T, TAG_BITS)` stores a pointer and a small tag (uN)
- Uses alignment guarantees so tag and pointer share one machine word
- Common use: Arc’s “inline vs pointer” bit lives in the tag

## Quick Start
```zig
const beam = @import("zigbeam");
const TaggedPointer = @import("tagged_pointer").TaggedPointer; // internal import

const P = struct { x: i32 };
const TP = TaggedPointer(*P, 1);

pub fn main() !void {
    var p: P = .{ .x = 1 };
    const one = TP.new(&p, 1) catch unreachable;
    const tag: u1 = one.getTag();
    const ptr: *P = one.getPtr();
    _ = tag; _ = ptr;
}
```

## Notes
- Tag width must fit the alignment (e.g., 1 bit for 2‑byte alignment)
- Provides APIs to set/get tag and pointer; does not own memory
- Used internally by Arc to encode representation (SVO vs heap)

## Code & Commands
- Source: `src/libs/tagged-pointer/tagged_pointer.zig`
- Tests/Samples: `zig build test`, `zig build samples-tagged`
