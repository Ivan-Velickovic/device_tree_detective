const std = @import("std");
const builtin = @import("builtin");
const dtb = @import("dtb.zig");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const log = std.log;

const objc = if (builtin.os.tag == .macos) @import("objc") else null;

const c = @cImport({
    @cDefine("CIMGUI_DEFINE_ENUMS_AND_STRUCTS", {});
    @cDefine("CIMGUI_USE_OPENGL3", {});
    @cDefine("CIMGUI_USE_GLFW", {});
    @cInclude("cimgui.h");
    @cInclude("cimgui_impl.h");
    @cInclude("GLFW/glfw3.h");
    @cDefine("STBI_ONLY_PNG", "");
    @cDefine("STB_IMAGE_IMPLEMENTATION", "");
    @cDefine("STBI_NO_STDIO", "");
    @cInclude("stb_image.h");
    @cInclude("ig_extern.h");
    if (builtin.os.tag == .linux) {
        @cInclude("gtk/gtk.h");
        @cInclude("gtk_extern.h");
    }
});

// TODO: get this from build.zig.zon instead
const VERSION = "0.1.0";
const ABOUT = std.fmt.comptimePrint("Device Tree Detective v{s}", .{ VERSION });

const SUPER_KEY_STR = if (builtin.os.tag == .macos) "CMD" else "CTRL";

const linux_driver_compatible_txt = @embedFile("linux_compatible_list.txt");
const linux_dt_binding_compatible_txt = @embedFile("dt_bindings_list.txt");
const uboot_driver_compatible_txt = @embedFile("uboot_compatible_list.txt");
const font: [:0]const u8 = @embedFile("assets/fonts/inter/Inter-Medium.ttf");
const logo: [:0]const u8 = @embedFile("assets/icons/macos.png");

/// Note that this must match to cimgui.h definition of ImGuiCol_.
/// I could have just used the C bindings but for convenience I made the
/// colours into a Zig enum.
const Colour = enum(usize) {
    text,
    text_disabled,
    window_bg,
    child_bg,
    popup_bg,
    border,
    border_shadow,
    frame_bg,
    frame_bg_hovered,
    frame_bg_active,
    title_bg,
    title_bg_active,
    title_bg_collapsed,
    menu_bar_bg,
    scrollbar_bg,
    scrollbar_grab,
    scrollbar_grab_hovered,
    scrollbar_grab_active,
    check_mark,
    slider_grab,
    slider_grab_active,
    button,
    button_hovered,
    button_active,
    header,
    header_hovered,
    header_active,
    separator,
    separator_hovered,
    separator_active,
    resize_grip,
    resize_grip_hovered,
    resize_grip_active,
    tab_hovered,
    tab,
    tab_selected,
    tab_selected_overline,
    tab_dimmed,
    tab_dimmed_selected,
    tab_dimmed_selected_overline,
    docking_preview,
    docking_empty_bg,
    plot_lines,
    plot_lines_hovered,
    plot_histogram,
    plot_histogram_hovered,
    table_header_bg,
    table_border_strong,
    table_border_light,
    table_row_bg,
    table_row_bg_alt,
    text_link,
    text_selected_bg,
    drag_drop_target,
    nav_cursor,
    nav_windowing_highlight,
    nav_windowing_dim_bg,
    modal_window_dim_bg,

    pub fn toVec(comptime hex: u24) c.ImVec4 {
        const r = (hex & 0xff0000) >> 16;
        const g = (hex & 0x00ff00) >> 8;
        const b = hex & 0x0000ff;

        return .{
            .x = @as(f32, @floatFromInt(r)) / 255.0,
            .y = @as(f32, @floatFromInt(g)) / 255.0,
            .z = @as(f32, @floatFromInt(b)) / 255.0,
            .w = 0.5,
        };
    }
};

comptime {
    std.debug.assert(@typeInfo(Colour).@"enum".fields.len == c.ImGuiCol_COUNT);
}

fn setColour(colour: Colour, value: c.ImVec4) void {
    c.igGetStyle().*.Colors[@intFromEnum(colour)] = value;
}

// TODO: move into State struct
const SavedState = struct {
    allocator: Allocator,
    path: []const u8,
    file: std.fs.File,
    parsed: ?std.json.Parsed(Json),
    // TODO: statically allocate and put limit of a 100 or something?
    recently_opened: std.ArrayList([:0]const u8),

    const Json = struct {
        recently_opened: []const [:0]const u8,
    };

    fn createEmpty(allocator: Allocator, path: []const u8, file: std.fs.File) error{OutOfMemory}!SavedState {
        var s: SavedState = .{
            .allocator = allocator,
            .path = path,
            .file = file,
            .parsed = null,
            .recently_opened = std.ArrayList([:0]const u8).init(allocator),
        };
        s.save() catch @panic("todo");

        return s;
    }

    pub fn create(allocator: Allocator, path: []const u8) error{OutOfMemory}!SavedState {
        // Create the file if it does not exist.
        const file = std.fs.cwd().openFile(path, .{ .mode = .read_write }) catch |e| {
            switch (e) {
                error.FileNotFound => {
                    log.info("saved state configuration does not exist '{s}', starting from scratch", .{ path });
                    const new_file = std.fs.cwd().createFile(path, .{}) catch @panic("TODO");
                    return createEmpty(allocator, path, new_file);
                },
                else => @panic("TODO"),
            }
        };
        const stat = file.stat() catch @panic("TODO");
        const bytes = file.reader().readAllAlloc(allocator, stat.size) catch @panic("TODO");
        defer allocator.free(bytes);
        const parsed = std.json.parseFromSlice(Json, allocator, bytes, .{}) catch |e| {
            log.err("could not parse saved state configuration '{s}' with error '{any}' removing and starting from scratch", .{ path, e });
            return createEmpty(allocator, path, file);
        };

        var recently_opened = try std.ArrayList([:0]const u8).initCapacity(allocator, parsed.value.recently_opened.len);
        for (parsed.value.recently_opened) |p| {
            recently_opened.appendAssumeCapacity(try allocator.dupeZ(u8, p));
        }

        log.info("using existing user configuration '{s}'", .{ path });

        return .{
            .allocator = allocator,
            .file = file,
            .path = path,
            .parsed = parsed,
            .recently_opened = recently_opened,
        };
    }

    pub fn isRecentlyOpened(s: *SavedState, path: []const u8) bool {
        for (s.recently_opened.items) |p| {
            if (std.mem.eql(u8, p, path)) {
                return true;
            }
        }

        return false;
    }

    /// Take the current state and write it out to the assocaited path
    pub fn save(s: *SavedState) !void {
        try s.file.seekTo(0);
        try s.file.setEndPos(0);
        try std.json.stringify(.{ .recently_opened = s.recently_opened.items }, .{ .whitespace = .indent_4 }, s.file.writer());
    }

    pub fn deinit(s: *SavedState) void {
        if (s.parsed) |p| {
            p.deinit();
        }
        s.file.close();
        for (s.recently_opened.items) |p| {
            s.allocator.free(p);
        }
        s.recently_opened.deinit();
    }
};

const State = struct {
    allocator: Allocator,
    /// Loaded platforms for inspection
    platforms: std.ArrayList(Platform),
    /// Current platform that we are inspecting
    platform: ?usize = null,
    // TODO: use defaults based on the monitor size
    window_width: u32 = 1920,
    window_height: u32 = 1080,
    main_menu_bar_height: f32 = undefined,
    /// Tree view state
    highlighted_node: ?*dtb.Node = null,

    pub fn create(allocator: Allocator) State {
        return .{
            .allocator = allocator,
            .platforms = std.ArrayList(Platform).init(allocator),
        };
    }

    pub fn setPlatform(s: *State, path: [:0]const u8) void {
        for (s.platforms.items, 0..) |platform, i| {
            if (std.mem.eql(u8, platform.path, path)) {
                if (s.platform) |curr_platform| {
                    if (curr_platform == i) {
                        // Reset platform-specific stored state
                        s.highlighted_node = null;
                    }
                }
                s.platform = i;
                return;
            }
        }

        log.err("could not set platform '{s}', does not exist", .{ path });
        log.err("existing platforms:", .{});
        for (s.platforms.items) |platform| {
            log.err("   {s}", .{ platform.path });
        }

        // TODO
        unreachable;
    }

    pub fn findPlatform(s: *State, path: [:0]const u8) usize {
        for (s.platforms.items, 0..) |platform, i| {
            if (std.mem.eql(u8, platform.path, path)) {
                return i;
            }
        }

        unreachable;
    }

    pub fn getPlatform(s: *State) ?*Platform {
        if (s.platform) |p| {
            return &s.platforms.items[p];
        } else {
            return null;
        }
    }

    pub fn loadPlatform(s: *State, saved: *SavedState, path: [:0]const u8) !void {
        // No need to load anything if it already exists
        if (s.isPlatformLoaded(path)) {
            return;
        }

        const platform = try Platform.init(s.allocator, path);
        try s.platforms.append(platform);

        if (!saved.isRecentlyOpened(path)) {
            // TODO: should instead order by recently opened
            try saved.recently_opened.append(try s.allocator.dupeZ(u8, path));
            try saved.save();
        }
    }

    pub fn unloadPlatform(s: *State, path: [:0]const u8) void {
        // First we need to get the current platform so we can
        // update our state after mutating the platform array.
        const maybe_current_platform = s.getPlatform();
        const maybe_current_platform_index = s.platform;

        // We need to find the platform for the given path.
        const platform_index = s.findPlatform(path);
        var platform = s.platforms.items[platform_index];
        // No matter what, we destroy the current platform
        defer platform.deinit();

        _ = s.platforms.orderedRemove(platform_index);

        // Now that we've changed the array, we need to fixup
        // the current platform.

        if (maybe_current_platform_index) |i| {
            if (i == platform_index) {
                // We are unloading the current platform
                if (i == 0) {
                    s.platform = null;
                } else {
                    s.platform = i - 1;
                }
                s.highlighted_node = null;
            } else {
                s.platform = s.findPlatform(maybe_current_platform.?.path);
            }
        }
    }

    pub fn isPlatformLoaded(s: *State, path: [:0]const u8) bool {
        for (s.platforms.items) |platform| {
            if (std.mem.eql(u8, platform.path, path)) {
                return true;
            }
        }

        return false;
    }

    /// Window position in pixels given a proportion of the view from 0 to 100.
    pub fn windowPos(s: *State, xp: f32, yp: f32) c.ImVec2 {
        std.debug.assert(xp <= 1 and yp <= 1 and xp >= 0 and yp >= 0);

        const y = (@as(f32, @floatFromInt(s.window_height))) * yp;
        const x = @as(f32, @floatFromInt(s.window_width)) * xp;

        return .{
            .x = @round(x),
            .y = @round(y + s.main_menu_bar_height * (1 - yp)),
        };
    }

    /// Window size in pixels given a proportion of the view from 0 to 100.
    pub fn windowSize(s: *State, width: f32, height: f32) c.ImVec2 {
        std.debug.assert(width <= 1 and height <= 1 and width >= 0 and height >= 0);

        return .{
            .x = @as(f32, @floatFromInt(s.window_width)) * width,
            .y = (@as(f32, @floatFromInt(s.window_height)) - s.main_menu_bar_height) * height,
        };
    }

    pub fn deinit(s: *State) void {
        for (s.platforms.items) |*p| {
            p.deinit();
        }
        s.platforms.deinit();
    }
};

var state: State = undefined;
var saved_state: SavedState = undefined;

fn dropCallback(_: ?*c.GLFWwindow, count: c_int, paths: [*c][*c]const u8) callconv(.C) void {
    for (0..@intCast(count)) |i| {
        log.debug("adding dropped '{s}'", .{ paths[i] });
        // TODO: check the file is actually an FDT
        state.loadPlatform(&saved_state, std.mem.span(paths[i])) catch @panic("TODO");
    }
    state.setPlatform(std.mem.span(paths[@as(usize, @intCast(count)) - 1]));
}

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
fn humanSize(allocator: Allocator, n: u64) [:0]const u8 {
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
    dtb_bytes: []const u8,
    path: [:0]const u8,
    root: *dtb.Node,
    model: ?[]const u8,
    regions: std.ArrayList(Platform.Region),
    main_memory: ?MainMemory,
    irqs: std.ArrayList(Irq),
    model_str: [:0]const u8,
    // cpus: ?ArrayList(Cpu),

    // pub const Cpu = struct {
    //     pub const Type = union(enum) {
    //         Named: []const u8,
    //         Unknown: []const u8,
    //     }

    //     type: Type
    // };

    pub const Region = struct {
        addr: u64,
        size: u64,
        node: *dtb.Node,
    };

    pub const MainMemory = struct {
        regions: ArrayList(MainMemory.Region),
        size: u64,
        fmt: [:0]const u8,

        pub const Region = struct {
            addr: u64,
            size: u64,
        };
    };

    pub fn init(allocator: Allocator, path: []const u8) !Platform {
        const dtb_file = std.fs.cwd().openFile(path, .{}) catch |e| {
            log.err("failed to open '{s}': {any}", .{ path, e });
            @panic("todo");
        };
        const dtb_size = (try dtb_file.stat()).size;
        const dtb_bytes = try dtb_file.reader().readAllAlloc(allocator, dtb_size);
        const root = try dtb.parse(allocator, dtb_bytes);

        var main_memory: ?MainMemory = null;
        const memory_node = dtb.memory(root);
        if (memory_node != null and memory_node.?.prop(.Reg) != null) {
            const regions = memory_node.?.prop(.Reg).?;
            var main_memory_size: u64 = 0;
            var memory_regions = ArrayList(MainMemory.Region).initCapacity(allocator, regions.len) catch @panic("OOM");
            for (regions) |reg| {
                const region: MainMemory.Region = .{
                    .addr = @intCast(reg[0]),
                    .size = @intCast(reg[1]),
                };
                main_memory_size += region.size;
                memory_regions.appendAssumeCapacity(region);
            }
            const human_size = humanSize(allocator, main_memory_size);
            defer allocator.free(human_size);
            main_memory = .{
                .regions = memory_regions,
                .size = main_memory_size,
                .fmt = fmt(allocator, "Main Memory ({s})", .{ human_size }),
            };
        }

        var model_str: [:0]const u8 = undefined;
        if (root.prop(.Model)) |model| {
            model_str = fmt(allocator, "Model: {s}", .{ model });
        } else {
            model_str = "N/A";
        }

        var regions = std.ArrayList(Region).init(allocator);
        try regionsAdd(root, &regions);

        return .{
            .allocator = allocator,
            .dtb_bytes = dtb_bytes,
            .path = try allocator.dupeZ(u8, path),
            .root = root,
            .model = root.prop(.Model),
            .main_memory = main_memory,
            .irqs = try irqList(allocator, root),
            .regions = regions,
            .model_str = model_str,
        };
    }

    pub fn deinit(platform: *Platform) void {
        const allocator = platform.allocator;
        if (platform.main_memory) |m| {
            allocator.free(m.fmt);
            m.regions.deinit();
        }
        allocator.free(platform.path);
        platform.irqs.deinit();
        platform.regions.deinit();
        platform.root.deinit(allocator);
        if (platform.model != null){
            allocator.free(platform.model_str);
        }
        allocator.free(platform.dtb_bytes);
    }
};

fn regionsAdd(node: *dtb.Node, regions: *std.ArrayList(Platform.Region)) !void {
    for (node.children) |child| {
        try regionsAdd(child, regions);
    }

    if (node.prop(.Reg)) |reg| {
        for (reg) |r| {
            try regions.append(.{
                .addr = @intCast(r[0]),
                .size = @intCast(r[1]),
                .node = node,
            });
        }
    }
}

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
        if (c.igTreeNodeEx_Str(c_name.ptr, flags)) {
            // TODO: maybe want better hover flags
            if (c.igIsItemToggledOpen()) {
                highlighted_node = node;
            }
            if (node.prop(.Compatible)) |compatibles| {
                if (c.igTreeNodeEx_Str("compatible", c.ImGuiTreeNodeFlags_DefaultOpen | c.ImGuiTreeNodeFlags_Leaf)) {
                    for (compatibles) |compatible| {
                        const compatible_str = fmt(allocator, "{s}", .{ compatible });
                        defer allocator.free(compatible_str);
                        if (c.igTreeNodeEx_Str(compatible_str, c.ImGuiTreeNodeFlags_Leaf)) {
                            c.igTreePop();
                        }
                    }
                    c.igTreePop();
                }
            }
            if (node.prop(.Reg)) |regions| {
                if (c.igTreeNodeEx_Str("memory", c.ImGuiTreeNodeFlags_DefaultOpen | c.ImGuiTreeNodeFlags_Leaf)) {
                    for (regions) |region| {
                        const human_size = humanSize(allocator, @intCast(region[1]));
                        defer allocator.free(human_size);
                        const addr = fmt(allocator, "[0x{x}..0x{x}] ({s})", .{ region[0], region[0] + region[1], human_size });
                        defer allocator.free(addr);
                        if (c.igTreeNodeEx_Str(addr, c.ImGuiTreeNodeFlags_Leaf)) {
                            c.igTreePop();
                        }
                    }
                    c.igTreePop();
                }
            }
            if (node.prop(.Interrupts)) |irqs| {
                if (c.igTreeNodeEx_Str("interrupts", c.ImGuiTreeNodeFlags_DefaultOpen | c.ImGuiTreeNodeFlags_Leaf)) {
                    for (irqs) |irq| {
                        // TODO: fix
                        if (node.interruptCells() != 3) {
                            continue;
                        }
                        {
                            const irq_str = fmt(allocator, "GIC visibile: 0x{x} ({d})", .{ irq[1], irq[1] });
                            defer allocator.free(irq_str);
                            if (c.igTreeNodeEx_Str(irq_str, c.ImGuiTreeNodeFlags_Leaf)) {
                                c.igTreePop();
                            }
                        }
                        {
                            const irq_str = fmt(allocator, "software visibile: 0x{x} ({d})", .{ irq[1] + 32, irq[1] + 32 });
                            defer allocator.free(irq_str);
                            if (c.igTreeNodeEx_Str(irq_str, c.ImGuiTreeNodeFlags_Leaf)) {
                                c.igTreePop();
                            }
                        }
                    }
                    c.igTreePop();
                }
            }
            if (node.children.len != 0) {
                highlighted_node = try nodeTree(allocator, node.children, highlighted_node, expand_all);
            }
            c.igTreePop();
        }
    }

    return highlighted_node;
}

fn readFileFull(allocator: Allocator, path: []const u8) ![]const u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    const size = (try file.stat()).size;
    const bytes = try file.reader().readAllAlloc(allocator, size);

    return bytes;
}

const CompatibleMap = struct {
    // This map will point to data in the file bytes, therefore the given bytes
    // must be valid as long as the map.
    map: std.StringHashMap([]const u8),

    pub fn create(allocator: Allocator, bytes: []const u8) !CompatibleMap {
        var map = std.StringHashMap([]const u8).init(allocator);
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

        return .{
            .map = map,
        };
    }

    pub fn deinit(compatible: *CompatibleMap) void {
        compatible.map.deinit();
    }
};

// TODO: clean up
fn stringLessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.order(u8, lhs, rhs) == .lt;
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

    std.mem.sort([:0]const u8, example_dtbs.items, {}, stringLessThan);

    return example_dtbs;
}

fn memoryInputTextCallback(_: ?*c.ImGuiInputTextCallbackData) callconv(.C) c_int {
    std.debug.print("got input\n", .{ });
    return 0;
}

fn handleFileDialogue(allocator: Allocator, s: *State, saved: *SavedState) !void {
    const paths = try openFilePicker(allocator);
    defer {
        for (paths.items) |path| {
            allocator.free(path);
        }
        paths.deinit();
    }
    for (paths.items) |path| {
        try s.loadPlatform(saved, path);
    }
    if (paths.items.len > 0) {
        s.setPlatform(paths.getLast());
    }
}

fn openFilePicker(allocator: Allocator) !std.ArrayList([:0]const u8) {
    var paths = std.ArrayList([:0]const u8).init(allocator);
    // TODO: when creating classes/objects, may need to handle deallaction explicilty?
    if (builtin.os.tag == .macos) {
        const NSOpenPanel = objc.getClass("NSOpenPanel").?;
        const panel = NSOpenPanel.msgSend(objc.Object, "openPanel", .{});
        panel.setProperty("allowsMultipleSelection", true);
        const response = panel.msgSend(usize, "runModal", .{});
        // const application = objc.getClass("NSApplication").?.msgSend(objc.Object, "sharedApplication", .{});
        // const NSApplication = objc.getClass("NSApplication").?;
        // const NSModalResponseOK = NSApplication.getProperty(usize, "NSModalResponseOK");
        // TODO: use actual constant
        if (response == 1) {
            const urls = panel.getProperty(objc.Object, "URLs");
            var it = urls.iterate();
            while (it.next()) |url| {
                // fileSystemRepresentation will deallocate the string, so we must copy it
                // for ourselves.
                const c_string = url.getProperty([*c]u8, "fileSystemRepresentation");
                const owned_c_string = try allocator.dupeZ(u8, std.mem.span(c_string));

                try paths.append(owned_c_string);
            }
        }
    } else if (builtin.os.tag == .linux) {
        const path = c.gtk_file_picker();
        if (path) |p| {
            try paths.append(try allocator.dupeZ(u8, std.mem.span(p)));
            c.g_free(p);
        }
    } else {
        @compileError("unknown OS");
    }

    return paths;
}

const usage_text =
    \\usage: dtd [-h|--help] [DTB PATHS ...]
    \\
    \\Open Device Tree Detective via the command line.
    \\Pass list of paths to DTBs to open first.
    \\
;

const Args = struct {
    paths: std.ArrayList([:0]const u8),
    // TODO: eventually remove and do automatic DPI scaling
    high_dpi: bool,

    pub fn parse(allocator: Allocator, args: []const [:0]const u8) !Args {
        const stdout = std.io.getStdOut();

        const usage_text_fmt = fmt(allocator, usage_text, .{});
        defer allocator.free(usage_text_fmt);

        var paths = std.ArrayList([:0]const u8).init(allocator);
        var high_dpi = false;

        var arg_i: usize = 1;
        while (arg_i < args.len) : (arg_i += 1) {
            const arg = args[arg_i];
            if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
                try stdout.writeAll(usage_text_fmt);
                std.process.exit(0);
            } else if (std.mem.eql(u8, arg, "--high-dpi")) {
                high_dpi = true;
            } else {
                try paths.append(arg);
            }
        }

        return .{
            .paths = paths,
            .high_dpi = high_dpi,
        };
    }

    pub fn deinit(args: Args) void {
        args.paths.deinit();
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer {
        _ = gpa.deinit();
    }

    const process_args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, process_args);
    const args = try Args.parse(allocator, process_args);
    defer args.deinit();

    if (builtin.os.tag == .linux) {
        log.info("GTK version build={d}.{d}.{d} runtime={d}.{d}.{d}", .{
            c.GTK_MAJOR_VERSION,
            c.GTK_MINOR_VERSION,
            c.GTK_MICRO_VERSION,
            c.gtk_get_major_version(),
            c.gtk_get_minor_version(),
            c.gtk_get_micro_version(),
        });
    }

    state = State.create(allocator);
    defer state.deinit();

    saved_state = try SavedState.create(allocator, "user.json");
    defer saved_state.deinit();

    // Do not need to deinit since it will be done when we deinit the whole
    // list of platforms.
    for (args.paths.items) |path| {
        try state.loadPlatform(&saved_state, path);
    }
    if (args.paths.items.len > 0) {
        state.setPlatform(args.paths.getLast());
    }

    // TODO
    // var dts = try decompileDtb(allocator, init_platform.path);
    // defer dts.deinit(allocator);

    var linux_driver_compatible = try CompatibleMap.create(allocator, linux_driver_compatible_txt);
    defer linux_driver_compatible.deinit();
    var linux_dt_binding_compatible = try CompatibleMap.create(allocator, linux_dt_binding_compatible_txt);
    defer linux_dt_binding_compatible.deinit();
    var uboot_driver_compatible = try CompatibleMap.create(allocator, uboot_driver_compatible_txt);
    defer uboot_driver_compatible.deinit();

    const sel4_example_dtbs: ?std.ArrayList([:0]const u8) = exampleDtbs(allocator, "dtbs/sel4") catch |e| blk: {
        switch (e) {
            error.FileNotFound => break :blk null,
            else => @panic("todo"),
        }
    };
    defer {
        if (sel4_example_dtbs) |list| {
            for (list.items) |d| {
                allocator.free(d);
            }
            list.deinit();
        }
    }
    const linux_example_dtbs: ?std.ArrayList([:0]const u8) = exampleDtbs(allocator, "dtbs/linux") catch |e| blk: {
        switch (e) {
            error.FileNotFound => break :blk null,
            else => @panic("todo"),
        }
    };
    defer {
        if (linux_example_dtbs) |list| {
            for (list.items) |d| {
                allocator.free(d);
            }
            list.deinit();
        }
    }

    // var procs: gl.ProcTable = undefined;

    _ = c.glfwSetErrorCallback(errorCallback);

    if (c.glfwInit() != c.GLFW_TRUE) {
        return;
    }
    defer c.glfwTerminate();

    const GLSL_VERSION = comptime switch (builtin.os.tag) {
        .macos => "#version 150",
        .linux => "#version 130",
        else => @compileError("unknown GLSL version for OS"),
    };
    c.glfwWindowHint(c.GLFW_CONTEXT_VERSION_MAJOR, 3);
    c.glfwWindowHint(c.GLFW_CONTEXT_VERSION_MINOR, 3);

    if (builtin.os.tag == .macos) {
        c.glfwWindowHint(c.GLFW_OPENGL_FORWARD_COMPAT, c.GL_TRUE);
    }

    const window = c.glfwCreateWindow(1920, 1080, "Device Tree Detective", null, null);
    if (window == null) {
        return;
    }
    defer c.glfwDestroyWindow(window);

    var window_width: c_int = undefined;
    var window_height: c_int = undefined;

    c.glfwMakeContextCurrent(window);
    c.glfwSwapInterval(1);

    // Load window icon
    if (builtin.os.tag == .macos) {
        // This GLFW API is not valid on macOS, we have to go through Objective-C
        // and the macOS API instead.
        const NSApplication = objc.getClass("NSApplication").?;
        const application = NSApplication.msgSend(objc.Object, "sharedApplication", .{});

        // TODO: need to call dealloc on things
        // We need to create an NSImage and then assign it to NSApplication.applicationIconImage

        const NSString = objc.getClass("NSString").?;

        const c_string: [:0]const u8 = "assets/icons/macos.png";
        const ns_string = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{
            c_string,
        });

        const NSImage = objc.getClass("NSImage").?;
        const ns_image = NSImage.msgSend(objc.Object, "alloc", .{});
        std.debug.assert(ns_image.value != null);
        ns_image.msgSend(void, "initByReferencingFile:", .{
            ns_string,
        });

        application.setProperty("applicationIconImage", ns_image);
    } else {
        var icons = std.mem.zeroes([1]c.GLFWimage);
        icons[0].pixels = c.stbi_load_from_memory(@constCast(@ptrCast(logo.ptr)), logo.len, &icons[0].width, &icons[0].height, 0, 4);
        c.glfwSetWindowIcon(window, 1, &icons);
        c.stbi_image_free(icons[0].pixels);
    }

    _ = c.glfwSetDropCallback(window, dropCallback);

    // if (!procs.init(c.glfwGetProcAddress)) return error.InitFailed;

    // gl.makeProcTableCurrent(&procs);
    // defer gl.makeProcTableCurrent(null);

    // TODO: not sure what to do about CIMGUI_CHECKVERSION
    // _ = c.CIMGUI_CHECKVERSION();
    _ = c.igCreateContext(null);
    defer c.igDestroyContext(null);

    const imio = c.igGetIO_Nil();
    imio.*.ConfigFlags = c.ImGuiConfigFlags_NavEnableKeyboard;

    const font_size: f32 = if (args.high_dpi) 20 else 14;
    const font_cfg = c.ImFontConfig_ImFontConfig();
    if (builtin.os.tag == .macos) {
        // TODO: this does largely fix the blurriness seen on macOS.
        // Not sure if it's the full solution. There's also https://github.com/ocornut/imgui/blob/master/docs/FONTS.md#using-freetype-rasterizer-imgui_freetype
        // and some comments on the RasterizerDensity field definition in imgui.
        font_cfg.*.RasterizerDensity = 2.0;
    }
    // Stop ImGui from freeing our font memory.
    font_cfg.*.FontDataOwnedByAtlas = false;
    _ = c.ImFontAtlas_AddFontFromMemoryTTF(imio.*.Fonts, @constCast(@ptrCast(font.ptr)), @intCast(font.len), font_size, font_cfg, null);

    c.igStyleColorsLight(null);

    _ = c.ImGui_ImplGlfw_InitForOpenGL(window, true);
    defer c.ImGui_ImplGlfw_Shutdown();

    _ = c.ImGui_ImplOpenGL3_Init(GLSL_VERSION);
    defer c.ImGui_ImplOpenGL3_Shutdown();

    // ===== Styling Begin =======
    const style = c.igGetStyle();
    style.*.TabRounding = 0;
    const scale: f32 = if (args.high_dpi) 2 else 1.25;
    c.ImGuiStyle_ScaleAllSizes(style, scale);

    setColour(.child_bg, .{ .x = 0.6, .y = 0.6, .z = 0.6, .w = 1 });
    setColour(.popup_bg, .{ .x = 0.8, .y = 0.8, .z = 0.8, .w = 1 });
    setColour(.window_bg, .{ .x = 0.751, .y = 0.751, .z = 0.751, .w = 1 });
    setColour(.text, .{ .x = 0, .y = 0, .z = 0, .w = 1 });
    setColour(.title_bg, .{ .x = 0.6, .y = 0.6, .z = 0.6, .w = 1 });
    setColour(.title_bg_active, .{ .x = 0.6, .y = 0.6, .z = 0.6, .w = 1 });
    setColour(.menu_bar_bg, .{ .x = 1, .y = 1, .z = 1, .w = 1 });
    setColour(.button, .{ .x = 0.729, .y = 0.506, .z = 0.125, .w = 1 });
    setColour(.button_hovered, .{ .x = 0.812, .y = 0.549, .z = 0.098, .w = 1 });
    setColour(.tab, .{ .x = 0.651, .y = 0.451, .z = 0.110, .w = 1 });
    setColour(.tab_selected, .{ .x = 0.788, .y = 0.541, .z = 0.110, .w = 1 });
    setColour(.tab_hovered, .{ .x = 0.812, .y = 0.549, .z = 0.098, .w = 1 });
    setColour(.header_hovered, .{ .x = 0.788, .y = 0.541, .z = 0.110, .w = 1 });
    // ===== Styling End =======

    // TODO: move this into platform struct
    var nodes_expand_all = false;
    while (c.glfwWindowShouldClose(window) != c.GLFW_TRUE) {
        c.glfwPollEvents();

        if (state.getPlatform()) |platform| {
            const window_title = fmt(allocator, "{s} - Device Tree Detective", .{ platform.path });
            defer allocator.free(window_title);
            c.glfwSetWindowTitle(window, window_title);
        } else {
            c.glfwSetWindowTitle(window, "Device Tree Detective");
        }

        c.ImGui_ImplOpenGL3_NewFrame();
        c.ImGui_ImplGlfw_NewFrame();
        c.igNewFrame();

        c.glfwGetWindowSize(window, &window_width, &window_height);
        state.window_width = @intCast(window_width);
        state.window_height = @intCast(window_height);

        var open_about = false;
        var exit = false;
        var open = false;
        var close = false;
        var close_all = false;
        var dtb_to_load: ?[:0]const u8 = null;
        if (c.igBeginMainMenuBar()) {
            if (c.igBeginMenu("File", true)) {
                if (c.igMenuItem_Bool("Open", SUPER_KEY_STR ++ " + O", false, true)) {
                    open = true;
                }
                if (c.igMenuItem_Bool("Close", SUPER_KEY_STR ++ " + W", false, true)) {
                    close = true;
                }
                if (c.igMenuItem_Bool("Close All", SUPER_KEY_STR ++ " + SHIFT + W", false, true)) {
                    close_all = true;
                }
                c.igSeparator();
                if (c.igBeginMenu("Example DTBs", true)) {
                    if (sel4_example_dtbs) |list| {
                        if (c.igBeginMenu("seL4", true)) {
                            for (list.items) |example| {
                                if (c.igMenuItem_Bool(example, null, false, true)) {
                                    dtb_to_load = example;
                                }
                            }
                            c.igEndMenu();
                        }
                    }
                    if (linux_example_dtbs) |list| {
                        if (c.igBeginMenu("Linux", true)) {
                            for (list.items) |example| {
                                if (c.igMenuItem_Bool(example, null, false, true)) {
                                    dtb_to_load = example;
                                }
                            }
                            c.igEndMenu();
                        }
                    }
                    c.igEndMenu();
                }
                if (builtin.mode == .Debug) {
                    if (c.igBeginMenu("Debug", true)) {
                        if (c.igBeginMenu("Colours", true)) {
                            const sz = c.igGetTextLineHeight();
                            for (0..c.ImGuiCol_COUNT) |i| {
                                const name = c.igGetStyleColorName(@intCast(i));
                                var p: c.ImVec2 = undefined;
                                c.igGetCursorScreenPos(&p);
                                c.ImDrawList_AddRectFilled(c.igGetWindowDrawList(), p, .{ .x = p.x + sz, .y = p.y + sz }, c.igGetColorU32_Col(@intCast(i), 1), 0, 0);
                                c.igDummy(.{ .x = sz, .y = sz });
                                c.igSameLine(0, -1.0);
                                _ = c.igMenuItem_Bool(name, null, false, true);
                            }
                            c.igEndMenu();
                        }
                        c.igEndMenu();
                    }
                }
                c.igSeparator();
                if (c.igMenuItem_Bool("Exit", null, false, true)) {
                    exit = true;
                }
                c.igEndMenu();
            }
            if (c.igBeginMenu("Help", true)) {
                if (c.igMenuItem_Bool("About", null, false, true)) {
                    open_about = true;
                }
                c.igEndMenu();
            }
            c.igEndMainMenuBar();
        }

        const menu_bar_window = c.igFindWindowByName("##MainMenuBar");
        state.main_menu_bar_height = c.igExtern_MainMenuBarHeight(menu_bar_window);

        // TODO: should we use igShortcut instead?
        // Yes we should, e.g if I open the 'about' window and the do CTRL + W the window
        // will close.

        if (open or c.igIsKeyChordPressed_Nil(c.ImGuiMod_Ctrl | c.ImGuiKey_O)) {
            try handleFileDialogue(allocator, &state, &saved_state);
        }

        if (close or c.igIsKeyChordPressed_Nil(c.ImGuiMod_Ctrl | c.ImGuiKey_W)) {
            if (state.platforms.items.len == 0) {
                exit = true;
            }

            if (state.getPlatform()) |p| {
                // TODO: a bit weird that we are using path here instead of index?
                state.unloadPlatform(p.path);
            }
        }

        if (close_all or c.igIsKeyChordPressed_Nil(c.ImGuiMod_Ctrl | c.ImGuiKey_W | c.ImGuiMod_Shift)) {
            for (state.platforms.items) |*platform| {
                platform.deinit();
            }
            state.platform = null;
            state.platforms.clearAndFree();
        }

        // We have a DTB to load, but it might already be the current one.
        if (dtb_to_load) |d| {
            nodes_expand_all = false;
            try state.loadPlatform(&saved_state, d);
            state.setPlatform(d);
        }

        if (exit) {
            // TODO: need to actually deallocate everything first
            std.process.exit(0);
        }

        if (open_about) {
            c.igOpenPopup_Str("About", 0);
        }

        var p_open = true;
        c.igSetNextWindowPos(state.windowPos(0.5, 0.5), 0, .{ .x = 0.5, .y = 0.5 });
        if (c.igBeginPopupModal("About", &p_open, c.ImGuiWindowFlags_AlwaysAutoResize | c.ImGuiWindowFlags_NoResize | c.ImGuiWindowFlags_NoMove)) {
            c.igText(ABOUT);
            c.igTextLinkOpenURL("Home page", "TODO");
            c.igSameLine(0, -1.0);
            c.igTextLinkOpenURL("Source Code", "TODO");
            c.igSameLine(0, -1.0);
            c.igTextLinkOpenURL("Report issue", "TODO");
            c.igSeparator();
            c.igText("This program is intended to help people explore and visualise Device Tree Blob files.");
            c.igText("Created by Ivan Velickovic in 2025.");
            c.igEndPopup();
        }

        if (state.getPlatform()) |platform| {
            c.igSetNextWindowPos(state.windowPos(0, 0), 0, .{});
            _ = c.igBegin("DTBs", null, c.ImGuiWindowFlags_NoCollapse | c.ImGuiWindowFlags_NoResize);
            c.igSetWindowSize_Vec2(state.windowSize(0.15, 1.0), 0);
            for (state.platforms.items) |p| {
                c.igText(p.path);
            }
            c.igEnd();

            c.igSetNextWindowPos(state.windowPos(0.15, 0), 0, .{});
            _ = c.igBegin("Tree", null, c.ImGuiWindowFlags_NoCollapse | c.ImGuiWindowFlags_NoResize);
            c.igSetWindowSize_Vec2(state.windowSize(0.35, 1.0), 0);

            // TODO: this logic is definetely wrong
            const expand_all = c.igButton("Expand All", .{});
            c.igSameLine(0, -1.0);
            const collapse_all = c.igButton("Collapse All", .{});
            if (!nodes_expand_all) {
                nodes_expand_all = expand_all;
            } else if (collapse_all) {
                nodes_expand_all = false;
            }

            state.highlighted_node = try nodeTree(allocator, platform.root.children, state.highlighted_node, nodes_expand_all);
            c.igEnd();

            // === Selected Node Window ===
            c.igSetNextWindowPos(state.windowPos(0.5, 0), 0, .{});

            _ = c.igBegin("Selected Node", null, c.ImGuiWindowFlags_NoCollapse | c.ImGuiWindowFlags_NoResize);
            c.igSetWindowSize_Vec2(state.windowSize(0.5, 0.5), 0);
            if (state.highlighted_node) |node| {
                var node_name = std.ArrayList(u8).init(allocator);
                defer node_name.deinit();
                const writer = node_name.writer();
                try nodeNamesFmt(node, writer);
                try writer.writeAll("\x00");
                c.igText(node_name.items[0..node_name.items.len - 1:0]);
                if (node.prop(.Compatible)) |compatibles| {
                    // TODO: do it for all compatibles, not just the first
                    c.igText("Linux driver:");
                    for (compatibles, 0..) |compatible, i| {
                        if (linux_driver_compatible.map.get(compatible)) |driver| {
                            const id = fmt(allocator, "{s}##linux-{}", .{ driver, i });
                            defer allocator.free(id);
                            const url = fmt(allocator, "{s}/{s}", .{ LINUX_GITHUB, driver });
                            defer allocator.free(url);
                            c.igTextLinkOpenURL(id, url);
                        }
                    }
                    if (linux_dt_binding_compatible.map.get(compatibles[0])) |driver| {
                        c.igText("Linux device tree bindings:");
                        c.igSameLine(0, -1.0);
                        const id = fmt(allocator, "{s}##linux-dt-bindings", .{ driver });
                        defer allocator.free(id);
                        const url = fmt(allocator, "{s}/{s}", .{ LINUX_GITHUB, driver });
                        defer allocator.free(url);
                        c.igTextLinkOpenURL(id, url);
                    }
                    if (uboot_driver_compatible.map.get(compatibles[0])) |driver| {
                        c.igText("U-Boot driver:");
                        c.igSameLine(0, -1.0);
                        const id = fmt(allocator, "{s}##uboot", .{ driver });
                        defer allocator.free(id);
                        const url = fmt(allocator, "{s}/{s}", .{ UBOOT_GITHUB, driver });
                        defer allocator.free(url);
                        c.igTextLinkOpenURL(id, url);
                    }
                }
                for (node.props) |prop| {
                    const prop_fmt = fmt(allocator, "{any}", .{ prop });
                    defer allocator.free(prop_fmt);
                    c.igText(prop_fmt);
                }
            }
            c.igEnd();
            // ===========================

            // === Details Window ===
            c.igSetNextWindowPos(state.windowPos(0.5, 0.5), 0, .{});
            _ = c.igBegin("Details", null, c.ImGuiWindowFlags_NoCollapse | c.ImGuiWindowFlags_NoResize);
            c.igSetWindowSize_Vec2(state.windowSize(0.5, 0.5), 0);
            if (c.igBeginTabBar("info", c.ImGuiTabBarFlags_None)) {
                if (c.igBeginTabItem("Platform", null, c.ImGuiTabItemFlags_None)) {
                    c.igText(platform.model_str);
                    if (platform.main_memory) |main_memory| {
                        if (c.igTreeNodeEx_Str(main_memory.fmt, c.ImGuiTreeNodeFlags_DefaultOpen)) {
                            for (main_memory.regions.items) |region| {
                                const human_size = humanSize(allocator, region.size);
                                defer allocator.free(human_size);
                                const addr = fmt(allocator, "[0x{x}..0x{x}] ({s})", .{ region.addr, region.addr + region.size, human_size });
                                defer allocator.free(addr);
                                if (c.igTreeNodeEx_Str(addr, c.ImGuiTreeNodeFlags_Leaf)) {
                                    c.igTreePop();
                                }
                            }
                            c.igTreePop();
                        }
                    }
                    if (platform.root.propAt(&.{ "cpus", "cpu@0" }, .RiscvIsaExtensions)) |extensions| {
                        if (c.igTreeNodeEx_Str("RISC-V ISA Extensions", c.ImGuiTreeNodeFlags_DefaultOpen)) {
                            for (extensions) |extension| {
                                const c_extension = fmt(allocator, "{s}", .{ extension });
                                defer allocator.free(c_extension);
                                if (c.igTreeNodeEx_Str(c_extension, c.ImGuiTreeNodeFlags_Leaf)) {
                                    c.igTreePop();
                                }
                            }
                            c.igTreePop();
                        }
                    }
                    c.igEndTabItem();
                }
                if (c.igBeginTabItem("Interrupts", null, c.ImGuiTabItemFlags_None)) {
                    var buf = [_:0]u8{0} ** 100;
                    _ = c.igInputText("input text", &buf, buf.len, 0, null, null);
                    for (platform.irqs.items) |irq| {
                        const irq_fmt = fmt(allocator, "{d} (0x{x}), {s}", .{ irq.number, irq.number, irq.node.name });
                        defer allocator.free(irq_fmt);
                        c.igText(irq_fmt);
                    }
                    c.igEndTabItem();
                }
                if (c.igBeginTabItem("Memory", null, c.ImGuiTabItemFlags_None)) {
                    var buf = [_:0]u8{0} ** 100;
                    _ = c.igInputTextWithHint("input text", "e.g 0x30400000", &buf, buf.len, 0, memoryInputTextCallback, null);
                    for (platform.regions.items) |reg| {
                        const reg_fmt = fmt(allocator, "[0x{x:0>12}..0x{x:0>12}], {s}", .{ reg.addr, reg.addr + reg.size, reg.node.name });
                        defer allocator.free(reg_fmt);
                        c.igText(reg_fmt);
                    }
                    c.igEndTabItem();
                }
                c.igEndTabBar();
            }
            c.igEnd();
        } else {
            // No platform, show welcome splash screen.
            c.igSetNextWindowPos(state.windowPos(0.5, 0.5), 0, .{ .x = 0.5, .y = 0.5 });
            _ = c.igBegin("Welcome", null, c.ImGuiWindowFlags_NoCollapse | c.ImGuiWindowFlags_NoResize | c.ImGuiWindowFlags_NoTitleBar);
            c.igSetWindowSize_Vec2(state.windowSize(0.5, 0.5), 0);
            c.igText("Device Tree Detective");
            if (c.igButton("Open DTB file", .{})) {
                try handleFileDialogue(allocator, &state, &saved_state);
            }

            c.igText("Recently opened");
            var selected_item: ?usize = null;
            if (c.igBeginTable("##recent-dtbs", 1, 0, .{}, 0.0)) {
                for (saved_state.recently_opened.items, 0..) |r, i| {
                    c.igTableNextRow(0, 0);
                    const colour = c.igGetColorU32_Vec4(Colour.toVec(0xF2A05C));
                    c.igTableSetBgColor(c.ImGuiTableBgTarget_RowBg0 + 1, colour, -1);
                    _ = c.igTableSetColumnIndex(0);
                    const is_selected = selected_item != null and selected_item.? == i;
                    const flags = if (is_selected) c.ImGuiSelectableFlags_Highlight else c.ImGuiSelectableFlags_None;

                    if (c.igSelectable_Bool(r, is_selected, flags, .{})) {
                        selected_item = i;
                    }

                    if (is_selected) {
                        c.igSetItemDefaultFocus();
                    }
                }
                c.igEndTable();
            }
            c.igEnd();

            if (selected_item) |i| {
                const item: [:0]const u8 = saved_state.recently_opened.items[i];
                try state.loadPlatform(&saved_state, item);
                state.setPlatform(item);
            }
        }
        // ===========================

        c.igRender();

        var width: c_int = 0;
        var height: c_int = 0;
        c.glfwGetFramebufferSize(window, &width, &height);
        c.glViewport(0, 0, width, height);
        c.glClearColor(0.2, 0.2, 0.2, 1.0);
        c.glClear(c.GL_COLOR_BUFFER_BIT);
        c.ImGui_ImplOpenGL3_RenderDrawData(c.igGetDrawData());

        c.glfwSwapBuffers(window);
    }
}
