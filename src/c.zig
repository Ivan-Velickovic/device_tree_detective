const builtin = @import("builtin");
pub const c = @cImport({
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
    if (builtin.os.tag == .windows) {
        @cInclude("windows_dialog.h");
    }
});
