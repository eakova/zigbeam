const std = @import("std");

pub const Thread = struct {
    id: std.Thread.Id,

    pub fn current() Thread {
        return .{ .id = std.Thread.getCurrentId() };
    }
};

