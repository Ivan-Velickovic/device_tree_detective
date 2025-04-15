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
        .name = "DTB viewer",
        .root_module = exe_mod,
    });
    exe.addIncludePath(b.path("include"));
    exe.root_module.addImport("dtb", dtb_mod);

    const assets = .{
        "assets/fonts/inter/Inter-Medium.ttf",
        "assets/icons/macos.png",
    };
    inline for (assets) |asset| {
        exe.root_module.addAnonymousImport(asset, .{ .root_source_file = b.path(asset) });
    }

    switch (target.result.os.tag) {
        .macos => {
            exe.linkFramework("OpenGL");
            exe.linkSystemLibrary2("glfw", .{
                // Prefer static linking so we do not actually have to ship any 3rd
                // party libraries for macOS.
                .preferred_link_mode = .static,
            });
            const maybe_objc_dep = b.lazyDependency("objc", .{
                .target = target,
                .optimize = optimize,
            });
            if (maybe_objc_dep) |objc_dep| {
                exe.root_module.addImport("objc", objc_dep.module("objc"));
            }
        },
        .linux => {
            exe.linkSystemLibrary("GL");
            exe.linkSystemLibrary("X11");
            exe.linkSystemLibrary("pthread");
            exe.linkSystemLibrary("Xrandr");
            exe.linkSystemLibrary("Xi");
            exe.linkSystemLibrary("dl");
            exe.linkSystemLibrary("glfw");

            exe.linkSystemLibrary("gtk+-3.0");
        },
        else => @panic("unknown OS target"),
    }

    exe.linkLibC();

    const cimgui_gen_out_path = cimgui_dep.path("generator/output");
    const imgui_path = cimgui_dep.path("imgui/");
    const imgui_backend_path = imgui_path.path(b, "backends");

    exe.addIncludePath(imgui_path);
    exe.addIncludePath(imgui_backend_path);
    exe.addIncludePath(cimgui_gen_out_path);

    exe.addCSourceFile(.{ .file = b.path("src/ig_extern.c") });
    if (target.result.os.tag == .linux) {
        exe.addCSourceFile(.{ .file = b.path("src/gtk_extern.c") });
    }

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
