//! Languages for kit apps: which one is current, plural categories, "{0}" templates. No translation
//! tables here: each app keeps src/i18n/<code>.zig (one struct type, one value per language).
//!   kit.i18n.apply(settings.lang);              // startup: MAKEKIT_LANG > saved choice > Windows UI language > en
//!   kit.i18n.fmt(&buf, kit.i18n.pick(tr().files, n), .{n})
const std = @import("std");
const im = @import("im");
const w = @import("w");

pub const Lang = enum(u8) {
    en,
    uk,
    pl,
    de,
    es,
    fr,

    /// ISO 639-1 code; the value to persist (`?Lang` null = "auto").
    pub fn code(l: Lang) [:0]const u8 {
        return @tagName(l);
    }

    /// The language's own name, for the language picker.
    pub fn name(l: Lang) [:0]const u8 {
        return switch (l) {
            .en => "English",
            .uk => "Українська",
            .pl => "Polski",
            .de => "Deutsch",
            .es => "Español",
            .fr => "Français",
        };
    }

    /// "pl", "PL", "pl-PL", "pl_PL" -> .pl; anything else (incl. "auto", "") -> null.
    pub fn parse(s: []const u8) ?Lang {
        const end = std.mem.findAny(u8, s, "-_") orelse s.len;
        inline for (comptime std.enums.values(Lang)) |l| {
            if (std.ascii.eqlIgnoreCase(s[0..end], @tagName(l))) return l;
        }
        return null;
    }
};

pub const all = std.enums.values(Lang);

var cur: std.atomic.Value(u8) = .init(@backingInt(Lang.en));

/// The language strings are drawn in. Cheap (one atomic load): call it every frame.
pub fn current() Lang {
    return @fromBackingInt(cur.load(.monotonic));
}

pub fn set(l: Lang) void {
    cur.store(@backingInt(l), .monotonic);
}

/// Makes the effective language current: MAKEKIT_LANG, else `pref` (the user's choice, null = Auto),
/// else the Windows UI language, else English. Call at startup and when the user picks a language.
pub fn apply(pref: ?Lang) void {
    set(forced() orelse pref orelse system());
}

/// MAKEKIT_LANG or the Windows UI language: what Auto means.
pub fn detect() Lang {
    return forced() orelse system();
}

/// The Windows display language (GetUserDefaultUILanguage) if supported, else English.
pub fn system() Lang {
    return fromLangId(w.GetUserDefaultUILanguage()) orelse .en;
}

/// LANGID -> Lang by its primary language (any region).
pub fn fromLangId(langid: u16) ?Lang {
    return switch (langid & 0x3FF) {
        0x09 => .en,
        0x22 => .uk,
        0x15 => .pl,
        0x07 => .de,
        0x0A => .es,
        0x0C => .fr,
        else => null,
    };
}

/// MAKEKIT_LANG=<code> (tests, screenshots); null when unset or unknown.
pub fn forced() ?Lang {
    var wb: [16]u16 = undefined;
    const n = w.GetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral("MAKEKIT_LANG"), &wb, wb.len);
    if (n == 0 or n >= wb.len) return null;
    var b: [16]u8 = undefined;
    for (wb[0..n], 0..) |c, i| b[i] = std.math.cast(u8, c) orelse return null;
    return Lang.parse(b[0..n]);
}

// ---- plurals

pub const Plural = enum { one, few, many, other };

/// CLDR cardinal category for a whole number (the subset kit languages need).
/// en/de/es: one (1) / other. fr: one (0, 1) / other. uk: one (1, 21, 101..) / few (2-4, 22-24..) /
/// many (0, 5-20, 25..). pl: one (only 1) / few (2-4, 22-24.., not 12-14) / many.
pub fn plural(l: Lang, n: u64) Plural {
    const d = n % 10;
    const h = n % 100;
    const few = d >= 2 and d <= 4 and (h < 12 or h > 14);
    return switch (l) {
        .en, .de, .es => if (n == 1) .one else .other,
        .fr => if (n <= 1) .one else .other,
        .uk => if (d == 1 and h != 11) .one else if (few) .few else .many,
        .pl => if (n == 1) .one else if (few) .few else .many,
    };
}

/// A plural string: en/de/es/fr fill one + other, uk/pl fill one + few + many. `check` enforces it.
pub const Forms = struct {
    one: ?[:0]const u8 = null,
    few: ?[:0]const u8 = null,
    many: ?[:0]const u8 = null,
    other: ?[:0]const u8 = null,

    fn get(f: Forms, p: Plural) ?[:0]const u8 {
        return switch (p) {
            .one => f.one,
            .few => f.few,
            .many => f.many,
            .other => f.other,
        };
    }
};

/// The form of `f` for `n` in the current language (missing form -> other / many / one).
pub fn pick(f: Forms, n: u64) [:0]const u8 {
    return f.get(plural(current(), n)) orelse f.other orelse f.many orelse f.one orelse "";
}

fn needs(l: Lang, p: Plural) bool {
    return switch (l) {
        .en, .de, .es, .fr => p == .one or p == .other,
        .uk, .pl => p != .other,
    };
}

// ---- numbers

/// Decimal separator of `l` (CLDR): '.' in English, ',' in the others.
pub fn decimalSep(l: Lang) u8 {
    return if (l == .en) '.' else ',';
}

/// Digit-group separator of `l` (CLDR): en ",", de/es ".", uk/pl/fr no-break space (U+00A0).
pub fn groupSep(l: Lang) []const u8 {
    return switch (l) {
        .en => ",",
        .de, .es => ".",
        .uk, .pl, .fr => "\u{A0}",
    };
}

// ---- templates

/// Replaces {0}..{9} in `template` with args[i] (strings as-is, numbers {d}, types with format() {f});
/// other braces stay literal. Truncates on a UTF-8 boundary when `buf` is too small. Result lives in `buf`.
pub fn fmt(buf: []u8, template: []const u8, args: anytype) [:0]const u8 {
    std.debug.assert(buf.len > 0);
    const out = buf[0 .. buf.len - 1];
    var n: usize = 0;
    var i: usize = 0;
    while (i < template.len) {
        if (template[i] == '{' and i + 2 < template.len and template[i + 2] == '}' and std.ascii.isDigit(template[i + 1])) {
            const idx = template[i + 1] - '0';
            var used = false;
            inline for (0..args.len) |k| {
                if (k == idx) {
                    putArg(out, &n, args[k]);
                    used = true;
                }
            }
            if (used) {
                i += 3;
                continue;
            }
        }
        put(out, &n, template[i .. i + 1]);
        i += 1;
    }
    if (n == out.len) { // maybe cut inside a sequence: drop the incomplete tail
        var j = n;
        while (j > 0 and n - j < 4) {
            j -= 1;
            if (out[j] & 0xC0 != 0x80) {
                const len = std.unicode.utf8ByteSequenceLength(out[j]) catch 1;
                if (j + len > n) n = j;
                break;
            }
        }
    }
    buf[n] = 0;
    return buf[0..n :0];
}

fn put(out: []u8, n: *usize, s: []const u8) void {
    const k = @min(s.len, out.len - n.*);
    @memcpy(out[n.*..][0..k], s[0..k]);
    n.* += k;
}

fn putArg(out: []u8, n: *usize, arg: anytype) void {
    const T = @TypeOf(arg);
    switch (@typeInfo(T)) {
        .pointer => put(out, n, arg), // []const u8, [:0]const u8, *const [N:0]u8
        else => {
            const spec = switch (@typeInfo(T)) {
                .int, .comptime_int, .float, .comptime_float => "{d}",
                else => "{f}",
            };
            var tmp: [256]u8 = undefined;
            const s: []const u8 = std.mem.print(&tmp, spec, .{arg}) catch &tmp;
            put(out, n, s);
        },
    }
}

fn placeholders(s: []const u8) u10 {
    var m: u10 = 0;
    var i: usize = 0;
    while (i + 2 < s.len) : (i += 1) {
        if (s[i] == '{' and s[i + 2] == '}' and std.ascii.isDigit(s[i + 1])) m |= @as(u10, 1) << @intCast(s[i + 1] - '0');
    }
    return m;
}

// ---- table check (for app tests)

/// First field of the strings table `t` that is wrong for `lang`, compared with the English `base`:
/// an empty string, a plural form `lang` needs but lacks (or one it does not use), or a {N} placeholder
/// set that differs from `base`. null = all good. Nested structs are walked; field types:
/// `[:0]const u8`, `Forms`, structs of those.
pub fn check(comptime T: type, base: *const T, t: *const T, lang: Lang) ?[]const u8 {
    const info = @typeInfo(T).@"struct";
    inline for (info.field_names, info.field_types) |f, FT| {
        const b = @field(base, f);
        const v = @field(t, f);
        const bad = if (FT == [:0]const u8)
            (v.len == 0 and b.len != 0) or placeholders(v) != placeholders(b)
        else if (FT == Forms)
            badForms(b, v, lang)
        else
            check(FT, &b, &v, lang) != null;
        if (bad) {
            if (FT != [:0]const u8 and FT != Forms) return check(FT, &b, &v, lang);
            return f;
        }
    }
    return null;
}

fn badForms(b: Forms, v: Forms, lang: Lang) bool {
    var want: u10 = 0;
    for ([_]?[:0]const u8{ b.one, b.few, b.many, b.other }) |s| if (s) |x| {
        want |= placeholders(x);
    };
    var got: u10 = 0;
    for (std.enums.values(Plural)) |p| {
        const s = v.get(p);
        if (needs(lang, p) != (s != null)) return true;
        if (s) |x| {
            if (x.len == 0 or placeholders(x) & ~want != 0) return true;
            got |= placeholders(x);
        }
    }
    return got != want;
}

// ---- language picker

/// Combo "Auto (system)" + the six languages in their own names. `pref` null = Auto. On a change it
/// updates `pref`, calls `apply` (takes effect next frame) and returns true: persist `pref` then.
/// Automation: items `<name>##lang_<code>` and `<auto_label>##lang_auto`.
pub fn combo(label: [*:0]const u8, auto_label: []const u8, pref: *?Lang) bool {
    var ab: [128]u8 = undefined;
    const auto: [:0]const u8 = std.mem.printSentinel(&ab, "{s}##lang_auto", .{auto_label}, 0) catch "Auto##lang_auto";
    var pb: [128]u8 = undefined;
    const preview: [:0]const u8 = if (pref.*) |l| l.name() else std.mem.printSentinel(&pb, "{s}", .{auto_label}, 0) catch "Auto";
    var changed = false;
    if (im.ImGui_BeginCombo(label, preview.ptr, 0)) {
        if (im.ImGui_SelectableEx(auto.ptr, pref.* == null, 0, .{ .x = 0, .y = 0 }) and pref.* != null) {
            pref.* = null;
            changed = true;
        }
        inline for (comptime std.enums.values(Lang)) |l| {
            const item = comptime l.name() ++ "##lang_" ++ @tagName(l);
            if (im.ImGui_SelectableEx(item, pref.* == l, 0, .{ .x = 0, .y = 0 }) and pref.* != l) {
                pref.* = l;
                changed = true;
            }
        }
        im.ImGui_EndCombo();
    }
    if (changed) apply(pref.*);
    return changed;
}

// ---- tests

const testing = std.testing;

test "plural categories" {
    const Case = struct { Lang, u64, Plural };
    for ([_]Case{
        .{ .en, 0, .other }, .{ .en, 1, .one },   .{ .en, 2, .other },  .{ .de, 1, .one },    .{ .es, 21, .other },
        .{ .fr, 0, .one },   .{ .fr, 1, .one },   .{ .fr, 2, .other },  .{ .uk, 0, .many },   .{ .uk, 1, .one },
        .{ .uk, 2, .few },   .{ .uk, 4, .few },   .{ .uk, 5, .many },   .{ .uk, 11, .many },  .{ .uk, 12, .many },
        .{ .uk, 14, .many }, .{ .uk, 21, .one },  .{ .uk, 22, .few },   .{ .uk, 111, .many }, .{ .uk, 101, .one },
        .{ .pl, 0, .many },  .{ .pl, 1, .one },   .{ .pl, 2, .few },    .{ .pl, 5, .many },   .{ .pl, 12, .many },
        .{ .pl, 21, .many }, .{ .pl, 22, .few },  .{ .pl, 104, .few },  .{ .pl, 112, .many }, .{ .uk, 1_000_001, .one },
    }) |c| {
        testing.expectEqual(c[2], plural(c[0], c[1])) catch |e| {
            std.debug.print("{t} {d}\n", .{ c[0], c[1] });
            return e;
        };
    }
}

test "codes, names, parse, LANGID" {
    try testing.expectEqual(Lang.pl, Lang.parse("pl").?);
    try testing.expectEqual(Lang.uk, Lang.parse("UK-ua").?);
    try testing.expectEqual(Lang.de, Lang.parse("de_AT").?);
    try testing.expectEqual(null, Lang.parse("auto"));
    try testing.expectEqual(null, Lang.parse(""));
    try testing.expectEqual(null, Lang.parse("ru"));
    for (all) |l| try testing.expectEqual(l, Lang.parse(l.code()).?);
    try testing.expectEqualStrings("Українська", Lang.uk.name());
    try testing.expectEqual(Lang.fr, fromLangId(0x0C0C).?); // fr-CA
    try testing.expectEqual(Lang.en, fromLangId(0x0809).?); // en-GB
    try testing.expectEqual(null, fromLangId(0x0419));
    _ = system(); // whatever Windows says, it is a Lang
    set(.pl);
    try testing.expectEqual(Lang.pl, current());
    set(.en);
}

test "fmt templates" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("Usunięto 3 z 10: a.txt", fmt(&buf, "Usunięto {0} z {1}: {2}", .{ 3, @as(u64, 10), "a.txt" }));
    try testing.expectEqualStrings("{1} {x} {0", fmt(&buf, "{1} {x} {0", .{"a"}));
    try testing.expectEqualStrings("b a", fmt(&buf, "{1} {0}", .{ "a", "b" }));
    var small: [6]u8 = undefined; // 5 bytes of text: "ab" + "ї" (2) + 1 byte of the next "ї" -> cut before it
    const cut = fmt(&small, "ab{0}", .{"її"});
    try testing.expectEqualStrings("abї", cut);
    try testing.expectEqual(0, cut.ptr[cut.len]);
}

test "pick + check" {
    const S = struct {
        title: [:0]const u8,
        files: Forms,
        sub: struct { ok: [:0]const u8 },
    };
    const en: S = .{ .title = "Delete {0}?", .files = .{ .one = "{0} file", .other = "{0} files" }, .sub = .{ .ok = "OK" } };
    const uk: S = .{ .title = "Видалити {0}?", .files = .{ .one = "{0} файл", .few = "{0} файли", .many = "{0} файлів" }, .sub = .{ .ok = "Гаразд" } };
    try testing.expectEqual(null, check(S, &en, &en, .en));
    try testing.expectEqual(null, check(S, &en, &uk, .uk));
    try testing.expectEqualStrings("files", check(S, &en, &uk, .en).?); // uk forms are wrong for English
    var bad = uk;
    bad.title = "Видалити?";
    try testing.expectEqualStrings("title", check(S, &en, &bad, .uk).?);
    bad = uk;
    bad.sub.ok = "";
    try testing.expectEqualStrings("ok", check(S, &en, &bad, .uk).?);

    set(.uk);
    defer set(.en);
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("22 файли", fmt(&buf, pick(uk.files, 22), .{22}));
    try testing.expectEqualStrings("25 файлів", fmt(&buf, pick(uk.files, 25), .{25}));
    try testing.expectEqualStrings("1 file", fmt(&buf, pick(en.files, 1), .{1})); // uk "one" of the en table
}
