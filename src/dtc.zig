/// Functionality relating to invoking the Device Tree Compiler (dtc)
const std = @import("std");
const Allocator = std.mem.Allocator;

/// 16MiB. Should be plenty given the biggest DTS/DTB in Linux at the
/// time of writing is less than 200KiB.
const DTC_DTB_MAX_OUTPUT = 1024 * 1024 * 16;
const DTC_DTS_MAX_OUTPUT = 1024 * 1024 * 16;

pub fn available(allocator: Allocator) bool {
    var dtc = std.process.Child.init(&.{ "dtc", "--version" }, allocator);

    dtc.stdin_behavior = .Ignore;
    dtc.stdout_behavior = .Pipe;
    dtc.stderr_behavior = .Pipe;

    dtc.spawn() catch return false;
    const term = dtc.wait() catch return false;

    switch (term) {
        .Exited => |code| switch (code) {
            0 => return true,
            else => return false,
        },
        else => return false,
    }
}

/// Invoke the Device Tree Compiler to convert the given DTS to DTB.
// pub fn fromSource(allocator: Allocator, input: []const u8) !void {
//     if (!canInvoke(allocator)) {
//         return null;
//     }

//     var dtc = std.process.Child.init(&.{ "dtc", "-I", "dts", "-O", "dtb", input }, allocator);

//     dtc.stdin_behavior = .Ignore;
//     dtc.stdout_behavior = .Pipe;
//     dtc.stderr_behavior = .Pipe;

//     var stdout = std.ArrayListUnmanaged(u8){};
//     defer stdout.deinit(allocator);
//     var stderr = std.ArrayListUnmanaged(u8){};
//     defer stderr.deinit(allocator);

//     try dtc.spawn();
//     try dtc.collectOutput(allocator, &stdout, &stderr, DTC_DTB_MAX_OUTPUT);
//     const term = try dtc.wait();

//     switch (term) {
//         .Exited => |code| switch (code) {
//             0 => std.debug.print("{}", .{ stdout }),
//             else => @panic("TODO"),
//         },
//         else => @panic("TODO"),
//     }
// }

/// Invoke the Device Tree Compiler to convert the given DTB to DTS.
pub fn fromBlob(allocator: Allocator, input: []const u8) !?std.ArrayListUnmanaged(u8) {
    if (!available(allocator)) {
        return null;
    }

    var dtc = std.process.Child.init(&.{ "dtc", "-I", "dtb", "-O", "dts", input }, allocator);

    dtc.stdin_behavior = .Ignore;
    dtc.stdout_behavior = .Pipe;
    dtc.stderr_behavior = .Pipe;

    var stdout = std.ArrayListUnmanaged(u8){};
    var stderr = std.ArrayListUnmanaged(u8){};
    defer stderr.deinit(allocator);

    try dtc.spawn();
    try dtc.collectOutput(allocator, &stdout, &stderr, DTC_DTS_MAX_OUTPUT);
    const term = try dtc.wait();

    switch (term) {
        .Exited => |code| switch (code) {
            0 => {},
            else => @panic("TODO"),
        },
        else => @panic("TODO"),
    }

    return stdout;
}
