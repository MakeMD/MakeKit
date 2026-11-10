//! Test automation over a named pipe (replaces UIA: ImGui has no accessibility tree).
//! Enabled with env MAKEKIT_AUTOMATION=1. Pipe: \\.\pipe\makekit-auto-<pid>, one request line in,
//! one JSON line out. Commands run on the UI thread between frames:
//!   list | click <label> [@x] | dblclick <label> [@x] | rclick <label> [@x] | hover <label> [@x] | type <text>
//!   key <[ctrl+][shift+][alt+]Name> | wait <label> [timeout_ms] | frames <n> | screenshot <path.bmp> | quit
//! <label> matching: exact full label ("Start##job"), else the visible text ("Start" = the label up to
//! "##"), else a label ending with the given "##id", else substring; >1 distinct match (after preferring
//! visible items) = error "ambiguous". `@x` moves the click off the item centre: `@12` = 12 px from the
//! left edge, `@-12` = from the right edge, `@75%` = at 75 % of the width (e.g. one column of a
//! SpanAllColumns row); y stays centred.
//! Real mouse/keyboard/focus messages are filtered out in app.zig's WndProc while active.
const std = @import("std");
const im = @import("im");
const w = @import("w");
const win = @import("win.zig");
const App = @import("app.zig").App;

pub var active = false;

const MkteItem = extern struct {
    id: u32,
    status: c_int,
    item_flags: c_int,
    x0: f32,
    y0: f32,
    x1: f32,
    y1: f32,
    label: c_int,
    window: c_int,
    visible: c_int,
    value: c_int,
};
const MkteWindow = extern struct {
    name: [*:0]const u8,
    x0: f32,
    y0: f32,
    x1: f32,
    y1: f32,
    flags: c_int,
    focused: c_int,
};
extern fn mkte_item_count() c_int;
extern fn mkte_items() ?[*]const MkteItem;
extern fn mkte_pool() ?[*]const u8;
extern fn mkte_window_count() c_int;
extern fn mkte_windows() ?[*]const MkteWindow;
extern fn mkte_enable() void;
extern fn mkte_tag(id: im.ImGuiID, label: ?[*:0]const u8, value: ?[*]const u8, value_len: c_int, status: c_int, add: c_int) void;

// ImGuiItemStatusFlags test-engine bits (imgui_internal.h, IMGUI_ENABLE_TEST_ENGINE)
const ST_EDITED = 1 << 2;
const ST_OPENABLE = 1 << 20;
const ST_OPENED = 1 << 21;
const ST_CHECKABLE = 1 << 22;
const ST_CHECKED = 1 << 23;
const ST_INPUTABLE = 1 << 24;
const ST_SELECTED = 1 << 30; // te_hooks.cpp MKTE_SELECTED

// ---------------------------------------------------------------- pipe thread <-> UI thread

// ponytail: process-lifetime allocator; the pipe thread is never joined, so leak-checked app.gpa would
// report its in-flight buffers at exit.
const gpa = std.heap.smp_allocator;
var lock: win.Lock = .{};
var request: ?[]u8 = null; // guarded by lock
var reply: ?[]u8 = null; // guarded by lock
var has_request: std.atomic.Value(bool) = .init(false);
var reply_event: w.HANDLE = null;
var written_event: w.HANDLE = null; // set after a reply reached the pipe
var unwritten: std.atomic.Value(bool) = .init(false);
var g_app: *App = undefined;

pub fn wanted(alloc: std.mem.Allocator) bool {
    const v = (win.getEnv(alloc, "MAKEKIT_AUTOMATION") catch null) orelse return false;
    defer alloc.free(v);
    return std.mem.eql(u8, v, "1");
}

pub fn start(app: *App) !void {
    g_app = app;
    reply_event = w.CreateEventW(null, 0, 0, null);
    written_event = w.CreateEventW(null, 0, 0, null);
    if (reply_event == null or written_event == null) return error.Unexpected;
    mkte_enable(); // ponytail: items are recorded only under automation, no per-item cost otherwise
    const t = try std.Thread.spawn(.{}, pipeThread, .{});
    t.detach(); // ponytail: blocks in ConnectNamedPipe/ReadFile; dies with the process
    active = true;
}

/// App is exiting: answer an in-flight command (e.g. a click on a "Quit" button) and give the pipe
/// thread a moment to deliver the last reply before the process ends.
pub fn stop() void {
    if (!active) return;
    if (cur != null) finish(gpa.dupe(u8, "{\"ok\":true,\"exiting\":true}") catch unreachable);
    if (unwritten.load(.acquire)) _ = w.WaitForSingleObject(written_event, 1000);
    active = false;
}

/// Reports the last submitted item to automation as `label`, with `value` as its readable text. Makes
/// items ImGui does not report findable (TextUnformatted, custom drawing over a Dummy). Like ImGui's own
/// labels it only counts while the item is visible. No-op unless automation is on.
pub fn tagLastItem(label: [*:0]const u8, value: ?[]const u8) void {
    if (!active) return;
    const id = im.ImGui_GetItemID();
    const v = value orelse "";
    mkte_tag(if (id != 0) id else im.ImGui_GetID(label), label, if (value != null) v.ptr else null, @intCast(v.len), 0, 1);
}

/// True while a command is queued or running (the main loop keeps rendering).
pub fn busy() bool {
    return active and (cur != null or has_request.load(.acquire));
}

/// WndProc filter: messages that carry real user input / focus changes.
pub fn isUserInput(msg: w.UINT) bool {
    return switch (msg) {
        0x0100...0x0109, // WM_KEYFIRST..WM_KEYLAST (incl. WM_CHAR, WM_SYSKEY*)
        0x0200...0x020E, // WM_MOUSEFIRST..WM_MOUSELAST
        0x00A0...0x00AD, // WM_NCMOUSEMOVE, WM_NC*BUTTON*
        0x02A2,
        0x02A3, // WM_NCMOUSELEAVE, WM_MOUSELEAVE
        0x0007,
        0x0008, // WM_SETFOCUS, WM_KILLFOCUS
        0x0281...0x0291, // WM_IME_* (ImGui IME positioning)
        => true,
        else => false,
    };
}

fn pipeThread() void {
    var name_buf: [64]u8 = undefined;
    const name = std.mem.print(&name_buf, "\\\\.\\pipe\\makekit-auto-{d}", .{w.GetCurrentProcessId()}) catch return;
    var wname_buf: [64]u16 = undefined;
    const n = std.unicode.wtf8ToWtf16Le(&wname_buf, name) catch return;
    wname_buf[n] = 0;
    const wname = wname_buf[0..n :0];
    while (true) {
        const h = w.CreateNamedPipeW(wname.ptr, @intCast(w.PIPE_ACCESS_DUPLEX), @intCast(w.PIPE_TYPE_BYTE | w.PIPE_READMODE_BYTE | w.PIPE_WAIT), 1, 1 << 16, 1 << 16, 0, null);
        if (h == w.INVALID_HANDLE_VALUE) return;
        if (w.ConnectNamedPipe(h, null) != 0 or w.GetLastError() == w.ERROR_PIPE_CONNECTED) serve(h);
        _ = w.DisconnectNamedPipe(h);
        _ = w.CloseHandle(h);
    }
}

fn serve(h: w.HANDLE) void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var chunk: [4096]u8 = undefined;
    while (true) {
        var got: w.DWORD = 0;
        if (w.ReadFile(h, &chunk, chunk.len, &got, null) == 0 or got == 0) return;
        buf.appendSlice(gpa, chunk[0..got]) catch return;
        while (std.mem.findScalar(u8, buf.items, '\n')) |nl| {
            const line = std.mem.trim(u8, buf.items[0..nl], " \r\t");
            const out = submit(line);
            defer gpa.free(out);
            var written: w.DWORD = 0;
            const wrote = w.WriteFile(h, out.ptr, @intCast(out.len), &written, null) != 0;
            unwritten.store(false, .release);
            _ = w.SetEvent(written_event);
            if (!wrote) return;
            buf.replaceRange(gpa, 0, nl + 1, &.{}) catch return;
        }
    }
}

/// Pipe thread: hand a line to the UI thread and block for its JSON reply (with trailing '\n').
fn submit(line: []const u8) []u8 {
    const copy = gpa.dupe(u8, line) catch return gpa.dupe(u8, "{\"ok\":false,\"error\":\"oom\"}\n") catch unreachable;
    lock.lock();
    request = copy;
    lock.unlock();
    has_request.store(true, .release);
    g_app.wake();
    _ = w.WaitForSingleObject(reply_event, w.INFINITE);
    lock.lock();
    defer lock.unlock();
    const r = reply.?;
    reply = null;
    return r;
}

/// UI thread: publish the reply for the current command.
fn finish(json: []u8) void {
    const line = std.mem.concat(gpa, u8, &.{ json, "\n" }) catch unreachable; // ponytail: OOM = crash
    gpa.free(json);
    lock.lock();
    reply = line;
    lock.unlock();
    unwritten.store(true, .release);
    if (cur) |c| gpa.free(c.arg);
    cur = null;
    _ = w.SetEvent(reply_event);
}

fn ok() void {
    finish(gpa.dupe(u8, "{\"ok\":true}") catch unreachable);
}

fn fail(comptime fmt: []const u8, args: anytype) void {
    var msg_buf: [512]u8 = undefined;
    const msg = std.mem.print(&msg_buf, fmt, args) catch "error";
    finish(std.json.Stringify.valueAlloc(gpa, .{ .ok = false, .@"error" = msg }, .{}) catch unreachable);
}

// ---------------------------------------------------------------- commands (UI thread)

const Kind = enum { list, click, dblclick, rclick, hover, type, key, wait, frames, screenshot, quit };

const Cmd = struct {
    kind: Kind,
    arg: []u8, // owned (freed by finish)
    q: []const u8 = "", // label/text view into arg
    step: u32 = 0,
    pos: im.ImVec2 = .{ .x = 0, .y = 0 },
    n: u64 = 0, // frames left / deadline ms
    key: c_int = 0,
    mods: [4]c_int = .{ 0, 0, 0, 0 },
    nmods: usize = 0,
};

var cur: ?Cmd = null;

pub fn beforeNewFrame(app: *App) void {
    // Start commands only after a few complete frames: ImGui needs 2-3 frames to lay out windows.
    if (cur == null and app.frame_count >= 3 and has_request.load(.acquire)) {
        lock.lock();
        const line = request.?;
        request = null;
        lock.unlock();
        has_request.store(false, .release);
        begin(app, line);
    }
    if (cur != null) stepCmd(app);
}

pub fn afterRender(app: *App) void {
    const c = &(cur orelse return);
    if (c.kind != .screenshot or c.step != 1) return;
    saveBackbuffer(app, c.arg) catch |e| return fail("screenshot failed: {t}", .{e});
    ok();
}

fn begin(app: *App, line: []u8) void {
    const sp = std.mem.findScalar(u8, line, ' ') orelse line.len;
    const kind = std.meta.stringToEnum(Kind, line[0..sp]) orelse {
        defer gpa.free(line);
        cur = .{ .kind = .list, .arg = gpa.dupe(u8, "") catch unreachable };
        return fail("unknown command '{s}'", .{line[0..sp]});
    };
    const arg = gpa.dupe(u8, std.mem.trim(u8, line[sp..], " ")) catch unreachable;
    gpa.free(line);
    cur = .{ .kind = kind, .arg = arg, .q = arg };
    const c = &cur.?;
    switch (kind) {
        .list => finish(listJson() catch unreachable),
        .quit => {
            ok();
            app.quit();
        },
        .click, .dblclick, .rclick, .hover => {
            var at: ?[]const u8 = null;
            if (std.mem.findLast(u8, c.q, " @")) |i| {
                at = c.q[i + 2 ..];
                c.q = std.mem.trimEnd(u8, c.q[0..i], " ");
            }
            const it = findItem(c.q) catch |e| return failFind(e, c.q);
            if (it.visible == 0) return fail("item '{s}' is not visible", .{c.q});
            if (kind != .hover and it.item_flags & im.ImGuiItemFlags_Disabled != 0) return fail("item '{s}' is disabled", .{c.q});
            c.pos = .{ .x = (it.x0 + it.x1) / 2, .y = (it.y0 + it.y1) / 2 };
            if (at) |a| c.pos.x = offsetX(it, a) orelse return fail("bad offset '@{s}' (use @12, @-12 or @75%)", .{a});
        },
        .key => parseKey(c) catch return fail("bad key chord '{s}'", .{c.arg}),
        .wait => {
            var timeout: u64 = 5000;
            if (std.mem.findScalarLast(u8, c.arg, ' ')) |i| {
                if (std.fmt.parseInt(u64, c.arg[i + 1 ..], 10)) |t| {
                    timeout = t;
                    c.q = std.mem.trimEnd(u8, c.arg[0..i], " ");
                } else |_| {}
            }
            c.n = w.GetTickCount64() + timeout;
        },
        .frames => c.n = std.fmt.parseInt(u64, c.arg, 10) catch return fail("bad frame count '{s}'", .{c.arg}),
        .type, .screenshot => {},
    }
}

fn stepCmd(app: *App) void {
    const c = &cur.?;
    const io = im.ImGui_GetIO();
    defer if (cur) |*cc| {
        cc.step += 1;
    };
    switch (c.kind) {
        .list, .quit => {},
        .click, .rclick => {
            const btn: c_int = if (c.kind == .rclick) 1 else 0;
            switch (c.step) {
                0 => im.ImGuiIO_AddMousePosEvent(io, c.pos.x, c.pos.y),
                1 => im.ImGuiIO_AddMouseButtonEvent(io, btn, true),
                2 => im.ImGuiIO_AddMouseButtonEvent(io, btn, false),
                else => ok(),
            }
        },
        .dblclick => switch (c.step) {
            0 => im.ImGuiIO_AddMousePosEvent(io, c.pos.x, c.pos.y),
            1, 3 => im.ImGuiIO_AddMouseButtonEvent(io, 0, true),
            2, 4 => im.ImGuiIO_AddMouseButtonEvent(io, 0, false),
            else => ok(),
        },
        .hover => switch (c.step) {
            0 => im.ImGuiIO_AddMousePosEvent(io, c.pos.x, c.pos.y),
            else => ok(),
        },
        .type => switch (c.step) {
            0 => {
                const z = gpa.dupeSentinel(u8, c.arg, 0) catch unreachable;
                defer gpa.free(z);
                im.ImGuiIO_AddInputCharactersUTF8(io, z.ptr);
            },
            else => ok(),
        },
        .key => switch (c.step) {
            0 => {
                for (c.mods[0..c.nmods]) |m| im.ImGuiIO_AddKeyEvent(io, m, true);
                im.ImGuiIO_AddKeyEvent(io, c.key, true);
            },
            1 => {
                im.ImGuiIO_AddKeyEvent(io, c.key, false);
                for (c.mods[0..c.nmods]) |m| im.ImGuiIO_AddKeyEvent(io, m, false);
            },
            else => ok(),
        },
        .wait => {
            if (findItem(c.q)) |it| {
                finish(itemJsonAlloc(it) catch unreachable);
            } else |e| {
                if (e == error.Ambiguous) {
                    finish(gpa.dupe(u8, "{\"ok\":true,\"ambiguous\":true}") catch unreachable);
                } else if (w.GetTickCount64() > c.n) fail("timeout waiting for '{s}'", .{c.q});
            }
        },
        .frames => {
            if (c.step >= c.n) finish(std.json.Stringify.valueAlloc(gpa, .{ .ok = true, .frame = app.frame_count }, .{}) catch unreachable);
        },
        .screenshot => {}, // step 0 -> this frame renders; afterRender() captures at step 1
    }
}

/// `@x` of click/hover: "12" px from the left edge, "-12" from the right, "75%" of the width.
fn offsetX(it: MkteItem, a: []const u8) ?f32 {
    if (std.mem.endsWith(u8, a, "%")) {
        const pct = std.fmt.parseFloat(f32, a[0 .. a.len - 1]) catch return null;
        return it.x0 + (it.x1 - it.x0) * pct / 100;
    }
    const px = std.fmt.parseFloat(f32, a) catch return null;
    return if (a[0] == '-') it.x1 + px else it.x0 + px;
}

fn parseKey(c: *Cmd) !void {
    var it = std.mem.splitScalar(u8, c.arg, '+');
    var last: []const u8 = "";
    while (it.next()) |part| {
        if (it.peek() == null) {
            last = part;
            break;
        }
        const m: c_int = if (std.ascii.eqlIgnoreCase(part, "ctrl")) im.ImGuiMod_Ctrl else if (std.ascii.eqlIgnoreCase(part, "shift")) im.ImGuiMod_Shift else if (std.ascii.eqlIgnoreCase(part, "alt")) im.ImGuiMod_Alt else if (std.ascii.eqlIgnoreCase(part, "super")) im.ImGuiMod_Super else return error.BadKey;
        if (c.nmods == c.mods.len) return error.BadKey;
        c.mods[c.nmods] = m;
        c.nmods += 1;
    }
    if (std.mem.startsWith(u8, last, "ImGuiKey_")) last = last["ImGuiKey_".len..];
    var k: c_int = im.ImGuiKey_NamedKey_BEGIN;
    while (k < im.ImGuiKey_NamedKey_END) : (k += 1) {
        if (std.ascii.eqlIgnoreCase(std.mem.span(im.ImGui_GetKeyName(k)), last)) {
            c.key = k;
            return;
        }
    }
    return error.BadKey;
}

// ---------------------------------------------------------------- item lookup / JSON

fn items() []const MkteItem {
    const n: usize = @intCast(mkte_item_count());
    return if (mkte_items()) |p| p[0..n] else &.{};
}

fn poolStr(off: c_int) []const u8 {
    if (off < 0) return "";
    const p = mkte_pool() orelse return "";
    return std.mem.span(@as([*:0]const u8, @ptrCast(p + @as(usize, @intCast(off)))));
}

const FindError = error{ NotFound, Ambiguous };

/// Root window that has keyboard focus (an open modal, when there is one); "" when none.
fn focusedWindow() []const u8 {
    const n: usize = @intCast(mkte_window_count());
    if (mkte_windows()) |ws| for (ws[0..n]) |win_| {
        if (win_.focused != 0) return std.mem.span(win_.name);
    };
    return "";
}

/// Ties between several matches go to the only visible one, else to the only visible one in the focused
/// window (e.g. "Delete" in an open message box over a page that has a "Delete##x" button too).
fn findItem(q: []const u8) FindError!MkteItem {
    const all = items();
    const focused = focusedWindow();
    const Stage = enum { exact, text, id_suffix, substring };
    for ([_]Stage{ .exact, .text, .id_suffix, .substring }) |stage| {
        if (stage == .text and std.mem.find(u8, q, "##") != null) continue;
        if (stage == .id_suffix and !std.mem.startsWith(u8, q, "##")) continue;
        var first: ?MkteItem = null;
        var first_visible: ?MkteItem = null;
        var distinct: usize = 0;
        var distinct_visible: usize = 0;
        var first_focused: ?MkteItem = null;
        var distinct_focused: usize = 0;
        for (all, 0..) |it, i| {
            const label = poolStr(it.label);
            if (label.len == 0) continue;
            const hit = switch (stage) {
                .exact => std.mem.eql(u8, label, q),
                .text => std.mem.eql(u8, label[0 .. std.mem.find(u8, label, "##") orelse label.len], q),
                .id_suffix => std.mem.endsWith(u8, label, q),
                .substring => std.mem.find(u8, label, q) != null,
            };
            if (!hit) continue;
            // count distinct ids (an item can be registered twice in one frame)
            const dup = for (all[0..i]) |prev| {
                if (prev.id == it.id and prev.label >= 0 and std.mem.eql(u8, poolStr(prev.label), label)) break true;
            } else false;
            if (dup) continue;
            distinct += 1;
            if (first == null) first = it;
            if (it.visible != 0) {
                distinct_visible += 1;
                if (first_visible == null) first_visible = it;
                if (std.mem.eql(u8, poolStr(it.window), focused)) {
                    distinct_focused += 1;
                    if (first_focused == null) first_focused = it;
                }
            }
        }
        if (distinct == 1) return first.?;
        if (distinct > 1) {
            if (distinct_visible == 1) return first_visible.?;
            if (distinct_focused == 1) return first_focused.?;
            return error.Ambiguous;
        }
    }
    return error.NotFound;
}

fn failFind(e: FindError, q: []const u8) void {
    switch (e) {
        error.NotFound => fail("item '{s}' not found", .{q}),
        error.Ambiguous => fail("item '{s}' is ambiguous (use the full label or its ##id)", .{q}),
    }
}

const ItemJson = struct {
    id: u32,
    label: []const u8,
    window: []const u8,
    x0: f32,
    y0: f32,
    x1: f32,
    y1: f32,
    visible: bool,
    disabled: bool,
    checkable: bool,
    checked: bool,
    openable: bool,
    opened: bool,
    inputable: bool,
    edited: bool,
    /// Selected Selectable row / the tab whose content is shown.
    selected: bool,
    /// Drawn with ImGuiItemFlags_MixedValue (kit.ui.triCheckbox in state .mixed).
    mixed: bool,
    /// Readable text: InputText* buffer (not passwords), combo preview, kit.ui.text; null when none.
    value: ?[]const u8,
};

fn itemJson(it: MkteItem) ItemJson {
    return .{
        .id = it.id,
        .label = poolStr(it.label),
        .window = poolStr(it.window),
        .x0 = it.x0,
        .y0 = it.y0,
        .x1 = it.x1,
        .y1 = it.y1,
        .visible = it.visible != 0,
        .disabled = it.item_flags & im.ImGuiItemFlags_Disabled != 0,
        .checkable = it.status & ST_CHECKABLE != 0,
        .checked = it.status & ST_CHECKED != 0,
        .openable = it.status & ST_OPENABLE != 0,
        .opened = it.status & ST_OPENED != 0,
        .inputable = it.status & ST_INPUTABLE != 0,
        .edited = it.status & ST_EDITED != 0,
        .selected = it.status & ST_SELECTED != 0,
        .mixed = it.item_flags & im.ImGuiItemFlags_MixedValue != 0,
        .value = if (it.value >= 0) poolStr(it.value) else null,
    };
}

fn itemJsonAlloc(it: MkteItem) ![]u8 {
    return std.json.Stringify.valueAlloc(gpa, .{ .ok = true, .item = itemJson(it) }, .{});
}

const WindowJson = struct { name: []const u8, x0: f32, y0: f32, x1: f32, y1: f32, focused: bool, popup: bool, child: bool };

fn listJson() ![]u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const all = items();
    const out = try a.alloc(ItemJson, all.len);
    var n: usize = 0;
    for (all) |r| {
        if (r.label < 0) continue; // unlabeled internals (scrollbars, resize grips, ...)
        out[n] = itemJson(r);
        n += 1;
    }
    const wn: usize = @intCast(mkte_window_count());
    const wins = try a.alloc(WindowJson, wn);
    if (mkte_windows()) |ws| for (ws[0..wn], wins) |src, *d| {
        d.* = .{
            .name = std.mem.span(src.name),
            .x0 = src.x0,
            .y0 = src.y0,
            .x1 = src.x1,
            .y1 = src.y1,
            .focused = src.focused != 0,
            .popup = src.flags & im.ImGuiWindowFlags_Popup != 0,
            .child = src.flags & im.ImGuiWindowFlags_ChildWindow != 0,
        };
    };
    return std.json.Stringify.valueAlloc(gpa, .{ .ok = true, .frame = g_app.frame_count, .items = out[0..n], .windows = wins }, .{});
}

// ---------------------------------------------------------------- screenshot (back buffer -> 32-bit BMP)

fn saveBackbuffer(app: *App, path: []const u8) !void {
    const dev = app.device;
    const ctx = app.context;
    var back: [*c]w.ID3D11Texture2D = null;
    try win.check(app.swapchain.*.lpVtbl.*.GetBuffer.?(app.swapchain, 0, &w.IID_ID3D11Texture2D, @ptrCast(&back)));
    defer win.release(back);
    var desc: w.D3D11_TEXTURE2D_DESC = undefined;
    back.*.lpVtbl.*.GetDesc.?(back, &desc);
    desc.Usage = w.D3D11_USAGE_STAGING;
    desc.BindFlags = 0;
    desc.CPUAccessFlags = @intCast(w.D3D11_CPU_ACCESS_READ);
    desc.MiscFlags = 0;
    var staging: [*c]w.ID3D11Texture2D = null;
    try win.check(dev.*.lpVtbl.*.CreateTexture2D.?(dev, &desc, null, &staging));
    defer win.release(staging);
    ctx.*.lpVtbl.*.CopyResource.?(ctx, @ptrCast(staging), @ptrCast(back));
    var map: w.D3D11_MAPPED_SUBRESOURCE = undefined;
    try win.check(ctx.*.lpVtbl.*.Map.?(ctx, @ptrCast(staging), 0, w.D3D11_MAP_READ, 0, &map));
    defer ctx.*.lpVtbl.*.Unmap.?(ctx, @ptrCast(staging), 0);

    const width: u32 = desc.Width;
    const height: u32 = desc.Height;
    const row_bytes = width * 4;
    const pixels = try gpa.alloc(u8, row_bytes * height);
    defer gpa.free(pixels);
    const src: [*]const u8 = @ptrCast(map.pData.?);
    const bgra_src = desc.Format == w.DXGI_FORMAT_B8G8R8A8_UNORM;
    for (0..height) |y| {
        const s = src[y * map.RowPitch ..][0..row_bytes];
        const d = pixels[y * row_bytes ..][0..row_bytes];
        var x: usize = 0;
        while (x < row_bytes) : (x += 4) {
            d[x + 0] = if (bgra_src) s[x + 0] else s[x + 2];
            d[x + 1] = s[x + 1];
            d[x + 2] = if (bgra_src) s[x + 2] else s[x + 0];
            d[x + 3] = 255;
        }
    }

    var hdr: [54]u8 = @splat(0);
    hdr[0] = 'B';
    hdr[1] = 'M';
    std.mem.writeInt(u32, hdr[2..6], 54 + @as(u32, @intCast(pixels.len)), .little);
    std.mem.writeInt(u32, hdr[10..14], 54, .little);
    std.mem.writeInt(u32, hdr[14..18], 40, .little); // BITMAPINFOHEADER
    std.mem.writeInt(i32, hdr[18..22], @intCast(width), .little);
    std.mem.writeInt(i32, hdr[22..26], -@as(i32, @intCast(height)), .little); // top-down
    std.mem.writeInt(u16, hdr[26..28], 1, .little);
    std.mem.writeInt(u16, hdr[28..30], 32, .little);
    std.mem.writeInt(u32, hdr[34..38], @intCast(pixels.len), .little);

    const wpath = try win.toW(gpa, path);
    defer gpa.free(wpath);
    const f = w.CreateFileW(wpath.ptr, w.GENERIC_WRITE, 0, null, w.CREATE_ALWAYS, w.FILE_ATTRIBUTE_NORMAL, null);
    if (f == w.INVALID_HANDLE_VALUE) return error.CreateFileFailed;
    defer _ = w.CloseHandle(f);
    for ([_][]const u8{ &hdr, pixels }) |part| {
        var wr: w.DWORD = 0;
        if (w.WriteFile(f, part.ptr, @intCast(part.len), &wr, null) == 0 or wr != part.len) return error.WriteFailed;
    }
}
