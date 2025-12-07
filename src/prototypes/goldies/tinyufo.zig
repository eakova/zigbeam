// Main TinyUFO module - exports V1 (FullAtomicTinyUFO) for backward compatibility
const v1 = @import("tinyufov1.zig");

// Re-export all public symbols from V1
pub const TinyUFO = v1.FullAtomicTinyUFO;
pub const FullAtomicTinyUFO = v1.FullAtomicTinyUFO;
pub const FullAtomicConfig = v1.FullAtomicConfig;
pub const FullAtomicAuto = v1.FullAtomicAuto;
pub const CountMinSketch = v1.CountMinSketch;
pub const CountMinSketchConfig = v1.CountMinSketchConfig;
pub const CountMinSketchDefault = v1.CountMinSketchDefault;
pub const CountMinSketchLarge = v1.CountMinSketchLarge;
pub const CountMinSketchCompact = v1.CountMinSketchCompact;
pub const LockFreeSegQueue = v1.LockFreeSegQueue;
pub const LockFreeHashMap = v1.LockFreeHashMap;
pub const S3FIFOConfig = v1.S3FIFOConfig;
pub const S3FIFOCache = v1.S3FIFOCache;
pub const S3FIFOAuto = v1.S3FIFOAuto;
pub const TinyLfuConfig = v1.TinyLfuConfig;
pub const TinyLfuCache = v1.TinyLfuCache;
pub const TinyLfuAuto = v1.TinyLfuAuto;
pub const TinyLFU = v1.TinyLFU;
