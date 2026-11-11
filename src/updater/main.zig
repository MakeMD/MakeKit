//! MakeUpdate.exe: the only MakeKit binary that goes online (WinHTTP over HTTPS, GitHub API unauthenticated,
//! User-Agent "MakeUpdate", no user data in requests). Apps spawn it hidden and read one JSON line from stdout.
//!
//!   MakeUpdate check   --repo MakeMD/App --current 2.0.0 [--api-base URL]
//!     -> {"ok":true,"newer":true,"latest":"2.1.0","tag":"v2.1.0","notes":"..","setup":"<url>","sha256":"<hex>","page":"<url>"}
//!   MakeUpdate install --repo MakeMD/App --tag v2.1.0 --wait-pid PID --relaunch "C:\..\App.exe" [--api-base URL]
//!     downloads <App>-Setup-2.1.0.exe + SHA256SUMS.txt to %TEMP%\MakeUpdate-<random>, checks the SHA-256, waits
//!     for PID (60 s), runs the setup /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /CLOSEAPPLICATIONS, relaunches the app.
//!   Any failure -> {"ok":false,"error":"..."} and exit code 1. Log: %LOCALAPPDATA%\MakeUpdate\update.log.
//!
//! Env: MAKEKIT_UPDATE_API = API base for tests (like --api-base; http:// is allowed only with an override);
//! MAKEKIT_NO_UPDATE=1 refuses the real GitHub API (tests that forget the override never go online).
const std = @import("std");
const Io = std.Io;
const rel = @import("release.zig");
const Sha256 = std.crypto.hash.sha2.Sha256;
const fspath = Io.Dir.path;

const default_api = "https://api.github.com";
const wait_ms = 60_000;

pub fn main(init: std.process.Init) u8 {
    const arena = init.arena.allocator();
    var ctx: Ctx = .{ .io = init.io, .arena = arena, .env = init.environ_map };
    const args = init.minimal.args.toSlice(arena) catch return 1;
    ctx.sweep();
    const cmd = if (args.len > 1) args[1] else "";
    const result = if (std.mem.eql(u8, cmd, "check"))
        ctx.check(args[2..])
    else if (std.mem.eql(u8, cmd, "install"))
        ctx.install(args[2..])
    else
        ctx.fail("usage: MakeUpdate check|install --repo Owner/Name ... (see src/updater/main.zig)", .{});
    result catch |err| {
        const msg = if (ctx.msg.len > 0) ctx.msg else @errorName(err);
        ctx.log("error: {s}", .{msg});
        ctx.emit(.{ .ok = false, .@"error" = msg });
        ctx.flushLog();
        return 1;
    };
    ctx.flushLog();
    return 0;
}

const Ctx = struct {
    io: Io,
    arena: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    msg: []const u8 = "",
    log_buf: std.ArrayList(u8) = .empty,
    session: ?*anyopaque = null,
    allow_http: bool = false,
    /// Host of the API base: the only host besides rel.download_hosts that fetch() talks to.
    api_host: []const u8 = "",

    /// Records the error text for the JSON line and returns error.Failed.
    fn fail(c: *Ctx, comptime fmt: []const u8, args: anytype) error{Failed} {
        c.msg = c.arena.print(fmt, args) catch "out of memory";
        return error.Failed;
    }

    fn emit(c: *Ctx, value: anytype) void {
        var buf: [4096]u8 = undefined;
        var out = Io.File.stdout().writer(c.io, &buf);
        std.json.Stringify.value(value, .{}, &out.interface) catch return;
        out.interface.writeAll("\n") catch return;
        out.interface.flush() catch {}; // the app may be gone (install): nobody reads
    }

    // ------------------------------------------------------------ log (%LOCALAPPDATA%\MakeUpdate\update.log)

    fn log(c: *Ctx, comptime fmt: []const u8, args: anytype) void {
        const now: u64 = @intCast(@max(0, Io.Timestamp.now(c.io, .real).toSeconds()));
        const es: std.time.epoch.EpochSeconds = .{ .secs = now };
        const yd = es.getEpochDay().calculateYearDay();
        const md = yd.calculateMonthDay();
        const ds = es.getDaySeconds();
        c.log_buf.print(c.arena, "{d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}Z ", .{
            yd.year, md.month.numeric(), md.day_index + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(),
        }) catch return;
        c.log_buf.print(c.arena, fmt ++ "\r\n", args) catch return;
    }

    /// Appends this run's lines; keeps the file under 256 KB (drops the older half).
    fn flushLog(c: *Ctx) void {
        const base = c.env.get("LOCALAPPDATA") orelse return;
        const dir_path = fspath.join(c.arena, &.{ base, "MakeUpdate" }) catch return;
        const cwd = Io.Dir.cwd();
        cwd.createDirPath(c.io, dir_path) catch return;
        const path = fspath.join(c.arena, &.{ dir_path, "update.log" }) catch return;
        var old: []const u8 = cwd.readFileAlloc(c.io, path, c.arena, .limited(1 << 20)) catch "";
        if (old.len > 256 * 1024) old = old[old.len / 2 ..];
        const all = std.mem.concat(c.arena, u8, &.{ old, c.log_buf.items }) catch return;
        cwd.writeFile(c.io, .{ .sub_path = path, .data = all }) catch return;
    }

    // ------------------------------------------------------------ arguments / environment

    fn opt(args: []const []const u8, name: []const u8) ?[]const u8 {
        var i: usize = 0;
        while (i + 1 < args.len) : (i += 1) if (std.mem.eql(u8, args[i], name)) return args[i + 1];
        return null;
    }

    fn need(c: *Ctx, args: []const []const u8, name: []const u8) ![]const u8 {
        return opt(args, name) orelse c.fail("missing {s}", .{name});
    }

    /// API base: --api-base > MAKEKIT_UPDATE_API > https://api.github.com. Opens the WinHTTP session.
    fn begin(c: *Ctx, args: []const []const u8) ![]const u8 {
        const raw = opt(args, "--api-base") orelse c.env.get("MAKEKIT_UPDATE_API") orelse default_api;
        const api = std.mem.trimEnd(u8, raw, "/");
        c.allow_http = !std.mem.eql(u8, api, default_api);
        const off = c.env.get("MAKEKIT_NO_UPDATE") orelse "";
        if (!c.allow_http and std.mem.eql(u8, off, "1")) return c.fail("updates are disabled (MAKEKIT_NO_UPDATE=1)", .{});
        c.api_host = (try c.crack(api)).host;
        c.session = WinHttpOpen(L("MakeUpdate"), WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY, null, null, 0) orelse
            return c.fail("WinHttpOpen failed ({d})", .{GetLastError()});
        _ = WinHttpSetTimeouts(c.session, 15_000, 15_000, 30_000, 60_000);
        // fetch() follows redirects itself, so every hop passes the host allow-list.
        var never: u32 = WINHTTP_OPTION_REDIRECT_POLICY_NEVER;
        if (!WinHttpSetOption(c.session, WINHTTP_OPTION_REDIRECT_POLICY, &never, @sizeOf(u32)).toBool())
            return c.fail("WinHttpSetOption failed ({d})", .{GetLastError()});
        return api;
    }

    const Parts = struct { https: bool, host: []const u8, whost: [:0]const u16, port: u16, wpath: [:0]const u16 };

    /// crack() + the host allow-list (rel.hostAllowed).
    fn allowed(c: *Ctx, url: []const u8) !Parts {
        const u = try c.crack(url);
        if (!rel.hostAllowed(u.host, c.api_host)) return c.fail("refusing host {s} ({s})", .{ u.host, url });
        return u;
    }

    /// Splits a URL; refuses non-https (plain http only with an overridden API base).
    fn crack(c: *Ctx, url: []const u8) !Parts {
        const wurl = try std.unicode.utf8ToUtf16LeAllocZ(c.arena, url);
        var uc: UrlComponents = .{};
        if (!WinHttpCrackUrl(wurl.ptr, @intCast(wurl.len), 0, &uc).toBool()) return c.fail("bad URL {s}", .{url});
        const https = uc.nScheme == INTERNET_SCHEME_HTTPS;
        if (!https and !(c.allow_http and uc.nScheme == INTERNET_SCHEME_HTTP)) return c.fail("refusing non-https URL {s}", .{url});
        const whost = try c.arena.dupeSentinel(u16, uc.lpszHostName.?[0..uc.dwHostNameLength], 0);
        return .{
            .https = https,
            .host = std.unicode.utf16LeToUtf8Alloc(c.arena, whost) catch return c.fail("bad host in {s}", .{url}),
            .whost = whost,
            .port = uc.nPort,
            .wpath = if (uc.lpszUrlPath) |p| try c.arena.dupeSentinel(u16, p[0 .. uc.dwUrlPathLength + uc.dwExtraInfoLength], 0) else L("/"),
        };
    }

    fn release(c: *Ctx, api: []const u8, repo: []const u8, what: []const u8) !rel.Release {
        const url = try c.arena.print("{s}/repos/{s}/releases/{s}", .{ api, repo, what });
        var aw: Io.Writer.Allocating = .init(c.arena);
        try c.fetch(url, true, &aw.writer, 4 << 20, null);
        return rel.parseRelease(c.arena, aw.written()) catch c.fail("bad release JSON from {s}", .{url});
    }

    fn sums(c: *Ctx, r: rel.Release, name: []const u8) ![64]u8 {
        const a = r.asset("SHA256SUMS.txt") orelse return c.fail("release {s} has no SHA256SUMS.txt", .{r.tag_name});
        var aw: Io.Writer.Allocating = .init(c.arena);
        try c.fetch(a.browser_download_url, false, &aw.writer, 1 << 20, null);
        return rel.sumFor(aw.written(), name) orelse c.fail("SHA256SUMS.txt has no line for {s}", .{name});
    }

    // ------------------------------------------------------------ check

    fn check(c: *Ctx, args: []const []const u8) !void {
        const repo = try c.need(args, "--repo");
        const current = try c.need(args, "--current");
        if (!rel.validRepo(repo)) return c.fail("bad --repo {s}", .{repo});
        const cur = rel.Version.parse(current) orelse return c.fail("bad --current {s}", .{current});
        const api = try c.begin(args);
        const r = try c.release(api, repo, "latest");
        if (r.draft or r.prerelease) return c.fail("latest release {s} is a draft/pre-release", .{r.tag_name});
        // the tag becomes a file name (setupName) and `install --tag`: no path characters
        if (!rel.safeSegment(r.tag_name)) return c.fail("bad tag_name in the release JSON", .{});
        if (r.html_url.len > 0) _ = try c.allowed(r.html_url); // the app opens `page` in the browser
        const latest = rel.tagVersion(r.tag_name);
        const lv = rel.Version.parse(latest) orelse return c.fail("latest tag {s} is not x.y.z", .{r.tag_name});
        const newer = lv.order(cur) == .gt;
        var setup: []const u8 = "";
        var hex: [64]u8 = @splat('0');
        if (newer) {
            var nb: [256]u8 = undefined;
            const name = rel.setupName(&nb, repo, latest) orelse return c.fail("bad setup name for {s}", .{r.tag_name});
            setup = (r.asset(name) orelse return c.fail("release {s} has no {s}", .{ r.tag_name, name })).browser_download_url;
            _ = try c.allowed(setup); // not fetched here, but the app hands it back to `install`
            hex = try c.sums(r, name);
        }
        c.log("check {s} {s}: latest {s}{s}", .{ repo, current, latest, if (newer) " (newer)" else "" });
        c.emit(.{
            .ok = true,
            .newer = newer,
            .latest = latest,
            .tag = r.tag_name,
            .notes = rel.utf8Prefix(r.body orelse "", 4000),
            .setup = setup,
            .sha256 = if (newer) @as([]const u8, &hex) else "",
            .page = r.html_url,
        });
    }

    // ------------------------------------------------------------ install

    fn install(c: *Ctx, args: []const []const u8) !void {
        const relaunch = opt(args, "--relaunch");
        const pid_s = try c.need(args, "--wait-pid");
        const pid = std.fmt.parseInt(u32, pid_s, 10) catch return c.fail("bad --wait-pid {s}", .{pid_s});
        c.installSteps(args, pid, relaunch) catch |err| {
            // The app usually quit right after starting us: bring it back instead of leaving the user with nothing.
            if (relaunch) |exe| if (!processRunning(pid)) c.launch(exe);
            return err;
        };
    }

    fn installSteps(c: *Ctx, args: []const []const u8, pid: u32, relaunch: ?[]const u8) !void {
        const repo = try c.need(args, "--repo");
        const tag = try c.need(args, "--tag");
        if (!rel.validRepo(repo)) return c.fail("bad --repo {s}", .{repo});
        if (!rel.safeSegment(tag) or rel.Version.parse(tag) == null) return c.fail("bad --tag {s}", .{tag});
        c.log("install {s} {s} (wait pid {d})", .{ repo, tag, pid });
        if (relaunch) |exe| {
            if (!fspath.isAbsolute(exe)) return c.fail("--relaunch must be an absolute path", .{});
            const dat = try fspath.join(c.arena, &.{ fspath.dirname(exe) orelse ".", "portable.dat" });
            if (Io.Dir.cwd().access(c.io, dat, .{})) |_| return c.fail("portable copy: no installer, open the release page", .{}) else |_| {}
        }

        const api = try c.begin(args);
        const r = try c.release(api, repo, try c.arena.print("tags/{s}", .{tag}));
        // only the release that was asked for (and checked by the app); r.tag_name is never used for paths
        if (!std.mem.eql(u8, r.tag_name, tag)) return c.fail("asked for {s}, the server answered with release {s}", .{ tag, r.tag_name });
        var nb: [256]u8 = undefined;
        const name = rel.setupName(&nb, repo, rel.tagVersion(tag)) orelse return c.fail("bad setup name for {s}", .{tag});
        const asset = r.asset(name) orelse return c.fail("release {s} has no {s}", .{ r.tag_name, name });
        const want = try c.sums(r, name);

        // Download into %TEMP%\MakeUpdate-<random>, removed on every way out.
        const tmp = c.env.get("TEMP") orelse c.env.get("TMP") orelse return c.fail("TEMP is not set", .{});
        var rnd: [6]u8 = undefined;
        c.io.random(&rnd);
        const work = try fspath.join(c.arena, &.{ tmp, try c.arena.print("MakeUpdate-{x}", .{&rnd}) });
        const cwd = Io.Dir.cwd();
        cwd.createDirPath(c.io, work) catch |e| return c.fail("cannot create {s}: {t}", .{ work, e });
        defer cwd.deleteTree(c.io, work) catch {};
        const setup = try fspath.join(c.arena, &.{ work, name });
        var hasher: Sha256 = .init(.{});
        {
            var file = cwd.createFile(c.io, setup, .{}) catch |e| return c.fail("cannot write {s}: {t}", .{ setup, e });
            defer file.close(c.io);
            var fbuf: [64 * 1024]u8 = undefined;
            var fw = file.writer(c.io, &fbuf);
            try c.fetch(asset.browser_download_url, false, &fw.interface, 256 << 20, &hasher); // setups are a few MB
            fw.interface.flush() catch |e| return c.fail("cannot write {s}: {t}", .{ setup, e });
        }
        const got = std.fmt.bytesToHex(hasher.finalResult(), .lower);
        if (!std.mem.eql(u8, &got, &want)) return c.fail("SHA-256 mismatch for {s}: got {s}, SHA256SUMS.txt says {s}", .{ name, &got, &want });
        c.log("downloaded {s}, SHA-256 ok", .{name});

        // Wait for the app to exit.
        if (OpenProcess(SYNCHRONIZE, .FALSE, pid)) |h| {
            defer _ = CloseHandle(h);
            if (WaitForSingleObject(h, wait_ms) != 0) return c.fail("the app (pid {d}) did not exit within 60 s", .{pid});
        }

        // Inno's /CLOSEAPPLICATIONS would try to close us (MakeUpdate.exe lives in the app folder and gets
        // replaced): a running exe can be renamed, so step aside; put it back if the setup brought none.
        const self = std.process.executablePathAlloc(c.io, c.arena) catch null;
        const aside = if (self) |s| try c.arena.print("{s}.old", .{s}) else "";
        const moved = if (self) |s| blk: {
            cwd.deleteFile(c.io, aside) catch {};
            if (moveFile(c.arena, s, aside)) break :blk true;
            c.log("cannot move {s} aside ({d})", .{ s, GetLastError() });
            break :blk false;
        } else false;
        defer if (moved) restoreSelf(c, self.?, aside);

        c.log("running {s}", .{name});
        var child = std.process.spawn(c.io, .{
            .argv = &.{ setup, "/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART", "/CLOSEAPPLICATIONS" },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
            .create_no_window = true,
        }) catch |e| return c.fail("cannot start {s}: {t}", .{ name, e });
        const term = child.wait(c.io) catch |e| return c.fail("waiting for {s}: {t}", .{ name, e });
        const code: u32 = switch (term) {
            .exited => |x| x,
            else => 255,
        };
        if (code != 0) return c.fail("{s} exited with code {d}", .{ name, code });
        c.log("setup done", .{});
        if (relaunch) |exe| c.launch(exe);
        c.emit(.{ .ok = true, .tag = r.tag_name });
    }

    /// Starts the app detached (no wait). Errors are only logged.
    fn launch(c: *Ctx, exe: []const u8) void {
        const child = std.process.spawn(c.io, .{
            .argv = &.{exe},
            .cwd = .{ .path = fspath.dirname(exe) orelse "." },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        }) catch |e| {
            c.log("cannot relaunch {s}: {t}", .{ exe, e });
            return;
        };
        if (child.id) |h| _ = CloseHandle(h);
        _ = CloseHandle(child.thread_handle);
        c.log("relaunched {s}", .{exe});
    }

    /// Removes leftovers of earlier runs: <self>.old (a finished install) and stale %TEMP%\MakeUpdate-*.
    fn sweep(c: *Ctx) void {
        const self = std.process.executablePathAlloc(c.io, c.arena) catch return;
        if (!std.ascii.endsWithIgnoreCase(self, ".old")) Io.Dir.cwd().deleteFile(c.io, c.arena.print("{s}.old", .{self}) catch return) catch {};
    }

    // ------------------------------------------------------------ HTTP

    /// GET `url` into `out` (status must be 200, at most `limit` bytes), hashing it when `hasher` is set.
    /// https only, unless the API base was overridden (tests run a plain-http server on 127.0.0.1); every
    /// URL, the first and each redirect hop, must be on an allowed host (rel.hostAllowed).
    fn fetch(c: *Ctx, url: []const u8, api: bool, out: *Io.Writer, limit: u64, hasher: ?*Sha256) !void {
        var next = url;
        for (0..6) |_| next = try c.fetchOnce(next, api, out, limit, hasher) orelse return;
        return c.fail("too many redirects from {s}", .{url});
    }

    /// One request: returns the Location of a redirect, or null once the 200 body is in `out`.
    fn fetchOnce(c: *Ctx, url: []const u8, api: bool, out: *Io.Writer, limit: u64, hasher: ?*Sha256) !?[]const u8 {
        const u = try c.allowed(url);

        const conn = WinHttpConnect(c.session, u.whost.ptr, u.port, 0) orelse return c.netFail(url);
        defer _ = WinHttpCloseHandle(conn);
        const req = WinHttpOpenRequest(conn, L("GET"), u.wpath.ptr, null, null, null, if (u.https) WINHTTP_FLAG_SECURE else 0) orelse return c.netFail(url);
        defer _ = WinHttpCloseHandle(req);
        const headers = if (api) L("Accept: application/vnd.github+json\r\nX-GitHub-Api-Version: 2022-11-28") else L("Accept: application/octet-stream");
        if (!WinHttpSendRequest(req, headers, std.math.maxInt(u32), null, 0, 0, 0).toBool()) return c.netFail(url);
        if (!WinHttpReceiveResponse(req, null).toBool()) return c.netFail(url);
        var status: u32 = 0;
        var len: u32 = @sizeOf(u32);
        if (!WinHttpQueryHeaders(req, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER, null, &status, &len, null).toBool()) return c.netFail(url);
        switch (status) {
            200 => {},
            301, 302, 303, 307, 308 => {
                var loc: [4096]u16 = undefined;
                len = @sizeOf(@TypeOf(loc));
                if (!WinHttpQueryHeaders(req, WINHTTP_QUERY_LOCATION, null, &loc, &len, null).toBool())
                    return c.fail("HTTP {d} without Location from {s}", .{ status, url });
                const to = std.unicode.utf16LeToUtf8Alloc(c.arena, loc[0 .. len / 2]) catch return c.fail("bad Location from {s}", .{url});
                // ponytail: absolute or "/path" Location; a "path" relative to the directory fails in crack().
                if (!std.mem.startsWith(u8, to, "/") or std.mem.startsWith(u8, to, "//")) return to;
                return try c.arena.print("{s}://{s}:{d}{s}", .{ if (u.https) "https" else "http", u.host, u.port, to });
            },
            else => return c.fail("HTTP {d} from {s}", .{ status, url }),
        }

        var buf: [64 * 1024]u8 = undefined;
        var total: u64 = 0;
        while (true) {
            var n: u32 = 0;
            if (!WinHttpReadData(req, &buf, buf.len, &n).toBool()) return c.netFail(url);
            if (n == 0) break;
            total += n;
            if (total > limit) return c.fail("{s} is larger than {d} bytes", .{ url, limit });
            if (hasher) |h| h.update(buf[0..n]);
            out.writeAll(buf[0..n]) catch return c.fail("cannot store {s}", .{url});
        }
        return null;
    }

    fn netFail(c: *Ctx, url: []const u8) error{Failed} {
        const code = GetLastError();
        return switch (code) {
            12002, 12007, 12029 => c.fail("no connection ({d}: {s})", .{ code, url }), // timeout, name not resolved, cannot connect
            else => c.fail("network error {d}: {s}", .{ code, url }),
        };
    }
};

fn restoreSelf(c: *Ctx, self: []const u8, aside: []const u8) void {
    Io.Dir.accessAbsolute(c.io, self, .{}) catch {
        _ = moveFile(c.arena, aside, self);
    };
}

/// MoveFileExW: unlike std's rename it may move a running exe (its image section allows it).
fn moveFile(arena: std.mem.Allocator, from: []const u8, to: []const u8) bool {
    const f = std.unicode.wtf8ToWtf16LeAllocZ(arena, from) catch return false;
    const t = std.unicode.wtf8ToWtf16LeAllocZ(arena, to) catch return false;
    return MoveFileExW(f.ptr, t.ptr, 0).toBool();
}

fn processRunning(pid: u32) bool {
    const h = OpenProcess(SYNCHRONIZE, .FALSE, pid) orelse return false;
    defer _ = CloseHandle(h);
    return WaitForSingleObject(h, 0) == WAIT_TIMEOUT;
}

fn L(comptime s: []const u8) [:0]const u16 {
    return std.unicode.utf8ToUtf16LeStringLiteral(s);
}

// ---------------------------------------------------------------- Win32 (winhttp.h, kernel32)
// ponytail: hand-written externs instead of translating winhttp.h: 11 functions, and MakeUpdate stays free of `w`.

const BOOL = std.os.windows.BOOL;
const HANDLE = *anyopaque;
const LPCWSTR = [*:0]const u16;
const WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY = 4; // Windows 8.1+: system / WPAD proxy
const WINHTTP_FLAG_SECURE = 0x00800000;
const WINHTTP_QUERY_STATUS_CODE = 19;
const WINHTTP_QUERY_FLAG_NUMBER = 0x20000000;
const WINHTTP_QUERY_LOCATION = 33;
const WINHTTP_OPTION_REDIRECT_POLICY = 88;
const WINHTTP_OPTION_REDIRECT_POLICY_NEVER = 0;
const INTERNET_SCHEME_HTTP = 1;
const INTERNET_SCHEME_HTTPS = 2;
const SYNCHRONIZE = 0x00100000;
const WAIT_TIMEOUT = 258;

const UrlComponents = extern struct {
    dwStructSize: u32 = @sizeOf(UrlComponents),
    lpszScheme: ?[*]u16 = null,
    dwSchemeLength: u32 = 0,
    nScheme: c_int = 0,
    lpszHostName: ?[*]u16 = null,
    dwHostNameLength: u32 = std.math.maxInt(u32), // nonzero = "point into the URL"
    nPort: u16 = 0,
    lpszUserName: ?[*]u16 = null,
    dwUserNameLength: u32 = 0,
    lpszPassword: ?[*]u16 = null,
    dwPasswordLength: u32 = 0,
    lpszUrlPath: ?[*]u16 = null,
    dwUrlPathLength: u32 = std.math.maxInt(u32),
    lpszExtraInfo: ?[*]u16 = null,
    dwExtraInfoLength: u32 = std.math.maxInt(u32),
};

extern "winhttp" fn WinHttpOpen(agent: ?LPCWSTR, access: u32, proxy: ?LPCWSTR, bypass: ?LPCWSTR, flags: u32) callconv(.winapi) ?*anyopaque;
extern "winhttp" fn WinHttpCloseHandle(h: ?*anyopaque) callconv(.winapi) BOOL;
extern "winhttp" fn WinHttpSetTimeouts(h: ?*anyopaque, resolve: c_int, connect: c_int, send: c_int, receive: c_int) callconv(.winapi) BOOL;
extern "winhttp" fn WinHttpSetOption(h: ?*anyopaque, option: u32, buf: *const anyopaque, len: u32) callconv(.winapi) BOOL;
extern "winhttp" fn WinHttpCrackUrl(url: [*]const u16, len: u32, flags: u32, uc: *UrlComponents) callconv(.winapi) BOOL;
extern "winhttp" fn WinHttpConnect(session: ?*anyopaque, host: LPCWSTR, port: u16, reserved: u32) callconv(.winapi) ?*anyopaque;
extern "winhttp" fn WinHttpOpenRequest(conn: ?*anyopaque, verb: LPCWSTR, path: LPCWSTR, version: ?LPCWSTR, referrer: ?LPCWSTR, accept: ?*const ?LPCWSTR, flags: u32) callconv(.winapi) ?*anyopaque;
extern "winhttp" fn WinHttpSendRequest(req: ?*anyopaque, headers: ?LPCWSTR, headers_len: u32, optional: ?*anyopaque, optional_len: u32, total_len: u32, context: usize) callconv(.winapi) BOOL;
extern "winhttp" fn WinHttpReceiveResponse(req: ?*anyopaque, reserved: ?*anyopaque) callconv(.winapi) BOOL;
extern "winhttp" fn WinHttpQueryHeaders(req: ?*anyopaque, level: u32, name: ?LPCWSTR, buf: ?*anyopaque, len: *u32, index: ?*u32) callconv(.winapi) BOOL;
extern "winhttp" fn WinHttpReadData(req: ?*anyopaque, buf: [*]u8, n: u32, read: *u32) callconv(.winapi) BOOL;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;
extern "kernel32" fn OpenProcess(access: u32, inherit: BOOL, pid: u32) callconv(.winapi) ?HANDLE;
extern "kernel32" fn WaitForSingleObject(h: HANDLE, ms: u32) callconv(.winapi) u32;
extern "kernel32" fn MoveFileExW(from: LPCWSTR, to: LPCWSTR, flags: u32) callconv(.winapi) BOOL;
extern "kernel32" fn CloseHandle(h: HANDLE) callconv(.winapi) BOOL;

test {
    _ = rel;
}
