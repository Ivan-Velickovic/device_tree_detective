#define CIMGUI_DEFINE_ENUMS_AND_STRUCTS

#include <cimgui.h>
#include <cimgui_impl.h>

/* ImGuiWindow is opaque when translated to Zig so we have this wrapper. */
float igExtern_MainMenuBarHeight(ImGuiWindow *window);
