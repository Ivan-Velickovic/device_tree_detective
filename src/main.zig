const std = @import("std");
const dtb = @import("dtb");
const gl = @import("gl");
const Allocator = std.mem.Allocator;

const c = @cImport({
    @cDefine("GLFW_INCLUDE_NONE", "1");
    @cInclude("GLFW/glfw3.h");
    @cInclude("dcimgui.h");
    @cInclude("backends/dcimgui_impl_glfw.h");
    @cInclude("backends/dcimgui_impl_opengl3.h");
});

fn errorCallback(errn: c_int, str: [*c]const u8) callconv(.C) void {
    std.log.err("GLFW Error '{}'': {s}", .{ errn, str });
}

fn fmt(allocator: Allocator, comptime s: []const u8, args: anytype) [:0]u8 {
    return std.fmt.allocPrintZ(allocator, s, args) catch @panic("OOM");
}

/// Caller owns allocated formatted string
fn humanSize(allocator: Allocator, n: u64) []const u8 {
    if (n < 1024) {
        return fmt(allocator, "{} bytes", .{ n });
    } else if (n < 1024 * 1024) {
        return fmt(allocator, "{d:.2} KiB", .{ @as(f64, @floatFromInt(n)) / 1024.0 });
    } else if (n < 1024 * 1024 * 1024) {
        return fmt(allocator, "{d:.2} MiB", .{ @as(f64, @floatFromInt(n)) / 1024.0 / 1024.0 });
    } else if (n < 1024 * 1024 * 1024 * 1024) {
        return fmt(allocator, "{d:.2} GiB", .{ @as(f64, @floatFromInt(n)) / 1024.0 / 1024.0 / 1024.0 });
    } else {
        return fmt(allocator, "{d:.2} TiB", .{ @as(f64, @floatFromInt(n)) / 1024.0 / 1024.0 / 1024.0 / 1024.0 });
    }
}

pub fn memory(d: *dtb.Node) ?*dtb.Node {
    for (d.children) |child| {
        const device_type = child.prop(.DeviceType);
        if (device_type != null) {
            if (std.mem.eql(u8, "memory", device_type.?)) {
                return child;
            }
        }

        if (memory(child)) |memory_node| {
            return memory_node;
        }
    }

    return null;
}

const PlatformInfo = struct {
    filename: []const u8,
    model: ?[]const u8,
    main_memory_size: u64,

    pub fn create(root: *dtb.Node, filename: []const u8) PlatformInfo {
        // TODO: handle memory node not existing
        const memory_node = memory(root).?;
        var main_memory_size: u64 = 0;
        for (memory_node.prop(.Reg).?) |region| {
            main_memory_size += @intCast(region[1]);
        }

        return .{
            .filename = filename,
            .model = root.prop(.Model),
            .main_memory_size = main_memory_size,
        };
    }
};

pub fn main() !void {
    std.debug.print("starting that shit\n", .{});

    const allocator = std.heap.c_allocator;

    const filename = "qemu_virt_aarch64.dtb";

    // DTB init
    const dtb_file = try std.fs.cwd().openFile(filename, .{});
    const dtb_size = (try dtb_file.stat()).size;
    const blob_bytes = try dtb_file.reader().readAllAlloc(allocator, dtb_size);
    defer allocator.free(blob_bytes);

    const parsed_dtb = try dtb.parse(allocator, blob_bytes);
    defer parsed_dtb.deinit(allocator);

    for (parsed_dtb.children) |child| {
        std.debug.print("child '{any}'\n", .{ child });
    }

    const platform_info = PlatformInfo.create(parsed_dtb, filename);
    //

    var procs: gl.ProcTable = undefined;

    _ = c.glfwSetErrorCallback(errorCallback);

    if (c.glfwInit() != c.GLFW_TRUE) {
        return;
    }
    defer c.glfwTerminate();

    const GLSL_VERSION = "#version 130";
    c.glfwWindowHint(c.GLFW_CONTEXT_VERSION_MAJOR, 3);
    c.glfwWindowHint(c.GLFW_CONTEXT_VERSION_MINOR, 0);

    const window = c.glfwCreateWindow(1920, 1080, "DTB viewer", null, null);
    if (window == null) {
        return;
    }
    defer c.glfwDestroyWindow(window);

    c.glfwMakeContextCurrent(window);
    c.glfwSwapInterval(1);

    if (!procs.init(c.glfwGetProcAddress)) return error.InitFailed;

    gl.makeProcTableCurrent(&procs);
    defer gl.makeProcTableCurrent(null);

    _ = c.CIMGUI_CHECKVERSION();
    _ = c.ImGui_CreateContext(null);
    defer c.ImGui_DestroyContext(null);

    const imio = c.ImGui_GetIO();
    imio.*.ConfigFlags = c.ImGuiConfigFlags_NavEnableKeyboard;

    c.ImGui_StyleColorsDark(null);
    c.ImGuiStyle_ScaleAllSizes(c.ImGui_GetStyle(), 1.5);

    _ = c.cImGui_ImplGlfw_InitForOpenGL(window, true);
    defer c.cImGui_ImplGlfw_Shutdown();

    _ = c.cImGui_ImplOpenGL3_InitEx(GLSL_VERSION);
    defer c.cImGui_ImplOpenGL3_Shutdown();

    var highlighted_node: ?*dtb.Node = null;
    while (c.glfwWindowShouldClose(window) != c.GLFW_TRUE) {
        c.glfwPollEvents();

        c.cImGui_ImplOpenGL3_NewFrame();
        c.cImGui_ImplGlfw_NewFrame();
        c.ImGui_NewFrame();

        const flag = c.ImGuiTreeNodeFlags_DefaultOpen;
        if (c.ImGui_TreeNodeEx("nodes", flag))
        {
            for (parsed_dtb.children) |child| {
                const c_name = try allocator.allocSentinel(u8, child.name.len, 0);
                defer allocator.free(c_name);
                @memcpy(c_name, child.name);
                if (c.ImGui_TreeNodeEx(c_name.ptr, c.ImGuiTreeNodeFlags_AllowOverlap | c.ImGuiTreeNodeFlags_SpanFullWidth)) {
                    // TODO: maybe want better hover flags
                    if (c.ImGui_IsItemHovered(c.ImGuiHoveredFlags_AllowWhenBlockedByActiveItem | c.ImGuiHoveredFlags_AllowWhenBlockedByPopup | c.ImGuiHoveredFlags_AllowWhenOverlappedByWindow)) {
                        highlighted_node = child;
                    }
                    if (child.prop(.Compatible)) |compatibles| {
                        if (c.ImGui_TreeNodeEx("compatible", c.ImGuiTreeNodeFlags_DefaultOpen)) {
                            for (compatibles) |compatible| {
                                const compatible_str = fmt(allocator, "{s}", .{ compatible });
                                defer allocator.free(compatible_str);
                                if (c.ImGui_TreeNodeEx(compatible_str, c.ImGuiTreeNodeFlags_Leaf)) {
                                    c.ImGui_TreePop();
                                }
                            }
                            c.ImGui_TreePop();
                        }
                    }
                    if (child.prop(.Reg)) |regions| {
                        if (c.ImGui_TreeNodeEx("memory", c.ImGuiTreeNodeFlags_DefaultOpen)) {
                            for (regions) |region| {
                                const human_size = humanSize(allocator, @intCast(region[1]));
                                defer allocator.free(human_size);
                                const addr = fmt(allocator, "[0x{x}..0x{x}] ({s})", .{ region[0], region[0] + region[1], human_size });
                                defer allocator.free(addr);
                                if (c.ImGui_TreeNodeEx(addr, c.ImGuiTreeNodeFlags_Leaf)) {
                                    c.ImGui_TreePop();
                                }
                            }
                            c.ImGui_TreePop();
                        }
                    }
                    if (child.prop(.Interrupts)) |irqs| {
                        if (c.ImGui_TreeNodeEx("interrupts", c.ImGuiTreeNodeFlags_DefaultOpen)) {
                            for (irqs) |irq| {
                                {
                                    const irq_str = fmt(allocator, "GIC visibile: 0x{x} ({d})", .{ irq[1], irq[1] });
                                    defer allocator.free(irq_str);
                                    if (c.ImGui_TreeNodeEx(irq_str, c.ImGuiTreeNodeFlags_Leaf)) {
                                        c.ImGui_TreePop();
                                    }
                                }
                                {
                                    const irq_str = fmt(allocator, "software visibile: 0x{x} ({d})", .{ irq[1] + 32, irq[1] + 32 });
                                    defer allocator.free(irq_str);
                                    if (c.ImGui_TreeNodeEx(irq_str, c.ImGuiTreeNodeFlags_Leaf)) {
                                        c.ImGui_TreePop();
                                    }
                                }
                            }
                            c.ImGui_TreePop();
                        }
                    }
                    c.ImGui_TreePop();
                }
            }
            c.ImGui_TreePop();
        }

        // === Selected Node Window ===
        _ = c.ImGui_Begin("selected node", null, 0);
        if (highlighted_node) |node| {
            c.ImGui_Text(fmt(allocator, "{s}", .{ node.name }));
            for (node.props) |prop| {
                c.ImGui_Text(fmt(allocator, "{any}", .{ prop }));
            }
        }
        c.ImGui_End();
        // ===========================

        // === Platform Info Window ===
        _ = c.ImGui_Begin("platform info", null, 0);
        c.ImGui_Text(fmt(allocator, "reading from '{s}'", .{ platform_info.filename }));
        const model = platform_info.model orelse "n/a";
        c.ImGui_Text(fmt(allocator, "model: {s}", .{ model }));
        c.ImGui_Text(fmt(allocator, "main memory: {s}", .{ humanSize(allocator, platform_info.main_memory_size )}));
        c.ImGui_End();
        // ===========================

        c.ImGui_Render();

        var width: c_int = 0;
        var height: c_int = 0;
        c.glfwGetFramebufferSize(window, &width, &height);
        gl.Viewport(0, 0, width, height);
        gl.ClearColor(0.2, 0.2, 0.2, 1.0);
        gl.Clear(gl.COLOR_BUFFER_BIT);
        c.cImGui_ImplOpenGL3_RenderDrawData(c.ImGui_GetDrawData());

        c.glfwSwapBuffers(window);
    }
}
