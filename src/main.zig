const std = @import("std");
const dtb = @import("dtb.zig");
const gl = @import("gl");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

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

const LINUX_GITHUB = "https://github.com/torvalds/linux/tree/master";

const Platform = struct {
    filename: []const u8,
    model: ?[]const u8,
    main_memory: ?MainMemory,
    // cpus: ?ArrayList(Cpu),

    // pub const Cpu = struct {
    //     pub const Type = union(enum) {
    //         Named: []const u8,
    //         Unknown: []const u8,
    //     }

    //     type: Type
    // };

    pub const MainMemory = struct {
        regions: ArrayList(Region),
        size: u64,
    };

    pub const Region = struct {
        addr: u64,
        size: u64,
    };

    pub fn init(allocator: Allocator, root: *dtb.Node, filename: []const u8) Platform {
        var main_memory: ?MainMemory = null;
        const memory_node = dtb.memory(root);
        if (memory_node != null and memory_node.?.prop(.Reg) != null) {
            const regions = memory_node.?.prop(.Reg).?;
            var main_memory_size: u64 = 0;
            var memory_regions = ArrayList(Region).initCapacity(allocator, regions.len) catch @panic("OOM");
            for (regions) |reg| {
                const region: Region = .{
                    .addr = @intCast(reg[0]),
                    .size = @intCast(reg[1]),
                };
                main_memory_size += region.size;
                memory_regions.appendAssumeCapacity(region);
            }
            main_memory = .{
                .regions = memory_regions,
                .size = main_memory_size,
            };
        }

        return .{
            .filename = filename,
            .model = root.prop(.Model),
            .main_memory = main_memory,
        };
    }

    pub fn deinit(platform: Platform) void {
        if (platform.main_memory) |m| {
            m.regions.deinit();
        }
    }
};

fn nodeTree(allocator: Allocator, nodes: []*dtb.Node, curr_highlighted_node: ?*dtb.Node) !?*dtb.Node {
    var highlighted_node: ?*dtb.Node = curr_highlighted_node;
    for (nodes) |node| {
        const c_name = try allocator.allocSentinel(u8, node.name.len, 0);
        defer allocator.free(c_name);
        @memcpy(c_name, node.name);
        if (c.ImGui_TreeNodeEx(c_name.ptr, c.ImGuiTreeNodeFlags_AllowOverlap | c.ImGuiTreeNodeFlags_SpanFullWidth)) {
            // TODO: maybe want better hover flags
            if (c.ImGui_IsItemToggledOpen()) {
                highlighted_node = node;
            }
            if (node.prop(.Compatible)) |compatibles| {
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
            if (node.prop(.Reg)) |regions| {
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
            if (node.prop(.Interrupts)) |irqs| {
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
            if (node.children.len != 0) {
                highlighted_node = try nodeTree(allocator, node.children, highlighted_node);
            }
            c.ImGui_TreePop();
        }
    }

    return highlighted_node;
}

pub fn main() !void {
    std.debug.print("starting that shit\n", .{});

    const allocator = std.heap.c_allocator;

    const dtb_filename = "qemu_virt_aarch64.dtb";

    // DTB init
    const dtb_file = try std.fs.cwd().openFile(dtb_filename, .{});
    const dtb_size = (try dtb_file.stat()).size;
    const blob_bytes = try dtb_file.reader().readAllAlloc(allocator, dtb_size);
    defer allocator.free(blob_bytes);

    const parsed_dtb = try dtb.parse(allocator, blob_bytes);
    defer parsed_dtb.deinit(allocator);

    for (parsed_dtb.children) |child| {
        std.debug.print("child '{any}'\n", .{ child });
    }

    const platform = Platform.init(allocator, parsed_dtb, dtb_filename);
    defer platform.deinit();
    //

    // Linux compatible list
    var linux_compatible_map = std.StringHashMap([]const u8).init(allocator);
    defer linux_compatible_map.deinit();
    {
        const file = try std.fs.cwd().openFile("linux_compatible_list.txt", .{});
        const size = (try file.stat()).size;
        const bytes = try file.reader().readAllAlloc(allocator, size);
        // TODO: freeing this is more complicated since the hash map points to
        // memory in the file.
        // defer allocator.free(bytes);
        var iterator = std.mem.splitScalar(u8, bytes, '\n');
        while (iterator.next()) |line| {
            if (line.len == 0) {
                // TODO: not sure why I have to have this, the file does not have an extra newline or anything
                continue;
            }
            var line_split = std.mem.splitScalar(u8, line, ':');
            const filename = line_split.first();
            const compatible = line_split.rest();
            try linux_compatible_map.put(compatible, filename);
            std.debug.assert(compatible.len != 0);
            std.debug.assert(filename.len != 0);
        }
    }
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

        c.ImGui_ShowDemoWindow(null);

        var open_about = false;
        if (c.ImGui_BeginMainMenuBar()) {
            if (c.ImGui_BeginMenu("File")) {
                c.ImGui_EndMenu();
            }
            if (c.ImGui_BeginMenu("Help")) {
                if (c.ImGui_MenuItem("About")) {
                    open_about = true;
                }
                c.ImGui_EndMenu();
            }
            c.ImGui_EndMainMenuBar();
        }

        if (open_about) {
            c.ImGui_OpenPopup("About", 0);
        }

        if (c.ImGui_BeginPopupModal("About", null, c.ImGuiWindowFlags_AlwaysAutoResize)) {
            c.ImGui_Text("Created by Ivan Velickovic in 2025.");
            c.ImGui_EndPopup();
        }

        _ = c.ImGui_Begin("DTB", null, c.ImGuiWindowFlags_NoCollapse);

        // const nodes_expand_all = c.ImGui_Button("Expand All");
        // const nodes_collapse_all = c.ImGui_Button("Collapse All");

        highlighted_node = try nodeTree(allocator, parsed_dtb.children, highlighted_node);
        c.ImGui_End();

        // === Selected Node Window ===
        _ = c.ImGui_Begin("Selected Node", null, 0);
        if (highlighted_node) |node| {
            c.ImGui_Text(fmt(allocator, "{s}", .{ node.name }));
            if (node.prop(.Compatible)) |compatible| {
                if (linux_compatible_map.get(compatible[0])) |linux_driver| {
                    c.ImGui_Text("linux driver:");
                    c.ImGui_TextLinkOpenURLEx(fmt(allocator, "{s}", .{ linux_driver }), fmt(allocator, "{s}/{s}", .{ LINUX_GITHUB, linux_driver }));
                }
            }
            for (node.props) |prop| {
                c.ImGui_Text(fmt(allocator, "{any}", .{ prop }));
            }
        }
        c.ImGui_End();
        // ===========================

        // === Platform Info Window ===
        _ = c.ImGui_Begin("Platform Info", null, 0);
        c.ImGui_Text(fmt(allocator, "reading from '{s}'", .{ platform.filename }));
        const model = platform.model orelse "n/a";
        c.ImGui_Text(fmt(allocator, "model: {s}", .{ model }));
        // TODO: don't .?
        const main_memory_text = fmt(allocator, "Main Memory ({s})", .{ humanSize(allocator, platform.main_memory.?.size )});
        defer allocator.free(main_memory_text);
        if (c.ImGui_TreeNodeEx(main_memory_text, c.ImGuiTreeNodeFlags_DefaultOpen)) {
            for (platform.main_memory.?.regions.items) |region| {
                const human_size = humanSize(allocator, region.size);
                defer allocator.free(human_size);
                const addr = fmt(allocator, "[0x{x}..0x{x}] ({s})", .{ region.addr, region.addr + region.size, human_size });
                defer allocator.free(addr);
                if (c.ImGui_TreeNodeEx(addr, c.ImGuiTreeNodeFlags_Leaf)) {
                    c.ImGui_TreePop();
                }
            }
            c.ImGui_TreePop();
        }
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
