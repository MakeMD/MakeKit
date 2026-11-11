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

    fn setInfo(s: *State, comptime fmt: []const u8, args: anytype) void {
        const text: []const u8 = std.mem.print(&s.info, fmt, args) catch &s.info; // truncated
        s.info_len = text.len;
    }
};

pub fn main(init: std.process.Init) !void {
    var state: State = .{ .gpa = init.gpa };
    const app = try App.init(init.gpa, .{ .title = "MakeKit Demo", .size = .{ 1280, 900 } });
    defer app.deinit();
    app.run(.{ .user = &state, .frame = frame, .close_requested = closeRequested, .files_dropped = dropped });
    state.job.cancel();
    state.job.join();
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
