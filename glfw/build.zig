// MIT License
//
// Copyright (c) 2024 Mitchell Hashimoto
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

// Shoutout to Mitchell Hashimoto for making this available as part of the Ghostty
// project. It makes things way easier for me since by default I can just
// build glfw statically into the binary and now users building from source (or
// even downloading the pre-built binary on Linux) don't have to think about downloading
// packaged glfw.

const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const use_x11 = b.option(
        bool,
        "x11",
        "Build with X11. Only useful on Linux",
    ) orelse true;
    const use_wl = b.option(
        bool,
        "wayland",
        "Build with Wayland. Only useful on Linux",
    ) orelse true;

    const use_opengl = b.option(
        bool,
        "opengl",
        "Build with OpenGL; deprecated on MacOS",
    ) orelse false;
    const use_gles = b.option(
        bool,
        "gles",
        "Build with GLES; not supported on MacOS",
    ) orelse false;
    const use_metal = b.option(
        bool,
        "metal",
        "Build with Metal; only supported on MacOS",
    ) orelse true;

    const lib = b.addLibrary(.{
        .name = "glfw",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
    });
    lib.linkLibC();

    const upstream = b.dependency("glfw", .{});
    lib.addIncludePath(upstream.path("include"));
    lib.installHeadersDirectory(upstream.path("include/GLFW"), "GLFW", .{});

    switch (target.result.os.tag) {
        .windows => {
            lib.linkSystemLibrary("gdi32");
            lib.linkSystemLibrary("user32");
            lib.linkSystemLibrary("shell32");

            if (use_opengl) {
                lib.linkSystemLibrary("opengl32");
            }

            if (use_gles) {
                lib.linkSystemLibrary("GLESv3");
            }

            const flags = [_][]const u8{"-D_GLFW_WIN32"};
            lib.addCSourceFiles(.{
                .root = upstream.path(""),
                .files = &base_sources,
                .flags = &flags,
            });
            lib.addCSourceFiles(.{
                .root = upstream.path(""),
                .files = &windows_sources,
                .flags = &flags,
            });
        },

        .macos => {
            lib.linkSystemLibrary("objc");
            lib.linkFramework("IOKit");
            lib.linkFramework("CoreFoundation");
            lib.linkFramework("AppKit");
            lib.linkFramework("CoreServices");
            lib.linkFramework("CoreGraphics");
            lib.linkFramework("Foundation");

            if (use_metal) {
                lib.linkFramework("Metal");
            }

            if (use_opengl) {
                lib.linkFramework("OpenGL");
            }

            const flags = [_][]const u8{"-D_GLFW_COCOA"};
            lib.addCSourceFiles(.{
                .root = upstream.path(""),
                .files = &base_sources,
                .flags = &flags,
            });
            lib.addCSourceFiles(.{
                .root = upstream.path(""),
                .files = &macos_sources,
                .flags = &flags,
            });
        },

        // everything that isn't windows or mac is linux :P
        else => {
            var sources = std.ArrayList([]const u8){};
            var flags = std.ArrayList([]const u8){};

            sources.appendSlice(b.allocator, &base_sources) catch unreachable;
            sources.appendSlice(b.allocator, &linux_sources) catch unreachable;

            if (use_x11) {
                sources.appendSlice(b.allocator, &linux_x11_sources) catch unreachable;
                flags.append(b.allocator, "-D_GLFW_X11") catch unreachable;
            }

            if (use_wl) {
                lib.root_module.addCMacro("WL_MARSHAL_FLAG_DESTROY", "1");
                lib.addIncludePath(b.path("wayland-headers"));

                sources.appendSlice(b.allocator, &linux_wl_sources) catch unreachable;
                flags.append(b.allocator, "-D_GLFW_WAYLAND") catch unreachable;
                flags.append(b.allocator, "-Wno-implicit-function-declaration") catch unreachable;
            }

            lib.addCSourceFiles(.{
                .root = upstream.path(""),
                .files = sources.items,
                .flags = flags.items,
            });
        },
    }

    b.installArtifact(lib);
}

const base_sources = [_][]const u8{
    "src/context.c",
    "src/egl_context.c",
    "src/init.c",
    "src/input.c",
    "src/monitor.c",
    "src/null_init.c",
    "src/null_joystick.c",
    "src/null_monitor.c",
    "src/null_window.c",
    "src/osmesa_context.c",
    "src/platform.c",
    "src/vulkan.c",
    "src/window.c",
};

const linux_sources = [_][]const u8{
    "src/linux_joystick.c",
    "src/posix_module.c",
    "src/posix_poll.c",
    "src/posix_thread.c",
    "src/posix_time.c",
    "src/xkb_unicode.c",
};

const linux_wl_sources = [_][]const u8{
    "src/wl_init.c",
    "src/wl_monitor.c",
    "src/wl_window.c",
};

const linux_x11_sources = [_][]const u8{
    "src/glx_context.c",
    "src/x11_init.c",
    "src/x11_monitor.c",
    "src/x11_window.c",
};

const windows_sources = [_][]const u8{
    "src/wgl_context.c",
    "src/win32_init.c",
    "src/win32_joystick.c",
    "src/win32_module.c",
    "src/win32_monitor.c",
    "src/win32_thread.c",
    "src/win32_time.c",
    "src/win32_window.c",
};

const macos_sources = [_][]const u8{
    // C sources
    "src/cocoa_time.c",
    "src/posix_module.c",
    "src/posix_thread.c",

    // ObjC sources
    "src/cocoa_init.m",
    "src/cocoa_joystick.m",
    "src/cocoa_monitor.m",
    "src/cocoa_window.m",
    "src/nsgl_context.m",
};
