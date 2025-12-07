// config.zig - Configuration Constants and Helper Functions for Parallel Iterator
//
// Contains:
// - Stack allocation constants
// - Context array helpers for stack/heap allocation decisions
// - Compile-time size checking

const std = @import("std");
const Allocator = std.mem.Allocator;

// ============================================================================
// Configuration Constants
// ============================================================================

/// Maximum chunks for stack-allocated context arrays
/// T127: Reduced from 128 to 32 for better cache locality
/// 32 = 4x oversubscription for 8 cores, plenty for typical systems
/// Note: When heap allocation succeeds, more chunks are allowed (Issue 55 fix)
pub const stack_max_chunks = 32;

/// Issue 55 fix: Maximum chunks when using heap allocation
/// On many-core systems (16-64 cores), 32 chunks leaves threads idle
/// Allow up to 128 chunks with heap allocation for better core utilization
pub const heap_max_chunks: usize = 128;

/// Issue 12 fix: Maximum stack bytes for context arrays before falling back to heap
/// 4KB is a safe threshold for most stack sizes (typical thread stack is 1-8MB)
pub const stack_context_threshold: usize = 4096;

/// Issue 18 fix: Check interval for early-exit in any()/all()
/// Larger interval (256 vs 64) reduces cache coherency traffic by 4x.
/// Trade-off: longer latency before detecting early-exit on slow predicates.
pub const early_exit_check_interval: usize = 256;

// ============================================================================
// Issue 12 fix: Context Array Helper
// ============================================================================

/// Error returned when heap allocation is required but not available or fails
pub const ContextAllocError = error{
    /// Heap allocation is required (count > stack_max_chunks) but no allocator provided
    HeapAllocationRequired,
    /// Heap allocation failed (out of memory)
    OutOfMemory,
};

/// Helper for managing context arrays with optional heap fallback
/// Returns heap-allocated array if stack would exceed threshold, null if stack can be used.
///
/// Issue 55/58 fix: Uses actual count for decision, not stack_max_chunks
/// This avoids unnecessary heap allocation for small fan-outs
///
/// Issue 60 fix: Returns error instead of null when heap allocation is required but fails.
/// This prevents out-of-bounds access when caller falls back to stack array.
pub fn allocContextsIfNeeded(
    comptime Context: type,
    allocator: ?Allocator,
    count: usize,
) ContextAllocError!?[]Context {
    // Issue 58 fix: Use min(stack_max_chunks, count) for accurate stack size estimate
    // This prevents unnecessary heap allocation when actual count is small
    const actual_stack_count: usize = @min(stack_max_chunks, count);
    const stack_size: usize = @sizeOf(Context) * actual_stack_count;
    if (stack_size > stack_context_threshold or count > stack_max_chunks) {
        // Large context OR more chunks than stack can hold - heap allocation required
        if (allocator) |alloc| {
            return alloc.alloc(Context, count) catch return error.OutOfMemory;
        }
        // Issue 60 fix: Heap required but no allocator - return error instead of null
        // Returning null here would cause caller to use stack_contexts[0..count]
        // where count > stack_max_chunks, causing out-of-bounds access
        return error.HeapAllocationRequired;
    }
    return null; // Stack allocation is safe
}

/// Free heap-allocated contexts if they were heap-allocated
pub fn freeContextsIfNeeded(comptime Context: type, contexts: ?[]Context, allocator: ?Allocator) void {
    if (contexts) |ctx| {
        if (allocator) |alloc| {
            alloc.free(ctx);
        }
    }
}

/// Issue 12 fix: Comptime check for context size
/// Emits a warning message at compile time if context is large
pub fn checkContextSize(comptime Context: type) void {
    const size = @sizeOf(Context) * stack_max_chunks;
    if (size > stack_context_threshold) {
        @compileLog("Warning: Large context type may cause stack pressure:", @typeName(Context), "total bytes:", size);
    }
}

// ============================================================================
// Tests
// ============================================================================

test "config constants sanity check" {
    try std.testing.expect(stack_max_chunks > 0);
    try std.testing.expect(stack_max_chunks <= 128);
    try std.testing.expect(stack_context_threshold > 0);
    try std.testing.expect(early_exit_check_interval > 0);
}

test "allocContextsIfNeeded returns null for small contexts" {
    const SmallContext = struct {
        value: u32,
    };
    const result = try allocContextsIfNeeded(SmallContext, null, 4);
    try std.testing.expectEqual(@as(?[]SmallContext, null), result);
}

test "allocContextsIfNeeded returns error when heap required but no allocator" {
    const SmallContext = struct {
        value: u32,
    };
    // Request more chunks than stack can hold, without providing allocator
    const result = allocContextsIfNeeded(SmallContext, null, stack_max_chunks + 10);
    try std.testing.expectError(error.HeapAllocationRequired, result);
}
