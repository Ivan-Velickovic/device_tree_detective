const std = @import("std");
const builtin = @import("builtin");
// build.zig configuration options
const config = @import("config");
const dtb = @import("dtb.zig");
const dtc = @import("dtc.zig");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const log = std.log;
const lib = @import("lib.zig");
const fmt = lib.fmt;
const imgui = @import("imgui.zig");
const Colour = imgui.Colour;

comptime {
    // Zig has many breaking changes between minor releases so it is important that
    // we check the user has the right version.
    if (!config.ignore_zig_version and !(builtin.zig_version.major == 0 and builtin.zig_version.minor == 14 and builtin.zig_version.pre == null and builtin.zig_version.build == null)) {
        @compileError("expected Zig version 0.14.x to be used, you have " ++ builtin.zig_version_string);
    }
}

const c = @import("c.zig").c;
const objc = if (builtin.os.tag == .macos) @import("objc") else null;

const ABOUT = std.fmt.comptimePrint("Device Tree Detective v{s}", .{ config.version });

const SUPER_KEY_STR = if (builtin.os.tag == .macos) "CMD" else "CTRL";

const riscv_isa_extensions_csv = @embedFile("assets/maps/riscv_isa_extensions.csv");
const linux_driver_compatible_txt = @embedFile("assets/maps/linux_compatible_list.txt");
const linux_dt_binding_compatible_txt = @embedFile("assets/maps/dt_bindings_list.txt");
const uboot_driver_compatible_txt = @embedFile("assets/maps/uboot_compatible_list.txt");
const font: [:0]const u8 = @embedFile("assets/fonts/inter/Inter-Medium.ttf");
const logo: [:0]const u8 = @embedFile("assets/icons/macos.png");

fn humanTimestampDiff(allocator: Allocator, t0: i64, t1: i64) [:0]const u8 {
    const diff_s = t1 - t0;
    if (diff_s < std.time.s_per_hour) {
        const diff_m = @divFloor(diff_s, 60);
        if (diff_m == 0) {
            return fmt(allocator, "just now", .{});
        } else if (diff_m == 1) {
            return fmt(allocator, "{d} minute ago", .{ diff_m });
        } else {
            return fmt(allocator, "{d} minutes ago", .{ diff_m });
        }
    } else if (diff_s < std.time.s_per_day) {
        const diff_h = @divFloor(diff_s, 60 * 60);
        if (diff_h == 1) {
            return fmt(allocator, "{d} hour ago", .{ diff_h });
        } else {
            return fmt(allocator, "{d} hours ago", .{ diff_h });
        }
    } else {
        const diff_d = @divFloor(diff_s, 60 * 60 * 24);
        if (diff_d == 1) {
            return fmt(allocator, "{d} day ago", .{ diff_d });
        } else {
            return fmt(allocator, "{d} days ago", .{ diff_d });
        }
    }
}


const State = struct {
    allocator: Allocator,
    /// Loaded platforms for inspection
    platforms: std.ArrayList(Platform),
    /// Current platform that we are inspecting
    platform: ?usize = null,
    /// Set during GLFW window runtime
    window_width: u32 = undefined,
    window_height: u32 = undefined,
    main_menu_bar_height: f32 = undefined,
    /// Tree view state
    highlighted_node: ?*dtb.Node = null,
    persistent: Persistent,
    /// Compatible string maps
    /// Linux driver paths
    compatible_linux_drivers: CompatibleMap,
    /// U-Boot driver paths
    compatible_uboot_drivers: CompatibleMap,
    /// YAML bindings (from linux/Documentation/devicetree/bindings)
    compatible_linux_bindings: CompatibleMap,
    dtc_available: bool,

    pub fn init(allocator: Allocator) !State {
        return .{
            .allocator = allocator,
            .platforms = std.ArrayList(Platform).init(allocator),
            .persistent = Persistent.create(allocator, "user.json") catch @panic("TODO"),
            // TODO: all these maps could actually be done at compile time
            .compatible_linux_drivers = try CompatibleMap.create(allocator, linux_driver_compatible_txt),
            .compatible_uboot_drivers = try CompatibleMap.create(allocator, uboot_driver_compatible_txt),
            .compatible_linux_bindings = try CompatibleMap.create(allocator, linux_dt_binding_compatible_txt),
            .dtc_available = dtc.available(allocator),
        };
    }

    pub fn deinit(s: *State) void {
        for (s.platforms.items) |*p| {
            p.deinit();
        }
        s.platforms.deinit();
        s.persistent.deinit();

        s.compatible_linux_drivers.deinit();
        s.compatible_uboot_drivers.deinit();
        s.compatible_linux_bindings.deinit();
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

    pub fn loadPlatform(s: *State, path: [:0]const u8) !void {
        // No need to load anything if it already exists
        if (s.isPlatformLoaded(path)) {
            return;
        }

        const platform = try Platform.init(s.allocator, path);
        try s.platforms.append(platform);

        if (!s.persistent.isRecentlyOpened(path)) {
            try s.persistent.recently_opened.append(.{
                .path = try s.allocator.dupeZ(u8, path),
                .last_opened = std.time.timestamp(),
            });
        } else {
            // Update last opened timestamp
            var updated = false;
            for (s.persistent.recently_opened.items) |*entry| {
                if (std.mem.eql(u8, entry.path, path)) {
                    entry.last_opened = std.time.timestamp();
                    updated = true;
                    break;
                }
            }

            std.debug.assert(updated);
        }

        std.mem.sort(Persistent.RecentlyOpened, s.persistent.recently_opened.items, {}, Persistent.RecentlyOpened.asc);

        try s.persistent.save();
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
                if (s.platforms.items.len == 0) {
                    s.platform = null;
                } else if (i < s.platforms.items.len) {
                    s.platform = i;
                } else {
                    s.platform = s.platforms.items.len - 1;
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

    const Persistent = struct {
        allocator: Allocator,
        path: []const u8,
        file: std.fs.File,
        parsed: ?std.json.Parsed(Json),
        // TODO: statically allocate and put limit of a 100 or something?
        recently_opened: std.ArrayList(RecentlyOpened),

        const RecentlyOpened = struct {
            path: [:0]const u8,
            last_opened: i64,

            fn asc(_: void, a: RecentlyOpened, b: RecentlyOpened) bool {
                return a.last_opened > b.last_opened;
            }
        };

        const Json = struct {
            recently_opened: []RecentlyOpened,
        };

        fn createEmpty(allocator: Allocator, path: []const u8, file: std.fs.File) error{OutOfMemory}!Persistent {
            var p: Persistent = .{
                .allocator = allocator,
                .path = path,
                .file = file,
                .parsed = null,
                .recently_opened = std.ArrayList(RecentlyOpened).init(allocator),
            };
            p.save() catch @panic("todo");

            return p;
        }

        pub fn create(allocator: Allocator, path: []const u8) error{OutOfMemory}!Persistent {
            // Create the file if it does not exist.
            const file = std.fs.cwd().openFile(path, .{ .mode = .read_write }) catch |e| {
                switch (e) {
                    error.FileNotFound => {
                        log.info("persistent state configuration does not exist '{s}', starting from scratch", .{ path });
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
                log.err("could not parse persistent state configuration '{s}' with error '{any}' removing and starting from scratch", .{ path, e });
                return createEmpty(allocator, path, file);
            };

            var recently_opened = try std.ArrayList(RecentlyOpened).initCapacity(allocator, parsed.value.recently_opened.len);
            for (parsed.value.recently_opened) |entry| {
                std.fs.cwd().access(entry.path, .{}) catch |e| {
                    log.info("cannot access recently opened file '{s}' ({any}), dropping from list", .{ entry.path, e });
                    continue;
                };
                recently_opened.appendAssumeCapacity(.{
                    .path = try allocator.dupeZ(u8, entry.path),
                    .last_opened = entry.last_opened,
                });
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

        pub fn isRecentlyOpened(p: *Persistent, path: []const u8) bool {
            for (p.recently_opened.items) |entry| {
                if (std.mem.eql(u8, entry.path, path)) {
                    return true;
                }
            }

            return false;
        }

        fn clearRecentlyOpened(p: *Persistent) !void {
            for (p.recently_opened.items) |entry| {
                p.allocator.free(entry.path);
            }
            p.recently_opened.clearAndFree();
            try p.save();
        }

        /// Take the current state and write it out to the assocaited path
        pub fn save(p: *Persistent) !void {
            try p.file.seekTo(0);
            try p.file.setEndPos(0);
            try std.json.stringify(.{ .recently_opened = p.recently_opened.items }, .{ .whitespace = .indent_4 }, p.file.writer());
        }

        pub fn deinit(p: *Persistent) void {
            if (p.parsed) |parsed| {
                parsed.deinit();
            }
            p.file.close();
            for (p.recently_opened.items) |entry| {
                p.allocator.free(entry.path);
            }
            p.recently_opened.deinit();
        }
    };
};

var state: State = undefined;

fn dropCallback(_: ?*c.GLFWwindow, count: c_int, paths: [*c][*c]const u8) callconv(.C) void {
    for (0..@intCast(count)) |i| {
        log.debug("adding dropped '{s}'", .{ paths[i] });
        // TODO: check the file is actually an FDT
        state.loadPlatform(std.mem.span(paths[i])) catch @panic("TODO");
    }
    state.setPlatform(std.mem.span(paths[@as(usize, @intCast(count)) - 1]));
}

fn glfwErrorCallback(errn: c_int, str: [*c]const u8) callconv(.C) void {
    // TODO:
    log.err("GLFW Error '{}'': {s}", .{ errn, str });
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

const LINUX_GITHUB = "https://github.com/torvalds/linux/tree/master";
const UBOOT_GITHUB = "https://github.com/u-boot/u-boot/tree/master";

const Platform = struct {
    allocator: Allocator,
    dtb_bytes: []const u8,
    dts: ?std.ArrayListUnmanaged(u8),
    path: [:0]const u8,
    root: *dtb.Node,
    model: ?[]const u8,
    regions: std.ArrayList(Platform.Region),
    main_memory: ?MainMemory,
    irqs: std.ArrayList(Irq),
    irq_controllers: std.ArrayList(*dtb.Node),
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

        pub fn asc(_: void, a: Region, b: Region) bool {
            return a.addr < b.addr;
        }
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
        std.mem.sort(Region, regions.items, {}, Region.asc);

        var irq_controllers = std.ArrayList(*dtb.Node).init(allocator);
        try irqControllers(root, &irq_controllers);

        var maybe_dts = dtc.fromBlob(allocator, path) catch @panic("TODO");
        if (maybe_dts) |*dts| {
            try dts.appendSlice(allocator, "\x00");
        }

        return .{
            .allocator = allocator,
            .dtb_bytes = dtb_bytes,
            .dts = maybe_dts,
            .path = try allocator.dupeZ(u8, path),
            .root = root,
            .model = root.prop(.Model),
            .main_memory = main_memory,
            .irqs = try irqList(allocator, root),
            .irq_controllers = irq_controllers,
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
        platform.irq_controllers.deinit();
        platform.regions.deinit();
        platform.root.deinit(allocator);
        if (platform.model != null){
            allocator.free(platform.model_str);
        }
        allocator.free(platform.dtb_bytes);
        if (platform.dts) |*dts| {
            dts.deinit(platform.allocator);
        }
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

    fn asc(_: void, a: Irq, b: Irq) bool {
        return a.number < b.number;
    }
};

fn irqList(allocator: Allocator, root: *dtb.Node) !std.ArrayList(Irq) {
    var irqs = std.ArrayList(Irq).init(allocator);
    try irqListAdd(root.children, &irqs);

    std.mem.sort(Irq, irqs.items, {}, Irq.asc);

    return irqs;
}

fn irqControllers(node: *dtb.Node, irq_controllers: *std.ArrayList(*dtb.Node)) !void {
    if (node.prop(.InterruptController)) |_| {
        try irq_controllers.append(node);
    }
    for (node.children) |child| {
        try irqControllers(child, irq_controllers);
    }
}

// fn drawIrqControllerLines(platform: *Platform, irq_controller: *dtb.Node, draw_list: *c.Im start_pos: c.ImVec2) void {
// }

fn filterProps(allocator: Allocator, filter: *c.ImGuiTextFilter, node: *dtb.Node) bool {
    for (node.props) |prop| {
        const prop_fmt = fmt(allocator, "{any}", .{ prop });
        defer allocator.free(prop_fmt);
        if (c.ImGuiTextFilter_PassFilter(filter, prop_fmt, null)) {
            return true;
        }
    }

    return false;
}

fn displayTree(allocator: Allocator, filter: *c.ImGuiTextFilter, nodes: []*dtb.Node, curr_highlighted_node: ?*dtb.Node, open: ?bool, ignore_disabled: bool, search_props: bool) !?*dtb.Node {
    var highlighted_node: ?*dtb.Node = curr_highlighted_node;
    for (nodes) |node| {
        const name = try allocator.dupeZ(u8, node.name);
        defer allocator.free(name);

        const disabled = blk: {
            if (node.prop(.Status)) |status| {
                break :blk status == .Disabled;
            } else {
                break :blk false;
            }
        };

        if ((ignore_disabled and disabled) or !c.ImGuiTextFilter_PassFilter(filter, name, null)) {
            if (search_props and !filterProps(allocator, filter, node)) {
                highlighted_node = try displayTree(allocator, filter, node.children, highlighted_node, open, ignore_disabled, search_props);
                continue;
            }
        }

        const flags = c.ImGuiTreeNodeFlags_AllowOverlap | c.ImGuiTreeNodeFlags_SpanFullWidth;
        if (open) |val| {
            c.igSetNextItemOpen(val, c.ImGuiCond_None);
        }
        if (c.igTreeNodeEx_Str(name, flags)) {
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
                highlighted_node = try displayTree(allocator, filter, node.children, highlighted_node, open, ignore_disabled, search_props);
            }
            c.igTreePop();
        }
        if (c.igIsItemHovered(c.ImGuiHoveredFlags_None)) {
            highlighted_node = node;
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

// fn nodeToSource(node: *dtb.Node, source: []const u8) []const u8 {

// }

fn displaySelectedNode(allocator: Allocator) !void {
    c.igSetNextWindowPos(state.windowPos(0.5, 0), 0, .{});
    _ = c.igBegin("Selected Node", null, c.ImGuiWindowFlags_NoCollapse | c.ImGuiWindowFlags_NoResize);
    c.igSetWindowSize_Vec2(state.windowSize(0.5, 0.5), 0);
    if (state.highlighted_node) |node| {
        if (c.igBeginTabBar("Views", c.ImGuiTabBarFlags_None)) {
            if (c.igBeginTabItem("Details", null, c.ImGuiTabItemFlags_None)) {
                var name_bytes = std.ArrayList(u8).init(allocator);
                defer name_bytes.deinit();
                const node_name = try dtb.nodeNameFullPath(&name_bytes, node);
                c.igText(node_name);
                if (node.interruptParent()) |irq_parent| {
                    if (imgui.secondaryButton("Go to IRQ parent")) {
                        state.highlighted_node = irq_parent;
                    }
                }
                if (node.prop(.Compatible)) |compatibles| {
                    // TODO: do it for all compatibles, not just the first
                    c.igText("Linux driver:");
                    for (compatibles, 0..) |compatible, i| {
                        if (state.compatible_linux_drivers.map.get(compatible)) |driver| {
                            const id = fmt(allocator, "{s}##linux-{}", .{ driver, i });
                            defer allocator.free(id);
                            const url = fmt(allocator, "{s}/{s}", .{ LINUX_GITHUB, driver });
                            defer allocator.free(url);
                            c.igTextLinkOpenURL(id, url);
                        }
                    }
                    if (state.compatible_linux_bindings.map.get(compatibles[0])) |driver| {
                        c.igText("Linux device tree bindings:");
                        c.igSameLine(0, -1.0);
                        const id = fmt(allocator, "{s}##linux-dt-bindings", .{ driver });
                        defer allocator.free(id);
                        const url = fmt(allocator, "{s}/{s}", .{ LINUX_GITHUB, driver });
                        defer allocator.free(url);
                        c.igTextLinkOpenURL(id, url);
                    }
                    if (state.compatible_uboot_drivers.map.get(compatibles[0])) |driver| {
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
                c.igEndTabItem();
            }
            if (c.igBeginTabItem("Source", null, c.ImGuiTabItemFlags_None)) {
                const platform = state.getPlatform().?;
                if (platform.dts) |dts| {
                    c.igTextUnformatted(@ptrCast(dts.items), null);
                } else if (!state.dtc_available) {
                    // TODO: this is a big mess - there's too much state to keep track of and weird edge
                    // cases. It would be way easier if we just always had dtc available by shipping it ourselves!
                    c.igText("The Device Tree Compiler (dtc) is required to be installed for the source view but could not be found.");
                    const try_again = c.igButton("Try again", .{});
                    if (try_again) {
                        state.dtc_available = dtc.available(allocator);
                        platform.dts = dtc.fromBlob(allocator, platform.path) catch |e| blk: {
                            log.err("dtc should have been available but we failed to decompile blob: {any}", .{ e });
                            break :blk null;
                        };
                        if (platform.dts) |*dts| {
                            try dts.appendSlice(allocator, "\x00");
                        }
                    }
                }
                c.igEndTabItem();
            }
        }
        c.igEndTabBar();
    }
    c.igEnd();
}

fn displayExampleDtbs(label: [:0]const u8, dtbs: ?std.ArrayList([:0]const u8), selected: *?[:0]const u8) void {
    if (dtbs != null and c.igBeginMenu(label, true)) {
        defer c.igEndMenu();

        var filter: c.ImGuiTextFilter = .{};

        if (c.igInputText("##example-filter", &filter.InputBuf, filter.InputBuf.len, c.ImGuiInputTextFlags_EscapeClearsAll, null, null)) {
            c.ImGuiTextFilter_Build(&filter);
        }

        for (dtbs.?.items) |example| {
            // TODO: there's a bug here, clicking instead clears the filter rather than
            // selecting the DTB to load
            if (c.ImGuiTextFilter_PassFilter(&filter, example, null)) {
                _ = c.igMenuItem_Bool(example, null, false, true);
                if (c.igIsItemClicked(c.ImGuiMouseButton_Left)) {
                    selected.* = example;
                    return;
                }
            }
        }
    }
}

fn memoryInputTextCallback(_: ?*c.ImGuiInputTextCallbackData) callconv(.C) c_int {
    std.debug.print("got input\n", .{ });
    return 0;
}

fn handleFileDialogue(allocator: Allocator, s: *State) !void {
    const paths = try openFilePicker(allocator);
    defer {
        for (paths.items) |path| {
            allocator.free(path);
        }
        paths.deinit();
    }
    for (paths.items) |path| {
        try s.loadPlatform(path);
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
    } else if (builtin.os.tag == .windows) {
        const utf16_path = c.windows_file_picker();
        if (utf16_path) |p| {
            const path = try std.unicode.utf16LeToUtf8AllocZ(allocator, std.mem.span(p));
            try paths.append(path);
        }
    } else {
        @compileError("unknown OS '" ++ @tagName(builtin.os.tag) ++ "' for file picker");
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

fn glfwWindowSizeCallback(_: ?*c.GLFWwindow, width: c_int, height: c_int) callconv(.C) void {
    log.info("window size changed to {}px by {}px", .{ width, height });
}

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

    log.info("starting Device Tree Detective version {s} on {s}", .{ config.version, @tagName(builtin.os.tag) });
    log.info("compiled with Zig {s}", .{ builtin.zig_version_string });
    log.info("GLFW version '{s}'", .{ c.glfwGetVersionString() });

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

    state = try State.init(allocator);
    defer state.deinit();

    log.info("dtc available: {}", .{ state.dtc_available });

    // Do not need to deinit since it will be done when we deinit the whole
    // list of platforms.
    for (args.paths.items) |path| {
        try state.loadPlatform(path);
    }
    if (args.paths.items.len > 0) {
        state.setPlatform(args.paths.getLast());
    }

    const sel4_example_dtbs: ?std.ArrayList([:0]const u8) = lib.exampleDtbs(allocator, lib.EXAMPLE_DTBS ++ "/sel4") catch |e| blk: {
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
    const linux_example_dtbs: ?std.ArrayList([:0]const u8) = lib.exampleDtbs(allocator, lib.EXAMPLE_DTBS ++ "/linux") catch |e| blk: {
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

    var riscv_isa_extensions = std.StringHashMap([]const u8).init(allocator);
    {
        var iterator = std.mem.splitScalar(u8, riscv_isa_extensions_csv, '\n');
        var i: usize = 0;
        while (iterator.next()) |line| : (i += 1) {
            if (i < 8) {
                continue;
            }

            var line_split = std.mem.splitScalar(u8, line, ',');
            // The CSV uses upper-case for the first letter of extensions, while we want
            // lower case as that is what Device Trees use.
            const isa_shorthand = try std.ascii.allocLowerString(allocator, line_split.first());
            const isa_name = line_split.peek().?;
            std.debug.assert(isa_shorthand.len != 0);
            std.debug.assert(isa_name.len != 0);

            try riscv_isa_extensions.put(isa_shorthand, isa_name);
        }
    }
    defer {
        var keys = riscv_isa_extensions.keyIterator();
        while (keys.next()) |key| {
            allocator.free(key.*);
        }
        defer riscv_isa_extensions.deinit();
    }
    // var procs: gl.ProcTable = undefined;

    _ = c.glfwSetErrorCallback(glfwErrorCallback);

    if (c.glfwInit() != c.GLFW_TRUE) {
        return;
    }
    defer c.glfwTerminate();

    const GLSL_VERSION = comptime switch (builtin.os.tag) {
        .macos => "#version 150",
        .linux, .windows => "#version 130",
        else => @compileError("unknown GLSL version for OS"),
    };
    c.glfwWindowHint(c.GLFW_CONTEXT_VERSION_MAJOR, 3);
    const opengl_minor_version = switch (builtin.os.tag) {
        .macos => 3,
        .linux => 1,
        else => @compileError("unknown OpenGL minor version for OS"),
    };
    c.glfwWindowHint(c.GLFW_CONTEXT_VERSION_MINOR, opengl_minor_version);

    if (builtin.os.tag == .macos) {
        c.glfwWindowHint(c.GLFW_OPENGL_FORWARD_COMPAT, c.GL_TRUE);
    }

    // TODO: window size needs to be figured out better, need to just make it full screen
    // on small screens and half size on large screens?
    const window = c.glfwCreateWindow(1920, 1080, "Device Tree Detective", null, null);
    if (window == null) {
        std.log.err("GLFW decided not to create a window", .{});
        return;
    }
    defer c.glfwDestroyWindow(window);

    _ = c.glfwSetWindowSizeCallback(window, glfwWindowSizeCallback);

    var window_width: c_int = undefined;
    var window_height: c_int = undefined;

    c.glfwMakeContextCurrent(window);
    c.glfwSwapInterval(1);

    // Load window icon
    if (builtin.os.tag == .macos) {
        // This GLFW API for setting the window icon is not valid on macOS, instead
        // we have to go through Objective-C and the Apple API instead.
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
        // NOTE: looks like this does mess up low-resolution screens on macOS, e.g my
        // 1080p monitor used as an external display.
        // Therefore, another consideration if we continue to use RasterizerDensity is that we need to
        // update this value based on the current monitor, which could change over the program's execution.
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
    style.*.ScrollbarRounding = 0;
    const scale: f32 = if (args.high_dpi) 2 else 1.25;
    c.ImGuiStyle_ScaleAllSizes(style, scale);

    inline for (imgui.GLOBAL_COLOURS) |colour| {
        Colour.setStyle(colour[0], colour[1]);
    }
    // ===== Styling End =======

    // TODO: move this into state struct?
    var filter_ignore_disabled = false;
    var fitler_include_props = true;
    var hovered_reg_box_index: ?usize = null;
    var hovered_irq_controller_index: ?usize = null;
    var hovered_irq_node_index: ?usize = null;
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
                if (c.igBeginMenu("Open Recent", true)) {
                    for (state.persistent.recently_opened.items) |p| {
                        if (c.igMenuItem_Bool(p.path, "", false, true)) {
                            dtb_to_load = p.path;
                        }
                    }
                    c.igSeparator();
                    if (imgui.secondaryButton("Clear items")) {
                        try state.persistent.clearRecentlyOpened();
                    }

                    c.igEndMenu();
                }
                if (c.igMenuItem_Bool("Close", SUPER_KEY_STR ++ " + W", false, true)) {
                    close = true;
                }
                if (c.igMenuItem_Bool("Close All", SUPER_KEY_STR ++ " + SHIFT + W", false, true)) {
                    close_all = true;
                }
                c.igSeparator();

                if (c.igMenuItem_Bool("Exit", null, false, true)) {
                    exit = true;
                }
                c.igEndMenu();
            }
            if (c.igBeginMenu("Example DTBs", true)) {
                displayExampleDtbs("seL4", sel4_example_dtbs, &dtb_to_load);
                displayExampleDtbs("Linux", linux_example_dtbs, &dtb_to_load);
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
            try handleFileDialogue(allocator, &state);
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
            try state.loadPlatform(d);
            state.setPlatform(d);
        }

        if (exit) {
            break;
        }

        if (open_about) {
            c.igOpenPopup_Str("About", 0);
        }

        var p_open = true;
        c.igSetNextWindowPos(state.windowPos(0.5, 0.5), 0, .{ .x = 0.5, .y = 0.5 });
        if (c.igBeginPopupModal("About", &p_open, c.ImGuiWindowFlags_AlwaysAutoResize | c.ImGuiWindowFlags_NoResize | c.ImGuiWindowFlags_NoMove)) {
            c.igText(ABOUT);
            c.igTextLinkOpenURL("Home Page", "https://ivanvelickovic.com/devicetreedetective");
            c.igSameLine(0, -1.0);
            c.igTextLinkOpenURL("Source Code", "https://github.com/Ivan-Velickovic/device_tree_detective");
            c.igSameLine(0, -1.0);
            c.igTextLinkOpenURL("Report Issue", "https://github.com/Ivan-Velickovic/device_tree_detective/issues");
            c.igSeparator();
            c.igText("This program is intended to help people explore and visualise Device Tree Blob files.");
            c.igText("Created by Ivan Velickovic in 2025.");
            c.igEndPopup();
        }

        if (state.getPlatform() != null) {
            var platform = state.getPlatform().?;
            c.igSetNextWindowPos(state.windowPos(0, 0), 0, .{});
            _ = c.igBegin("DTBs", null, c.ImGuiWindowFlags_NoCollapse | c.ImGuiWindowFlags_NoResize);
            c.igSetWindowSize_Vec2(state.windowSize(0.15, 1.0), 0);
            for (state.platforms.items, 0..) |p, i| {
                if (c.igSelectable_Bool(p.path, i == state.platform, 0, .{})) {
                    state.setPlatform(p.path);
                    const window_title = fmt(allocator, "{s} - Device Tree Detective", .{ platform.path });
                    defer allocator.free(window_title);
                    c.glfwSetWindowTitle(window, window_title);
                }
            }
            c.igEnd();

            platform = state.getPlatform().?;

            c.igSetNextWindowPos(state.windowPos(0.15, 0), 0, .{});
            _ = c.igBegin("Tree", null, c.ImGuiWindowFlags_NoCollapse | c.ImGuiWindowFlags_NoResize);
            c.igSetWindowSize_Vec2(state.windowSize(0.35, 1.0), 0);

            const expand_all = c.igButton("Expand All", .{});
            c.igSameLine(0, -1.0);
            const collapse_all = c.igButton("Collapse All", .{});
            var nodes_open: ?bool = null;
            if (expand_all) {
                nodes_open = true;
            }
            if (collapse_all) {
                nodes_open = false;
            }

            const filter = c.ImGuiTextFilter_ImGuiTextFilter(null);
            defer c.ImGuiTextFilter_destroy(filter);

            _ = c.ImGuiTextFilter_Draw(filter, "Search nodes", 0);

            _ = c.igCheckbox("Ignore disabled devices", &filter_ignore_disabled);
            if (c.igIsItemHovered(c.ImGuiHoveredFlags_DelayNormal | c.ImGuiHoveredFlags_NoSharedDelay)) {
                c.igSetTooltip("Do not display any devices with 'status = \"disabled\"'");
            }
            _ = c.igCheckbox("Include properties", &fitler_include_props);
            if (c.igIsItemHovered(c.ImGuiHoveredFlags_DelayNormal | c.ImGuiHoveredFlags_NoSharedDelay)) {
                c.igSetTooltip("Filter based on each node's properties as well as node names");
            }

            state.highlighted_node = try displayTree(allocator, filter, platform.root.children, state.highlighted_node, nodes_open, filter_ignore_disabled, fitler_include_props);

            c.igEnd(); // End filter

            try displaySelectedNode(allocator);

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
                            const isa_filter = c.ImGuiTextFilter_ImGuiTextFilter(null);
                            defer c.ImGuiTextFilter_destroy(isa_filter);
                            _ = c.ImGuiTextFilter_Draw(isa_filter, "Filter Extensions", 200);

                            for (extensions) |extension| {
                                const extension_fmt = blk: {
                                    const maybe_fullname = riscv_isa_extensions.get(extension);
                                    if (maybe_fullname) |fullname| {
                                        break :blk fmt(allocator, "{s} - {s}", .{ extension, fullname });
                                    } else {
                                        break :blk fmt(allocator, "{s}", .{ extension });
                                    }
                                };
                                defer allocator.free(extension_fmt);

                                if (c.ImGuiTextFilter_PassFilter(isa_filter, extension_fmt, null)) {
                                    c.igText(extension_fmt);
                                }
                            }
                            c.igTreePop();
                        }
                    }
                    c.igEndTabItem();
                }
                if (c.igBeginTabItem("Interrupts", null, c.ImGuiTabItemFlags_None)) {
                    if (c.igBeginTabBar("Views", c.ImGuiTabBarFlags_None)) {
                        if (c.igBeginTabItem("List", null, c.ImGuiTabItemFlags_None)) {
                            const irq_filter = c.ImGuiTextFilter_ImGuiTextFilter(null);
                            defer c.ImGuiTextFilter_destroy(irq_filter);

                            _ = c.ImGuiTextFilter_Draw(irq_filter, "interrupts-filter", 0);
                            for (platform.irqs.items) |irq| {
                                const irq_fmt = fmt(allocator, "{d} (0x{x}), {s}", .{ irq.number, irq.number, irq.node.name });
                                defer allocator.free(irq_fmt);
                                if (c.ImGuiTextFilter_PassFilter(irq_filter, irq_fmt, null)) {
                                    c.igText(irq_fmt);
                                }
                            }
                            c.igEndTabItem();
                        }
                        if (c.igBeginTabItem("Canvas?", null, c.ImGuiTabItemFlags_None)) {
                            const canvas_sz = state.windowSize(0.5, 0.5);
                            _ = c.igBeginChild_Str("canvas_child", canvas_sz, c.ImGuiChildFlags_None, c.ImGuiWindowFlags_HorizontalScrollbar);

                            const draw_list = c.igGetWindowDrawList();
                            var canvas_p0: c.ImVec2 = undefined;
                            c.igGetCursorScreenPos(&canvas_p0);

                            const canvas_p1: c.ImVec2 = .{ .x = canvas_p0.x + canvas_sz.x, .y = canvas_p0.y + canvas_sz.y };
                            c.ImDrawList_AddRectFilled(draw_list, canvas_p0, canvas_p1, 0xffaaaaaa, 0, 0);
                            // c.ImDrawList_AddRect(draw_list, canvas_p0, canvas_p1, 0xff000000, 0, 0);

                            c.ImDrawList_PushClipRect(draw_list, canvas_p0, canvas_p1, true);

                            var hovered_any = false;
                            for (platform.irq_controllers.items, 0..) |irq_controller, i| {
                                var name_bytes = std.ArrayList(u8).init(allocator);
                                defer name_bytes.deinit();
                                const name = try dtb.nodeNameFullPath(&name_bytes, irq_controller);
                                var name_size: c.ImVec2 = undefined;
                                c.igCalcTextSize(&name_size, name, null, false, 0.0);

                                const fill: u32 = blk: {
                                    if (hovered_irq_controller_index != null and hovered_irq_controller_index.? == i) {
                                        break :blk Colour.U32(0xdbb13f);
                                    } else {
                                        break :blk 0xffdddddd;
                                    }
                                };

                                const p0: c.ImVec2 = .{ .x = canvas_p0.x + 10, .y = canvas_p0.y + 10 + (75 * @as(f32, @floatFromInt(i))) };
                                const size: c.ImVec2 = .{ .x = @max(130, name_size.x + 20), .y = 50 };
                                const p1: c.ImVec2 = .{ .x = p0.x + size.x, .y = p0.y + size.y };
                                c.igPushStyleVar_Float(c.ImGuiStyleVar_FrameBorderSize, 1.0);
                                // c.ImDrawList_AddRectFilled(draw_list, p0, p1, fill, 0, 0);
                                c.igRenderFrame(p0, p1, fill, true, 0);
                                c.igPopStyleVar(1);

                                if (c.igIsMouseHoveringRect(p0, p1, false)) {
                                    state.highlighted_node = irq_controller;
                                    hovered_irq_controller_index = i;
                                    hovered_any = true;
                                }

                                {
                                    const text_start_x = p0.x + (size.x / 2) - (name_size.x / 2);
                                    const text_start_y = p0.y + (size.y / 2) - (name_size.y / 2);
                                    c.ImDrawList_AddText_Vec2(draw_list, .{ .x = text_start_x, .y = text_start_y }, 0xff000000, name, null);
                                }

                                var num_lines: usize = 0;
                                for (platform.irqs.items) |irq| {
                                    if (irq.node.interruptParent() == irq_controller) {
                                        num_lines += 1;
                                    }
                                }

                                const irq_size: c.ImVec2 = .{ .x = 250, .y = 30 };
                                const irq_spacing: f32 = 10;
                                const irq_diff_y = irq_size.y + irq_spacing;
                                // Get the middle, and then subtract half of the total space of all the lines
                                const irq_x = p0.x + (size.x / 2);
                                const irq_y = (p1.y + 30);

                                var curr_irq: usize = 0;
                                const border_size = 1.0;
                                for (platform.irqs.items, 0..) |irq, j| {
                                    if (irq.node.interruptParent() == irq_controller) {
                                        const irq_start: c.ImVec2 = .{ .x = irq_x + 20 , .y = irq_y + @as(f32, @floatFromInt(curr_irq)) * irq_diff_y };
                                        const irq_end: c.ImVec2 = .{ .x = irq_start.x + irq_size.x, .y = irq_start.y + irq_size.y };

                                        const hovered = hovered_irq_node_index != null and hovered_irq_node_index.? == j;
                                        const irq_fill: u32 = if (hovered) Colour.U32(0xdbb13f) else 0xffdddddd;
                                        const line_fill_horizontal: u32 = if (hovered) Colour.U32(0xdbb13f) else 0xff000000;
                                        const line_fill_vertical = blk: {
                                            if (hovered_irq_node_index != null and hovered_irq_node_index.? >= j) {
                                                break :blk Colour.U32(0xdbb13f);
                                            } else {
                                                break :blk 0xff000000;
                                            }
                                        };

                                        c.igPushStyleVar_Float(c.ImGuiStyleVar_FrameBorderSize, border_size);
                                        c.igRenderFrame(irq_start, irq_end, irq_fill, true, 0);
                                        c.igPopStyleVar(1);

                                        if (c.igIsMouseHoveringRect(irq_start, irq_end, false)) {
                                            state.highlighted_node = irq.node;
                                            hovered_irq_node_index = j;
                                            hovered_any = true;
                                        }

                                        const irq_fmt = fmt(allocator, "{} (0x{x}) - {s}", .{ irq.number, irq.number, irq.node.name });
                                        defer allocator.free(irq_fmt);
                                        c.ImDrawList_AddText_Vec2(draw_list, imgui.centerText(irq_fmt, irq_start, irq_size), 0xff000000, irq_fmt, null);

                                        curr_irq += 1;

                                        const line_width = 2;

                                        const vertical_start: c.ImVec2 = .{ .x = irq_start.x - 20, .y = irq_start.y - irq_diff_y / 2.0 - line_width / 2.0 };
                                        const vertical_end: c.ImVec2 = .{ .x = irq_start.x - 20, .y = irq_start.y + irq_diff_y / 2.0 + line_width / 2.0 };
                                        c.ImDrawList_AddLine(
                                            draw_list,
                                            vertical_start,
                                            vertical_end,
                                            line_fill_vertical,
                                            line_width,
                                        );
                                        std.log.info("{} vertical {d} {d} - {d} {d}", .{ curr_irq, vertical_start.x, vertical_start.y, vertical_end.x, vertical_end.y });

                                        c.ImDrawList_AddLine(
                                            draw_list,
                                            .{ .x = irq_start.x - 20 + line_width / 2.0, .y = irq_start.y + (irq_size.y / 2.0) },
                                            .{ .x = irq_start.x - border_size, .y = irq_start.y + (irq_size.y / 2.0) },
                                            line_fill_horizontal,
                                            line_width,
                                        );
                                    }
                                }

                                // if (curr_irq > 0) {
                                //     c.ImDrawList_AddLine(
                                //         draw_list,
                                //         .{ .x = irq_x, .y = p1.y },
                                //         .{ .x = irq_x, .y = irq_y + irq_diff_y * ((@as(f32, @floatFromInt(curr_irq)) - 0.5)) + 1 },
                                //         0xff000000,
                                //         2
                                //     );
                                // }
                            }

                            if (!hovered_any) {
                                hovered_irq_controller_index = null;
                                hovered_irq_node_index = null;
                            }

                            c.ImDrawList_PopClipRect(draw_list);

                            c.igEndChild();

                            c.igEndTabItem();
                        }
                        c.igEndTabBar();
                    }
                    c.igEndTabItem();
                }
                if (c.igBeginTabItem("Memory", null, c.ImGuiTabItemFlags_None)) {
                    if (c.igBeginTabBar("Views", c.ImGuiTabBarFlags_None)) {
                        if (c.igBeginTabItem("Regions", null, c.ImGuiTabItemFlags_None)) {
                            for (platform.regions.items) |reg| {
                                const reg_fmt = fmt(allocator, "[0x{x:0>12}..0x{x:0>12}], {s}", .{ reg.addr, reg.addr + reg.size, reg.node.name });
                                defer allocator.free(reg_fmt);
                                c.igText(reg_fmt);
                            }
                            c.igEndTabItem();
                        }
                        if (c.igBeginTabItem("Map", null, c.ImGuiTabItemFlags_None)) {
                            const canvas_sz = state.windowSize(0.5, 1.0);
                            _ = c.igBeginChild_Str("memory_map_child", canvas_sz, c.ImGuiChildFlags_None, c.ImGuiWindowFlags_HorizontalScrollbar);

                            const draw_list = c.igGetWindowDrawList();
                            var canvas_p0: c.ImVec2 = undefined;
                            c.igGetCursorScreenPos(&canvas_p0);

                            const canvas_p1: c.ImVec2 = .{ .x = canvas_p0.x + canvas_sz.x, .y = canvas_p0.y + canvas_sz.y };
                            c.ImDrawList_AddRectFilled(draw_list, canvas_p0, canvas_p1, 0xffaaaaaa, 0, 0);

                            // c.ImDrawList_PushClipRect(draw_list, canvas_p0, canvas_p1, true);

                            var drawed_regs: usize = 0;
                            var hovered_any = false;
                            for (platform.regions.items, 0..) |reg, i| {
                                if (reg.addr == 0 or reg.size == 0) {
                                    continue;
                                }

                                const text = fmt(allocator, "{s}", .{ reg.node.name });
                                defer allocator.free(text);
                                var text_size: c.ImVec2 = undefined;
                                c.igCalcTextSize(&text_size, text, null, false, 0.0);

                                const box_size: c.ImVec2 = .{ .x = @max(150, text_size.x + 20), .y = 50 };
                                const box_start: c.ImVec2 = .{ .x = canvas_p0.x + 20, .y = canvas_p0.y + 20 + box_size.y * @as(f32, @floatFromInt(drawed_regs)) };
                                const box_end: c.ImVec2 = .{ .x = box_start.x + box_size.x, .y = box_start.y + box_size.y };
                                const fill: u32 = blk: {
                                    if (hovered_reg_box_index != null and hovered_reg_box_index.? == i) {
                                        break :blk Colour.U32(0xdbb13f);
                                    } else if (drawed_regs % 2 == 0) {
                                        break :blk 0xffdddddd;
                                    } else {
                                        break :blk 0xffeeeeee;
                                    }
                                };
                                c.ImDrawList_AddRectFilled(draw_list, box_start, box_end, fill, 0, 0);

                                c.ImDrawList_AddText_Vec2(draw_list, imgui.centerText(text, box_start, box_size), 0xff000000, text, null);

                                if (c.igIsMouseHoveringRect(box_start, box_end, false)) {
                                    state.highlighted_node = reg.node;
                                    hovered_reg_box_index = i;
                                    hovered_any = true;
                                }

                                drawed_regs += 1;
                            }

                            if (!hovered_any) {
                                hovered_reg_box_index = null;
                            }

                            // c.ImDrawList_PopClipRect(draw_list);
                            c.igEndChild();
                            c.igEndTabItem();
                        }
                        c.igEndTabBar();
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
                try handleFileDialogue(allocator, &state);
            }

            c.igText("Recently opened");
            if (imgui.secondaryButton("Clear items")) {
                try state.persistent.clearRecentlyOpened();
            }
            var selected_item: ?usize = null;
            if (c.igBeginTable("##recent-dtbs", 1, 0, .{}, 0.0)) {
                const timestamp = std.time.timestamp();
                for (state.persistent.recently_opened.items, 0..) |entry, i| {
                    c.igTableNextRow(0, 0);
                    const colour: u24 = if (i % 2 != 0) 0xBCA275 else 0xA38B61;
                    c.igTableSetBgColor(c.ImGuiTableBgTarget_RowBg0 + 1, Colour.U32(colour), -1);
                    _ = c.igTableSetColumnIndex(0);
                    const is_selected = selected_item != null and selected_item.? == i;
                    const flags = if (is_selected) c.ImGuiSelectableFlags_Highlight else c.ImGuiSelectableFlags_None;

                    const timestamp_fmt = humanTimestampDiff(allocator, entry.last_opened, timestamp);
                    defer allocator.free(timestamp_fmt);

                    const entry_fmt = fmt(allocator, "{s} ({s})", .{ entry.path, timestamp_fmt });
                    defer allocator.free(entry_fmt);

                    if (c.igSelectable_Bool(entry_fmt, is_selected, flags, .{})) {
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
                const item: [:0]const u8 = state.persistent.recently_opened.items[i].path;
                try state.loadPlatform(item);
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
