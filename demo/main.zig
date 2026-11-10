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
    const app = try App.init(init.gpa, .{ .title = "MakeKit Demo", .size = .{ 980, 760 } });
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

    // Title (bold, larger) + Ukrainian + icon glyphs.
    im.ImGui_PushFontFloat(app.fonts.bold, 24);
    im.ImGui_TextUnformatted("MakeKit demo");
    im.ImGui_PopFont();
    const icons_line = "Їжак ґанок є  " ++ "\u{E8B7} \u{E74D} \u{E72C} \u{E713} \u{E946} \u{E7BA}";
    im.ImGui_TextUnformatted(icons_line);
    var dpi_buf: [96]u8 = undefined;
    const dpi_text = std.mem.printSentinel(&dpi_buf, "DPI {d} ({d:.2}x){s}", .{ app.dpi, sc, if (app.warp) ", WARP" else "" }, 0) catch unreachable;
    im.ImGui_TextDisabled("%s", dpi_text.ptr);
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
        if (s.job.isFinished() and s.job.thread != null) {
            s.job.join();
            s.job_done = true;
        }
        if (ui.iconButton(ui.icons.refresh, "Start job##job", "Runs a 1.2 s fake job")) {
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
    if (ui.iconButton(ui.icons.warning, "Show dialog##msg", null)) ui.openMessage("Delete files?##dlg");
    if (ui.messageBox("Delete files?##dlg", .warning, "Delete 3 selected items? Їх можна відновити з Кошика.", &.{ "Delete", "Cancel" })) |r| s.dialog_result = r;
    if (s.dialog_result) |r| {
        im.ImGui_SameLine();
        if (im.ImGui_Button(if (r == 0) "Dialog: Delete##dlgres" else "Dialog: Cancel##dlgres")) s.dialog_result = null;
    }

    im.ImGui_SameLine();
    if (ui.iconButton(ui.icons.open_file, "Open file...##open", "IFileOpenDialog")) {
        const filters = [_]kit.win.Filter{ .{ .name = "Text", .spec = "*.txt;*.md" }, .{ .name = "All files", .spec = "*.*" } };
        if (kit.win.openFiles(s.gpa, app.hwnd, true, .{ .title = "Pick files", .filters = &filters })) |res| {
            if (res) |list| {
                defer kit.win.freeList(s.gpa, list);
                s.setInfo("Picked {d}: {s}", .{ list.len, list[0] });
            } else s.setInfo("Open dialog cancelled", .{});
        } else |e| s.setInfo("dialog error {t} hr=0x{x}", .{ e, @as(u32, @bitCast(kit.win.last_hr)) });
    }

    im.ImGui_SameLine();
    if (ui.iconButton(ui.icons.delete, "Recycle temp file##recycle", "Creates a temp file and sends it to the Recycle Bin")) recycleTemp(s);

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
    if (s.info_len > 0) {
        im.ImGui_TextUnformattedEx(&s.info, @as([*]const u8, &s.info) + s.info_len);
    }

    // Close veto while the job runs.
    if (s.quit_asked) {
        s.quit_asked = false;
        ui.openMessage("Quit?##quit");
    }
    if (ui.messageBox("Quit?##quit", .question, "A job is still running. Quit anyway?", &.{ "Quit", "Keep running" })) |r| {
        if (r == 0) {
            s.job.cancel();
            app.quit();
        }
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
