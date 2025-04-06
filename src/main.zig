const std = @import("std");
const dtb = @import("dtb.zig");
const gl = @import("gl");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const VERSION = "0.1.0";
const ABOUT = std.fmt.comptimePrint("DTB viewer v{s}", .{ VERSION });

const c = @cImport({
    @cDefine("GLFW_INCLUDE_NONE", "1");
    @cInclude("GLFW/glfw3.h");
    @cInclude("dcimgui.h");
    @cInclude("backends/dcimgui_impl_glfw.h");
    @cInclude("backends/dcimgui_impl_opengl3.h");
    @cDefine("STBI_ONLY_PNG", "");
    @cDefine("STB_IMAGE_IMPLEMENTATION", "");
    // @cDefine("STBI_NO_STDIO", "");
    @cInclude("stb_image.h");
});

/// 16MiB. Should be plenty given the biggest DTS in Linux at the
/// time of writing is less than 200KiB.
const DTB_DECOMPILE_MAX_OUTPUT = 1024 * 1024 * 16;

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

fn compileDtb(allocator: Allocator, input: []const u8) !void {
    var dtc = std.process.Child.init(&.{ "dtc", "-I", "dts", "-O", "dtb", input }, allocator);

    dtc.stdin_behavior = .Ignore;
    dtc.stdout_behavior = .Pipe;
    dtc.stderr_behavior = .Pipe;

    var stdout = std.ArrayListUnmanaged(u8){};
    defer stdout.deinit(allocator);
    var stderr = std.ArrayListUnmanaged(u8){};
    defer stderr.deinit(allocator);

    try dtc.spawn();
    try dtc.collectOutput(allocator, &stdout, &stderr, 1024 * 1024);
    const term = try dtc.wait();

    switch (term) {
        .Exited => |code| switch (code) {
            0 => std.debug.print("{}", .{ stdout }),
            else => @panic("TODO"),
        },
        else => @panic("TODO"),
    }
}

fn decompileDtb(allocator: Allocator, input: []const u8) !std.ArrayListUnmanaged(u8) {
    var dtc = std.process.Child.init(&.{ "dtc", "-I", "dtb", "-O", "dts", input }, allocator);

    dtc.stdin_behavior = .Ignore;
    dtc.stdout_behavior = .Pipe;
    dtc.stderr_behavior = .Pipe;

    var stdout = std.ArrayListUnmanaged(u8){};
    var stderr = std.ArrayListUnmanaged(u8){};
    defer stderr.deinit(allocator);

    try dtc.spawn();
    try dtc.collectOutput(allocator, &stdout, &stderr, DTB_DECOMPILE_MAX_OUTPUT);
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

const LINUX_GITHUB = "https://github.com/torvalds/linux/tree/master";
const UBOOT_GITHUB = "https://github.com/u-boot/u-boot/tree/master";

const Platform = struct {
    allocator: Allocator,
    path: []const u8,
    root: *dtb.Node,
    model: ?[]const u8,
    main_memory: ?MainMemory,
    irqs: std.ArrayList(Irq),
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

    pub fn init(allocator: Allocator, path: []const u8) !Platform {
        const dtb_file = try std.fs.cwd().openFile(path, .{});
        const dtb_size = (try dtb_file.stat()).size;
        const blob_bytes = try dtb_file.reader().readAllAlloc(allocator, dtb_size);
        // TODO: do we need to free this in deinit or is it safe to do here?
        // defer allocator.free(blob_bytes);
        const root = try dtb.parse(allocator, blob_bytes);

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
            .allocator = allocator,
            .path = path,
            .root = root,
            .model = root.prop(.Model),
            .main_memory = main_memory,
            .irqs = try irqList(allocator, root),
        };
    }

    pub fn deinit(platform: *Platform) void {
        if (platform.main_memory) |m| {
            m.regions.deinit();
        }
        platform.irqs.deinit();
        platform.root.deinit(platform.allocator);
    }
};

fn nodeNamesFmt(node: *dtb.Node, writer: std.ArrayList(u8).Writer) !void {
    if (node.parent) |parent| {
        try nodeNamesFmt(parent, writer);
        try writer.writeAll("/");
    }

    try writer.writeAll(node.name);
}

fn irqListAdd(nodes: []*dtb.Node, irqs: *std.ArrayList(Irq)) !void {
    for (nodes) |node| {
        if (node.prop(.Interrupts)) |node_irqs| {
            for (node_irqs) |irq| {
                if (node.interruptCells() == 1) {
                    // HACK: for risc-v
                    try irqs.append(.{ .number = irq[0], .node = node });
                } else {
                    // HACK: for arm
                    try irqs.append(.{ .number = irq[1], .node = node });
                }
            }
        }
        try irqListAdd(node.children, irqs);
    }
}

/// Go through all the nodes, and make a hash map from IRQ number to
/// DTB node.
/// Owner own hash map memory, DTB node data must live longer than
/// the hash map.
// TODO: maybe this should be an array of lists instead
const Irq = struct {
    number: u64,
    node: *dtb.Node,
};

fn irqAsc(_: void, a: Irq, b: Irq) bool {
    return a.number < b.number;
}

fn irqList(allocator: Allocator, root: *dtb.Node) !std.ArrayList(Irq) {
    var irqs = std.ArrayList(Irq).init(allocator);
    try irqListAdd(root.children, &irqs);

    std.mem.sort(Irq, irqs.items, {}, irqAsc);

    return irqs;
}

fn nodeTree(allocator: Allocator, nodes: []*dtb.Node, curr_highlighted_node: ?*dtb.Node, expand_all: bool) !?*dtb.Node {
    var highlighted_node: ?*dtb.Node = curr_highlighted_node;
    for (nodes) |node| {
        const c_name = try allocator.allocSentinel(u8, node.name.len, 0);
        defer allocator.free(c_name);
        @memcpy(c_name, node.name);
        var flags = c.ImGuiTreeNodeFlags_AllowOverlap | c.ImGuiTreeNodeFlags_SpanFullWidth;
        if (expand_all) {
            flags |= c.ImGuiTreeNodeFlags_DefaultOpen;
        }
        if (c.ImGui_TreeNodeEx(c_name.ptr, flags)) {
            // TODO: maybe want better hover flags
            if (c.ImGui_IsItemToggledOpen()) {
                highlighted_node = node;
            }
            if (node.prop(.Compatible)) |compatibles| {
                if (c.ImGui_TreeNodeEx("compatible", c.ImGuiTreeNodeFlags_DefaultOpen | c.ImGuiTreeNodeFlags_Leaf)) {
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
                if (c.ImGui_TreeNodeEx("memory", c.ImGuiTreeNodeFlags_DefaultOpen | c.ImGuiTreeNodeFlags_Leaf)) {
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
                if (c.ImGui_TreeNodeEx("interrupts", c.ImGuiTreeNodeFlags_DefaultOpen | c.ImGuiTreeNodeFlags_Leaf)) {
                    for (irqs) |irq| {
                        // TODO: fix
                        if (node.interruptCells() != 3) {
                            continue;
                        }
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
                highlighted_node = try nodeTree(allocator, node.children, highlighted_node, expand_all);
            }
            c.ImGui_TreePop();
        }
    }

    return highlighted_node;
}

fn compatibleMap(allocator: Allocator, path: []const u8) !std.StringHashMap([]const u8) {
    var map = std.StringHashMap([]const u8).init(allocator);
    const file = try std.fs.cwd().openFile(path, .{});
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
        try map.put(compatible, filename);
        std.debug.assert(compatible.len != 0);
        std.debug.assert(filename.len != 0);
    }

    return map;
}

fn exampleDtbs(allocator: Allocator, dir_path: []const u8) !std.ArrayList([:0]const u8) {
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

    return example_dtbs;
}

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    var platform = try Platform.init(allocator, "dtbs/sel4/qemu_virt_aarch64.dtb");
    defer platform.deinit();

    var dts = try decompileDtb(allocator, "dtbs/sel4/qemu_virt_aarch64.dtb");
    defer dts.deinit(allocator);

    var linux_compatible_map = try compatibleMap(allocator, "linux_compatible_list.txt");
    defer linux_compatible_map.deinit();
    var uboot_compatible_map = try compatibleMap(allocator, "uboot_compatible_list.txt");
    defer uboot_compatible_map.deinit();

    const sel4_example_dtbs = try exampleDtbs(allocator, "dtbs/sel4");
    defer {
        for (sel4_example_dtbs.items) |d| {
            allocator.free(d);
        }
        sel4_example_dtbs.deinit();
    }
    const linux_example_dtbs = try exampleDtbs(allocator, "dtbs/linux");
    defer {
        for (linux_example_dtbs.items) |d| {
            allocator.free(d);
        }
        linux_example_dtbs.deinit();
    }

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

    // Load window icon
    var icons = std.mem.zeroes([1]c.GLFWimage);
    icons[0].pixels = c.stbi_load("test-logo.png", &icons[0].width, &icons[0].height, 0, 4);
    c.glfwSetWindowIcon(window, 1, &icons);
    c.stbi_image_free(icons[0].pixels);

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

    // TODO: move this into platform struct
    var highlighted_node: ?*dtb.Node = null;
    var dtb_to_load: ?[]const u8 = null;
    var nodes_expand_all = false;
    while (c.glfwWindowShouldClose(window) != c.GLFW_TRUE) {
        c.glfwPollEvents();

        c.cImGui_ImplOpenGL3_NewFrame();
        c.cImGui_ImplGlfw_NewFrame();
        c.ImGui_NewFrame();

        var open_about = false;
        if (c.ImGui_BeginMainMenuBar()) {
            if (c.ImGui_BeginMenu("File")) {
                if (c.ImGui_BeginMenu("Example DTBs")) {
                    if (c.ImGui_BeginMenu("seL4")) {
                        for (sel4_example_dtbs.items) |example| {
                            if (c.ImGui_MenuItem(example)) {
                                dtb_to_load = example;
                            }
                        }
                        c.ImGui_EndMenu();
                    }
                    if (c.ImGui_BeginMenu("Linux")) {
                        for (linux_example_dtbs.items) |example| {
                            if (c.ImGui_MenuItem(example)) {
                                dtb_to_load = example;
                            }
                        }
                        c.ImGui_EndMenu();
                    }
                    c.ImGui_EndMenu();
                }
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

        if (dtb_to_load) |d| {
            if (!std.mem.eql(u8, platform.path, d)) {
                // TODO: pretty sus on this
                platform.deinit();
                platform = try Platform.init(allocator, d);
                highlighted_node = null;
                nodes_expand_all = false;
            }
        }

        if (open_about) {
            c.ImGui_OpenPopup("About", 0);
        }

        if (c.ImGui_BeginPopupModal("About", null, c.ImGuiWindowFlags_AlwaysAutoResize)) {
            c.ImGui_Text(ABOUT);
            c.ImGui_TextLinkOpenURLEx("Home page", "https://ivanvelickovic.com");
            c.ImGui_SameLine();
            c.ImGui_TextLinkOpenURLEx("Source Code", "https://git.ivanvelickovic.com/ivanv/dtb_viewer");
            c.ImGui_Separator();
            c.ImGui_Text("This program is intended to help people explore and visualise Device Tree Blob files.");
            c.ImGui_Text("Created by Ivan Velickovic in 2025.");
            c.ImGui_EndPopup();
        }

        c.ImGui_SetNextWindowPos(c.ImVec2 { .x = 0, .y = 20 }, 0);
        _ = c.ImGui_Begin("DTB", null, c.ImGuiWindowFlags_NoCollapse | c.ImGuiWindowFlags_NoResize);
        c.ImGui_SetWindowSize(c.ImVec2 { .x = 1920 / 2, .y = 1080 - 20 }, 0);

        // TODO: this logic is definetely wrong
        const expand_all = c.ImGui_Button("Expand All");
        c.ImGui_SameLine();
        const collapse_all = c.ImGui_Button("Collapse All");
        if (!nodes_expand_all) {
            nodes_expand_all = expand_all;
        } else if (collapse_all) {
            nodes_expand_all = false;
        }

        highlighted_node = try nodeTree(allocator, platform.root.children, highlighted_node, nodes_expand_all);
        c.ImGui_End();

        // === Selected Node Window ===
        c.ImGui_SetNextWindowPos(c.ImVec2 { .x = 1920 / 2, .y = 20 }, 0);
        _ = c.ImGui_Begin("Selected Node", null, c.ImGuiWindowFlags_NoCollapse | c.ImGuiWindowFlags_NoResize);
        c.ImGui_SetWindowSize(c.ImVec2 { .x = 1920 / 2, .y = (1080 / 2) - 20 }, 0);
        if (highlighted_node) |node| {
            var node_name = std.ArrayList(u8).init(allocator);
            defer node_name.deinit();
            const writer = node_name.writer();
            try nodeNamesFmt(node, writer);
            c.ImGui_Text(fmt(allocator, "{s}", .{ node_name.items }));
            if (node.prop(.Compatible)) |compatible| {
                if (linux_compatible_map.get(compatible[0])) |driver| {
                    c.ImGui_Text("Linux driver:");
                    c.ImGui_SameLine();
                    c.ImGui_TextLinkOpenURLEx(fmt(allocator, "{s}##linux", .{ driver }), fmt(allocator, "{s}/{s}", .{ LINUX_GITHUB, driver }));
                }
                if (uboot_compatible_map.get(compatible[0])) |driver| {
                    c.ImGui_Text("U-Boot driver:");
                    c.ImGui_SameLine();
                    c.ImGui_TextLinkOpenURLEx(fmt(allocator, "{s}##uboot", .{ driver }), fmt(allocator, "{s}/{s}", .{ UBOOT_GITHUB, driver }));
                }
            }
            for (node.props) |prop| {
                c.ImGui_Text(fmt(allocator, "{any}", .{ prop }));
            }
        }
        c.ImGui_End();
        // ===========================

        // === Details Window ===
        c.ImGui_SetNextWindowPos(c.ImVec2 { .x = 1920 / 2, .y = 1080 / 2 }, 0);
        _ = c.ImGui_Begin("Details", null, c.ImGuiWindowFlags_NoCollapse | c.ImGuiWindowFlags_NoResize);
        c.ImGui_SetWindowSize(c.ImVec2 { .x = 1920 / 2, .y = 1080 / 2 }, 0);
        if (c.ImGui_BeginTabBar("info", c.ImGuiTabBarFlags_None)) {
            if (c.ImGui_BeginTabItem("Platform", null, c.ImGuiTabItemFlags_None)) {
                c.ImGui_Text(fmt(allocator, "File: '{s}'", .{ platform.path }));
                const model = platform.model orelse "n/a";
                c.ImGui_Text(fmt(allocator, "Model: {s}", .{ model }));
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
                if (platform.root.propAt(&.{ "cpus", "cpu@0" }, .RiscvIsaExtensions)) |extensions| {
                    if (c.ImGui_TreeNodeEx("RISC-V ISA Extensions", c.ImGuiTreeNodeFlags_DefaultOpen)) {
                        for (extensions) |extension| {
                            const c_extension = fmt(allocator, "{s}", .{ extension });
                            if (c.ImGui_TreeNodeEx(c_extension, c.ImGuiTreeNodeFlags_Leaf)) {
                                c.ImGui_TreePop();
                            }
                        }
                        c.ImGui_TreePop();
                    }
                }
                c.ImGui_EndTabItem();
            }
            if (c.ImGui_BeginTabItem("Interrupts", null, c.ImGuiTabItemFlags_None)) {
                var buf = [_:0]u8{0} ** 100;
                _ = c.ImGui_InputText("input text", &buf, buf.len, 0);
                for (platform.irqs.items) |irq| {
                    c.ImGui_Text(fmt(allocator, "{d} (0x{x}), {s}", .{ irq.number, irq.number, irq.node.name }));
                }
                c.ImGui_EndTabItem();
            }
            c.ImGui_EndTabBar();
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
