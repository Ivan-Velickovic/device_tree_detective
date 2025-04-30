/// We use cimgui, so we have no native Zig bindings. This is fine
/// 99% of the time and honestly not that big of a deal. For some things
/// it's convenient to have abstract it in Zig (e.g custom buttons that appear
/// multiple times or style changes).
const std = @import("std");
const c = @import("c.zig").c;

pub const GLOBAL_COLOURS = .{
    .{ .child_bg, 0x999999 },
    .{ .popup_bg, 0xcccccc },
    .{ .window_bg, 0xc0c0c0 },
    .{ .text, 0x000000 },
    .{ .title_bg, 0x999999 },
    .{ .title_bg_active, 0x999999 },
    .{ .menu_bar_bg, 0xffffff },
    .{ .button, 0xba8120 },
    .{ .button_hovered, 0xcf8c19 },
    .{ .tab, 0xa6731c },
    .{ .tab_selected, 0xc98a1c },
    .{ .tab_hovered, 0xcf8c19 },
    .{ .header_hovered, 0xc98a1c },
    .{ .check_mark, 0xba8120 },
    .{ .frame_bg_hovered, 0xd1a65e },
    .{ .header , 0xd1a65e },
};

/// Note that this must match to cimgui.h definition of ImGuiCol_.
/// I could have just used the C bindings but for convenience I made the
/// colours into a Zig enum.
pub const Colour = enum(usize) {
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
            .w = 1,
        };
    }

    pub fn push(colour: Colour, comptime hex: u24) void {
        c.igPushStyleColor_Vec4(@intCast(@intFromEnum(colour)), Colour.toVec(hex));
    }

    pub fn pop(count: c_int) void {
        c.igPopStyleColor(count);
    }

    pub fn setStyle(colour: Colour, comptime hex: u24) void {
        c.igGetStyle().*.Colors[@intFromEnum(colour)] = toVec(hex);
    }
};

comptime {
    std.debug.assert(@typeInfo(Colour).@"enum".fields.len == c.ImGuiCol_COUNT);
}

pub fn secondaryButton(text: [:0]const u8) bool {
    Colour.button.push(0xdddddd);
    defer Colour.pop(1);

    return c.igSmallButton(text);
}
