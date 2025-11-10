//! A generic, type-safe, and zero-cost abstraction for tagged pointers in Zig.
//!
//! This utility allows you to "steal" the lower, unused bits of an aligned
//! pointer to store a small integer tag. This is a common low-level optimization
//! technique for packing a data type discriminator and a pointer into a single word.
//!
//! Features:
//! - Generic over any pointer type.
//! - Generic over the number of tag bits (1 to 3 bits).
//! - Compile-time validation of pointer alignment against tag bits.
//! - Type-safe API that prevents raw integer manipulation.
//! - Zero-cost abstraction: all methods are inlined, resulting in no runtime
//!   overhead compared to manual bit-masking.
//!
//! Usage:
//!
//! ```zig
//! const std = @import("std");
//! const TaggedPointer = @import("tagged_pointer.zig").TaggedPointer;
//!
//! const MyPointer = *align(8) u64; // A pointer that is guaranteed to be 8-byte aligned.
//!
//! // Create a TaggedPointer type that uses 3 bits for the tag.
//! // This will only compile if MyPointer's alignment (8) is sufficient for 3 bits (2^3=8).
//! const MyTaggedPtr = TaggedPointer(MyPointer, 3);
//!
//! const my_ptr_value = @ptrFromInt(0x1000); // A valid, aligned pointer.
//!
//! // Create a new tagged pointer with a tag value of 5.
//! var tagged = try MyTaggedPtr.new(my_ptr_value, 5);
//!
//! std.debug.print("Tag: {}\n", .{tagged.getTag()}); // Prints "Tag: 5"
//! std.debug.print("Pointer: {*any}\n", .{tagged.getPtr()}); // Prints "Pointer: 0x1000"
//!
//! // Update the tag
//! tagged.setTag(2);
//! std.debug.print("New Tag: {}\n", .{tagged.getTag()}); // Prints "New Tag: 2"
//! ```

const std = @import("std");
const assert = std.debug.assert;

/// A generic and type-safe wrapper for a tagged pointer.
/// - `PointerType`: The pointer type to be wrapped (e.g., `*MyStruct`).
/// - `num_tag_bits`: The number of low-order bits to use for the tag (1, 2, or 3).
pub fn TaggedPointer(
    comptime PointerType: type,
    comptime num_tag_bits: comptime_int,
) type {
    // --- Compile-Time Validation ---
    comptime {
        if (@typeInfo(PointerType) != .Pointer) {
            @compileError("TaggedPointer can only wrap pointer types.");
        }
        if (num_tag_bits < 1 or num_tag_bits > 3) {
            @compileError("Number of tag bits must be between 1 and 3.");
        }

        // The core safety check: The pointer's alignment must be at least
        // 2^num_tag_bits to guarantee that the lower bits are always zero.
        const required_alignment = @as(u29, 1) << num_tag_bits;
        const pointer_alignment = @alignOf(PointerType);
        if (pointer_alignment < required_alignment) {
            @compileError(std.fmt.comptimePrint(
                "Pointer alignment ({d}) is insufficient for {d} tag bits (requires alignment of at least {d}).",
                .{ pointer_alignment, num_tag_bits, required_alignment },
            ));
        }
    }

    // --- Type and Constant Definitions ---
    const PtrInt = std.meta.Int(.unsigned, @sizeOf(usize) * 8);
    const tag_mask: PtrInt = (@as(PtrInt, 1) << num_tag_bits) - 1;
    const ptr_mask: PtrInt = ~tag_mask;

    return struct {
        const Self = @This();

        /// The raw internal value, storing both the pointer and the tag.
        /// This field is private to enforce use of the safe API.
        value: usize,

        /// Creates a new `TaggedPointer`.
        /// Returns `error.TagTooLarge` if the tag value exceeds the available bits.
        pub fn new(ptr: PointerType, tag: PtrInt) !Self {
            if (tag > tag_mask) {
                return error.TagTooLarge;
            }
            // The compile-time alignment check guarantees that the lower bits of the pointer are zero.
            assert((@intFromPtr(ptr) & tag_mask) == 0);

            return .{
                .value = @intFromPtr(ptr) | tag,
            };
        }

        /// Returns the raw pointer value with the tag bits cleared.
        pub inline fn getPtr(self: Self) PointerType {
            return @ptrFromInt(self.value & ptr_mask);
        }

        /// Returns the integer value of the tag.
        pub inline fn getTag(self: Self) PtrInt {
            return self.value & tag_mask;
        }

        /// Updates the pointer part of the `TaggedPointer`, preserving the tag.
        pub inline fn setPtr(self: *Self, ptr: PointerType) void {
            assert((@intFromPtr(ptr) & tag_mask) == 0);
            const current_tag = self.getTag();
            self.value = @intFromPtr(ptr) | current_tag;
        }

        /// Updates the tag part of the `TaggedPointer`, preserving the pointer.
        pub inline fn setTag(self: *Self, tag: PtrInt) void {
            assert(tag <= tag_mask);
            const current_ptr_bits = self.value & ptr_mask;
            self.value = current_ptr_bits | tag;
        }

        /// Returns the raw integer value (pointer + tag).
        /// Useful for debugging or storage.
        pub inline fn toUnsigned(self: Self) usize {
            return self.value;
        }

        /// Creates a `TaggedPointer` from a raw integer value.
        /// This is an unsafe operation as it assumes the value was created
        /// by a compatible `TaggedPointer`.
        pub inline fn fromUnsigned(value: usize) Self {
            return .{ .value = value };
        }
    };
}
