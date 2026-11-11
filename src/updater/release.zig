//! Pure parts of the updater (no I/O), shared by MakeUpdate.exe and kit.update: versions, SHA256SUMS.txt,
//! the GitHub release JSON and the one-line result of `MakeUpdate check`.
const std = @import("std");

pub const Version = struct {
    major: u32,
    minor: u32,
    patch: u32,
    /// "-rc.1" suffix: sorts before the same x.y.z without one (the text after '-' is not compared).
    pre: bool = false,

    /// "1.2.3", "v1.2.3", "1.2.3-rc.1", "1.2.3+build"; null unless exactly three numbers.
    pub fn parse(s: []const u8) ?Version {
        var t = std.mem.trim(u8, s, " \t\r\n");
        if (t.len > 0 and (t[0] == 'v' or t[0] == 'V')) t = t[1..];
        const end = std.mem.findAny(u8, t, "-+") orelse t.len;
        var it = std.mem.splitScalar(u8, t[0..end], '.');
        var v: Version = .{ .major = 0, .minor = 0, .patch = 0, .pre = end < t.len and t[end] == '-' };
        inline for (.{ "major", "minor", "patch" }) |f| {
            const part = it.next() orelse return null;
            @field(v, f) = std.fmt.parseInt(u32, part, 10) catch return null;
        }
        if (it.next() != null) return null;
        return v;
    }

    pub fn order(a: Version, b: Version) std.math.Order {
        inline for (.{ "major", "minor", "patch" }) |f| {
            const o = std.math.order(@field(a, f), @field(b, f));
            if (o != .eq) return o;
        }
        if (a.pre == b.pre) return .eq;
        return if (a.pre) .lt else .gt;
    }
};

/// true when `latest` is a higher version than `current`; null if either is not x.y.z.
pub fn isNewer(latest: []const u8, current: []const u8) ?bool {
    const l = Version.parse(latest) orelse return null;
    const c = Version.parse(current) orelse return null;
    return l.order(c) == .gt;
}

/// The version text of a tag: "v2.1.0" -> "2.1.0".
pub fn tagVersion(tag: []const u8) []const u8 {
    return if (tag.len > 0 and (tag[0] == 'v' or tag[0] == 'V')) tag[1..] else tag;
}

/// Lowercase hex SHA-256 of `name` in a SHA256SUMS.txt. Accepts sha256sum ("<hex>  name", "<hex> *name"),
/// upper-case hex (PowerShell Get-FileHash), CRLF and a UTF-8 BOM. null if absent or malformed.
pub fn sumFor(sums: []const u8, name: []const u8) ?[64]u8 {
    var lines = std.mem.splitScalar(u8, sums, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, "\xEF\xBB\xBF \t\r");
        if (line.len < 66 or (line[64] != ' ' and line[64] != '\t')) continue;
        var file = std.mem.trimStart(u8, line[64..], " \t");
        if (file.len > 0 and file[0] == '*') file = file[1..];
        if (!std.ascii.eqlIgnoreCase(file, name)) continue;
        var out: [64]u8 = undefined;
        for (line[0..64], &out) |c, *o| {
            if (!std.ascii.isHex(c)) return null;
            o.* = std.ascii.toLower(c);
        }
        return out;
    }
    return null;
}

/// The part of a GitHub `releases/latest` / `releases/tags/<tag>` response the updater reads.
pub const Release = struct {
    tag_name: []const u8,
    html_url: []const u8 = "",
    body: ?[]const u8 = null,
    draft: bool = false,
    prerelease: bool = false,
    assets: []const Asset = &.{},

    pub const Asset = struct {
        name: []const u8,
        browser_download_url: []const u8,
        size: u64 = 0,
    };

    pub fn asset(r: Release, name: []const u8) ?Asset {
        for (r.assets) |a| if (std.ascii.eqlIgnoreCase(a.name, name)) return a;
        return null;
    }
};

/// Parses a release object; strings are allocated in `arena`.
pub fn parseRelease(arena: std.mem.Allocator, json: []const u8) !Release {
    return std.json.parseFromSliceLeaky(Release, arena, json, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
}

/// "MakeMD/MakeCleaner" + "2.1.0" -> "MakeCleaner-Setup-2.1.0.exe". null if `repo` has no '/' or the name
/// would not be a plain file name (it is joined to the download folder).
pub fn setupName(buf: []u8, repo: []const u8, version: []const u8) ?[]const u8 {
    _, const app = std.mem.cutScalar(u8, repo, '/') orelse return null;
    const name = std.mem.print(buf, "{s}-Setup-{s}.exe", .{ app, version }) catch return null;
    return if (safeSegment(name)) name else null;
}

/// "Owner/Name" of letters, digits, '.', '_', '-' (it goes into a URL path).
pub fn validRepo(repo: []const u8) bool {
    const owner, const name = std.mem.cutScalar(u8, repo, '/') orelse return false;
    return safeSegment(owner) and safeSegment(name);
}

/// Hosts a release may point downloads at (and GitHub redirects them to).
pub const download_hosts = [_][]const u8{ "github.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com" };

/// May MakeUpdate fetch from `host`? Only the API host itself (api.github.com, or the test --api-base)
/// and `download_hosts`: a release JSON (or a redirect) pointing anywhere else is refused, else the
/// SHA256SUMS.txt it names could come from the same attacker as the setup.
pub fn hostAllowed(host: []const u8, api_host: []const u8) bool {
    if (api_host.len > 0 and std.ascii.eqlIgnoreCase(host, api_host)) return true;
    for (download_hosts) |h| if (std.ascii.eqlIgnoreCase(host, h)) return true;
    return false;
}

pub fn safeSegment(s: []const u8) bool {
    if (s.len == 0 or s.len > 100 or std.mem.eql(u8, s, ".") or std.mem.eql(u8, s, "..")) return false;
    for (s) |c| if (!(std.ascii.isAlphanumeric(c) or c == '.' or c == '_' or c == '-')) return false;
    return true;
}

/// One stdout line of `MakeUpdate check` (and of a failed `install`). Every field has a default, so the
/// failure line `{"ok":false,"error":"..."}` parses into the same struct.
pub const CheckResult = struct {
    ok: bool = false,
    newer: bool = false,
    /// "2.1.0"
    latest: []const u8 = "",
    /// "v2.1.0": pass it to `MakeUpdate install --tag`.
    tag: []const u8 = "",
    /// Release body (Markdown), cut to 4000 bytes.
    notes: []const u8 = "",
    /// Download URL of <App>-Setup-<latest>.exe (only when newer).
    setup: []const u8 = "",
    /// Its SHA-256 from the release's SHA256SUMS.txt (only when newer).
    sha256: []const u8 = "",
    /// Release page (html_url): portable copies open this instead of installing.
    page: []const u8 = "",
    @"error": []const u8 = "",
};

/// `s` cut to at most `max` bytes without splitting a UTF-8 sequence.
pub fn utf8Prefix(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var n = max;
    while (n > 0 and s[n] & 0xC0 == 0x80) n -= 1;
    return s[0..n];
}

const testing = std.testing;

test "Version: parse and order (semver x.y.z, pre-release before release)" {
    const v = Version.parse("v2.10.3").?;
    try testing.expect(v.major == 2 and v.minor == 10 and v.patch == 3 and !v.pre);
    try testing.expect(Version.parse("1.2.3-rc.1").?.pre);
    try testing.expect(!Version.parse("1.2.3+build.7").?.pre);
    for ([_][]const u8{ "", "v", "1", "1.2", "1.2.3.4", "1..3", "a.b.c", "1.2.x", "-1.2.3", "1.2.3 4" }) |bad|
        try testing.expectEqual(null, Version.parse(bad));

    try testing.expectEqual(true, isNewer("2.1.0", "2.0.9"));
    try testing.expectEqual(true, isNewer("v2.10.0", "2.9.0")); // numeric, not text order
    try testing.expectEqual(true, isNewer("3.0.0", "2.99.99"));
    try testing.expectEqual(false, isNewer("2.1.0", "2.1.0"));
    try testing.expectEqual(false, isNewer("2.0.0", "2.1.0"));
    try testing.expectEqual(true, isNewer("2.1.0", "2.1.0-rc.2"));
    try testing.expectEqual(false, isNewer("2.1.0-rc.2", "2.1.0"));
    try testing.expectEqual(null, isNewer("latest", "2.1.0"));
    try testing.expectEqualStrings("2.1.0", tagVersion("v2.1.0"));
}

test "SHA256SUMS.txt: sha256sum, PowerShell, BOM, CRLF" {
    const a = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
    const sums = "\xEF\xBB\xBF" ++ a ++ "  Demo-Setup-1.2.0.exe\r\n" ++
        "BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AE *Demo-1.2.0-portable.zip\r\n" ++
        "zz7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad  bad.exe\n";
    try testing.expectEqualStrings(a, &sumFor(sums, "Demo-Setup-1.2.0.exe").?);
    try testing.expectEqualStrings(a[0..63] ++ "e", &sumFor(sums, "demo-1.2.0-PORTABLE.zip").?);
    try testing.expectEqual(null, sumFor(sums, "bad.exe"));
    try testing.expectEqual(null, sumFor(sums, "Demo-Setup-1.2"));
    try testing.expectEqual(null, sumFor("", "x"));
    try testing.expectEqual(null, sumFor(a ++ "Demo-Setup-1.2.0.exe", "Demo-Setup-1.2.0.exe")); // no separator
}

test "GitHub releases/latest response (captured shape) -> Release" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const r = try parseRelease(arena.allocator(), @embedFile("testdata/releases-latest.json"));
    try testing.expectEqualStrings("v2.1.0", r.tag_name);
    try testing.expect(!r.draft and !r.prerelease);
    try testing.expectEqualStrings("https://github.com/MakeMD/MakeCleaner/releases/tag/v2.1.0", r.html_url);
    try testing.expect(std.mem.startsWith(u8, r.body.?, "## What's new"));
    var nb: [128]u8 = undefined;
    const setup = r.asset(setupName(&nb, "MakeMD/MakeCleaner", tagVersion(r.tag_name)).?).?;
    try testing.expectEqualStrings("https://github.com/MakeMD/MakeCleaner/releases/download/v2.1.0/MakeCleaner-Setup-2.1.0.exe", setup.browser_download_url);
    try testing.expectEqual(2711552, setup.size);
    try testing.expect(r.asset("SHA256SUMS.txt") != null);
    try testing.expect(r.asset("MakeCleaner-Setup-2.0.0.exe") == null);
    // body: null and no assets are valid too
    const bare = try parseRelease(arena.allocator(), "{\"tag_name\":\"v1.0.0\",\"body\":null,\"extra\":{\"x\":[1]}}");
    try testing.expect(bare.body == null and bare.assets.len == 0);
    try testing.expectError(error.MissingField, parseRelease(arena.allocator(), "{\"message\":\"Not Found\"}"));
}

test "hostAllowed: API host + GitHub download hosts only" {
    for ([_][]const u8{ "api.github.com", "github.com", "GitHub.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com" }) |h|
        try testing.expect(hostAllowed(h, "api.github.com"));
    try testing.expect(hostAllowed("127.0.0.1", "127.0.0.1")); // test --api-base
    for ([_][]const u8{ "evil.invalid", "localhost", "github.com.evil.invalid", "evilgithub.com", "github.com.", "x.objects.githubusercontent.com", "" }) |h|
        try testing.expect(!hostAllowed(h, "127.0.0.1"));
    try testing.expect(!hostAllowed("api.github.com", "127.0.0.1")); // an overridden base never reaches the real API
    try testing.expect(!hostAllowed("", ""));
}

test "CheckResult: success and failure lines, repo/tag validation, UTF-8 cut" {
    const ok = try std.json.parseFromSlice(CheckResult, testing.allocator,
        \\{"ok":true,"newer":true,"latest":"2.1.0","tag":"v2.1.0","notes":"x","setup":"https://h/s.exe","sha256":"ab","page":"https://h/p"}
    , .{});
    defer ok.deinit();
    try testing.expect(ok.value.ok and ok.value.newer and ok.value.@"error".len == 0);
    try testing.expectEqualStrings("v2.1.0", ok.value.tag);
    const bad = try std.json.parseFromSlice(CheckResult, testing.allocator, "{\"ok\":false,\"error\":\"no connection (12007)\"}", .{});
    defer bad.deinit();
    try testing.expect(!bad.value.ok and !bad.value.newer);
    try testing.expectEqualStrings("no connection (12007)", bad.value.@"error");

    try testing.expect(validRepo("MakeMD/MakeCleaner") and validRepo("a-b/c.d_e"));
    for ([_][]const u8{ "MakeMD", "/x", "x/", "a/b/c", "a/..", "a/b?x=1", "a/b c", "a/%2e" }) |r| try testing.expect(!validRepo(r));
    var nb: [64]u8 = undefined;
    try testing.expectEqualStrings("Demo-Setup-1.2.0.exe", setupName(&nb, "MakeMD/Demo", "1.2.0").?);
    for ([_][]const u8{ "1.2.0-a/../../pwned", "1.2.0-a\\..\\x", "1.2.0 x" }) |v| try testing.expectEqual(null, setupName(&nb, "MakeMD/Demo", v));
    try testing.expectEqualStrings("ab", utf8Prefix("ab\u{0416}", 3));
    try testing.expectEqualStrings("ab\u{0416}", utf8Prefix("ab\u{0416}", 4));
}
