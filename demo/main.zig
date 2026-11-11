//! MakeKit demo = the kit's smoke test (tools/smoke.ps1 drives it over the automation pipe).
const std = @import("std");
const kit = @import("kit");
const im = kit.im;
const ui = kit.ui;
const App = kit.app.App;

const State = struct {
    gpa: std.mem.Allocator,
    docs: ui.Tri = .on,
    pics: ui.Tri = .off,
    temp: ui.Tri = .on,
    all: ui.Tri = .mixed,
    name: [128:0]u8 = @splat(0),
    verbose: bool = false,
    level: usize = 1,
    selected_row: usize = 0,
    job: kit.jobs.Job = .{},
    job_done: bool = false,
    dialog_result: ?usize = null,
    info: [512]u8 = @splat(0),
    info_len: usize = 0,
    quit_asked: bool = false,
    // compact-metrics row
    small: [32:0]u8 = @splat(0),
    check2: bool = true,
    radio: c_int = 0,
    mixed: ui.Tri = .mixed,
    slider: c_int = 40,
    lang: ?kit.i18n.Lang = null, // Auto
    // update banner: only with MAKEKIT_UPDATE_API set (tools/update-e2e.ps1's fake GitHub); the demo never asks GitHub
    upd: kit.update.Checker = .{},
    upd_path: []u8 = "",
    upd_latest: [32]u8 = undefined,
    upd_latest_len: usize = 0,

    fn setInfo(s: *State, comptime fmt: []const u8, args: anytype) void {
        const text: []const u8 = std.mem.print(&s.info, fmt, args) catch &s.info; // truncated
        s.info_len = text.len;
    }
};

pub fn main(init: std.process.Init) !void {
    var state: State = .{ .gpa = init.gpa };
    kit.i18n.apply(state.lang); // MAKEKIT_LANG > saved choice > Windows UI language > en
    const app = try App.init(init.gpa, .{ .title = "MakeKit Demo", .size = .{ 1280, 900 } });
    defer app.deinit();
    if (init.environ_map.get("MAKEKIT_UPDATE_API") != null and !kit.update.disabled()) {
        state.upd_path = try kit.update.updaterPath(init.gpa, init.io);
        try state.upd.start(init.gpa, init.io, state.upd_path, "MakeMD/Demo", "1.0.0");
    }
    defer if (state.upd_path.len > 0) init.gpa.free(state.upd_path);
    app.run(.{ .user = &state, .frame = frame, .close_requested = closeRequested, .files_dropped = dropped });
    state.job.cancel();
    state.job.join();
    state.upd.deinit();
}

fn closeRequested(app: *App) bool {
    const s = app.userData(State);
    if (!s.job.isRunning()) return true;
    s.quit_asked = true; // ask in a modal, quit from there
    return false;
}

fn dropped(app: *App, paths: []const []const u8, pos: im.ImVec2) void {
    const s = app.userData(State);
    s.setInfo("Dropped {d} file(s) at {d:.0},{d:.0}: {s}", .{ paths.len, pos.x, pos.y, paths[0] });
}

fn worker(job: *kit.jobs.Job) anyerror!void {
    const n = 120;
    job.setTotal(n);
    for (0..n) |i| {
        if (job.cancelled()) return error.Canceled;
        job.setStatus("Processing item {d} of {d}...", .{ i + 1, n });
        kit.w.Sleep(10); // pretend work
        job.addDone(1);
    }
    job.setStatus("Done", .{});
}

fn frame(app: *App) void {
    const s = app.userData(State);
    const sc = app.scale();
    const vp = im.ImGui_GetMainViewport();
    im.ImGui_SetNextWindowPos(vp.*.WorkPos, 0);
    im.ImGui_SetNextWindowSize(vp.*.WorkSize, 0);
    _ = im.ImGui_Begin("MakeKit Demo##main", null, im.ImGuiWindowFlags_NoDecoration | im.ImGuiWindowFlags_NoMove | im.ImGuiWindowFlags_NoSavedSettings | im.ImGuiWindowFlags_NoBringToFrontOnFocus);
    defer im.ImGui_End();

    if (s.upd.poll()) |res| {
        if (res) |r| {
            defer r.deinit();
            const latest: []const u8 = std.mem.print(&s.upd_latest, "{s}", .{r.value.latest}) catch "";
            if (r.value.newer) s.upd_latest_len = latest.len;
            s.setInfo("update check: {s}", .{if (r.value.ok) "ok" else r.value.@"error"});
        } else |e| s.setInfo("update check failed: {t}", .{e});
    }
    if (s.upd_latest_len > 0) {
        var tb: [96]u8 = undefined;
        const text = std.mem.print(&tb, "Version {s} is available", .{s.upd_latest[0..s.upd_latest_len]}) catch "";
        if (kit.update.banner(.{ .text = text, .update = "Update now", .notes = "Release notes", .later = "Later" })) |a| {
            s.setInfo("update banner: {t}", .{a});
            s.upd_latest_len = 0; // the demo only hides it; an app would install / open the page / remember the skip
        }
    }

    // Left: widgets. Right: the theme (palette swatches + every icon at 16/24/32/48).
    im.ImGui_PushStyleColorImVec4(im.ImGuiCol_ChildBg, .{ .x = 0, .y = 0, .z = 0, .w = 0 });
    _ = im.ImGui_BeginChild("left", .{ .x = 640 * sc, .y = 0 }, 0, 0);
    im.ImGui_PopStyleColor();
    widgets(app, s, sc);
    im.ImGui_EndChild();
    im.ImGui_SameLine();
    _ = im.ImGui_BeginChild("theme", .{ .x = 0, .y = 0 }, im.ImGuiChildFlags_Borders, 0);
    theme(app);
    im.ImGui_EndChild();

    // Close veto while the job runs.
    if (s.quit_asked) {
        s.quit_asked = false;
        ui.openMessage("Quit?##quit");
    }
    if (ui.messageBoxEx("Quit?##quit", .question, "A job is still running. Quit anyway?", &.{ "Quit", "Keep running" }, .{ .width = 300 })) |r| {
        if (r == 0) {
            s.job.cancel();
            app.quit();
        }
    }
}

fn theme(app: *App) void {
    const p = app.cfg.palette;
    im.ImGui_PushFontFloat(app.fonts.bold, 20);
    im.ImGui_TextUnformatted("Carbon Mint");
    im.ImGui_PopFont();
    const names = std.enums.values(kit.icons.Name);
    im.ImGui_SameLine();
    im.ImGui_AlignTextToFramePadding();
    var cb: [32]u8 = undefined;
    ui.text("iconCount", std.mem.print(&cb, "{d} icons", .{names.len}) catch "", p.muted, 0); // smoke checks it
    if (im.ImGui_BeginTable("palette", 3, 0)) {
        inline for (@typeInfo(kit.app.Palette).@"struct".field_names) |f| {
            _ = im.ImGui_TableNextColumn();
            const c = @field(p, f);
            _ = im.ImGui_ColorButtonEx("##sw" ++ f, kit.app.color(c, 1), im.ImGuiColorEditFlags_NoTooltip | im.ImGuiColorEditFlags_NoDragDrop, .{ .x = 18 * app.scale(), .y = 18 * app.scale() });
            im.ImGui_SameLine();
            var b: [48]u8 = undefined;
            im.ImGui_TextUnformatted((std.mem.printSentinel(&b, f ++ " #{X:0>6}", .{c}, 0) catch unreachable).ptr);
        }
        im.ImGui_EndTable();
    }
    if (ui.primaryButton("Primary##primary")) {}
    im.ImGui_SameLine();
    _ = im.ImGui_Button("Secondary##secondary");
    im.ImGui_SameLine();
    _ = ui.dangerButtonEx("Delete##danger", .{ .x = 0, .y = 0 });
    im.ImGui_SameLine();
    _ = ui.iconButton("iconOnly", .settings, 16, null);
    im.ImGui_SetItemTooltip("Icon-only button");
    im.ImGui_SameLine();
    _ = im.ImGui_TextLink("Text link##link");

    // kit.i18n: picker (applies at once) + one line per language, so every glyph shows up in the screenshot.
    im.ImGui_SeparatorText("Languages");
    const s = app.userData(State);
    im.ImGui_SetNextItemWidth(180 * app.scale());
    _ = kit.i18n.combo("Language##lang", "Auto (system)", &s.lang);
    im.ImGui_SameLine();
    im.ImGui_AlignTextToFramePadding();
    const l = kit.i18n.current();
    var lb: [64]u8 = undefined;
    ui.text("langCur", kit.i18n.fmt(&lb, "{0} ({1})", .{ l.name(), l.code() }), p.muted, 0);
    const lines = [_][2][:0]const u8{
        .{ "glyphs_en", "English: The quick brown fox jumps over the lazy dog." },
        .{ "glyphs_uk", "Українська: Ґанок, їжак, єнот і п’ять яблук — «Гаразд»." },
        .{ "glyphs_pl", "Polski: Zażółć gęślą jaźń. ĄĆĘŁŃÓŚŹŻ" },
        .{ "glyphs_de", "Deutsch: Größe, Übermaß, Fußgänger. ÄÖÜ äöü ß „Ja“" },
        .{ "glyphs_es", "Español: ¿Qué año? ¡Señor Muñoz! á é í ó ú ü ñ Ñ" },
        .{ "glyphs_fr", "Français: « Ça déjà », où, île, cœur, æ, naïve, Noël, ÿ, â ê î ô û à è ù ç Œ Æ" },
    };
    for (lines) |ln| ui.text(ln[0], ln[1], null, 0);

    im.ImGui_PushStyleVarImVec2(im.ImGuiStyleVar_ItemSpacing, .{ .x = 6 * app.scale(), .y = 6 * app.scale() });
    defer im.ImGui_PopStyleVar();
    for ([_]f32{ 16, 24, 32, 48 }) |size| {
        var hb: [32]u8 = undefined;
        im.ImGui_SeparatorText((std.mem.printSentinel(&hb, "Icons {d} px", .{size}, 0) catch unreachable).ptr);
        const step = kit.icons.pixels(size) + im.ImGui_GetStyle().*.ItemSpacing.x;
        const per_row: usize = @max(1, @as(usize, @intFromFloat(im.ImGui_GetContentRegionAvail().x / step)));
        for (names, 0..) |n, i| {
            if (i % per_row != 0) im.ImGui_SameLine();
            ui.icon(n, size);
            im.ImGui_SetItemTooltip(@tagName(n));
        }
    }
}

fn widgets(app: *App, s: *State, sc: f32) void {
    // Title (bold, larger) + Ukrainian + icon glyphs.
    im.ImGui_PushFontFloat(app.fonts.bold, 24);
    im.ImGui_TextUnformatted("MakeKit demo");
    im.ImGui_PopFont();
    const icons_line = "Їжак ґанок є  " ++ "\u{E8B7} \u{E74D} \u{E72C} \u{E713} \u{E946} \u{E7BA}";
    im.ImGui_TextUnformatted(icons_line);
    var dpi_buf: [96]u8 = undefined;
    const dpi_text = std.mem.printSentinel(&dpi_buf, "DPI {d} ({d:.2}x){s}", .{ app.dpi, sc, if (app.warp) ", WARP" else "" }, 0) catch unreachable;
    ui.text("dpi", dpi_text, app.cfg.palette.muted, 0);
    compactRow(s, sc);
    im.ImGui_Separator();

    // Tri-state checkboxes: "All" follows its children.
    if (ui.triCheckbox("All##all", &s.all)) {
        s.docs = s.all;
        s.pics = s.all;
        s.temp = s.all;
    }
    im.ImGui_Indent();
    var any_change = ui.triCheckbox("Documents##c1", &s.docs);
    any_change = ui.triCheckbox("Pictures##c2", &s.pics) or any_change;
    any_change = ui.triCheckbox("Temp files##c3", &s.temp) or any_change;
    im.ImGui_Unindent();
    if (any_change) {
        const on = @as(u8, @intFromBool(s.docs == .on)) + @intFromBool(s.pics == .on) + @intFromBool(s.temp == .on);
        s.all = if (on == 3) .on else if (on == 0) .off else .mixed;
    }

    // Plain ImGui tab bar + combo: automation sees tab labels (selected = shown tab) and the combo preview.
    if (im.ImGui_BeginTabBar("tabs", im.ImGuiTabBarFlags_DrawSelectedOverline)) { // the kit tab look: mint overline
        if (im.ImGui_BeginTabItem("Options##tabOptions", null, 0)) {
            im.ImGui_AlignTextToFramePadding(); // a checkbox that starts a frame-high line: centre it like text
            _ = ui.checkbox("Verbose log##verbose", &s.verbose);
            im.ImGui_SameLine();
            const levels = [_][*:0]const u8{ "Fast", "Normal", "Ultra" };
            im.ImGui_SetNextItemWidth(160 * sc);
            if (im.ImGui_BeginCombo("Level##lvl", levels[s.level], 0)) {
                for (levels, 0..) |l, i| {
                    im.ImGui_PushIDInt(@intCast(i));
                    if (im.ImGui_SelectableEx(l, i == s.level, 0, .{ .x = 0, .y = 0 })) s.level = i;
                    im.ImGui_PopID();
                }
                im.ImGui_EndCombo();
            }
            im.ImGui_EndTabItem();
        }
        if (im.ImGui_BeginTabItem("About##tabAbout", null, 0)) {
            ui.text("about", "MakeKit: Zig 0.17 + Dear ImGui 1.93 on Win32/D3D11.", null, 0);
            im.ImGui_EndTabItem();
        }
        im.ImGui_EndTabBar();
    }

    // Table.
    im.ImGui_SeparatorText("Table");
    const rows = [_][3][*:0]const u8{
        .{ "Browser cache", "412 MB", "Ready" },
        .{ "Windows temp", "1.2 GB", "Ready" },
        .{ "Thumbnails", "88 MB", "Skipped" },
        .{ "Кошик (Recycle Bin)", "3.4 GB", "Ready" },
    };
    const tflags = im.ImGuiTableFlags_Borders | im.ImGuiTableFlags_RowBg | im.ImGuiTableFlags_SizingStretchProp;
    if (im.ImGui_BeginTable("files", 3, tflags)) {
        im.ImGui_TableSetupColumn("Name", 0);
        im.ImGui_TableSetupColumn("Size", 0);
        im.ImGui_TableSetupColumn("Status", 0);
        im.ImGui_TableHeadersRow();
        for (rows, 0..) |r, i| {
            im.ImGui_TableNextRow();
            _ = im.ImGui_TableNextColumn();
            if (im.ImGui_SelectableEx(r[0], s.selected_row == i, im.ImGuiSelectableFlags_SpanAllColumns, .{ .x = 0, .y = 0 })) s.selected_row = i;
            _ = im.ImGui_TableNextColumn();
            im.ImGui_TextUnformatted(r[1]);
            _ = im.ImGui_TableNextColumn();
            im.ImGui_TextUnformatted(r[2]);
        }
        im.ImGui_EndTable();
    }

    // Background job + progress strip.
    im.ImGui_SeparatorText("Background job");
    if (s.job.isRunning()) {
        var sb: [256]u8 = undefined;
        if (ui.progressStrip("job", s.job.status(&sb), s.job.done.load(.acquire), s.job.total.load(.acquire), true)) s.job.cancel();
    } else {
        if (s.job.takeFinished()) s.job_done = true;
        if (ui.iconButton("job", .refresh, 16, "Start job")) {
            s.job_done = false;
            s.job.start(s, worker) catch |e| s.setInfo("start failed: {t}", .{e});
        }
        if (s.job_done) {
            im.ImGui_SameLine();
            var eb: [256]u8 = undefined;
            const label: [*:0]const u8 = if (s.job.errorText(&eb) != null) "Job failed##jobdone" else if (s.job.cancelled()) "Job cancelled##jobdone" else "Job finished##jobdone";
            if (im.ImGui_Button(label)) s.job_done = false;
        }
    }

    // Modal dialog.
    im.ImGui_SeparatorText("Dialogs & shell");
    if (ui.iconButton("msg", .warning, 16, "Show dialog")) ui.openMessage("Delete files?##dlg");
    im.ImGui_SameLine();
    if (im.ImGui_Button("Delete##pageDelete")) s.setInfo("page Delete clicked", .{}); // same text as the dialog button
    if (ui.messageBox("Delete files?##dlg", .warning, "Delete 3 selected items? Їх можна відновити з Кошика.", &.{ "Delete", "Cancel" })) |r| s.dialog_result = r;
    if (s.dialog_result) |r| {
        im.ImGui_SameLine();
        if (im.ImGui_Button(if (r == 0) "Dialog: Delete##dlgres" else "Dialog: Cancel##dlgres")) s.dialog_result = null;
    }

    im.ImGui_SameLine();
    if (ui.iconButton("open", .folder, 16, "Open file...")) {
        const filters = [_]kit.win.Filter{ .{ .name = "Text", .spec = "*.txt;*.md" }, .{ .name = "All files", .spec = "*.*" } };
        if (kit.win.openFiles(s.gpa, app.hwnd, true, .{ .title = "Pick files", .filters = &filters })) |res| {
            if (res) |list| {
                defer kit.win.freeList(s.gpa, list);
                s.setInfo("Picked {d}: {s}", .{ list.len, list[0] });
            } else s.setInfo("Open dialog cancelled", .{});
        } else |e| s.setInfo("dialog error {t} hr=0x{x}", .{ e, @as(u32, @bitCast(kit.win.last_hr)) });
    }

    im.ImGui_SameLine();
    if (ui.iconButton("recycle", .delete, 16, "Recycle temp file")) recycleTemp(s);
    im.ImGui_SetItemTooltip("Creates a temp file and sends it to the Recycle Bin");

    // Text input (fixed buffer) + echo button for automation checks.
    im.ImGui_SeparatorText("Input");
    im.ImGui_SetNextItemWidth(320 * sc);
    _ = im.ImGui_InputText("Name##name", &s.name, s.name.len, 0);
    const name = std.mem.sliceTo(&s.name, 0);
    if (name.len > 0) {
        var eb: [200]u8 = undefined;
        if (std.mem.printSentinel(&eb, "Echo: {s}##echo", .{name}, 0)) |echo| {
            im.ImGui_SameLine();
            _ = im.ImGui_Button(echo.ptr);
        } else |_| {}
    }

    im.ImGui_Spacing();
    im.ImGui_TextDisabled("Drop files onto the window to see their paths.");
    if (s.info_len > 0) ui.text("info", s.info[0..s.info_len], null, im.ImGui_GetContentRegionAvail().x);
}

/// Every widget kind side by side: frames 24 px, check/radio boxes 14 px centred on the line, tree, slider.
fn compactRow(s: *State, sc: f32) void {
    im.ImGui_SeparatorText("Widgets");
    _ = im.ImGui_Button("Button##mBtn");
    im.ImGui_SameLine();
    im.ImGui_SetNextItemWidth(100 * sc);
    _ = im.ImGui_InputTextWithHint("##mInput", "Input", &s.small, s.small.len, 0);
    im.ImGui_SameLine();
    im.ImGui_SetNextItemWidth(100 * sc);
    if (im.ImGui_BeginCombo("##mCombo", "Combo with a long preview", 0)) im.ImGui_EndCombo(); // ellipsis + chevron
    im.ImGui_SameLine();
    _ = im.ImGui_Checkbox("Check##mChk", &s.check2);
    im.ImGui_SameLine();
    _ = im.ImGui_RadioButtonIntPtr("Radio##mRadio0", &s.radio, 0);
    im.ImGui_SameLine();
    _ = im.ImGui_RadioButtonIntPtr("Other##mRadio1", &s.radio, 1);
    im.ImGui_SameLine();
    _ = ui.triCheckbox("Mixed##mTri", &s.mixed);
    im.ImGui_SetNextItemWidth(160 * sc);
    _ = im.ImGui_SliderInt("##mSlider", &s.slider, 0, 100);
    im.ImGui_SameLine();
    im.ImGui_TextUnformatted("\u{2116} 5 \u{20B4} \u{2192} \u{00BD} | fallback (Segoe UI): \u{0531}\u{0532} \u{10D0}\u{10D1}");
    if (im.ImGui_TreeNodeEx("Tree node##mTree", im.ImGuiTreeNodeFlags_DefaultOpen)) {
        _ = im.ImGui_Checkbox("Child checkbox##mChk2", &s.check2);
        if (im.ImGui_TreeNode("Closed child##mTree2")) im.ImGui_TreePop();
        im.ImGui_TreePop();
    }
}

fn recycleTemp(s: *State) void {
    const gpa = s.gpa;
    const tmp = kit.win.expandEnv(gpa, "%TEMP%\\makekit-demo-recycle.tmp") catch return;
    defer gpa.free(tmp);
    const wpath = kit.win.toW(gpa, tmp) catch return;
    defer gpa.free(wpath);
    const w = kit.w;
    const h = w.CreateFileW(wpath.ptr, w.GENERIC_WRITE, 0, null, w.CREATE_ALWAYS, w.FILE_ATTRIBUTE_NORMAL, null);
    if (h == w.INVALID_HANDLE_VALUE) return s.setInfo("could not create {s}", .{tmp});
    _ = w.CloseHandle(h);
    const r = kit.win.recycle(gpa, &.{tmp});
    s.setInfo("Recycled {s}: hr=0x{x:0>8} aborted={}", .{ tmp, @as(u32, @bitCast(r.hr)), r.aborted });
}
