const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const dtbzig_dep = b.dependency("dtb", .{});
    const dtb_mod = dtbzig_dep.module("dtb");

    const cimgui_dep = b.dependency("cimgui", .{
        .target = target,
        .optimize = optimize,
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
    exe.addIncludePath(b.path("include"));
    exe.root_module.addImport("dtb", dtb_mod);

    switch (target.result.os.tag) {
        .macos => {
            exe.linkFramework("OpenGL");
        },
        .linux => {
            exe.linkSystemLibrary("GL");
            exe.linkSystemLibrary("X11");
            exe.linkSystemLibrary("pthread");
            exe.linkSystemLibrary("Xrandr");
            exe.linkSystemLibrary("Xi");
            exe.linkSystemLibrary("dl");
        },
        else => @panic("unknown OS target"),
    }

    exe.linkSystemLibrary("glfw");
    exe.linkLibC();

    const cimgui_gen_out_path = cimgui_dep.path("generator/output");
    const imgui_path = cimgui_dep.path("imgui/");
    const imgui_backend_path = imgui_path.path(b, "backends");

    exe.addIncludePath(imgui_path);
    exe.addIncludePath(imgui_backend_path);
    exe.addIncludePath(cimgui_gen_out_path);

    const cpp_flags: []const []const u8 = &[_][]const u8
    {
        "-O2",
        "-ffunction-sections",
        "-fdata-sections",
        "-DIMGUI_DISABLE_OBSOLETE_FUNCTIONS=1",
        "-DIMGUI_IMPL_API=extern \"C\" ",
        "-DIMGUI_IMPL_OPENGL_LOADER_GL3W",
        "-Dcimgui_EXPORTS"
    };
    exe.linkLibCpp(); // Dear Imgui uses C++ standard library

    // --- Dear ImGui proper ---
    exe.addCSourceFile(.{ .file = imgui_path.path(b, "imgui.cpp"), .flags = cpp_flags });
    exe.addCSourceFile(.{ .file = imgui_path.path(b, "imgui_demo.cpp"), .flags = cpp_flags });
    exe.addCSourceFile(.{ .file = imgui_path.path(b, "imgui_draw.cpp"), .flags = cpp_flags });
    exe.addCSourceFile(.{ .file = imgui_path.path(b, "imgui_tables.cpp"), .flags = cpp_flags });
    exe.addCSourceFile(.{ .file = imgui_path.path(b, "imgui_widgets.cpp"), .flags = cpp_flags });
    exe.addCSourceFile(.{ .file = imgui_backend_path.path(b, "imgui_impl_glfw.cpp"), .flags = cpp_flags });
    exe.addCSourceFile(.{ .file = imgui_backend_path.path(b, "imgui_impl_opengl3.cpp"), .flags = cpp_flags });
    // --- CImGui wrapper ---
    exe.addIncludePath(cimgui_dep.path(""));
    exe.addCSourceFile(.{ .file = cimgui_dep.path("cimgui.cpp"), .flags = cpp_flags });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
