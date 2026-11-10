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
    const app = try kit.app.App.init(init.gpa, .{ .title = "MakeCleaner", .palette = kit.app.palettes.cleaner });
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
                if (kit.ui.iconButton(kit.ui.icons.refresh, "Scan##scan", "Start scanning")) s.clicks += 1;
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
    while (!job.isFinished()) std.atomic.spinLoopHint(); // UI: poll once per frame instead
    job.join();
    try testing.expectEqual(@as(f32, 1), job.progress());
}
