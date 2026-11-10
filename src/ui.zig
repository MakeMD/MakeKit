//! Small reusable widgets: compact / tri-state checkbox, automation-readable text, modal message box,
//! progress strip, icon buttons.
const std = @import("std");
const im = @import("im");
const app = @import("app.zig");
const automation = @import("automation.zig");

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

// ---------------------------------------------------------------- checkboxes

/// ImGui checkbox with a compact box (~20 px, not button-tall). Returns true when the user changed it.
pub fn checkbox(label: [*:0]const u8, v: *bool) bool {
    const pad = im.ImGui_GetStyle().*.FramePadding;
    im.ImGui_PushStyleVarImVec2(im.ImGuiStyleVar_FramePadding, .{ .x = pad.x, .y = @max(1, pad.y * 0.35) });
    defer im.ImGui_PopStyleVar();
    return im.ImGui_Checkbox(label, v);
}

pub const Tri = enum { off, on, mixed };

/// `checkbox` with an indeterminate ("mixed", automation item `mixed: true`) state. Clicking mixed/off -> on,
/// on -> off. Returns true when the user changed it.
pub fn triCheckbox(label: [*:0]const u8, state: *Tri) bool {
    var b = state.* == .on;
    const mixed = state.* == .mixed;
    if (mixed) im.ImGui_PushItemFlag(im.ImGuiItemFlags_MixedValue, true);
    const changed = checkbox(label, &b);
    if (mixed) im.ImGui_PopItemFlag();
    if (changed) state.* = if (b) .on else .off;
    return changed;
}

// ---------------------------------------------------------------- automation-readable text

/// TextUnformatted that automation can read: item "<text>##<id>" with `value` = the full text (plain text
/// is no item). `color` 0xRRGGBB (null = theme text); `wrap_w` > 0 wraps at that many px.
pub fn text(id: []const u8, s: []const u8, color: ?u32, wrap_w: f32) void {
    if (color) |c| im.ImGui_PushStyleColorImVec4(im.ImGuiCol_Text, app.color(c, 1));
    if (wrap_w > 0) im.ImGui_PushTextWrapPos(im.ImGui_GetCursorPosX() + wrap_w);
    im.ImGui_TextUnformattedEx(s.ptr, s.ptr + s.len);
    if (wrap_w > 0) im.ImGui_PopTextWrapPos();
    if (color != null) im.ImGui_PopStyleColor();
    if (!automation.active) return;
    var buf: [512]u8 = undefined;
    // ponytail: a long text is cut in the label (at a UTF-8 boundary); `value` keeps all of it
    var n = @min(s.len, buf.len -| (id.len + 3));
    while (n > 0 and n < s.len and s[n] & 0xC0 == 0x80) n -= 1;
    const label = std.mem.printSentinel(&buf, "{s}##{s}", .{ s[0..n], id }, 0) catch return; // id > 500 bytes
    automation.tagLastItem(label.ptr, s);
}

// ---------------------------------------------------------------- modal message box

pub const MsgKind = enum { info, warning, err, question };

pub const MsgOptions = struct {
    /// Text wrap width in logical px (the box grows to fit it).
    width: f32 = 480,
};

/// Opens the message box `id` (call once, e.g. on a button press; not every frame).
pub fn openMessage(id: [*:0]const u8) void {
    _ = im.ImGui_OpenPopup(id, 0);
}

/// Draws the modal `id` if it is open. Returns the index of the clicked button once
/// (Enter = button 0, Esc = last button), null otherwise. `id` is the window title
/// ("Delete files?##confirm"). `buttons` are labels ("Delete", "Cancel").
/// Automation: text `<text>##msgText`, buttons `<label>##msgButton<i>`.
pub fn messageBox(id: [*:0]const u8, kind: MsgKind, msg: []const u8, buttons: []const [*:0]const u8) ?usize {
    return messageBoxEx(id, kind, msg, buttons, .{});
}

pub fn messageBoxEx(id: [*:0]const u8, kind: MsgKind, msg: []const u8, buttons: []const [*:0]const u8, opt: MsgOptions) ?usize {
    const s = if (app.current()) |a| a.scale() else 1.0;
    const vp = im.ImGui_GetMainViewport();
    im.ImGui_SetNextWindowPosEx(im.ImGuiViewport_GetCenter(vp), im.ImGuiCond_Appearing, .{ .x = 0.5, .y = 0.5 });
    im.ImGui_SetNextWindowSizeConstraints(.{ .x = 340 * s, .y = 0 }, .{ .x = (opt.width + 160) * s, .y = 10000 }, null, null);
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
    text("msgText", msg, null, opt.width * s);
    im.ImGui_Dummy(.{ .x = 0, .y = 6 * s });

    // Right-aligned button row.
    const style = im.ImGui_GetStyle();
    const min_w = 88 * s;
    var row_w: f32 = 0;
    for (buttons) |b| row_w += buttonWidth(b, min_w) + style.*.ItemSpacing.x;
    row_w -= style.*.ItemSpacing.x;
    const avail = im.ImGui_GetContentRegionAvail().x;
    if (avail > row_w) im.ImGui_SetCursorPosX(im.ImGui_GetCursorPosX() + avail - row_w);
    var result: ?usize = null;
    for (buttons, 0..) |b, i| {
        if (i > 0) im.ImGui_SameLine();
        var lb: [256]u8 = undefined;
        const label = std.mem.printSentinel(&lb, "{s}##msgButton{d}", .{ std.mem.span(b), i }, 0) catch std.mem.span(b);
        if (im.ImGui_ButtonEx(label.ptr, .{ .x = buttonWidth(b, min_w), .y = 0 })) result = i;
        if (i == 0) im.ImGui_SetItemDefaultFocus();
    }
    if (result == null and buttons.len > 0 and !im.ImGui_IsWindowAppearing()) {
        if (im.ImGui_IsKeyPressed(im.ImGuiKey_Enter) or im.ImGui_IsKeyPressed(im.ImGuiKey_KeypadEnter)) result = 0;
        if (im.ImGui_IsKeyPressed(im.ImGuiKey_Escape)) result = buttons.len - 1;
    }
    if (result != null) im.ImGui_CloseCurrentPopup();
    return result;
}

fn buttonWidth(label: [*:0]const u8, min_w: f32) f32 {
    return @max(min_w, im.ImGui_CalcTextSizeEx(label, null, true, -1).x + im.ImGui_GetStyle().*.FramePadding.x * 2);
}

// ---------------------------------------------------------------- progress strip

/// Status line, then [bar] "NN% (x of y)" [Cancel]. `total == 0` draws an indeterminate bar
/// (call `app.animate(true)` while it is shown). Returns true when Cancel was clicked.
/// Automation: `<status>##status`, `<NN% (x of y)>##percent`, `Cancel##cancel` (ImGui ids scoped by `id`).
pub fn progressStrip(id: []const u8, status: []const u8, done: u64, total: u64, can_cancel: bool) bool {
    im.ImGui_PushIDStr(id.ptr, id.ptr + id.len);
    defer im.ImGui_PopID();
    var buf: [128]u8 = undefined;
    text("status", status, null, 0);
    const pct: u64 = if (total == 0) 0 else @min(100, done * 100 / total);
    const label = (if (total == 0)
        std.mem.print(&buf, "{d}", .{done})
    else
        std.mem.print(&buf, "{d}% ({d} of {d})", .{ pct, done, total })) catch return false;
    const style = im.ImGui_GetStyle();
    const label_w = im.ImGui_CalcTextSizeEx(label.ptr, label.ptr + label.len, false, -1).x;
    const cancel_w = if (can_cancel) im.ImGui_CalcTextSize("Cancel").x + style.*.FramePadding.x * 2 + style.*.ItemSpacing.x else 0;
    const bar_w = @max(40, im.ImGui_GetContentRegionAvail().x - label_w - style.*.ItemSpacing.x - cancel_w);
    const frac: f32 = if (total == 0) @floatCast(-im.ImGui_GetTime()) else @as(f32, @floatFromInt(done)) / @as(f32, @floatFromInt(total));
    im.ImGui_ProgressBar(frac, .{ .x = bar_w, .y = 0 }, "");
    im.ImGui_SameLine();
    im.ImGui_AlignTextToFramePadding();
    text("percent", label, null, 0);
    if (!can_cancel) return false;
    im.ImGui_SameLine();
    return im.ImGui_Button("Cancel##cancel");
}

// ---------------------------------------------------------------- icon buttons

/// Button showing an icon glyph followed by `label` ("Open...##open"); a label starting with
/// "##" gives an icon-only button. Optional tooltip on hover.
pub fn iconButton(icon: u21, label: []const u8, tooltip: ?[*:0]const u8) bool {
    var buf: [256]u8 = undefined;
    const g = glyph(icon);
    const gs = std.mem.sliceTo(&g, 0);
    const lbl = (if (label.len == 0 or std.mem.startsWith(u8, label, "##"))
        std.mem.printSentinel(&buf, "{s}{s}", .{ gs, label }, 0)
    else
        std.mem.printSentinel(&buf, "{s}  {s}", .{ gs, label }, 0)) catch return false;
    const pressed = im.ImGui_Button(lbl.ptr);
    if (tooltip) |t| if (im.ImGui_IsItemHovered(im.ImGuiHoveredFlags_ForTooltip)) im.ImGui_SetTooltip("%s", t);
    return pressed;
}

test "glyph encodes PUA code points" {
    const g = glyph(icons.delete);
    try std.testing.expectEqualSlices(u8, "\u{E74D}", std.mem.sliceTo(&g, 0));
}
