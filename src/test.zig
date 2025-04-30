const std = @import("std");
const lib = @import("lib.zig");
const dtb = @import("dtb.zig");
const allocator = std.testing.allocator;
const log = std.log;

test "All example DTBs" {
    const sel4_example_dtbs: std.ArrayList([:0]const u8) = lib.exampleDtbs(allocator, lib.EXAMPLE_DTBS ++ "/sel4") catch |e| {
        switch (e) {
            error.FileNotFound => return error.SkipZigTest,
            else => @panic("cannot open seL4 example DTBs"),
        }
    };
    defer {
        for (sel4_example_dtbs.items) |d| {
            allocator.free(d);
        }
        sel4_example_dtbs.deinit();
    }
    const linux_example_dtbs: std.ArrayList([:0]const u8) = lib.exampleDtbs(allocator, lib.EXAMPLE_DTBS ++ "/linux") catch |e| {
        switch (e) {
            error.FileNotFound => return error.SkipZigTest,
            else => @panic("todo"),
        }
    };
    defer {
        for (linux_example_dtbs.items) |d| {
            allocator.free(d);
        }
        linux_example_dtbs.deinit();
    }

    for (sel4_example_dtbs.items) |path| {
        const dtb_file = std.fs.cwd().openFile(path, .{}) catch |e| {
            log.err("failed to open '{s}': {any}", .{ path, e });
            return error.TestUnexpectedResult;
        };
        const dtb_size = (try dtb_file.stat()).size;
        const dtb_bytes = try dtb_file.reader().readAllAlloc(allocator, dtb_size);
        const parsed = dtb.parse(allocator, dtb_bytes) catch {
            log.err("failed to parse '{s}'", .{ path });
            return error.TestUnexpectedResult;
        };
        defer allocator.free(dtb_bytes);
        defer parsed.deinit(allocator);
    }

    var failed = false;
    for (linux_example_dtbs.items) |path| {
        const dtb_file = std.fs.cwd().openFile(path, .{}) catch |e| {
            log.err("failed to open '{s}': {any}", .{ path, e });
            return error.TestUnexpectedResult;
        };
        const dtb_size = (try dtb_file.stat()).size;
        const dtb_bytes = try dtb_file.reader().readAllAlloc(allocator, dtb_size);
        const parsed = dtb.parse(allocator, dtb_bytes) catch {
            log.err("failed to parse '{s}'", .{ path });
            failed = true;
            defer allocator.free(dtb_bytes);
            // return error.TestUnexpectedResult;
            continue;
        };
        defer allocator.free(dtb_bytes);
        defer parsed.deinit(allocator);
    }

    if (failed) {
        return error.TestUnexpectedResult;
    }
}
