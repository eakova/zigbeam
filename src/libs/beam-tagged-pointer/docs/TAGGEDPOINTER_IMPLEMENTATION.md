## Implementation Plan: `TaggedPointer` - Zero-Cost Pointer Tag Storage Using Alignment Bits

---

### **Part 1: Architectural Vision & Design Philosophy**

**1.1. The Goal: Pack Metadata into Pointer's Unused Bits**
The objective is to "steal" the lower, unused bits of an aligned pointer to store a small integer tag, enabling data type discriminators and pointers to be packed into a single machine word without additional memory overhead.

**1.2. The Architectural Pattern: Alignment-Based Bit Stealing**
*   **Alignment Guarantee:** Aligned pointers have guaranteed-zero low bits (e.g., 8-byte alignment → 3 bits always zero).
*   **Tag in Low Bits:** Store tag value in these unused bits, pointer in upper bits.
*   **Compile-Time Validation:** Enforce alignment requirements at compile time.
*   **Zero-Cost Abstraction:** All operations inline to simple bitwise ops.
*   **Type Safety:** Prevent raw integer manipulation through typed API.

**1.3. The Core Components**
*   **TaggedPointer(PointerType, num_tag_bits):** Generic factory producing tagged pointer type.
*   **value:** Single `usize` storing combined pointer + tag.
*   **tag_mask / ptr_mask:** Compile-time constants for bit extraction.

**1.4. Performance Guarantees**
*   **Zero Runtime Overhead:** All methods `inline`, compiles to single bitwise ops.
*   **Single Word Storage:** Pointer + tag fit in one `usize`.
*   **No Memory Allocation:** Pure value type, stack-allocated.
*   **Compile-Time Safety:** Invalid configurations caught at compile time.

---

### **Part 2: Core Design Decisions**

**2.1. Alignment-Based Tag Bits**
*   **Decision:** Require pointer alignment >= 2^num_tag_bits at compile time.
*   **Justification:** Alignment guarantees the low bits of the pointer address are always zero, making them safe to use for the tag without corrupting the pointer value.

**2.2. Maximum 3 Tag Bits**
*   **Decision:** Limit num_tag_bits to range [1, 3].
*   **Justification:** 3 bits (8-byte alignment) covers most use cases. Higher values would require uncommon alignments and are rarely needed.

**2.3. Error on Tag Overflow**
*   **Decision:** `new()` returns `error.TagTooLarge` if tag exceeds mask.
*   **Justification:** Prevents silent data corruption from tag overflow. Debug asserts catch issues in setTag() for performance-critical paths.

**2.4. Separate Get/Set for Pointer and Tag**
*   **Decision:** Provide `getPtr/setPtr` and `getTag/setTag` as separate operations.
*   **Justification:** Most uses only need to access one or the other. Combined operations can be built from these primitives.

**2.5. fromUnsigned/toUnsigned for Serialization**
*   **Decision:** Provide conversion to/from raw `usize` for storage.
*   **Justification:** Enables storing tagged pointers in atomic variables or persistent storage, then reconstructing the typed wrapper.

**2.6. Debug Assertions for setPtr/setTag**
*   **Decision:** Use `assert()` instead of returning error in setPtr/setTag.
*   **Justification:** These are hot-path operations. Tag/alignment violations are programming errors that should be caught during development.

---

### **Part 3: Implementation Overview**

#### **Phase 1: Data Structures**

```
TaggedPointer(PointerType, num_tag_bits)
│
├── Compile-Time Validation
│   ├── PointerType must be a pointer type
│   ├── num_tag_bits must be 1, 2, or 3
│   └── alignment(PointerType) >= 2^num_tag_bits
│
├── Compile-Time Constants
│   ├── PtrInt: usize-width integer type
│   ├── tag_mask: (1 << num_tag_bits) - 1
│   └── ptr_mask: ~tag_mask
│
└── Generated Struct
    │
    └── value: usize  ← Combined pointer + tag

Memory Layout (64-bit, 3 tag bits example):
┌────────────────────────────────────────────────────────────────┐
│ 63                                                           3 │ 2 │ 1 │ 0 │
│◄──────────────── Pointer (61 bits) ─────────────────────────►│◄─ Tag ─►│
└────────────────────────────────────────────────────────────────┘
```

#### **Phase 2: Core Operations**

| Operation | Cost | Return | Notes |
|-----------|------|--------|-------|
| `new(ptr, tag)` | O(1) | `!Self` | Combine ptr + tag, error if tag too large |
| `getPtr()` | O(1) | `PointerType` | Mask out tag bits |
| `getTag()` | O(1) | `PtrInt` | Mask out pointer bits |
| `setPtr(ptr)` | O(1) | `void` | Preserve tag, update pointer |
| `setTag(tag)` | O(1) | `void` | Preserve pointer, update tag |
| `toUnsigned()` | O(1) | `usize` | Return raw value |
| `fromUnsigned(v)` | O(1) | `Self` | Construct from raw value |

#### **Phase 3: Key Algorithms**

**new(ptr, tag) - Create Tagged Pointer:**
1. If `tag > tag_mask`: return error.TagTooLarge
2. Assert pointer's low bits are zero (alignment check)
3. Combine: `value = @intFromPtr(ptr) | tag`
4. Return struct with value

**getPtr() - Extract Pointer:**
1. Mask out tag: `value & ptr_mask`
2. Cast to pointer: `@ptrFromInt(...)`
3. Return typed pointer

**getTag() - Extract Tag:**
1. Mask out pointer: `value & tag_mask`
2. Return as PtrInt

**setPtr(ptr) - Update Pointer, Preserve Tag:**
1. Assert pointer's low bits are zero
2. Get current tag: `value & tag_mask`
3. Combine: `value = @intFromPtr(ptr) | current_tag`

**setTag(tag) - Update Tag, Preserve Pointer:**
1. Assert tag <= tag_mask
2. Get current pointer bits: `value & ptr_mask`
3. Combine: `value = ptr_bits | tag`

#### **Phase 4: Flow Diagrams**

**Bit Layout:**
```
┌─────────────────────────────────────────────────────────────────┐
│                    TaggedPointer Bit Layout                     │
└─────────────────────────────────────────────────────────────────┘

num_tag_bits = 1 (requires 2-byte alignment):
┌───────────────────────────────────────────────────────┬───┐
│                  Pointer (63 bits)                    │ T │
└───────────────────────────────────────────────────────┴───┘
                                                         └─ 1 bit tag

num_tag_bits = 2 (requires 4-byte alignment):
┌───────────────────────────────────────────────────────┬─────┐
│                  Pointer (62 bits)                    │ Tag │
└───────────────────────────────────────────────────────┴─────┘
                                                         └─ 2 bit tag (0-3)

num_tag_bits = 3 (requires 8-byte alignment):
┌───────────────────────────────────────────────────────┬───────┐
│                  Pointer (61 bits)                    │  Tag  │
└───────────────────────────────────────────────────────┴───────┘
                                                         └─ 3 bit tag (0-7)
```

**Alignment Requirement:**
```
             Pointer Alignment vs Tag Bits
             ==============================

┌───────────────────┬───────────────────┬─────────────────┐
│ Alignment (bytes) │ Guaranteed 0 Bits │ Max Tag Bits    │
├───────────────────┼───────────────────┼─────────────────┤
│         2         │        1          │       1         │
│         4         │        2          │       2         │
│         8         │        3          │       3         │
│        16         │        4          │       3 (max)   │
└───────────────────┴───────────────────┴─────────────────┘

Example: *align(8) u64 → 8-byte alignment → 3 bits available
```

**Create and Access Flow:**
```
new(ptr, tag)
      │
      ▼
┌─────────────────┐
│ tag > tag_mask? │
└────────┬────────┘
         │
    ┌────┴────┐
    │         │
   yes        no
    │         │
    ▼         ▼
 error    ┌─────────────────────────────────────┐
 .Tag     │ assert(ptr & tag_mask == 0)         │
 TooLarge │ value = intFromPtr(ptr) | tag       │
          └─────────────────┬───────────────────┘
                            │
                            ▼
                    return Self{ .value }


getPtr()                              getTag()
   │                                     │
   ▼                                     ▼
┌────────────────────┐            ┌────────────────────┐
│ value & ptr_mask   │            │ value & tag_mask   │
│ 0xFFFF...FFF8      │            │ 0x0000...0007      │
└─────────┬──────────┘            └─────────┬──────────┘
          │                                 │
          ▼                                 ▼
   ptrFromInt(...)                   return as PtrInt
          │
          ▼
   return PointerType
```

**Use Case: Arc Representation Discriminator:**
```
Arc uses 1 tag bit to distinguish representations:

┌─────────────────────────────────────────────────────────────┐
│ Tag = 0: Pointer to heap allocation                         │
│ ┌───────────────────────────────────────────────────┬───┐   │
│ │            Pointer to ArcInner                    │ 0 │   │
│ └───────────────────────────────────────────────────┴───┘   │
│                                                             │
│ Tag = 1: Inline small value optimization (SVO)              │
│ ┌───────────────────────────────────────────────────┬───┐   │
│ │            Inline payload data                    │ 1 │   │
│ └───────────────────────────────────────────────────┴───┘   │
└─────────────────────────────────────────────────────────────┘

Benefits:
- No extra word for discriminator
- Branch-free tag check: just mask low bit
- Same memory footprint as raw pointer
```

---

### **Part 4: Verification & Testing Strategy**

**4.1. Unit Tests**
*   new() succeeds with valid pointer and tag.
*   new() returns error.TagTooLarge for oversized tag.
*   getPtr() returns original pointer.
*   getTag() returns original tag.
*   setPtr() updates pointer, preserves tag.
*   setTag() updates tag, preserves pointer.
*   toUnsigned()/fromUnsigned() roundtrip.
*   Compile-time error for insufficient alignment.
*   Compile-time error for num_tag_bits < 1 or > 3.
*   Compile-time error for non-pointer types.

**4.2. Integration Tests**
*   Use with atomic operations (store/load raw usize).
*   Integration with Arc for SVO discriminator.
*   Multiple tag bit configurations (1, 2, 3 bits).
*   Various pointer types and alignments.
*   Thread-safe usage via atomic usize.

**4.3. Benchmarks**
*   getPtr()/getTag() throughput (should be ~0 overhead).
*   new()/setPtr()/setTag() latency.
*   Comparison: tagged pointer vs. separate pointer+tag struct.
*   Code size impact (verify inlining).

