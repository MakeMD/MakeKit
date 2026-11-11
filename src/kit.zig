//! MakeKit: shared foundation for MakeCleaner / MakePack (Zig 0.17 + Dear ImGui 1.93 docking,
//! Win32 + DX11). See docs/ZIG-0.17-NOTES.md.
pub const im = @import("im"); // dear_bindings C API: ImGui_Button, ImGuiIO_AddKeyEvent, ImGuiCol_Text, ...
pub const w = @import("w"); // translated windows.h & co; COM: p.*.lpVtbl.*.Method.?(p, ...)
pub const app = @import("app.zig");
pub const ui = @import("ui.zig");
pub const icons = @import("icons.zig"); // Carbon Mint icon set: icons.get(.delete, 24)
pub const win = @import("win.zig");
pub const jobs = @import("jobs.zig");
pub const automation = @import("automation.zig");

test {
    _ = win;
    _ = jobs;
    _ = ui;
    _ = app;
    _ = automation;
    _ = icons;
}
