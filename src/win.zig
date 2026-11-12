//! Small Win32 helpers on top of the translated `w` module (utf8 <-> utf16, HRESULT, COM, registry,
//! shell, file dialogs, recycle bin, process/OS info). All strings in/out are UTF-8; results are
//! allocated with the caller's allocator.
const std = @import("std");
pub const w = @import("w");

const Allocator = std.mem.Allocator;

// ---------------------------------------------------------------- UTF-8 <-> UTF-16

/// Comptime UTF-16 literal: `L("Hello")` -> `*const [5:0]u16`.
pub const L = std.unicode.utf8ToUtf16LeStringLiteral;

/// UTF-8 -> NUL-terminated UTF-16 (caller frees).
pub fn toW(gpa: Allocator, s: []const u8) ![:0]u16 {
    return std.unicode.wtf8ToWtf16LeAllocZ(gpa, s);
}

/// UTF-16 slice -> UTF-8 (caller frees). Unpaired surrogates become WTF-8 (never fails on bad input).
pub fn fromW(gpa: Allocator, s: []const u16) ![]u8 {
    return std.unicode.wtf16LeToWtf8Alloc(gpa, s);
}

/// NUL-terminated UTF-16 -> UTF-8 (caller frees).
pub fn fromWZ(gpa: Allocator, s: [*:0]const u16) ![]u8 {
    return fromW(gpa, std.mem.span(s));
}

// ---------------------------------------------------------------- HRESULT / errors

/// HRESULT of the last failed `check` on this thread (for logging).
pub threadlocal var last_hr: w.HRESULT = 0;

/// `try win.check(hr)` -> error.ComFailed when FAILED(hr); the code is kept in `last_hr`.
pub fn check(hr: w.HRESULT) error{ComFailed}!void {
    if (hr < 0) {
        last_hr = hr;
        return error.ComFailed;
    }
}

pub const E_CANCELLED: w.HRESULT = @bitCast(@as(u32, 0x800704C7)); // HRESULT_FROM_WIN32(ERROR_CANCELLED)

/// std's file/OS errors -> the Win32 code whose system message says the same; null = no such code.
pub fn errorCode(err: anyerror) ?u32 {
    return switch (err) {
        error.FileNotFound => 2,
        error.AccessDenied, error.PermissionDenied => 5,
        error.FileBusy => 32,
        error.PathAlreadyExists => 183,
        error.NoSpaceLeft => 112,
        error.DiskQuota => 1295,
        error.NameTooLong => 206,
        error.BadPathName => 123,
        error.NotDir => 267,
        error.DirNotEmpty => 145,
        error.OutOfMemory, error.SystemResources => 8,
        error.InputOutput => 1117,
        error.NetworkNotFound => 53,
        error.FileTooBig => 223,
        error.SharingViolation => 32,
        error.ReadOnlyFileSystem => 19,
        error.NoDevice => 21,
        error.DeviceBusy => 170,
        error.Timeout, error.ConnectionTimedOut => 1460,
        error.ConnectionRefused => 1225,
        error.NetworkUnreachable => 1231,
        error.ProcessFdQuotaExceeded, error.SystemFdQuotaExceeded => 4,
        error.InvalidUtf8, error.InvalidWtf8 => 123,
        error.Canceled => 1223,
        else => null,
    };
}

/// Windows' text for a Win32 code or HRESULT, in the user's UI language, trimmed of " \r\n."; null when it has
/// none (or `buf` is too small). A slice of `buf`.
pub fn sysMessage(buf: []u8, code: u32) ?[]const u8 {
    var wbuf: [512]u16 = undefined;
    const n = w.FormatMessageW(w.FORMAT_MESSAGE_FROM_SYSTEM | w.FORMAT_MESSAGE_IGNORE_INSERTS, null, code, 0, &wbuf, wbuf.len, null);
    if (n == 0 or buf.len < 3 * n) return null;
    return std.mem.trim(u8, buf[0..std.unicode.wtf16LeToWtf8(buf, wbuf[0..n])], " \r\n.");
}

/// Words for the user: Windows' localized message for std's file errors (what .NET's ex.Message said), else
/// Windows' "An internal error occurred" (never the Zig name: log @errorName yourself). A slice of `buf`
/// (1536 bytes holds any system message) or a static string.
pub fn errorText(buf: []u8, err: anyerror) []const u8 {
    if (errorCode(err)) |c| if (sysMessage(buf, c)) |m| return m;
    return sysMessage(buf, 1359) orelse "An internal error occurred"; // ERROR_INTERNAL_ERROR
}

/// errorText as a "{f}" argument: `print("Could not save: {f}", .{win.errText(e)})`.
pub fn errText(err: anyerror) ErrText {
    return .{ .err = err };
}

pub const ErrText = struct {
    err: anyerror,
    pub fn format(t: ErrText, wr: *std.Io.Writer) std.Io.Writer.Error!void {
        var buf: [1536]u8 = undefined;
        try wr.writeAll(errorText(&buf, t.err));
    }
};

/// Initialize COM as STA (call once on the UI thread, and on any worker thread that uses shell COM).
pub fn comInitSta() !void {
    const hr = w.CoInitializeEx(null, @intCast(w.COINIT_APARTMENTTHREADED | w.COINIT_DISABLE_OLE1DDE));
    try check(hr); // S_FALSE (already initialized) is a success code
}

pub fn comUninit() void {
    w.CoUninitialize();
}

/// Release any COM interface pointer (`p.lpVtbl.Release(p)`); null-safe.
pub fn release(p: anytype) void {
    if (p) |q| _ = q.*.lpVtbl.*.Release.?(q);
}

// ---------------------------------------------------------------- tiny lock (no Io needed)

/// ponytail: SRWLOCK wrapper so kit internals (jobs, automation) don't need an `std.Io` instance.
pub const Lock = struct {
    s: w.SRWLOCK = std.mem.zeroes(w.SRWLOCK),
    pub fn lock(l: *Lock) void {
        w.AcquireSRWLockExclusive(&l.s);
    }
    pub fn unlock(l: *Lock) void {
        w.ReleaseSRWLockExclusive(&l.s);
    }
};

// ---------------------------------------------------------------- environment

/// Value of an environment variable (caller frees) or null when unset.
pub fn getEnv(gpa: Allocator, name: []const u8) !?[]u8 {
    const live: std.process.Environ = .{ .block = .global };
    return live.getAlloc(gpa, name) catch |e| switch (e) {
        error.EnvironmentVariableMissing => null,
        else => |x| return x,
    };
}

/// ExpandEnvironmentStringsW ("%WINDIR%\\Fonts" -> "C:\\Windows\\Fonts").
pub fn expandEnv(gpa: Allocator, s: []const u8) ![]u8 {
    const src = try toW(gpa, s);
    defer gpa.free(src);
    var buf: [1024]u16 = undefined;
    const n = w.ExpandEnvironmentStringsW(src.ptr, &buf, buf.len);
    if (n == 0) return error.Unexpected;
    if (n <= buf.len) return fromW(gpa, buf[0 .. n - 1]);
    const big = try gpa.alloc(u16, n);
    defer gpa.free(big);
    const m = w.ExpandEnvironmentStringsW(src.ptr, big.ptr, n);
    if (m == 0 or m > n) return error.Unexpected;
    return fromW(gpa, big[0 .. m - 1]);
}

/// SHGetKnownFolderPath, e.g. `knownFolder(gpa, &w.FOLDERID_LocalAppData)`.
pub fn knownFolder(gpa: Allocator, id: *const w.KNOWNFOLDERID) ![]u8 {
    var p: w.PWSTR = null;
    try check(w.SHGetKnownFolderPath(id, 0, null, &p));
    defer w.CoTaskMemFree(p);
    return fromWZ(gpa, @ptrCast(p));
}

// ---------------------------------------------------------------- registry

pub const Root = enum { hkcu, hklm, hkcr, hku };
/// Registry view: `.default` follows the process bitness; `.wow64_64`/`.wow64_32` force a view.
pub const View = enum { default, wow64_64, wow64_32 };

/// Predefined HKEYs. `w.HKEY_CURRENT_USER` & co. do not compile: translate_c turns them into an
/// int->pointer cast that fails the alignment check (HKEY points to a 4-aligned struct).
fn rootKey(r: Root) w.HKEY {
    @setRuntimeSafety(false); // ponytail: the handle is an odd magic value, never dereferenced
    const v: usize = switch (r) {
        .hkcr => 0x80000000,
        .hkcu => 0x80000001,
        .hklm => 0x80000002,
        .hku => 0x80000003,
    };
    return @ptrFromInt(v);
}

const key_rw: w.REGSAM = @intCast(w.KEY_READ | w.KEY_WRITE);
const key_r: w.REGSAM = @intCast(w.KEY_READ);

fn viewFlag(v: View) w.REGSAM {
    return switch (v) {
        .default => 0,
        .wow64_64 => @intCast(w.KEY_WOW64_64KEY),
        .wow64_32 => @intCast(w.KEY_WOW64_32KEY),
    };
}

pub const RegError = error{ NotFound, AccessDenied, WrongType, OutOfMemory, Unexpected };

/// Last raw Win32 error code from a failed registry call on this thread.
pub threadlocal var last_reg_error: u32 = 0;

fn regErr(rc: w.LSTATUS) RegError!void {
    if (rc == 0) return;
    last_reg_error = @bitCast(rc);
    return switch (rc) {
        w.ERROR_FILE_NOT_FOUND, w.ERROR_PATH_NOT_FOUND => error.NotFound,
        w.ERROR_ACCESS_DENIED => error.AccessDenied,
        else => error.Unexpected,
    };
}

pub const KeyOptions = struct { write: bool = false, view: View = .default };

/// Scratch for the UTF-16 strings of one Win32 call: on the stack up to ~500 units, heap beyond (no limit).
/// `var sb: [1024]u8 = undefined; var bfa = scratch(&sb); const a = bfa.allocator();` + `defer a.free(x)`.
fn scratch(buf: []u8) std.heap.BufferFirstAllocator {
    return .init(buf, std.heap.page_allocator);
}

/// Optional value name -> UTF-16Z (null = the default value); free with `freeOptW`.
fn optW(a: Allocator, name: ?[]const u8) !?[:0]u16 {
    return if (name) |s| try toW(a, s) else null;
}

fn freeOptW(a: Allocator, s: ?[:0]u16) void {
    if (s) |x| a.free(x);
}

fn ptrW(s: ?[:0]u16) ?[*:0]const u16 {
    return if (s) |x| x.ptr else null;
}

pub fn openKey(root: Root, path: []const u8, opt: KeyOptions) !Key {
    var sb: [1024]u8 = undefined;
    var bfa = scratch(&sb);
    const a = bfa.allocator();
    const p = try toW(a, path);
    defer a.free(p);
    var h: w.HKEY = null;
    const access: w.REGSAM = (if (opt.write) key_rw else key_r) | viewFlag(opt.view);
    try regErr(w.RegOpenKeyExW(rootKey(root), p.ptr, 0, access, &h));
    return .{ .h = h };
}

/// Opens or creates `path` (and missing parents) with read/write access.
pub fn createKey(root: Root, path: []const u8, view: View) !Key {
    var sb: [1024]u8 = undefined;
    var bfa = scratch(&sb);
    const a = bfa.allocator();
    const p = try toW(a, path);
    defer a.free(p);
    var h: w.HKEY = null;
    try regErr(w.RegCreateKeyExW(rootKey(root), p.ptr, 0, null, 0, key_rw | viewFlag(view), null, &h, null));
    return .{ .h = h };
}

/// Deletes `path` with all subkeys and values (in the given view).
pub fn deleteKeyTree(root: Root, path: []const u8, view: View) !void {
    var sb: [1024]u8 = undefined;
    var bfa = scratch(&sb);
    const a = bfa.allocator();
    const p = try toW(a, path);
    defer a.free(p);
    var h: w.HKEY = null;
    try regErr(w.RegOpenKeyExW(rootKey(root), p.ptr, 0, key_rw | @as(w.REGSAM, @intCast(w.DELETE)) | viewFlag(view), &h));
    const rc = w.RegDeleteTreeW(h, null);
    _ = w.RegCloseKey(h);
    try regErr(rc);
    try regErr(w.RegDeleteKeyExW(rootKey(root), p.ptr, viewFlag(view), 0));
}

pub const ValueInfo = struct { name: []u8, kind: u32 };

pub const Key = struct {
    h: w.HKEY,

    pub fn close(k: Key) void {
        _ = w.RegCloseKey(k.h);
    }

    /// Raw value bytes + REG_* type. `name` null/"" = default value.
    pub fn readRaw(k: Key, gpa: Allocator, name: ?[]const u8) !struct { data: []u8, kind: u32 } {
        const n = if (name) |s| try toW(gpa, s) else null;
        defer if (n) |s| gpa.free(s);
        const np: ?[*:0]const u16 = if (n) |s| s.ptr else null;
        var size: w.DWORD = 0;
        var kind: w.DWORD = 0;
        try regErr(w.RegQueryValueExW(k.h, np, null, &kind, null, &size));
        while (true) {
            const data = try gpa.alloc(u8, size);
            var got = size;
            const rc = w.RegQueryValueExW(k.h, np, null, &kind, data.ptr, &got);
            if (rc == w.ERROR_MORE_DATA) { // value grew between calls
                gpa.free(data);
                size = got;
                continue;
            }
            regErr(rc) catch |e| {
                gpa.free(data);
                return e;
            };
            return .{ .data = try shrink(gpa, data, got), .kind = kind };
        }
    }

    /// REG_SZ / REG_EXPAND_SZ (not expanded) -> UTF-8.
    pub fn readString(k: Key, gpa: Allocator, name: ?[]const u8) ![]u8 {
        const v = try k.readRaw(gpa, name);
        defer gpa.free(v.data);
        if (v.kind != w.REG_SZ and v.kind != w.REG_EXPAND_SZ) return error.WrongType;
        const ws = try utf16(gpa, v.data);
        defer gpa.free(ws);
        return fromW(gpa, trimNul(ws));
    }

    pub fn readDword(k: Key, name: ?[]const u8) !u32 {
        var sb: [1024]u8 = undefined;
        var bfa = scratch(&sb);
        const a = bfa.allocator();
        const nw = try optW(a, name);
        defer freeOptW(a, nw);
        const np = ptrW(nw);
        var v: u32 = 0;
        var size: w.DWORD = 0;
        var kind: w.DWORD = 0;
        try regErr(w.RegQueryValueExW(k.h, np, null, &kind, null, &size)); // type first: a bigger value would fail with ERROR_MORE_DATA
        if (kind != w.REG_DWORD or size != 4) return error.WrongType;
        try regErr(w.RegQueryValueExW(k.h, np, null, &kind, @ptrCast(&v), &size));
        return v;
    }

    pub fn readBinary(k: Key, gpa: Allocator, name: ?[]const u8) ![]u8 {
        const v = try k.readRaw(gpa, name);
        return v.data;
    }

    /// REG_MULTI_SZ -> list of UTF-8 strings (free each + the slice, or use an arena).
    pub fn readMultiSz(k: Key, gpa: Allocator, name: ?[]const u8) ![][]u8 {
        const v = try k.readRaw(gpa, name);
        defer gpa.free(v.data);
        if (v.kind != w.REG_MULTI_SZ) return error.WrongType;
        var list: std.ArrayList([]u8) = .empty;
        errdefer {
            for (list.items) |s| gpa.free(s);
            list.deinit(gpa);
        }
        const ws = try utf16(gpa, v.data);
        defer gpa.free(ws);
        var it = std.mem.splitScalar(u16, ws, 0);
        while (it.next()) |part| {
            if (part.len == 0) continue;
            try list.append(gpa, try fromW(gpa, part));
        }
        return list.toOwnedSlice(gpa);
    }

    pub fn writeString(k: Key, name: ?[]const u8, value: []const u8) !void {
        return k.writeStr(name, value, w.REG_SZ);
    }

    pub fn writeExpandString(k: Key, name: ?[]const u8, value: []const u8) !void {
        return k.writeStr(name, value, w.REG_EXPAND_SZ);
    }

    fn writeStr(k: Key, name: ?[]const u8, value: []const u8, kind: u32) !void {
        const gpa = std.heap.page_allocator; // ponytail: rare call; avoids an allocator param
        const v = try toW(gpa, value);
        defer gpa.free(v);
        return k.writeRaw(name, kind, std.mem.sliceAsBytes(v[0 .. v.len + 1]));
    }

    pub fn writeDword(k: Key, name: ?[]const u8, value: u32) !void {
        return k.writeRaw(name, w.REG_DWORD, std.mem.asBytes(&value));
    }

    pub fn writeBinary(k: Key, name: ?[]const u8, data: []const u8) !void {
        return k.writeRaw(name, w.REG_BINARY, data);
    }

    pub fn writeMultiSz(k: Key, name: ?[]const u8, list: []const []const u8) !void {
        const gpa = std.heap.page_allocator;
        var buf: std.ArrayList(u16) = .empty;
        defer buf.deinit(gpa);
        for (list) |s| {
            const ws = try toW(gpa, s);
            defer gpa.free(ws);
            try buf.appendSlice(gpa, ws[0 .. ws.len + 1]);
        }
        try buf.append(gpa, 0);
        return k.writeRaw(name, w.REG_MULTI_SZ, std.mem.sliceAsBytes(buf.items));
    }

    pub fn writeRaw(k: Key, name: ?[]const u8, kind: u32, data: []const u8) !void {
        var sb: [1024]u8 = undefined;
        var bfa = scratch(&sb);
        const a = bfa.allocator();
        const nw = try optW(a, name);
        defer freeOptW(a, nw);
        try regErr(w.RegSetValueExW(k.h, ptrW(nw), 0, kind, data.ptr, @intCast(data.len)));
    }

    pub fn deleteValue(k: Key, name: ?[]const u8) !void {
        var sb: [1024]u8 = undefined;
        var bfa = scratch(&sb);
        const a = bfa.allocator();
        const nw = try optW(a, name);
        defer freeOptW(a, nw);
        try regErr(w.RegDeleteValueW(k.h, ptrW(nw)));
    }

    /// True when value `name` exists (null = the default value). Names compare case-insensitively.
    pub fn hasValue(k: Key, name: ?[]const u8) !bool {
        var sb: [1024]u8 = undefined;
        var bfa = scratch(&sb);
        const a = bfa.allocator();
        const nw = try optW(a, name);
        defer freeOptW(a, nw);
        regErr(w.RegQueryValueExW(k.h, ptrW(nw), null, null, null, null)) catch |e| return if (e == error.NotFound) false else e;
        return true;
    }

    /// Deletes subkey `leaf` (a name or a relative path) with all its subkeys and values. Needs a key
    /// opened for writing.
    pub fn deleteSubTree(k: Key, leaf: []const u8) !void {
        if (leaf.len == 0) return error.NotFound; // RegDeleteTree(k, "") would empty `k` itself
        var sb: [1024]u8 = undefined;
        var bfa = scratch(&sb);
        const a = bfa.allocator();
        const lw = try toW(a, leaf);
        defer a.free(lw);
        try regErr(w.RegDeleteTreeW(k.h, lw.ptr));
    }

    /// Names of direct subkeys (free each + the slice, or use an arena).
    pub fn subkeys(k: Key, gpa: Allocator) ![][]u8 {
        var list: std.ArrayList([]u8) = .empty;
        errdefer {
            for (list.items) |s| gpa.free(s);
            list.deinit(gpa);
        }
        var name: [256]u16 = undefined; // max key name length is 255
        var i: w.DWORD = 0;
        while (true) : (i += 1) {
            var len: w.DWORD = name.len;
            const rc = w.RegEnumKeyExW(k.h, i, &name, &len, null, null, null, null);
            if (rc == w.ERROR_NO_MORE_ITEMS) break;
            try regErr(rc);
            try list.append(gpa, try fromW(gpa, name[0..len]));
        }
        return list.toOwnedSlice(gpa);
    }

    /// Value names + types (free each `.name` + the slice, or use an arena).
    pub fn values(k: Key, gpa: Allocator) ![]ValueInfo {
        var list: std.ArrayList(ValueInfo) = .empty;
        errdefer {
            for (list.items) |v| gpa.free(v.name);
            list.deinit(gpa);
        }
        var name: [16384]u16 = undefined; // max value name length is 16383
        var i: w.DWORD = 0;
        while (true) : (i += 1) {
            var len: w.DWORD = name.len;
            var kind: w.DWORD = 0;
            const rc = w.RegEnumValueW(k.h, i, &name, &len, null, &kind, null, null);
            if (rc == w.ERROR_NO_MORE_ITEMS) break;
            try regErr(rc);
            try list.append(gpa, .{ .name = try fromW(gpa, name[0..len]), .kind = kind });
        }
        return list.toOwnedSlice(gpa);
    }
};

/// Registry data is byte-aligned; copy into a real []u16 (caller frees).
fn utf16(gpa: Allocator, bytes: []const u8) ![]u16 {
    const out = try gpa.alloc(u16, bytes.len / 2);
    @memcpy(std.mem.sliceAsBytes(out), bytes[0 .. out.len * 2]);
    return out;
}

fn trimNul(s: []const u16) []const u16 {
    var e = s.len;
    while (e > 0 and s[e - 1] == 0) e -= 1;
    return s[0..e];
}

fn shrink(gpa: Allocator, data: []u8, len: usize) ![]u8 {
    if (len == data.len) return data;
    defer gpa.free(data);
    return gpa.dupe(u8, data[0..len]);
}

// ---------------------------------------------------------------- long paths

/// `path` as a UTF-16Z Win32 path (caller frees). Long ones (>= 248 units) are made absolute and get the
/// `\\?\` (`\\?\UNC\`) prefix, so they work without LongPathsEnabled / a longPathAware manifest.
pub fn longPathW(gpa: Allocator, path: []const u8) ![:0]u16 {
    const wp = try toW(gpa, path);
    if (wp.len < 248 or std.mem.startsWith(u16, wp, L("\\\\?\\")) or std.mem.startsWith(u16, wp, L("\\\\.\\"))) return wp;
    defer gpa.free(wp);
    const n = w.GetFullPathNameW(wp.ptr, 0, null, null);
    if (n == 0) return error.Unexpected;
    const full = try gpa.alloc(u16, n);
    defer gpa.free(full);
    const len = w.GetFullPathNameW(wp.ptr, n, full.ptr, null);
    if (len == 0 or len >= n) return error.Unexpected;
    const unc = full[0] == '\\' and full[1] == '\\'; // \\server\share -> \\?\UNC\server\share
    return std.mem.concatWithSentinel(gpa, u16, &.{ if (unc) L("\\\\?\\UNC") else L("\\\\?\\"), full[@intFromBool(unc)..len] }, 0);
}

fn attributes(path: []const u8) ?w.DWORD {
    var sb: [1024]u8 = undefined;
    var bfa = scratch(&sb);
    const a = bfa.allocator();
    const p = longPathW(a, path) catch return null;
    defer a.free(p);
    const r = w.GetFileAttributesW(p.ptr);
    return if (r == w.INVALID_FILE_ATTRIBUTES) null else r;
}

/// File or folder exists (long paths ok; unreadable = false).
pub fn exists(path: []const u8) bool {
    return attributes(path) != null;
}

pub fn isDir(path: []const u8) bool {
    const a = attributes(path) orelse return false;
    return a & w.FILE_ATTRIBUTE_DIRECTORY != 0;
}

pub fn isFile(path: []const u8) bool {
    const a = attributes(path) orelse return false;
    return a & w.FILE_ATTRIBUTE_DIRECTORY == 0;
}

// ---------------------------------------------------------------- shell / processes

pub const ShellExecOptions = struct {
    file: []const u8,
    params: ?[]const u8 = null,
    dir: ?[]const u8 = null,
    /// "open", "runas" (elevate), "edit", ... null = default verb.
    verb: ?[]const u8 = null,
    hidden: bool = false,
    /// Block until the process exits and return its exit code.
    wait: bool = false,
};

/// ShellExecuteExW. Returns the exit code when `wait`, else null. error.Cancelled if the user
/// declined the UAC prompt.
pub fn shellExecute(gpa: Allocator, o: ShellExecOptions) !?u32 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sei = std.mem.zeroes(w.SHELLEXECUTEINFOW);
    sei.cbSize = @sizeOf(w.SHELLEXECUTEINFOW);
    sei.fMask = w.SEE_MASK_NOCLOSEPROCESS | w.SEE_MASK_FLAG_NO_UI | w.SEE_MASK_NOASYNC;
    sei.lpFile = (try toW(a, o.file)).ptr;
    if (o.params) |s| sei.lpParameters = (try toW(a, s)).ptr;
    if (o.dir) |s| sei.lpDirectory = (try toW(a, s)).ptr;
    if (o.verb) |s| sei.lpVerb = (try toW(a, s)).ptr;
    sei.nShow = if (o.hidden) w.SW_HIDE else w.SW_SHOWNORMAL;
    if (w.ShellExecuteExW(&sei) == 0) {
        const err = w.GetLastError();
        if (err == w.ERROR_CANCELLED) return error.Cancelled;
        if (err == w.ERROR_FILE_NOT_FOUND or err == w.ERROR_PATH_NOT_FOUND) return error.FileNotFound;
        return error.Unexpected;
    }
    defer if (sei.hProcess != null) {
        _ = w.CloseHandle(sei.hProcess);
    };
    if (!o.wait or sei.hProcess == null) return null;
    _ = w.WaitForSingleObject(sei.hProcess, w.INFINITE);
    var code: w.DWORD = 0;
    if (w.GetExitCodeProcess(sei.hProcess, &code) == 0) return error.Unexpected;
    return code;
}

/// Terminal-services session of a process (0 = services session).
pub fn sessionId(pid: u32) !u32 {
    var sid: w.DWORD = 0;
    if (w.ProcessIdToSessionId(pid, &sid) == 0) return error.Unexpected;
    return sid;
}

pub const OsVersion = struct { major: u32, minor: u32, build: u32 };

extern "ntdll" fn RtlGetVersion(info: *w.RTL_OSVERSIONINFOW) callconv(.winapi) i32;

/// Real OS version (RtlGetVersion is not affected by compatibility shims / manifests).
pub fn osVersion() OsVersion {
    var vi = std.mem.zeroes(w.RTL_OSVERSIONINFOW);
    vi.dwOSVersionInfoSize = @sizeOf(w.RTL_OSVERSIONINFOW);
    _ = RtlGetVersion(&vi);
    return .{ .major = vi.dwMajorVersion, .minor = vi.dwMinorVersion, .build = vi.dwBuildNumber };
}

/// True when the process token is elevated (IsUserAnAdmin equivalent under UAC).
pub fn isElevated() bool {
    var tok: w.HANDLE = null;
    if (w.OpenProcessToken(w.GetCurrentProcess(), w.TOKEN_QUERY, &tok) == 0) return false;
    defer _ = w.CloseHandle(tok);
    var el: w.TOKEN_ELEVATION = .{ .TokenIsElevated = 0 };
    var len: w.DWORD = 0;
    if (w.GetTokenInformation(tok, w.TokenElevation, &el, @sizeOf(w.TOKEN_ELEVATION), &len) == 0) return false;
    return el.TokenIsElevated != 0;
}

// ---------------------------------------------------------------- file dialogs (IFileOpenDialog / IFileSaveDialog)

pub const Filter = struct {
    name: []const u8, // "Archives"
    spec: []const u8, // "*.7z;*.zip"
};

pub const DialogOptions = struct {
    title: ?[]const u8 = null,
    filters: []const Filter = &.{},
    /// Save: suggested file name; open: initial file name text.
    file_name: ?[]const u8 = null,
    /// Save: extension appended when the user types none ("zip", no dot).
    default_ext: ?[]const u8 = null,
    /// Initial folder (absolute path).
    folder: ?[]const u8 = null,
};

const Mode = enum { open, open_multi, save, folder };

/// Open-file dialog. Returns selected paths (null = cancelled). Free with `freeList`.
/// Requires COM initialized on this thread (`comInitSta`).
pub fn openFiles(gpa: Allocator, owner: w.HWND, multi: bool, o: DialogOptions) !?[][]u8 {
    return dialog(gpa, owner, if (multi) .open_multi else .open, o);
}

/// Save-file dialog. Returns the chosen path (null = cancelled).
pub fn saveFile(gpa: Allocator, owner: w.HWND, o: DialogOptions) !?[]u8 {
    const r = try dialog(gpa, owner, .save, o) orelse return null;
    defer gpa.free(r);
    return r[0];
}

/// Folder picker. Returns the folder path (null = cancelled).
pub fn pickFolder(gpa: Allocator, owner: w.HWND, o: DialogOptions) !?[]u8 {
    const r = try dialog(gpa, owner, .folder, o) orelse return null;
    defer gpa.free(r);
    return r[0];
}

pub fn freeList(gpa: Allocator, list: [][]u8) void {
    for (list) |s| gpa.free(s);
    gpa.free(list);
}

fn dialog(gpa: Allocator, owner: w.HWND, mode: Mode, o: DialogOptions) !?[][]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // IFileOpenDialog and IFileSaveDialog share the IFileDialog vtable prefix.
    var dlg: [*c]w.IFileDialog = null;
    if (mode == .save) {
        try check(w.CoCreateInstance(&w.CLSID_FileSaveDialog, null, w.CLSCTX_INPROC_SERVER, &w.IID_IFileSaveDialog, @ptrCast(&dlg)));
    } else {
        try check(w.CoCreateInstance(&w.CLSID_FileOpenDialog, null, w.CLSCTX_INPROC_SERVER, &w.IID_IFileOpenDialog, @ptrCast(&dlg)));
    }
    defer release(dlg);
    const v = dlg.*.lpVtbl.*;

    var opts: w.FILEOPENDIALOGOPTIONS = 0;
    try check(v.GetOptions.?(dlg, &opts));
    opts |= w.FOS_FORCEFILESYSTEM | w.FOS_NOCHANGEDIR;
    switch (mode) {
        .open => opts |= w.FOS_FILEMUSTEXIST | w.FOS_PATHMUSTEXIST,
        .open_multi => opts |= w.FOS_FILEMUSTEXIST | w.FOS_PATHMUSTEXIST | w.FOS_ALLOWMULTISELECT,
        .save => opts |= w.FOS_OVERWRITEPROMPT | w.FOS_PATHMUSTEXIST,
        .folder => opts |= w.FOS_PICKFOLDERS | w.FOS_PATHMUSTEXIST,
    }
    try check(v.SetOptions.?(dlg, opts));
    if (o.title) |t| try check(v.SetTitle.?(dlg, (try toW(a, t)).ptr));
    if (o.file_name) |t| try check(v.SetFileName.?(dlg, (try toW(a, t)).ptr));
    if (o.default_ext) |t| try check(v.SetDefaultExtension.?(dlg, (try toW(a, t)).ptr));
    if (o.filters.len > 0 and mode != .folder) {
        const specs = try a.alloc(w.COMDLG_FILTERSPEC, o.filters.len);
        for (o.filters, specs) |f, *s| s.* = .{ .pszName = (try toW(a, f.name)).ptr, .pszSpec = (try toW(a, f.spec)).ptr };
        try check(v.SetFileTypes.?(dlg, @intCast(specs.len), specs.ptr));
    }
    if (o.folder) |f| {
        var item: [*c]w.IShellItem = null;
        if (w.SHCreateItemFromParsingName((try toW(a, f)).ptr, null, &w.IID_IShellItem, @ptrCast(&item)) >= 0) {
            _ = v.SetFolder.?(dlg, item);
            release(item);
        }
    }

    const hr = v.Show.?(dlg, owner);
    if (hr == E_CANCELLED) return null;
    try check(hr);

    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |s| gpa.free(s);
        out.deinit(gpa);
    }
    if (mode == .open_multi) {
        const od: [*c]w.IFileOpenDialog = @ptrCast(dlg);
        var arr: [*c]w.IShellItemArray = null;
        try check(od.*.lpVtbl.*.GetResults.?(od, &arr));
        defer release(arr);
        var n: w.DWORD = 0;
        try check(arr.*.lpVtbl.*.GetCount.?(arr, &n));
        for (0..n) |i| {
            var item: [*c]w.IShellItem = null;
            try check(arr.*.lpVtbl.*.GetItemAt.?(arr, @intCast(i), &item));
            defer release(item);
            try out.append(gpa, try itemPath(gpa, item));
        }
    } else {
        var item: [*c]w.IShellItem = null;
        try check(v.GetResult.?(dlg, &item));
        defer release(item);
        try out.append(gpa, try itemPath(gpa, item));
    }
    return try out.toOwnedSlice(gpa);
}

fn itemPath(gpa: Allocator, item: [*c]w.IShellItem) ![]u8 {
    var p: w.LPWSTR = null;
    try check(item.*.lpVtbl.*.GetDisplayName.?(item, w.SIGDN_FILESYSPATH, &p));
    defer w.CoTaskMemFree(p);
    return fromWZ(gpa, @ptrCast(p));
}

// ---------------------------------------------------------------- recycle bin

/// Moves `paths` to the Recycle Bin via IFileOperation (no UI, undo allowed). Returns the HRESULT of
/// the call (S_OK = 0 when everything was recycled; a failure code from item creation, e.g. a missing
/// path, or from PerformOperations). `aborted` = some operation was cancelled/failed silently.
/// Requires COM initialized on this thread (STA recommended).
pub fn recycle(gpa: Allocator, paths: []const []const u8) struct { hr: w.HRESULT, aborted: bool } {
    var op: [*c]w.IFileOperation = null;
    var hr = w.CoCreateInstance(&w.CLSID_FileOperation, null, w.CLSCTX_ALL, &w.IID_IFileOperation, @ptrCast(&op));
    if (hr < 0) return .{ .hr = hr, .aborted = true };
    defer release(op);
    const v = op.*.lpVtbl.*;
    const flags: w.DWORD = @intCast(w.FOF_ALLOWUNDO | w.FOF_NOCONFIRMATION | w.FOF_SILENT | w.FOF_NOERRORUI | w.FOFX_RECYCLEONDELETE | w.FOFX_EARLYFAILURE);
    hr = v.SetOperationFlags.?(op, flags);
    if (hr < 0) return .{ .hr = hr, .aborted = true };
    for (paths) |p| {
        const pw = toW(gpa, p) catch return .{ .hr = w.E_OUTOFMEMORY, .aborted = true };
        defer gpa.free(pw);
        var item: [*c]w.IShellItem = null;
        hr = w.SHCreateItemFromParsingName(pw.ptr, null, &w.IID_IShellItem, @ptrCast(&item));
        if (hr < 0) return .{ .hr = hr, .aborted = true };
        defer release(item);
        hr = v.DeleteItem.?(op, item, null);
        if (hr < 0) return .{ .hr = hr, .aborted = true };
    }
    hr = v.PerformOperations.?(op);
    var aborted: w.BOOL = 0;
    _ = v.GetAnyOperationsAborted.?(op, &aborted);
    return .{ .hr = hr, .aborted = aborted != 0 };
}

// ---------------------------------------------------------------- tests

test "errorText: Windows' words for std errors, a generic message otherwise" {
    var buf: [1536]u8 = undefined;
    const t = errorText(&buf, error.AccessDenied);
    try std.testing.expect(t.len > 0 and std.mem.find(u8, t, "AccessDenied") == null);
    try std.testing.expect(sysMessage(&buf, 5) != null);
    var gen: [1536]u8 = undefined;
    var other: [1536]u8 = undefined;
    try std.testing.expectEqualStrings(sysMessage(&gen, 1359).?, errorText(&other, error.NoSuchThing));
    var out: [2048]u8 = undefined;
    try std.testing.expectEqualStrings(try std.mem.print(&out, "x: {s}", .{t}), try std.mem.print(out[1024..], "x: {f}", .{errText(error.AccessDenied)}));
}

test "utf8 <-> utf16 round trip" {
    const gpa = std.testing.allocator;
    const s = "Їжак ґанок є — ok";
    const ws = try toW(gpa, s);
    defer gpa.free(ws);
    try std.testing.expectEqual(@as(u16, 0x0407), ws[0]); // 'Ї'
    const back = try fromWZ(gpa, ws.ptr);
    defer gpa.free(back);
    try std.testing.expectEqualStrings(s, back);
    try std.testing.expectEqualSlices(u16, L("ab"), &[_]u16{ 'a', 'b' });
}

test "registry round trip under HKCU" {
    const gpa = std.testing.allocator;
    var rnd: [4]u8 = undefined;
    std.testing.io.random(&rnd);
    const path = try gpa.print("Software\\MakeKitTest-{x}", .{std.mem.readInt(u32, &rnd, .little)});
    defer gpa.free(path);
    errdefer deleteKeyTree(.hkcu, path, .default) catch {}; // never leave test keys behind

    {
        const k = try createKey(.hkcu, path, .default);
        defer k.close();
        try k.writeString("s", "Привіт");
        try k.writeDword("d", 0xDEADBEEF);
        try k.writeBinary("b", &.{ 1, 2, 3 });
        try k.writeMultiSz("m", &.{ "a", "бб" });
        const sub_path = try std.mem.concat(gpa, u8, &.{ path, "\\sub" });
        defer gpa.free(sub_path);
        const sub = try createKey(.hkcu, sub_path, .wow64_64);
        sub.close();
    }
    {
        const k = try openKey(.hkcu, path, .{ .write = true });
        defer k.close();
        const s = try k.readString(gpa, "s");
        defer gpa.free(s);
        try std.testing.expectEqualStrings("Привіт", s);
        try std.testing.expectEqual(@as(u32, 0xDEADBEEF), try k.readDword("d"));
        const b = try k.readBinary(gpa, "b");
        defer gpa.free(b);
        try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, b);
        const m = try k.readMultiSz(gpa, "m");
        defer freeList(gpa, m);
        try std.testing.expectEqual(@as(usize, 2), m.len);
        try std.testing.expectEqualStrings("бб", m[1]);
        try std.testing.expectError(error.WrongType, k.readDword("s"));
        const vals = try k.values(gpa);
        defer {
            for (vals) |v| gpa.free(v.name);
            gpa.free(vals);
        }
        try std.testing.expectEqual(@as(usize, 4), vals.len);
        const subs = try k.subkeys(gpa);
        defer freeList(gpa, subs);
        try std.testing.expectEqual(@as(usize, 1), subs.len);
        try std.testing.expectEqualStrings("sub", subs[0]);
        try k.deleteValue("d");
        try std.testing.expectError(error.NotFound, k.readDword("d"));
    }
    {
        // > 255 UTF-16 units (each component stays under the 255 limit), long value name, hasValue, deleteSubTree
        const as: [200]u8 = @splat('a');
        const bs: [200]u8 = @splat('b');
        const long = try std.mem.concat(gpa, u8, &.{ path, "\\", &as, "\\", &bs });
        defer gpa.free(long);
        const name_buf: [600]u8 = @splat('v');
        const name: []const u8 = &name_buf;
        {
            const k = try createKey(.hkcu, long, .default);
            defer k.close();
            try k.writeDword(name, 7);
        }
        const k = try openKey(.hkcu, long, .{ .write = true });
        defer k.close();
        try std.testing.expectEqual(@as(u32, 7), try k.readDword(name));
        try std.testing.expect(try k.hasValue(name));
        try std.testing.expect(!try k.hasValue("missing"));
        try k.deleteValue(name);
        try std.testing.expect(!try k.hasValue(name));
        const parent = try openKey(.hkcu, path, .{ .write = true });
        defer parent.close();
        try parent.deleteSubTree(&as);
        try std.testing.expectError(error.NotFound, parent.deleteSubTree(&as));
        try std.testing.expectError(error.NotFound, openKey(.hkcu, long, .{}));
    }
    try deleteKeyTree(.hkcu, path, .default);
    try std.testing.expectError(error.NotFound, openKey(.hkcu, path, .{}));
}

test "long paths: exists / isDir / isFile past MAX_PATH" {
    const gpa = std.testing.allocator;
    var rnd: [4]u8 = undefined;
    std.testing.io.random(&rnd);
    const root = try expandEnv(gpa, "%TEMP%");
    defer gpa.free(root);
    const base = try gpa.print("{s}\\makekit-test-{x}", .{ root, std.mem.readInt(u32, &rnd, .little) });
    defer gpa.free(base);
    const ds: [120]u8 = @splat('d');
    const seg = "\\" ++ ds;
    const dirs = [_][]const u8{ base, try std.mem.concat(gpa, u8, &.{ base, seg }), try std.mem.concat(gpa, u8, &.{ base, seg, seg }) };
    defer for (dirs[1..]) |d| gpa.free(d);
    const file = try std.mem.concat(gpa, u8, &.{ dirs[2], "\\f.txt" });
    defer gpa.free(file);
    try std.testing.expect(file.len > 260);
    defer { // never leave test dirs behind
        if (longPathW(gpa, file)) |p| {
            _ = w.DeleteFileW(p.ptr);
            gpa.free(p);
        } else |_| {}
        var i: usize = dirs.len;
        while (i > 0) {
            i -= 1;
            if (longPathW(gpa, dirs[i])) |p| {
                _ = w.RemoveDirectoryW(p.ptr);
                gpa.free(p);
            } else |_| {}
        }
    }
    for (dirs) |d| {
        const p = try longPathW(gpa, d);
        defer gpa.free(p);
        try std.testing.expect(w.CreateDirectoryW(p.ptr, null) != 0);
    }
    const fp = try longPathW(gpa, file);
    defer gpa.free(fp);
    try std.testing.expect(std.mem.startsWith(u16, fp, L("\\\\?\\")));
    const h = w.CreateFileW(fp.ptr, w.GENERIC_WRITE, 0, null, w.CREATE_NEW, w.FILE_ATTRIBUTE_NORMAL, null);
    try std.testing.expect(h != w.INVALID_HANDLE_VALUE);
    _ = w.CloseHandle(h);
    try std.testing.expect(exists(file) and isFile(file) and !isDir(file));
    try std.testing.expect(exists(dirs[2]) and isDir(dirs[2]) and !isFile(dirs[2]));
    try std.testing.expect(!exists(file[0 .. file.len - 1]) and !isFile(file[0 .. file.len - 1]));
    const short = try longPathW(gpa, "C:\\Windows");
    defer gpa.free(short);
    try std.testing.expectEqualSlices(u16, L("C:\\Windows"), short); // short paths stay as they are
}

test "tlhelp32: the process snapshot lists this process" {
    const snap = w.CreateToolhelp32Snapshot(w.TH32CS_SNAPPROCESS, 0);
    try std.testing.expect(snap != w.INVALID_HANDLE_VALUE);
    defer _ = w.CloseHandle(snap);
    var pe: w.PROCESSENTRY32W = undefined;
    pe.dwSize = @sizeOf(w.PROCESSENTRY32W);
    var found = false;
    var more = w.Process32FirstW(snap, &pe);
    while (more != 0) : (more = w.Process32NextW(snap, &pe)) {
        if (pe.th32ProcessID == w.GetCurrentProcessId()) found = true;
    }
    try std.testing.expect(found);
}

test "env, known folder, os version" {
    const gpa = std.testing.allocator;
    const e = try expandEnv(gpa, "%SystemRoot%\\Fonts");
    defer gpa.free(e);
    try std.testing.expect(std.mem.endsWith(u8, e, "\\Fonts"));
    try std.testing.expect((try getEnv(gpa, "MAKEKIT_SURELY_UNSET_VAR")) == null);
    _ = w.SetEnvironmentVariableW(L("MAKEKIT_TEST_VAR"), L("Їж"));
    const got = (try getEnv(gpa, "MAKEKIT_TEST_VAR")).?;
    defer gpa.free(got);
    try std.testing.expectEqualStrings("Їж", got);
    try comInitSta();
    defer comUninit();
    const la = try knownFolder(gpa, &w.FOLDERID_LocalAppData);
    defer gpa.free(la);
    try std.testing.expect(la.len > 3);
    try std.testing.expect(osVersion().major >= 10);
    _ = isElevated();
    try std.testing.expect(try sessionId(w.GetCurrentProcessId()) < 1000);
}

test "shellExecute waits and returns the exit code" {
    const code = try shellExecute(std.testing.allocator, .{ .file = "cmd.exe", .params = "/c exit 7", .hidden = true, .wait = true });
    try std.testing.expectEqual(@as(?u32, 7), code);
    try std.testing.expectError(error.FileNotFound, shellExecute(std.testing.allocator, .{ .file = "C:\\no\\such\\file.exe", .hidden = true }));
}
