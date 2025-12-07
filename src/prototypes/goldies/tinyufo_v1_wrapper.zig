// Wrapper for TinyUFO V1 (FullAtomicTinyUFO - original 3-queue implementation)
const v1 = @import("tinyufov1.zig");

pub const TinyUFO = v1.FullAtomicTinyUFO;
pub const Config = v1.FullAtomicConfig;

// Helper to create a default config from capacity
pub fn defaultConfig(capacity: usize) Config {
    return Config{
        .capacity = capacity,
        .window_ratio = 0.30,    // Window queue: 30%
        .main_ratio = 0.50,      // Main queue: 50%
        .protected_ratio = 0.20, // Protected queue: 20%
        .cm_sketch_width = 2048,
        .cm_sketch_depth = 4,
        .use_admission_control = true,
    };
}
