//! App side of updates. No network here: the app spawns MakeUpdate.exe (installed next to its exe, see
//! docs K11) hidden and reads one JSON line. MAKEKIT_NO_UPDATE=1 turns every check/install off (tests).
//!
//!   startup:   if (setting_on and kit.update.due(last_check, now)) try checker.start(gpa, io, updater, "MakeMD/App", "2.1.0");
//!   per frame: if (checker.poll()) |res| { save last_check = now; const r = res catch ...; if (r.value.newer) show banner }
//!   banner:    switch (kit.update.banner(.{ ... }) orelse ...) { .update => install + quit, .notes => open r.page, .later => skip }
const std = @import("std");
const im = @import("im");
const w = @import("w");
const win = @import("win.zig");
const jobs = @import("jobs.zig");
const app = @import("app.zig");
const ui = @import("ui.zig");
const icons = @import("icons.zig");
pub const release = @import("updater/release.zig");

pub const Version = release.Version;
/// The line `MakeUpdate check` prints (`ok`, `newer`, `latest`, `tag`, `notes`, `setup`, `sha256`, `page`, and on
/// failure `error` (plain English), `reason` (map it to the app's own translated text) and `detail` (log only)).
pub const Result = release.CheckResult;
pub const isNewer = release.isNewer;

pub const exe_name = "MakeUpdate.exe";
pub const check_interval_s = 24 * 3600;

/// A check is due: never checked, 24 h passed, or the clock went back. Unix seconds.
pub fn due(last_check: i64, now: i64) bool {
    return last_check <= 0 or now < last_check or now - last_check >= check_interval_s;
}

/// MAKEKIT_NO_UPDATE=1: no check, no install, nothing spawned (every test script and smoke sets it).
pub fn disabled() bool {
    var buf: [4]u16 = undefined;
    const n = w.GetEnvironmentVariableW(win.L("MAKEKIT_NO_UPDATE"), &buf, buf.len);
    return n == 1 and buf[0] == '1';
}

/// `<folder of this exe>\MakeUpdate.exe` (caller frees).
pub fn updaterPath(gpa: std.mem.Allocator, io: std.Io) ![]u8 {
    const dir = try std.process.executableDirPathAlloc(io, gpa);
    defer gpa.free(dir);
    return std.Io.Dir.path.join(gpa, &.{ dir, exe_name });
}

/// portable.dat next to the exe: a portable copy, which never installs (open `Result.page` instead).
pub fn isPortable(gpa: std.mem.Allocator, io: std.Io) bool {
    const dir = std.process.executableDirPathAlloc(io, gpa) catch return false;
    defer gpa.free(dir);
    const dat = std.Io.Dir.path.join(gpa, &.{ dir, "portable.dat" }) catch return false;
    defer gpa.free(dat);
    return win.isFile(dat);
}

/// Runs `MakeUpdate.exe check` hidden and parses its line (30 s timeout; caller deinit()s). A network or
/// GitHub problem is a value: `.ok = false` + `.reason` / `.error` (offline is normal: don't alert on a background check).
/// Zig errors: Disabled (MAKEKIT_NO_UPDATE=1), FileNotFound (no helper), Timeout, BadOutput.
pub fn check(gpa: std.mem.Allocator, io: std.Io, updater: []const u8, repo: []const u8, current: []const u8) !std.json.Parsed(Result) {
    if (disabled()) return error.Disabled;
    const r = try std.process.run(gpa, io, .{
        .argv = &.{ updater, "check", "--repo", repo, "--current", current },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(30), .clock = .awake } },
    });
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    return parseLine(gpa, r.stdout);
}

/// The first line of MakeUpdate's stdout -> Result.
pub fn parseLine(gpa: std.mem.Allocator, out: []const u8) !std.json.Parsed(Result) {
    const line = std.mem.trim(u8, out[0 .. std.mem.findScalar(u8, out, '\n') orelse out.len], " \r\t");
    return std.json.parseFromSlice(Result, gpa, line, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch error.BadOutput;
}

/// Starts `MakeUpdate.exe install` detached (hidden, no pipes) for this process and returns; then quit the app:
/// the helper downloads and checks the setup, waits for this PID (60 s), installs silently and starts `relaunch`
/// (normally this exe). Portable copies must not call it (`isPortable`).
pub fn install(io: std.Io, updater: []const u8, repo: []const u8, tag: []const u8, relaunch: []const u8) !void {
    if (disabled()) return error.Disabled;
    var pid_buf: [16]u8 = undefined;
    const pid = try std.mem.print(&pid_buf, "{d}", .{w.GetCurrentProcessId()});
    const child = try std.process.spawn(io, .{
        .argv = &.{ updater, "install", "--repo", repo, "--tag", tag, "--wait-pid", pid, "--relaunch", relaunch },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .create_no_window = true,
    });
    _ = w.CloseHandle(child.id); // not waited for: it outlives us
    _ = w.CloseHandle(child.thread_handle);
}

/// Background check on a kit.jobs worker. `start` after startup; `poll` every frame. Keep it at a fixed
/// address (in the app state); the strings passed to `start` must outlive the run. Before app.deinit: `deinit`.
pub const Checker = struct {
    job: jobs.Job = .{},
    gpa: std.mem.Allocator = undefined,
    io: std.Io = undefined,
    updater: []const u8 = "",
    repo: []const u8 = "",
    current: []const u8 = "",
    result: ?std.json.Parsed(Result) = null,

    pub fn start(c: *Checker, gpa: std.mem.Allocator, io: std.Io, updater: []const u8, repo: []const u8, current: []const u8) !void {
        if (c.job.isRunning()) return error.Busy;
        if (c.result) |*r| r.deinit();
        c.result = null;
        c.gpa = gpa;
        c.io = io;
        c.updater = updater;
        c.repo = repo;
        c.current = current;
        try c.job.start(c, worker);
    }

    fn worker(job: *jobs.Job) anyerror!void {
        const c = job.ctx(Checker);
        c.result = try check(c.gpa, c.io, c.updater, c.repo, c.current);
    }

    pub fn running(c: *Checker) bool {
        return c.job.isRunning();
    }

    /// Once, on the frame the check finished: the result (caller deinit()s) or the Zig error; null otherwise.
    pub fn poll(c: *Checker) ?anyerror!std.json.Parsed(Result) {
        if (!c.job.takeFinished()) return null;
        if (c.job.err) |e| return e;
        const r = c.result orelse return error.Canceled;
        c.result = null;
        return r;
    }

    pub fn deinit(c: *Checker) void {
        c.job.cancel(); // ponytail: a running check is not interrupted; join waits for it (<= 30 s timeout)
        c.job.join();
        if (c.result) |*r| r.deinit();
        c.result = null;
    }
};

pub const BannerAction = enum { update, notes, later };

/// Texts come from the app's i18n table. `text`: "Version 2.1.0 is available".
pub const BannerLabels = struct {
    text: []const u8,
    update: []const u8,
    notes: []const u8,
    later: []const u8,
};

/// Slim full-width bar: icon, `text`, then [update] [notes] [later] on the right. Returns the clicked button once.
/// Automation: `<text>##updText`, `<update>##updNow`, `<notes>##updNotes`, `<later>##updLater`.
pub fn banner(l: BannerLabels) ?BannerAction {
    const s = if (app.current()) |a| a.scale() else 1.0;
    const p = if (app.current()) |a| a.cfg.palette else app.palettes.carbon;
    const style = im.ImGui_GetStyle();
    const pad = 6 * s;
    im.ImGui_PushStyleColorImVec4(im.ImGuiCol_ChildBg, app.color(p.accent_soft, 1));
    im.ImGui_PushStyleVarImVec2(im.ImGuiStyleVar_WindowPadding, .{ .x = 10 * s, .y = pad });
    defer im.ImGui_PopStyleVar();
    defer im.ImGui_PopStyleColor();
    const h = im.ImGui_GetFrameHeight() + pad * 2;
    var result: ?BannerAction = null;
    if (im.ImGui_BeginChild("##updBanner", .{ .x = 0, .y = h }, im.ImGuiChildFlags_AlwaysUseWindowPadding, im.ImGuiWindowFlags_NoScrollbar)) {
        var lb: [3][256]u8 = undefined;
        const ids = [_][]const u8{ "updNow", "updNotes", "updLater" };
        const texts = [_][]const u8{ l.update, l.notes, l.later };
        var labels: [3][:0]const u8 = undefined;
        var buttons_w: f32 = 0;
        for (&labels, ids, texts, &lb) |*lab, id, t, *b| {
            lab.* = std.mem.printSentinel(b, "{s}##{s}", .{ t, id }, 0) catch "?";
            buttons_w += im.ImGui_CalcTextSizeEx(lab.ptr, null, true, -1).x + style.*.FramePadding.x * 2 + style.*.ItemSpacing.x;
        }
        // A frame-high empty item starts the row, so the icon can sit lower (centred) without moving the row.
        im.ImGui_Dummy(.{ .x = 0, .y = im.ImGui_GetFrameHeight() });
        im.ImGui_SameLineEx(0, 0);
        im.ImGui_SetCursorPosY(im.ImGui_GetCursorPosY() + @round((im.ImGui_GetFrameHeight() - icons.pixels(16)) / 2));
        ui.iconTinted(.info, 16, p.accent);
        im.ImGui_SameLine();
        im.ImGui_AlignTextToFramePadding();
        ui.text("updText", l.text, null, 0);
        const x = im.ImGui_GetWindowWidth() - style.*.WindowPadding.x - buttons_w + style.*.ItemSpacing.x;
        im.ImGui_SameLineEx(@max(x, im.ImGui_GetCursorPosX()), -1);
        for (labels, 0..) |lab, i| {
            if (i > 0) im.ImGui_SameLine();
            const clicked = if (i == 0) ui.primaryButton(lab.ptr) else im.ImGui_Button(lab.ptr);
            if (clicked) result = ([_]BannerAction{ .update, .notes, .later })[i];
        }
    }
    im.ImGui_EndChild();
    return result;
}

const testing = std.testing;

test "due: first run, 24 h, clock moved back" {
    const t = 1_800_000_000;
    try testing.expect(due(0, t));
    try testing.expect(!due(t, t + 3600));
    try testing.expect(!due(t, t + check_interval_s - 1));
    try testing.expect(due(t, t + check_interval_s));
    try testing.expect(due(t, t - 60));
}

test "parseLine: MakeUpdate output lines" {
    const ok = try parseLine(testing.allocator, "{\"ok\":true,\"newer\":true,\"latest\":\"2.1.0\",\"tag\":\"v2.1.0\",\"page\":\"https://x/p\",\"future\":1}\r\n");
    defer ok.deinit();
    try testing.expect(ok.value.ok and ok.value.newer);
    try testing.expectEqualStrings("v2.1.0", ok.value.tag);
    const off = try parseLine(testing.allocator, "{\"ok\":false,\"reason\":\"offline\",\"error\":\"No internet connection.\",\"detail\":\"no connection (12007: https://api.github.com/x)\"}");
    defer off.deinit();
    try testing.expect(!off.value.ok and std.mem.eql(u8, off.value.reason, "offline"));
    try testing.expectError(error.BadOutput, parseLine(testing.allocator, ""));
    try testing.expectError(error.BadOutput, parseLine(testing.allocator, "panic: oops\n"));
}

test "check/install refuse under MAKEKIT_NO_UPDATE=1 without spawning" {
    const name = std.unicode.utf8ToUtf16LeStringLiteral("MAKEKIT_NO_UPDATE");
    var old: [8]u16 = undefined;
    const had = w.GetEnvironmentVariableW(name, &old, old.len);
    _ = w.SetEnvironmentVariableW(name, std.unicode.utf8ToUtf16LeStringLiteral("1"));
    defer _ = w.SetEnvironmentVariableW(name, if (had > 0 and had < old.len) blk: {
        old[had] = 0;
        break :blk @ptrCast(&old);
    } else null);
    try testing.expect(disabled());
    try testing.expectError(error.Disabled, check(testing.allocator, testing.io, "C:\\nonexistent\\MakeUpdate.exe", "MakeMD/Demo", "1.0.0"));
    try testing.expectError(error.Disabled, install(testing.io, "C:\\nonexistent\\MakeUpdate.exe", "MakeMD/Demo", "v1.0.0", "C:\\x.exe"));
}
