/*
 * All our interaction with Dear ImGui is done via cimgui which
 * Zig auto-translates for us to use. However, there are certain edge
 * cases where we need to make our own C wrappers, this is what this file
 * is for.
 */

#define CIMGUI_DEFINE_ENUMS_AND_STRUCTS

#include <cimgui.h>
#include <cimgui_impl.h>

/* ImGuiWindow is opaque when translated to Zig so we have this wrapper. */
float igExtern_MainMenuBarHeight(ImGuiWindow *window);
