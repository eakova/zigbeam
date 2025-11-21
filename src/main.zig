const std = @import("std");
const zig_rcu = @import("zig_rcu");

pub fn main() !void {
    // Prints to stderr, ignoring potential errors.
    std.debug.print("All your {s} are belong to us.\n", .{"codebase"});
    try zig_rcu.bufferedPrint();
}
