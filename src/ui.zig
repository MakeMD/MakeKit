//! Small reusable widgets: tri-state checkbox, modal message box, progress strip, icon buttons.
const std = @import("std");
const im = @import("im");
const app = @import("app.zig");

/// Segoe Fluent Icons / Segoe MDL2 Assets code points (same in both fonts).
pub const icons = struct {
    pub const menu: u21 = 0xE700;
    pub const add: u21 = 0xE710;
    pub const cancel: u21 = 0xE711;
    pub const more: u21 = 0xE712;
    pub const settings: u21 = 0xE713;
    pub const search: u21 = 0xE721;
    pub const forward: u21 = 0xE72A;
    pub const back: u21 = 0xE72B;
    pub const refresh: u21 = 0xE72C;
    pub const check: u21 = 0xE73E;
    pub const up: u21 = 0xE74A;
    pub const delete: u21 = 0xE74D;
    pub const save: u21 = 0xE74E;
    pub const warning: u21 = 0xE7BA;
    pub const download: u21 = 0xE896;
    pub const upload: u21 = 0xE898;
    pub const document: u21 = 0xE8A5;
    pub const folder: u21 = 0xE8B7;
    pub const copy: u21 = 0xE8C8;
    pub const open_file: u21 = 0xE8E5;
    pub const info: u21 = 0xE946;
    pub const question: u21 = 0xE9CE;
    pub const err: u21 = 0xEA39;
};

/// UTF-8 bytes of an icon glyph, NUL-terminated (for embedding in labels/text).
pub fn glyph(cp: u21) [4:0]u8 {
    var out: [4:0]u8 = @splat(0);
    _ = std.unicode.utf8Encode(cp, &out) catch {};
    return out;
}

// ---------------------------------------------------------------- tri-state checkbox

pub const Tri = enum { off, on, mixed };

/// Checkbox with an indeterminate ("mixed") state. Clicking mixed/off -> on, on -> off.
/// Returns true when the user changed it.
pub fn triCheckbox(label: [*:0]const u8, state: *Tri) bool {
    var b = state.* == .on;
    const mixed = state.* == .mixed;
    if (mixed) im.ImGui_PushItemFlag(im.ImGuiItemFlags_MixedValue, true);
    // Box size = frame height; use a compact vertical padding so it is ~20 px, not button-tall.
    const pad = im.ImGui_GetStyle().*.FramePadding;
    im.ImGui_PushStyleVarImVec2(im.ImGuiStyleVar_FramePadding, .{ .x = pad.x, .y = @max(1, pad.y * 0.35) });
    const changed = im.ImGui_Checkbox(label, &b);
    im.ImGui_PopStyleVar();
    if (mixed) im.ImGui_PopItemFlag();
    if (changed) state.* = if (b) .on else .off;
    return changed;
}

// ---------------------------------------------------------------- modal message box

pub const MsgKind = enum { info, warning, err, question };

/// Opens the message box `id` (call once, e.g. on a button press; not every frame).
pub fn openMessage(id: [*:0]const u8) void {
    _ = im.ImGui_OpenPopup(id, 0);
}

/// Draws the modal `id` if it is open. Returns the index of the clicked button once
/// (Enter = button 0, Esc = last button), null otherwise. `id` is the window title
/// ("Delete files?##confirm"). `buttons` are labels ("Delete", "Cancel").
pub fn messageBox(id: [*:0]const u8, kind: MsgKind, text: []const u8, buttons: []const [*:0]const u8) ?usize {
    const s = if (app.current()) |a| a.scale() else 1.0;
    const vp = im.ImGui_GetMainViewport();
    im.ImGui_SetNextWindowPosEx(im.ImGuiViewport_GetCenter(vp), im.ImGuiCond_Appearing, .{ .x = 0.5, .y = 0.5 });
    im.ImGui_SetNextWindowSizeConstraints(.{ .x = 340 * s, .y = 0 }, .{ .x = 640 * s, .y = 10000 }, null, null);
    if (!im.ImGui_BeginPopupModal(id, null, im.ImGuiWindowFlags_AlwaysAutoResize | im.ImGuiWindowFlags_NoSavedSettings)) return null;
    defer im.ImGui_EndPopup();

    const pal = if (app.current()) |a| a.cfg.palette else app.palettes.cleaner;
    const icon: u21, const col: u32 = switch (kind) {
        .info => .{ icons.info, pal.accent },
        .warning => .{ icons.warning, 0xC77700 },
        .err => .{ icons.err, pal.danger },
        .question => .{ icons.question, pal.accent },
    };
    const g = glyph(icon);
    im.ImGui_PushFontFloat(null, im.ImGui_GetStyle().*.FontSizeBase * 1.75);
    im.ImGui_PushStyleColorImVec4(im.ImGuiCol_Text, app.color(col, 1));
    im.ImGui_TextUnformatted(&g);
    im.ImGui_PopStyleColor();
    im.ImGui_PopFont();
    im.ImGui_SameLineEx(0, 14 * s);
    im.ImGui_PushTextWrapPos(im.ImGui_GetCursorPosX() + 480 * s);
    im.ImGui_TextUnformattedEx(text.ptr, text.ptr + text.len);
    im.ImGui_PopTextWrapPos();
    im.ImGui_Dummy(.{ .x = 0, .y = 6 * s });

    // Right-aligned button row.
    const style = im.ImGui_GetStyle();
    const min_w = 88 * s;
    var row_w: f32 = 0;
    for (buttons) |b| row_w += @max(min_w, im.ImGui_CalcTextSize(b).x + style.*.FramePadding.x * 2) + style.*.ItemSpacing.x;
    row_w -= style.*.ItemSpacing.x;
    const avail = im.ImGui_GetContentRegionAvail().x;
    if (avail > row_w) im.ImGui_SetCursorPosX(im.ImGui_GetCursorPosX() + avail - row_w);
    var result: ?usize = null;
    for (buttons, 0..) |b, i| {
        if (i > 0) im.ImGui_SameLine();
        if (im.ImGui_ButtonEx(b, .{ .x = @max(min_w, im.ImGui_CalcTextSize(b).x + style.*.FramePadding.x * 2), .y = 0 })) result = i;
        if (i == 0) im.ImGui_SetItemDefaultFocus();
    }
    if (result == null and buttons.len > 0 and !im.ImGui_IsWindowAppearing()) {
        if (im.ImGui_IsKeyPressed(im.ImGuiKey_Enter) or im.ImGui_IsKeyPressed(im.ImGuiKey_KeypadEnter)) result = 0;
        if (im.ImGui_IsKeyPressed(im.ImGuiKey_Escape)) result = buttons.len - 1;
    }
    if (result != null) im.ImGui_CloseCurrentPopup();
    return result;
}

// ---------------------------------------------------------------- progress strip

/// Status line, then [bar] "NN% (x of y)" [Cancel]. `total == 0` draws an indeterminate bar
/// (call `app.animate(true)` while it is shown). Returns true when Cancel was clicked.
/// The Cancel button label is "Cancel##<id>" (for automation: `click Cancel##<id>`).
pub fn progressStrip(id: []const u8, status: []const u8, done: u64, total: u64, can_cancel: bool) bool {
    var buf: [128]u8 = undefined;
    im.ImGui_TextUnformattedEx(status.ptr, status.ptr + status.len);
    const pct: u64 = if (total == 0) 0 else @min(100, done * 100 / total);
    const label = (if (total == 0)
        std.mem.printSentinel(&buf, "{d}", .{done}, 0)
    else
        std.mem.printSentinel(&buf, "{d}% ({d} of {d})", .{ pct, done, total }, 0)) catch return false;
    const style = im.ImGui_GetStyle();
    var cancel_buf: [96]u8 = undefined;
    const cancel_label = std.mem.printSentinel(&cancel_buf, "Cancel##{s}", .{id}, 0) catch return false;
    const label_w = im.ImGui_CalcTextSize(label.ptr).x;
    const cancel_w = if (can_cancel) im.ImGui_CalcTextSize("Cancel").x + style.*.FramePadding.x * 2 + style.*.ItemSpacing.x else 0;
    const bar_w = @max(40, im.ImGui_GetContentRegionAvail().x - label_w - style.*.ItemSpacing.x - cancel_w);
    const frac: f32 = if (total == 0) @floatCast(-im.ImGui_GetTime()) else @as(f32, @floatFromInt(done)) / @as(f32, @floatFromInt(total));
    im.ImGui_ProgressBar(frac, .{ .x = bar_w, .y = 0 }, "");
    im.ImGui_SameLine();
    im.ImGui_AlignTextToFramePadding();
    im.ImGui_TextUnformatted(label.ptr);
    if (!can_cancel) return false;
    im.ImGui_SameLine();
    return im.ImGui_Button(cancel_label.ptr);
}

// ---------------------------------------------------------------- icon buttons

/// Button showing an icon glyph followed by `label` ("Open...##open"); a label starting with
/// "##" gives an icon-only button. Optional tooltip on hover.
pub fn iconButton(icon: u21, label: []const u8, tooltip: ?[*:0]const u8) bool {
    var buf: [256]u8 = undefined;
    const g = glyph(icon);
    const gs = std.mem.sliceTo(&g, 0);
    const text = (if (label.len == 0 or std.mem.startsWith(u8, label, "##"))
        std.mem.printSentinel(&buf, "{s}{s}", .{ gs, label }, 0)
    else
        std.mem.printSentinel(&buf, "{s}  {s}", .{ gs, label }, 0)) catch return false;
    const pressed = im.ImGui_Button(text.ptr);
    if (tooltip) |t| if (im.ImGui_IsItemHovered(im.ImGuiHoveredFlags_ForTooltip)) im.ImGui_SetTooltip("%s", t);
    return pressed;
}

test "glyph encodes PUA code points" {
    const g = glyph(icons.delete);
    try std.testing.expectEqualSlices(u8, "\u{E74D}", std.mem.sliceTo(&g, 0));
}
