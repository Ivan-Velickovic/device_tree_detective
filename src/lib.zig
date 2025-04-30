const std = @import("std");
const Allocator = std.mem.Allocator;

pub const EXAMPLE_DTBS = "example_dtbs";

// TODO: clean up
fn stringLessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.order(u8, lhs, rhs) == .lt;
}

pub fn exampleDtbs(allocator: Allocator, dir_path: []const u8) !std.ArrayList([:0]const u8) {
    var example_dtbs = std.ArrayList([:0]const u8).init(allocator);
    var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) {
            continue;
        }

        // TODO: we can do this instead by reading the DTB magic
        if (std.mem.eql(u8, ".dtb", entry.name[entry.name.len - 4..entry.name.len])) {
            try example_dtbs.append(fmt(allocator, "{s}/{s}", .{ dir_path, entry.name }));
        }
    }

    std.mem.sort([:0]const u8, example_dtbs.items, {}, stringLessThan);

    return example_dtbs;
}

pub fn fmt(allocator: Allocator, comptime s: []const u8, args: anytype) [:0]u8 {
    return std.fmt.allocPrintZ(allocator, s, args) catch @panic("OOM");
}

