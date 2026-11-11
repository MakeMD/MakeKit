//! Compiled + run snippets of docs/ZIG-0.17-NOTES.md (run by `zig build test`).
//! std-only snippets live in notes_std.zig; this file holds the kit / Win32 / COM / ImGui ones.
//! Keep the markdown in sync: every ```zig block in the KIT sections is copied from here.
const std = @import("std");
const testing = std.testing;
const kit = @import("kit");
const w = kit.w;
const im = kit.im;

test {
    _ = @import("notes_std.zig");
}

// ---- K1. Calling COM through `w` (CINTERFACE: struct with lpVtbl; methods are optional fn ptrs)
test "K1 call COM: IShellItem from a path" {
    try kit.win.comInitSta();
    defer kit.win.comUninit();

    var item: [*c]w.IShellItem = null; // COM out-param: pointer to a [*c] interface pointer
    try kit.win.check(w.SHCreateItemFromParsingName(kit.win.L("C:\\Windows"), null, &w.IID_IShellItem, @ptrCast(&item)));
    defer _ = item.*.lpVtbl.*.Release.?(item); // or kit.win.release(item)

    var name: w.LPWSTR = null;
    // p.*.lpVtbl.*.Method.?(p, args...)  -- `.?` because translated vtable entries are ?*const fn
    try kit.win.check(item.*.lpVtbl.*.GetDisplayName.?(item, w.SIGDN_FILESYSPATH, &name));
    defer w.CoTaskMemFree(name);
    const utf8 = try kit.win.fromWZ(testing.allocator, @ptrCast(name));
    defer testing.allocator.free(utf8);
    try testing.expect(std.ascii.eqlIgnoreCase(utf8, "C:\\Windows"));
}

// ---- K2. Implementing a COM object in Zig (IDropSource; IUnknown part is generic)
const DropSource = extern struct {
    // The interface struct MUST be the first field: COM sees a pointer to it.
    iface: w.IDropSource = .{ .lpVtbl = @constCast(&vtbl) },
    refs: u32 = 1,

    const vtbl: w.IDropSourceVtbl = .{
        .QueryInterface = queryInterface,
        .AddRef = addRef,
        .Release = release,
        .QueryContinueDrag = queryContinueDrag,
        .GiveFeedback = giveFeedback,
    };

    fn self(this: [*c]w.IDropSource) *DropSource {
        return @fieldParentPtr("iface", @as(*w.IDropSource, @ptrCast(this)));
    }
    fn queryInterface(this: [*c]w.IDropSource, riid: [*c]const w.IID, out: [*c]?*anyopaque) callconv(.c) w.HRESULT {
        if (guidEql(riid.*, w.IID_IUnknown) or guidEql(riid.*, w.IID_IDropSource)) {
            out.* = this;
            _ = addRef(this);
            return w.S_OK;
        }
        out.* = null;
        return w.E_NOINTERFACE;
    }
    fn addRef(this: [*c]w.IDropSource) callconv(.c) w.ULONG {
        const s = self(this);
        s.refs += 1; // ponytail: single-threaded (STA) object; use std.atomic.Value for free-threaded
        return s.refs;
    }
    fn release(this: [*c]w.IDropSource) callconv(.c) w.ULONG {
        const s = self(this);
        s.refs -= 1;
        return s.refs; // heap objects: destroy when it reaches 0
    }
    fn queryContinueDrag(_: [*c]w.IDropSource, escape: w.WINBOOL, keys: w.DWORD) callconv(.c) w.HRESULT {
        if (escape != 0) return w.DRAGDROP_S_CANCEL;
        if (keys & w.MK_LBUTTON == 0) return w.DRAGDROP_S_DROP;
        return w.S_OK;
    }
    fn giveFeedback(_: [*c]w.IDropSource, _: w.DWORD) callconv(.c) w.HRESULT {
        return w.DRAGDROP_S_USEDEFAULTCURSORS;
    }
};

fn guidEql(a: w.GUID, b: w.GUID) bool {
    return std.mem.eql(u8, std.mem.asBytes(&a), std.mem.asBytes(&b));
}

test "K2 implement COM: Zig IDropSource called by Windows (IBindCtx AddRef/Release)" {
    try kit.win.comInitSta();
    defer kit.win.comUninit();
    var ds: DropSource = .{};
    const unk: [*c]w.IUnknown = @ptrCast(&ds.iface);

    // Windows calls our AddRef when we hand the object to a bind context ...
    var bc: [*c]w.IBindCtx = null;
    try kit.win.check(w.CreateBindCtx(0, &bc));
    try kit.win.check(bc.*.lpVtbl.*.RegisterObjectParam.?(bc, @constCast(kit.win.L("obj")), unk));
    try testing.expectEqual(@as(u32, 2), ds.refs);
    // ... and our Release when it lets go.
    _ = bc.*.lpVtbl.*.Release.?(bc);
    try testing.expectEqual(@as(u32, 1), ds.refs);

    // QueryInterface through the vtable, like any COM client would.
    var p: ?*anyopaque = null;
    try kit.win.check(ds.iface.lpVtbl.*.QueryInterface.?(&ds.iface, &w.IID_IDropSource, &p));
    try testing.expect(p == @as(?*anyopaque, @ptrCast(&ds.iface)));
    try testing.expectEqual(w.E_NOINTERFACE, ds.iface.lpVtbl.*.QueryInterface.?(&ds.iface, &w.IID_IShellItem, &p));
    _ = ds.iface.lpVtbl.*.Release.?(&ds.iface);
    try testing.expectEqual(w.DRAGDROP_S_CANCEL, ds.iface.lpVtbl.*.QueryContinueDrag.?(&ds.iface, 1, 0));
}

// ---- K3. GUIDs and HRESULTs
fn guid(comptime s: []const u8) w.GUID {
    const g = comptime std.os.windows.GUID.parse(s); // std GUID and w.GUID are different types
    return .{ .Data1 = g.Data1, .Data2 = g.Data2, .Data3 = g.Data3, .Data4 = g.Data4 };
}

test "K3 GUID constants and HRESULT checks" {
    // IIDs/CLSIDs/FOLDERIDs come from libuuid/libdxguid as `extern const` (linked by the kit).
    const iid_unknown = guid("{00000000-0000-0000-C000-000000000046}");
    try testing.expect(guidEql(iid_unknown, w.IID_IUnknown));

    const hr: w.HRESULT = w.E_NOINTERFACE; // HRESULT = c_long (i32); failure = negative
    try testing.expect(hr < 0 and w.S_OK == 0);
    try testing.expectError(error.ComFailed, kit.win.check(hr));
    try testing.expectEqual(hr, kit.win.last_hr); // last failing HRESULT on this thread
    try testing.expectEqual(@as(u32, 0x80004002), @as(u32, @bitCast(hr))); // print as hex: {x}
}

// ---- K4. translate_c gotchas in `w`
/// Integer smuggled in a pointer (HKEY_*, MAKEINTRESOURCE ids). `v` must be a runtime value:
/// with a comptime-known value Zig checks the alignment at compile time and rejects it.
fn intPtr(comptime T: type, v: usize) T {
    @setRuntimeSafety(false);
    return @ptrFromInt(v);
}

test "K4 translated Win32 constants: casts you will need" {
    // Macro constants are mostly c_int; Win32 params are DWORD/UINT (c_ulong/c_uint) -> @intCast.
    const flags: w.DWORD = @intCast(w.FOF_ALLOWUNDO | w.FOF_NOCONFIRMATION);
    try testing.expect(flags != 0);
    // Predefined handles that are odd integers (HKEY_CURRENT_USER, HWND_TOPMOST, ...) do NOT compile:
    // the comptime int->pointer cast fails the alignment check. Build them at runtime (intPtr below).
    const hkcu = intPtr(w.HKEY, 0x80000001);
    var k: w.HKEY = null;
    try testing.expectEqual(@as(w.LSTATUS, 0), w.RegOpenKeyExW(hkcu, kit.win.L("Software"), 0, @intCast(w.KEY_READ), &k));
    _ = w.RegCloseKey(k);
    // MAKEINTRESOURCE / A-W alias macros (IDC_ARROW, CreateWindowEx, MessageBox) do not translate:
    // call the ...W function and pass the resource id as a pointer built the same way.
    const IDC_ARROW = intPtr(w.LPCWSTR, 32512);
    try testing.expect(w.LoadCursorW(null, IDC_ARROW) != null);
    // Callbacks: Win32 callback types are `?*const fn (...) callconv(.c)`; on x86_64 .c == .winapi.
}

// ---- K5. Dear ImGui through `im` (dear_bindings naming)
test "K5 ImGui widgets via im (headless frame)" {
    const ctx = im.ImGui_CreateContext(null);
    defer im.ImGui_DestroyContext(ctx);
    const io = im.ImGui_GetIO();
    io.*.DisplaySize = .{ .x = 800, .y = 600 };
    io.*.DeltaTime = 1.0 / 60.0;
    io.*.IniFilename = null;
    io.*.BackendFlags |= im.ImGuiBackendFlags_RendererHasTextures; // headless: nobody uploads the atlas

    var check = true;
    var combo_idx: usize = 0;
    var name: [64:0]u8 = @splat(0); // InputText edits a fixed, NUL-terminated buffer in place
    var open_modal = true;
    var modal_shown = false;
    for (0..2) |_| {
        im.ImGui_NewFrame();
        // Function names: ImGui_X(...) uses default args; ImGui_XEx(...) takes all of them.
        if (im.ImGui_Begin("Window##id", null, im.ImGuiWindowFlags_MenuBar)) {
            if (im.ImGui_BeginMenuBar()) {
                if (im.ImGui_BeginMenu("File")) {
                    if (im.ImGui_MenuItem("Quit")) {}
                    im.ImGui_EndMenu();
                }
                im.ImGui_EndMenuBar();
            }
            // Text: format in Zig, then TextUnformatted (ImGui_Text is C varargs printf).
            var buf: [64]u8 = undefined;
            const line = try std.mem.printSentinel(&buf, "{d} files, {s}", .{ 42, "Їжак" }, 0);
            im.ImGui_TextUnformatted(line.ptr);
            _ = im.ImGui_Checkbox("Enabled##chk", &check);
            const items = [_][*:0]const u8{ "Fast", "Normal", "Ultra" };
            if (im.ImGui_BeginCombo("Level##lvl", items[combo_idx], 0)) {
                for (items, 0..) |it, i| {
                    if (im.ImGui_SelectableEx(it, i == combo_idx, 0, .{ .x = 0, .y = 0 })) combo_idx = i;
                }
                im.ImGui_EndCombo();
            }
            _ = im.ImGui_InputText("Name##name", &name, name.len, 0);
            if (im.ImGui_BeginTable("tbl", 2, im.ImGuiTableFlags_Borders | im.ImGuiTableFlags_RowBg)) {
                im.ImGui_TableSetupColumn("Key", 0);
                im.ImGui_TableSetupColumn("Value", 0);
                im.ImGui_TableHeadersRow();
                for (0..3) |row| {
                    im.ImGui_PushIDInt(@intCast(row)); // unique ids for repeated labels
                    im.ImGui_TableNextRow();
                    _ = im.ImGui_TableNextColumn();
                    _ = im.ImGui_Selectable("row");
                    _ = im.ImGui_TableNextColumn();
                    im.ImGui_TextUnformatted("value");
                    im.ImGui_PopID();
                }
                im.ImGui_EndTable();
            }
            if (im.ImGui_TreeNode("Details")) {
                im.ImGui_TextUnformatted("inside");
                im.ImGui_TreePop();
            }
            if (open_modal) {
                _ = im.ImGui_OpenPopup("Confirm##modal", 0); // once, not every frame
                open_modal = false;
            }
            if (im.ImGui_BeginPopupModal("Confirm##modal", null, im.ImGuiWindowFlags_AlwaysAutoResize)) {
                modal_shown = true;
                if (im.ImGui_Button("OK")) im.ImGui_CloseCurrentPopup();
                im.ImGui_EndPopup();
            }
        }
        im.ImGui_End(); // End() always, even when Begin() returned false (BeginX/EndX pairs differ!)
        im.ImGui_Render();
    }
    // Only call ImGui between NewFrame and Render (e.g. IsPopupOpen here would crash: no window).
    try testing.expect(modal_shown);
    // Colors: style.Colors is [ImGuiCol_COUNT]ImVec4 indexed by c_int enum constants.
    const style = im.ImGui_GetStyle();
    style.*.Colors[@intCast(im.ImGuiCol_Text)] = kit.app.color(0x1D232B, 1);
}

// ---- K6. App skeleton (compiled, not run: it opens a window)
fn exampleAppMain(init: std.process.Init) !void {
    const State = struct { clicks: u32 = 0 };
    var state: State = .{};
    const app = try kit.app.App.init(init.gpa, .{ .title = "MakeCleaner", .palette = kit.app.palettes.carbon });
    defer app.deinit();
    app.run(.{
        .user = &state,
        .frame = struct {
            fn frame(a: *kit.app.App) void {
                const s = a.userData(State);
                const vp = im.ImGui_GetMainViewport();
                im.ImGui_SetNextWindowPos(vp.*.WorkPos, 0);
                im.ImGui_SetNextWindowSize(vp.*.WorkSize, 0);
                _ = im.ImGui_Begin("Main##main", null, im.ImGuiWindowFlags_NoDecoration | im.ImGuiWindowFlags_NoMove);
                defer im.ImGui_End();
                // kit icon (16 logical px, DPI-exact) + label; ImGui label "Scan##scan"
                if (kit.ui.iconButton("scan", .cleaner, 16, "Scan")) s.clicks += 1;
                im.ImGui_SetItemTooltip("Start scanning");
                if (kit.ui.primaryButton("Clean##clean")) s.clicks += 1; // mint fill, anthracite text
                kit.ui.icon(.warning, 24);
                if (kit.icons.get(.drive, 16)) |tex| im.ImGui_Image(tex, .{ .x = kit.icons.pixels(16), .y = kit.icons.pixels(16) });
            }
        }.frame,
    });
}

test "K6 app skeleton type-checks" {
    _ = &exampleAppMain; // `&` forces semantic analysis of the body
}

// ---- K7. Background job polled by the UI
fn scan(job: *kit.jobs.Job) anyerror!void {
    job.setTotal(100);
    for (0..100) |i| {
        if (job.cancelled()) return error.Canceled; // Canceled = no error text
        job.setStatus("file {d}", .{i});
        job.addDone(1); // wakes the UI thread, throttled to ~30/s
    }
}

test "K7 jobs.Job" {
    var job: kit.jobs.Job = .{};
    try job.start(null, scan); // `user` ptr -> job.ctx(T) in the worker
    // UI, once per frame: true exactly once per run, then the thread is joined
    while (!job.takeFinished()) std.atomic.spinLoopHint();
    try testing.expectEqual(@as(f32, 1), job.progress());
}

// ---- K10. Languages: one strings table per language + the tr() accessor
const i18n = kit.i18n;

// src/i18n/en.zig: the type (one field per string, plurals = i18n.Forms) and the English values.
const Strings = struct {
    delete_q: [:0]const u8,
    files: i18n.Forms,
};
const en: Strings = .{ .delete_q = "Delete {0}?", .files = .{ .one = "{0} file", .other = "{0} files" } };
// src/i18n/uk.zig ... fr.zig: `pub const t: en.Strings = .{...}` (missing or extra field = compile error)
const uk: Strings = .{ .delete_q = "Видалити {0}?", .files = .{ .one = "{0} файл", .few = "{0} файли", .many = "{0} файлів" } };
const pl: Strings = .{ .delete_q = "Usunąć {0}?", .files = .{ .one = "{0} plik", .few = "{0} pliki", .many = "{0} plików" } };
const de: Strings = .{ .delete_q = "{0} löschen?", .files = .{ .one = "{0} Datei", .other = "{0} Dateien" } };
const es: Strings = .{ .delete_q = "¿Eliminar {0}?", .files = .{ .one = "{0} archivo", .other = "{0} archivos" } };
const fr: Strings = .{ .delete_q = "Supprimer {0}\u{A0}?", .files = .{ .one = "{0} fichier", .other = "{0} fichiers" } };

// A language without a table is a compile error (EnumArray.init wants every Lang).
const tables = std.enums.EnumArray(i18n.Lang, *const Strings).init(.{ .en = &en, .uk = &uk, .pl = &pl, .de = &de, .es = &es, .fr = &fr });
fn tr() *const Strings {
    return tables.get(i18n.current()); // one atomic load: fine every frame
}

test "K10 kit.i18n: tables, plurals, {0} templates" {
    // App test: every table has the plural forms its language needs and the same {N} as English.
    for (i18n.all) |l| try testing.expectEqual(null, i18n.check(Strings, &en, tables.get(l), l));

    const saved = "pl"; // persist `if (pref) |l| l.code() else "auto"`; read back with Lang.parse
    const pref: ?i18n.Lang = .parse(saved); // "auto" / unknown -> null = Auto
    i18n.apply(pref); // MAKEKIT_LANG > pref > Windows UI language > en
    defer i18n.set(.en);
    if (i18n.forced() == null) try testing.expectEqual(i18n.Lang.pl, i18n.current());
    i18n.set(.pl);

    var nb: [32]u8 = undefined;
    var buf: [64]u8 = undefined;
    const n: u64 = 5;
    const files = i18n.fmt(&nb, i18n.pick(tr().files, n), .{n}); // pl: 5 -> many
    try testing.expectEqualStrings("Usunąć 5 plików?", i18n.fmt(&buf, tr().delete_q, .{files}));
    i18n.set(.uk);
    try testing.expectEqualStrings("22 файли", i18n.fmt(&nb, i18n.pick(tr().files, 22), .{22}));
    try testing.expectEqualStrings("Українська", i18n.Lang.uk.name());
}

// ---- K11. Updates (kit.update + MakeUpdate.exe)
const Upd = struct {
    checker: kit.update.Checker = .{},
    updater: []const u8 = "", // kit.update.updaterPath(gpa, io), kept by the app
    found: ?std.json.Parsed(kit.update.Result) = null, // the newer release the banner offers
    skipped: [32]u8 = @splat(0), // "Later" = skip this version (persist it next to UpdateCheck / last check)
};

fn updateOnStartup(u: *Upd, gpa: std.mem.Allocator, io: std.Io, setting_on: bool, last_check: i64) void {
    const now = std.Io.Timestamp.now(io, .real).toSeconds();
    if (!setting_on or kit.update.disabled() or !kit.update.due(last_check, now)) return;
    u.checker.start(gpa, io, u.updater, "MakeMD/MakeCleaner", "2.1.0") catch {}; // background: kit.jobs
}

fn updateFrame(a: *kit.app.App, u: *Upd, gpa: std.mem.Allocator, io: std.Io) void {
    if (u.checker.poll()) |res| { // once, when the check is over: save last_check = now (also after errors)
        if (res) |r| {
            const skip = std.mem.eql(u8, r.value.latest, std.mem.sliceTo(&u.skipped, 0));
            if (r.value.ok and r.value.newer and !skip) u.found = r else r.deinit(); // !ok = offline etc.: stay quiet
        } else |_| {}
    }
    const r = u.found orelse return;
    var buf: [128]u8 = undefined;
    const text: []const u8 = std.mem.print(&buf, "Version {s} is available", .{r.value.latest}) catch "";
    const action = kit.update.banner(.{ .text = text, .update = "Update now", .notes = "Release notes", .later = "Later" }) orelse return;
    switch (action) {
        .update => if (kit.update.isPortable(gpa, io)) {
            _ = kit.win.shellExecute(gpa, .{ .file = r.value.page }) catch null; // portable: the page, no installer
        } else {
            const self = std.process.executablePathAlloc(io, gpa) catch return;
            defer gpa.free(self);
            kit.update.install(io, u.updater, "MakeMD/MakeCleaner", r.value.tag, self) catch return;
            a.quit(); // MakeUpdate waits for this PID, installs silently, starts `self` again
        },
        .notes => _ = kit.win.shellExecute(gpa, .{ .file = r.value.page }) catch null,
        .later => {
            const n = @min(r.value.latest.len, u.skipped.len - 1);
            u.skipped = @splat(0);
            @memcpy(u.skipped[0..n], r.value.latest[0..n]);
            r.deinit();
            u.found = null;
        },
    }
}

test "K11 kit.update: due, the MakeUpdate line, versions" {
    _ = &updateOnStartup;
    _ = &updateFrame;
    try testing.expect(kit.update.due(0, 1_800_000_000)); // never checked
    try testing.expect(!kit.update.due(1_800_000_000, 1_800_000_000 + 3600)); // checked 1 h ago
    const r = try kit.update.parseLine(testing.allocator,
        \\{"ok":true,"newer":true,"latest":"2.1.0","tag":"v2.1.0","page":"https://github.com/MakeMD/MakeCleaner/releases/tag/v2.1.0"}
    );
    defer r.deinit();
    try testing.expect(r.value.ok and r.value.newer and r.value.@"error".len == 0);
    try testing.expectEqual(true, kit.update.isNewer("2.10.0", "2.9.1")); // numeric x.y.z, "v" prefix ok
}
