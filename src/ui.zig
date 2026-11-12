//! Small reusable widgets: compact / tri-state checkbox, automation-readable text, modal message box,
//! progress strip, icons (kit.icons set), icon / primary buttons.
const std = @import("std");
const im = @import("im");
const app = @import("app.zig");
const automation = @import("automation.zig");
const icons_png = @import("icons.zig");
const i18n = @import("i18n.zig");

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

/// = `im.ImGui_Checkbox`, which the kit already makes compact (box = font size, centred on a frame-high
/// line: see src/c/im.h). Returns true when the user changed it.
pub fn checkbox(label: [*:0]const u8, v: *bool) bool {
    return im.ImGui_Checkbox(label, v);
}

pub const Tri = enum { off, on, mixed };

/// `checkbox` with an indeterminate ("mixed", automation item `mixed: true`) state. Clicking mixed/off -> on,
/// on -> off. Returns true when the user changed it.
pub fn triCheckbox(label: [*:0]const u8, state: *Tri) bool {
    var b = state.* == .on;
    const mixed = state.* == .mixed;
    if (mixed) {
        im.ImGui_PushItemFlag(im.ImGuiItemFlags_MixedValue, true);
        im.ImGui_PushStyleColorImVec4(im.ImGuiCol_CheckMark, .{ .x = 0, .y = 0, .z = 0, .w = 0 }); // ImGui's square reads as a dot
    }
    const changed = checkbox(label, &b);
    if (mixed) {
        im.ImGui_PopStyleColor();
        im.ImGui_PopItemFlag();
        // "partial" = a dash across the box (the box is a square of the item's height at its left edge)
        const r0 = im.ImGui_GetItemRectMin();
        const side = im.ImGui_GetItemRectMax().y - r0.y;
        const t = @max(2, @round(side * 0.14));
        const y = @round(r0.y + (side - t) / 2);
        im.ImDrawList_AddRectFilled(im.ImGui_GetWindowDrawList(), .{ .x = @round(r0.x + side * 0.25), .y = y }, .{ .x = @round(r0.x + side * 0.75), .y = y + t }, im.ImGui_GetColorU32(im.ImGuiCol_CheckMark));
    }
    if (changed) state.* = if (b) .on else .off;
    return changed;
}

/// Right after `checkbox` / `triCheckbox` (whose label is drawn cut with "..." when wider than the window):
/// on hover, a tooltip with the whole visible label if it was cut, then `extra` (e.g. a warning; null = none).
pub fn checkboxTooltip(label: [*:0]const u8, extra: ?[]const u8) void {
    const cut = im.mkui_LabelCut();
    if (!cut and extra == null) return;
    if (!im.ImGui_IsItemHovered(im.ImGuiHoveredFlags_ForTooltip) or !im.ImGui_BeginTooltip()) return;
    defer im.ImGui_EndTooltip();
    if (cut) {
        const l = std.mem.span(label);
        const shown = l[0 .. std.mem.find(u8, l, "##") orelse l.len];
        im.ImGui_TextUnformattedEx(shown.ptr, shown.ptr + shown.len);
    }
    if (extra) |e| {
        if (cut) im.ImGui_Separator();
        im.ImGui_TextUnformattedEx(e.ptr, e.ptr + e.len);
    }
}

// ---------------------------------------------------------------- drop arrow

/// The kit combo's chevron as a narrow frame-coloured button (`dropArrowWidth()` x frame height) for a
/// custom drop-down: after `SameLineEx(0, 0)` right of an input box it joins the box (one frame). `open` =
/// your popup is open (chevron up). Returns true when clicked. NoPreview combos draw the same.
pub fn dropArrow(label: [*:0]const u8, open: bool) bool {
    return im.mkui_DropArrow(label, open);
}

/// Width of `dropArrow` / the chevron zone of a combo (font size + FramePadding.x: 22 px at 96 DPI).
pub fn dropArrowWidth() f32 {
    return im.ImGui_GetFontSize() + im.ImGui_GetStyle().*.FramePadding.x;
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

/// `danger` = a destructive confirm ("Delete 3 files?"): danger icon and a danger-filled button 0.
pub const MsgKind = enum { info, warning, err, question, danger };

/// The picture of a message kind: info/question = info, warning = warning, err/danger = danger (red triangle).
pub fn msgIcon(kind: MsgKind) icons_png.Name {
    return switch (kind) {
        .info, .question => .info,
        .warning => .warning,
        .err, .danger => .danger,
    };
}

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

    icon(msgIcon(kind), 32);
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
        const size: im.ImVec2 = .{ .x = buttonWidth(b, min_w), .y = 0 };
        const clicked = if (i > 0) im.ImGui_ButtonEx(label.ptr, size) else if (kind == .danger) dangerButtonEx(label.ptr, size) else primaryButtonEx(label.ptr, size);
        if (clicked) result = i;
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

/// The words of `progressStrip`; a translated app passes its own to `progressStripEx`.
pub const ProgressLabels = struct {
    cancel: []const u8 = "Cancel",
    /// {0} = percent, {1} = done, {2} = total.
    count: []const u8 = "{0}% ({1} of {2})",
};

/// Status line, then [bar] "NN% (x of y)" [Cancel]. `total == 0` draws an indeterminate bar
/// (call `app.animate(true)` while it is shown). Returns true when Cancel was clicked.
/// Automation: `<status>##status`, `<NN% (x of y)>##percent`, `<cancel>##cancel` (ImGui ids scoped by `id`).
pub fn progressStrip(id: []const u8, status: []const u8, done: u64, total: u64, can_cancel: bool) bool {
    return progressStripEx(id, status, done, total, can_cancel, .{});
}

pub fn progressStripEx(id: []const u8, status: []const u8, done: u64, total: u64, can_cancel: bool, l: ProgressLabels) bool {
    im.ImGui_PushIDStr(id.ptr, id.ptr + id.len);
    defer im.ImGui_PopID();
    var buf: [128]u8 = undefined;
    text("status", status, null, 0);
    const pct: u64 = if (total == 0) 0 else @min(100, done * 100 / total);
    const label: []const u8 = if (total == 0)
        std.mem.print(&buf, "{d}", .{done}) catch return false
    else
        i18n.fmt(&buf, l.count, .{ pct, done, total });
    var cb: [128]u8 = undefined;
    const cancel = std.mem.printSentinel(&cb, "{s}##cancel", .{l.cancel}, 0) catch "Cancel##cancel";
    const style = im.ImGui_GetStyle();
    const label_w = im.ImGui_CalcTextSizeEx(label.ptr, label.ptr + label.len, false, -1).x;
    const cancel_w = if (can_cancel) im.ImGui_CalcTextSizeEx(cancel.ptr, null, true, -1).x + style.*.FramePadding.x * 2 + style.*.ItemSpacing.x else 0;
    const bar_w = @max(40, im.ImGui_GetContentRegionAvail().x - label_w - style.*.ItemSpacing.x - cancel_w);
    const frac: f32 = if (total == 0) @floatCast(-im.ImGui_GetTime()) else @as(f32, @floatFromInt(done)) / @as(f32, @floatFromInt(total));
    im.ImGui_ProgressBar(frac, .{ .x = bar_w, .y = 0 }, "");
    im.ImGui_SameLine();
    im.ImGui_AlignTextToFramePadding();
    text("percent", label, null, 0);
    if (!can_cancel) return false;
    im.ImGui_SameLine();
    return im.ImGui_Button(cancel.ptr);
}

// ---------------------------------------------------------------- icons and buttons

/// Icon of the kit set, `size` logical px (pixel-exact at any DPI). Missing texture = empty space.
pub fn icon(name: icons_png.Name, size: f32) void {
    iconTinted(name, size, 0xFFFFFF);
}

/// `icon` multiplied by `tint` (0xRRGGBB; 0xFFFFFF = as drawn). Respects BeginDisabled's alpha.
pub fn iconTinted(name: icons_png.Name, size: f32, tint: u32) void {
    const px = icons_png.pixels(size);
    const pos = im.ImGui_GetCursorScreenPos();
    im.ImGui_Dummy(.{ .x = px, .y = px });
    drawIcon(name, size, .{ .x = pos.x, .y = pos.y }, tint);
}

fn drawIcon(name: icons_png.Name, size: f32, pos: im.ImVec2, tint: u32) void {
    const t = icons_png.get(name, size) orelse return;
    const px = icons_png.pixels(size);
    const x = @round(pos.x); // whole pixels: texels map 1:1, no bilinear blur or fringes
    const y = @round(pos.y);
    const col = im.ImGui_GetColorU32ImU32(app.colorU32(tint)); // style alpha (disabled) applied
    im.ImDrawList_AddImageEx(im.ImGui_GetWindowDrawList(), t, .{ .x = x, .y = y }, .{ .x = x + px, .y = y + px }, .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 1 }, col);
}

/// Button with a kit icon (`size` logical px) and an optional label after it. ImGui label =
/// "<label>##<id>" (automation sees both). Tooltip: `im.ImGui_SetItemTooltip("...")` right after.
pub fn iconButton(id: []const u8, name: icons_png.Name, size: f32, label: ?[]const u8) bool {
    var buf: [256]u8 = undefined;
    const lbl = std.mem.printSentinel(&buf, "{s}##{s}", .{ label orelse "", id }, 0) catch return false;
    const style = im.ImGui_GetStyle();
    const pad = style.*.FramePadding;
    const px = icons_png.pixels(size);
    const text_w = if (label) |l| im.ImGui_CalcTextSizeEx(l.ptr, l.ptr + l.len, false, -1).x + style.*.ItemInnerSpacing.x else 0;
    const h = @max(im.ImGui_GetFrameHeight(), px + pad.y * 2);
    const pos = im.ImGui_GetCursorScreenPos();
    // The label is drawn by ImGui, right-aligned, so it lands just after the icon.
    im.ImGui_PushStyleVarImVec2(im.ImGuiStyleVar_ButtonTextAlign, .{ .x = 1, .y = 0.5 });
    const pressed = im.ImGui_ButtonEx(lbl.ptr, .{ .x = pad.x * 2 + px + text_w, .y = h });
    im.ImGui_PopStyleVar();
    drawIcon(name, size, .{ .x = pos.x + pad.x, .y = pos.y + (h - px) / 2 }, 0xFFFFFF);
    return pressed;
}

/// Mint-filled call-to-action button with anthracite text (palette accent / accent_dark).
/// Inside BeginDisabled it is a plain (dimmed) button: a faded mint fill is unreadable.
pub fn primaryButton(label: [*:0]const u8) bool {
    return primaryButtonEx(label, .{ .x = 0, .y = 0 });
}

pub fn primaryButtonEx(label: [*:0]const u8, size: im.ImVec2) bool {
    const p = if (app.current()) |a| a.cfg.palette else app.palettes.carbon;
    return filledButton(label, size, p.accent, p.accent_dark);
}

/// `primaryButtonEx` in palette danger, for the confirm button of a destructive action.
pub fn dangerButtonEx(label: [*:0]const u8, size: im.ImVec2) bool {
    const p = if (app.current()) |a| a.cfg.palette else app.palettes.carbon;
    return filledButton(label, size, p.danger, app.mix(p.danger, 0xFFFFFF, 0.2)); // lighter hover keeps bg text >= 4.9:1
}

fn filledButton(label: [*:0]const u8, size: im.ImVec2, fill: u32, hover: u32) bool {
    // ponytail: "disabled" = BeginDisabled lowered style.Alpha (ImGui has no public query for the disabled stack)
    if (im.ImGui_GetStyle().*.Alpha < 1) return im.ImGui_ButtonEx(label, size);
    const bg = if (app.current()) |a| a.cfg.palette.bg else app.palettes.carbon.bg;
    im.ImGui_PushStyleColorImVec4(im.ImGuiCol_Button, app.color(fill, 1));
    im.ImGui_PushStyleColorImVec4(im.ImGuiCol_ButtonHovered, app.color(hover, 1));
    im.ImGui_PushStyleColorImVec4(im.ImGuiCol_ButtonActive, app.color(hover, 1));
    im.ImGui_PushStyleColorImVec4(im.ImGuiCol_Text, app.color(bg, 1));
    im.ImGui_PushStyleColorImVec4(im.ImGuiCol_Border, app.color(fill, 1));
    defer im.ImGui_PopStyleColorEx(5);
    return im.ImGui_ButtonEx(label, size);
}

test "glyph encodes PUA code points" {
    const g = glyph(icons.delete);
    try std.testing.expectEqualSlices(u8, "\u{E74D}", std.mem.sliceTo(&g, 0));
}
