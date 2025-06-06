const std = @import("std");

// In the current version of Zig (0.14.0), we cannot import build.zig.zon without a
// explicit result type. https://github.com/ziglang/zig/pull/22907 fixes this, but
// until 0.15.0 of Zig is released, we must do this.
const zon: struct {
    name: enum { device_tree_detective },
    version: []const u8,
    fingerprint: u64,
    minimum_zig_version: []const u8,
    dependencies: struct {
        cimgui: struct { path: []const u8 },
        glfw: struct { path: []const u8 },
        dtb: Dependency,
        objc: Dependency,
    },
    paths: []const []const u8,

    const Dependency = struct { url: []const u8, hash: []const u8, lazy: bool = false };
} = @import("build.zig.zon");

const DebPackage = struct {
    // TODO: handle libglfw3 being a dependency for system integration mode?
    const CONTROL_TEMPLATE =
    \\Package: DeviceTreeDetective
    \\Version: {s}
    \\Architecture: {s}
    \\Maintainer: Ivan Velickovic <i.velickovic@unsw.edu.au>
    \\Description: A program for inspecting Device Trees.
    \\
    ;

    dir: []const u8,
    arch: []const u8,
    bin_dest: []const u8,
    control_dest: []const u8,
    control: []const u8,
    desktop_dest: []const u8,
    desktop: std.Build.LazyPath,

    fn debArch(arch: std.Target.Cpu.Arch) []const u8 {
        return switch (arch) {
            .x86_64 => "amd64",
            .aarch64 => "arm64",
            .riscv32, .riscv64 => @tagName(arch),
            else => @panic("Unknown architecture for DebPackage"),
        };
    }

    pub fn create(b: *std.Build, arch: std.Target.Cpu.Arch) DebPackage {
        const deb_arch = debArch(arch);
        const dir = b.fmt("device_tree_detective-{s}-1_{s}", .{ zon.version, deb_arch });

        return .{
            .dir = dir,
            .bin_dest = b.fmt("{s}/usr/local/bin/device_tree_detective", .{ dir }),
            .arch = deb_arch,
            .control_dest = b.fmt("{s}/DEBIAN/control", .{ dir }),
            .control = b.fmt(CONTROL_TEMPLATE, .{ zon.version, deb_arch }),
            .desktop_dest = b.fmt("{s}/usr/local/share/applications/device_tree_detective.desktop", .{ dir }),
            .desktop = b.path("packaging/device-tree-detective.desktop"),
        };
    }
};

fn buildExe(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, dtb_dep: *std.Build.Dependency, cimgui_dep: *std.Build.Dependency, ignore_zig_version: bool) *std.Build.Step.Compile {
    const dtb_mod = dtb_dep.module("dtb");

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "device_tree_detective",
        .root_module = exe_mod,
    });
    exe.addIncludePath(b.path("include"));
    exe.addIncludePath(b.path("vendor/stb_image"));
    exe.root_module.addImport("dtb", dtb_mod);

    const assets = .{
        "build.zig.zon",
        "assets/maps/riscv_isa_extensions.csv",
        "assets/maps/linux_compatible_list.txt",
        "assets/maps/dt_bindings_list.txt",
        "assets/maps/uboot_compatible_list.txt",
        "assets/fonts/inter/Inter-Medium.ttf",
        "assets/icons/macos.png",
    };
    inline for (assets) |asset| {
        exe.root_module.addAnonymousImport(asset, .{ .root_source_file = b.path(asset) });
    }

    switch (target.result.os.tag) {
        .macos => {
            exe.linkFramework("Cocoa");
            exe.linkFramework("IOKit");
            exe.linkFramework("CoreFoundation");
            exe.linkFramework("CoreVideo");
            const maybe_objc_dep = b.lazyDependency("objc", .{
                .target = target,
                .optimize = optimize,
            });
            if (maybe_objc_dep) |objc_dep| {
                exe.root_module.addImport("objc", objc_dep.module("objc"));
            }
        },
        .windows => {
            // exe.addLibraryPath(.{ .cwd_relative = "glfw-3.4.bin.WIN64/glfw-3.4.bin.WIN64/lib-mingw-w64" });
            // exe.addIncludePath(.{ .cwd_relative = "glfw-3.4.bin.WIN64/glfw-3.4.bin.WIN64/include" });
            exe.linkSystemLibrary("opengl32");
            // exe.linkSystemLibrary2("glfw3", .{ .preferred_link_mode = .static });
            exe.linkSystemLibrary("gdi32");
            exe.linkSystemLibrary("imm32");
            exe.linkSystemLibrary("Ole32");
        },
        .linux => {
            exe.linkSystemLibrary("GL");
            exe.linkSystemLibrary("X11");
            exe.linkSystemLibrary("pthread");
            exe.linkSystemLibrary("Xrandr");
            exe.linkSystemLibrary("Xi");
            exe.linkSystemLibrary("dl");
            exe.linkSystemLibrary("gtk+-3.0");
        },
        else => @panic("unknown OS target"),
    }

    const glfw = b.dependency("glfw", .{
        .target = target,
        .optimize = optimize,
        .opengl = true,
        .metal = false,
        .wayland = false,
    });
    exe.linkLibrary(glfw.artifact("glfw"));

    exe.linkLibC();
    exe.linkLibCpp();

    exe.addCSourceFile(.{ .file = b.path("src/ig_extern.c") });
    if (target.result.os.tag == .linux) {
        exe.addCSourceFile(.{ .file = b.path("src/os/linux/gtk_dialog.c") });
    }
    if (target.result.os.tag == .windows) {
        exe.addCSourceFile(.{ .file = b.path("src/os/windows/dialog.cpp") });
    }

    const imgui_path = cimgui_dep.path("imgui/");
    const imgui_backend_path = imgui_path.path(b, "backends");

    exe.addIncludePath(imgui_path);
    exe.addIncludePath(imgui_backend_path);

    const cpp_flags: []const []const u8 = &[_][]const u8
    {
        "-O2",
        "-ffunction-sections",
        "-fdata-sections",
        "-DIMGUI_DISABLE_OBSOLETE_FUNCTIONS=1",
        "-DIMGUI_IMPL_API=extern \"C\" ",
        "-DIMGUI_IMPL_OPENGL_LOADER_GL3W",
    };

    // --- Dear ImGui proper ---
    exe.addCSourceFiles(.{
        .root = imgui_path,
        .files = &.{
            "imgui.cpp",
            "imgui_demo.cpp",
            "imgui_draw.cpp",
            "imgui_tables.cpp",
            "imgui_widgets.cpp",
            "backends/imgui_impl_glfw.cpp",
            "backends/imgui_impl_opengl3.cpp",
        },
        .flags = cpp_flags,
    });
    // --- CImGui wrapper ---
    exe.addIncludePath(cimgui_dep.path(""));
    exe.addCSourceFile(.{ .file = cimgui_dep.path("cimgui.cpp"), .flags = cpp_flags });

    const options = b.addOptions();
    options.addOption(bool, "ignore_zig_version", ignore_zig_version);
    options.addOption([]const u8, "version", zon.version);
    exe.root_module.addOptions("config", options);

    return exe;
}

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const ignore_zig_version = b.option(bool, "ignore-zig-version", "Do not emit compile error if the wrong version of Zig is used") orelse false;

    const dtb_dep = b.dependency("dtb", .{
        .target = target,
        .optimize = optimize,
    });
    const cimgui_dep = b.dependency("cimgui", .{
        .target = target,
        .optimize = optimize,
    });

    const dtb_mod = dtb_dep.module("dtb");

    const exe = buildExe(b, target, optimize, dtb_dep, cimgui_dep, ignore_zig_version);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Testing
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const tests = b.addTest(.{
        .root_module = test_mod,
    });
    tests.root_module.addImport("dtb", dtb_mod);
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    // Packaging
    const deb_step = b.step("deb", "Build .deb packages");
    const deb_install_dir: std.Build.InstallDir = .{ .custom = "deb" };
    const wf = b.addWriteFiles();
    const package = DebPackage.create(b, target.result.cpu.arch);
    _ = wf.add(package.control_dest, package.control);
    _ = wf.addCopyFile(package.desktop, package.desktop_dest);
    _ = wf.addCopyFile(b.path("assets/icons/macos.png"), b.fmt("{s}/usr/share/icons/hicolor/128x128@2/apps/device_tree_detective.png", .{ package.dir }));

    const deb_create = b.step("deb-create", "Generate debian package directory");
    deb_create.dependOn(&wf.step);
    deb_create.dependOn(&b.addInstallDirectory(.{ .source_dir = wf.getDirectory(), .install_dir = deb_install_dir, .install_subdir = "" }).step);

    const package_exe = buildExe(b, target, .ReleaseSafe, dtb_dep, cimgui_dep, ignore_zig_version);
    const target_output = b.addInstallArtifact(package_exe, .{
        .dest_dir = .{
            .override = deb_install_dir,
        },
        .dest_sub_path = package.bin_dest,
    });

    deb_create.dependOn(&target_output.step);

    const dpkg_cmd = b.addSystemCommand(&.{
        "dpkg-deb", "--build", "--root-owner-group"
    });
    dpkg_cmd.addDirectoryArg(.{ .cwd_relative = b.getInstallPath(deb_install_dir, package.dir) });
    const deb_name = b.fmt("{s}.deb", .{ package.dir });
    const deb = dpkg_cmd.addOutputFileArg(deb_name);
    dpkg_cmd.step.dependOn(deb_create);

    deb_step.dependOn(&dpkg_cmd.step);
    deb_step.dependOn(&b.addInstallFileWithDir(deb, deb_install_dir, deb_name).step);
}
