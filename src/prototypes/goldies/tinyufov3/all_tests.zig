// Aggregate TinyUFO v3 tests and modules
const _segq = @import("seg_queue.zig");
const _est  = @import("estimator.zig");
const _mod  = @import("model.zig");
const _bf   = @import("buckets_fast.zig");
const _bc   = @import("buckets_compact.zig");
const _b    = @import("buckets.zig");
const _f    = @import("fifos.zig");
const _api  = @import("api.zig");
const _ebr  = @import("ebr.zig");

// Collect standalone test files (inside module path)
const _t_ebr  = @import("tests/ebr_unit_test.zig");
const _t_seg  = @import("tests/seg_queue_integration_test.zig");
const _t_ufo  = @import("tests/tinyufo_unit_test.zig");

