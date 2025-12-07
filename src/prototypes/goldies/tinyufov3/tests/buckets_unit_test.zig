const std = @import("std");
const Buckets = @import("../buckets.zig");
const Model = @import("../model.zig");

test "buckets fast/compact basic" {
    const gpa = std.testing.allocator;
    {
        var b = try Buckets.Buckets(*Model.Bucket(usize)).with_capacity(gpa, .fast, 32);
        defer b.deinit(gpa);
        try std.testing.expectEqual(@as(?*Model.Bucket(usize), null), b.get(1));
        const p = try gpa.create(Model.Bucket(usize));
        p.* = Model.Bucket(usize).init(5, 1);
        try std.testing.expectEqual(@as(?*Model.Bucket(usize), null), try b.insert(gpa, 1, p));
        try std.testing.expect(b.get(1) != null);
        var mapped: bool = false;
        const fn_map = struct { fn f(x: *Model.Bucket(usize)) void { _ = x; } }.f;
        mapped = b.get_map(1, fn_map);
        try std.testing.expect(mapped);
        const r = b.remove(1).?;
        gpa.destroy(r);
    }
    {
        var b = try Buckets.Buckets(*Model.Bucket(usize)).with_capacity(gpa, .compact, 32);
        defer b.deinit(gpa);
        const p = try gpa.create(Model.Bucket(usize));
        p.* = Model.Bucket(usize).init(5, 1);
        try std.testing.expectEqual(@as(?*Model.Bucket(usize), null), try b.insert(gpa, 2, p));
        try std.testing.expect(b.get(2) != null);
        const r = b.remove(2).?;
        gpa.destroy(r);
    }
}
