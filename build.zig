const std = @import("std");
const cimgui = @import("cimgui_zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const dtbzig_dep = b.dependency("dtb", .{});
    const dtb_mod = dtbzig_dep.module("dtb");

    const cimgui_dep = b.dependency("cimgui_zig", .{
        .target = target,
        .optimize = optimize,
        .platform = cimgui.Platform.GLFW,
        .renderer = cimgui.Renderer.OpenGL3,
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "dtb_viewer",
        .root_module = exe_mod,
    });
    const cimgui_lib = cimgui_dep.artifact("cimgui");
    exe.linkLibrary(cimgui_lib);
    exe.addIncludePath(b.path("include"));
    exe.root_module.addImport("gl", cimgui_lib.root_module.import_table.get("gl").?);
    exe.root_module.addImport("dtb", dtb_mod);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
