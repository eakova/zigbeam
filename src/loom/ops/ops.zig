// ops.zig - Parallel Operations Index
//
// Re-exports all standalone parallel operations for direct use.
// These can be used independently of ParallelIterator.

pub const for_each_ops = @import("for_each.zig");
pub const reduce_ops = @import("reduce.zig");
pub const predicates = @import("predicates.zig");
pub const map_ops = @import("map.zig");
pub const filter_ops = @import("filter.zig");
pub const chunks_ops = @import("chunks.zig");
pub const sort_ops = @import("sort.zig");
pub const range_ops = @import("../iter/par_range.zig");

// Direct function exports for convenience
pub const forEach = for_each_ops.forEach;
pub const forEachIndexed = for_each_ops.forEachIndexed;
pub const reduce = reduce_ops.reduce;
pub const any = predicates.any;
pub const all = predicates.all;
pub const find = predicates.find;
pub const position = predicates.position;
pub const count = predicates.count;
pub const map = map_ops.map;
pub const mapIndexed = map_ops.mapIndexed;
pub const filter = filter_ops.filter;
pub const chunks = chunks_ops.chunks;
pub const chunksConst = chunks_ops.chunksConst;
pub const sort = sort_ops.sort;
pub const par_range = range_ops.par_range;
pub const RangeParallelIterator = range_ops.RangeParallelIterator;
pub const ContextRangeParallelIterator = range_ops.ContextRangeParallelIterator;

test {
    @import("std").testing.refAllDecls(@This());
}
