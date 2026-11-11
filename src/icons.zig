//! The shared Carbon Mint icon set (icons/*.png, 128 px masters embedded in the exe).
//! `get(name, logical_px)` decodes a master with WIC, scales it (HighQualityCubic, premultiplied, so no
//! dark fringes) to exactly logical_px x DPI scale and uploads a D3D11 texture, cached per (name, px).
//! `<exe dir>\icons\<name>.png` (any size, square) wins over the embedded master.
//! UI thread only; the App drops the cache on DPI change, device reset and deinit.
const std = @import("std");
const im = @import("im");
const w = @import("w");
const app = @import("app.zig");
const win = @import("win.zig");
const embed = @import("kit_icons");

pub const Name = enum {
    delete,
    find,
    info,
    settings,
    lock,
    drive,
    favorite,
    up,
    warning,
    folder,
    document,
    ok,
    danger, // shared (danger = the warning triangle in palette danger: errors, destructive confirms)
    add,
    extract,
    @"test",
    view,
    convert,
    report,
    refresh,
    archive_locked,
    folder_protected,
    history,
    pack,
    copy, // MakePack
    cleaner,
    registry,
    tools,
    options,
    uninstall,
    startup,
    duplicates,
    disk_analyzer,
    wipe,
    restore,
    cookies,
    schedule,
    folder_add,
    folder_remove, // MakeCleaner
};

const masters = blk: {
    var a: [std.enums.values(Name).len][]const u8 = undefined;
    for (std.enums.values(Name), 0..) |n, i| a[i] = embed.png(@tagName(n));
    break :blk a;
};

/// Bytes of all embedded masters (what the icon set adds to an exe).
pub const embedded_bytes = blk: {
    var n: usize = 0;
    for (masters) |m| n += m.len;
    break :blk n;
};

const Key = struct { name: Name, px: u16 };
var cache: std.AutoHashMapUnmanaged(Key, u64) = .empty; // value: ID3D11ShaderResourceView*, 0 = failed
var cache_gpa: ?std.mem.Allocator = null;
var factory: [*c]w.IWICImagingFactory = null;

/// Texture of `name` at `logical_px` (x DPI scale, rounded) or null (no App/device, decode failed).
/// Draw it at exactly that pixel size on whole pixels (kit.ui.icon / iconButton do).
pub fn get(name: Name, logical_px: f32) ?im.ImTextureRef {
    const a = app.current() orelse return null;
    const key: Key = .{ .name = name, .px = @intFromFloat(std.math.clamp(@round(logical_px * a.scale()), 1, 512)) };
    const t = cache.get(key) orelse blk: {
        const t = load(a, key) catch 0;
        cache.put(a.gpa, key, t) catch {};
        cache_gpa = a.gpa;
        break :blk t;
    };
    return if (t == 0) null else .{ ._TexData = null, ._TexID = t };
}

/// Pixel size `get` uses for `logical_px` at the current DPI.
pub fn pixels(logical_px: f32) f32 {
    const s = if (app.current()) |a| a.scale() else 1;
    return std.math.clamp(@round(logical_px * s), 1, 512);
}

/// Drops every texture (and the WIC factory); the next `get` decodes again.
pub fn releaseAll() void {
    var it = cache.valueIterator();
    while (it.next()) |v| if (v.* != 0) win.release(@as([*c]w.ID3D11ShaderResourceView, @ptrFromInt(v.*)));
    if (cache_gpa) |g| cache.deinit(g);
    cache = .empty;
    if (factory != null) win.release(factory);
    factory = null;
}

const CLSID_WICImagingFactory = guid(0xcacaf262, 0x9370, 0x4615, .{ 0xa1, 0x3b, 0x9f, 0x55, 0x39, 0xda, 0x4c, 0x0a });
const IID_IWICImagingFactory = guid(0xec5ec8a9, 0xc395, 0x4314, .{ 0x9c, 0x77, 0x54, 0xd7, 0xa9, 0x35, 0xff, 0x70 });
const GUID_WICPixelFormat32bppPBGRA = guid(0x6fddc324, 0x4e03, 0x4bfe, .{ 0xb1, 0x85, 0x3d, 0x77, 0x76, 0x8d, 0xc9, 0x10 });

// mingw ships these WIC GUIDs in no library (DEFINE_GUID without INITGUID = unresolved extern).
fn guid(d1: u32, d2: u16, d3: u16, d4: [8]u8) w.GUID {
    return .{ .Data1 = d1, .Data2 = d2, .Data3 = d3, .Data4 = d4 };
}

fn load(a: *app.App, key: Key) !u64 {
    if (a.device == null) return error.NoDevice;
    if (factory == null) try win.check(w.CoCreateInstance(&CLSID_WICImagingFactory, null, w.CLSCTX_INPROC_SERVER, &IID_IWICImagingFactory, @ptrCast(&factory)));
    const px: usize = key.px;
    const buf = try a.gpa.alloc(u32, px * px);
    defer a.gpa.free(buf);
    const from_file = if (overridePath(a.gpa, key.name)) |p| blk: {
        defer a.gpa.free(p);
        break :blk decode(p, null, key.px, buf);
    } else |_| error.NoOverride;
    from_file catch try decode(null, masters[@backingInt(key.name)], key.px, buf);

    // WIC scaled in premultiplied space; ImGui's DX11 blend (SRC_ALPHA, INV_SRC_ALPHA) wants straight alpha.
    for (buf) |*p| {
        const al = p.* >> 24;
        if (al == 0 or al == 255) continue;
        var out = p.* & 0xFF000000;
        inline for (.{ 0, 8, 16 }) |sh| out |= @as(u32, @min(255, (((p.* >> sh) & 0xFF) * 255 + al / 2) / al)) << sh;
        p.* = out;
    }
    return texture(a.device, buf, px);
}

/// `<exe dir>\icons\<name>.png` as a NUL-terminated wide path, error.NoOverride when there is no such file.
fn overridePath(gpa: std.mem.Allocator, name: Name) ![:0]u16 {
    var exe: [1024]u16 = undefined;
    const n = w.GetModuleFileNameW(null, &exe, exe.len);
    if (n == 0 or n >= exe.len) return error.NoOverride; // ponytail: exe paths > 1023 units get no override
    const dir = exe[0 .. (std.mem.findScalarLast(u16, exe[0..n], '\\') orelse return error.NoOverride) + 1];
    var nb: [40]u8 = undefined;
    const file = try std.mem.print(&nb, "icons\\{t}.png", .{name});
    const p = try gpa.allocSentinel(u16, dir.len + file.len, 0);
    @memcpy(p[0..dir.len], dir);
    for (file, p[dir.len..]) |c, *o| o.* = c; // ASCII
    const attr = w.GetFileAttributesW(p.ptr);
    if (attr == w.INVALID_FILE_ATTRIBUTES or attr & w.FILE_ATTRIBUTE_DIRECTORY != 0) {
        gpa.free(p);
        return error.NoOverride;
    }
    return p;
}

/// PNG (file `path` or bytes `mem`) -> px x px premultiplied BGRA in `out`.
fn decode(path: ?[:0]const u16, mem: ?[]const u8, px: u16, out: []u32) !void {
    const f = factory;
    var dec: [*c]w.IWICBitmapDecoder = null;
    if (path) |p| {
        try win.check(f.*.lpVtbl.*.CreateDecoderFromFilename.?(f, p.ptr, null, w.GENERIC_READ, w.WICDecodeMetadataCacheOnDemand, &dec));
    } else {
        var stream: [*c]w.IWICStream = null;
        try win.check(f.*.lpVtbl.*.CreateStream.?(f, &stream));
        defer win.release(stream);
        try win.check(stream.*.lpVtbl.*.InitializeFromMemory.?(stream, @constCast(mem.?.ptr), @intCast(mem.?.len)));
        try win.check(f.*.lpVtbl.*.CreateDecoderFromStream.?(f, @ptrCast(stream), null, w.WICDecodeMetadataCacheOnDemand, &dec));
    }
    defer win.release(dec);
    var frame: [*c]w.IWICBitmapFrameDecode = null;
    try win.check(dec.*.lpVtbl.*.GetFrame.?(dec, 0, &frame));
    defer win.release(frame);
    var conv: [*c]w.IWICFormatConverter = null;
    try win.check(f.*.lpVtbl.*.CreateFormatConverter.?(f, &conv));
    defer win.release(conv);
    try win.check(conv.*.lpVtbl.*.Initialize.?(conv, @ptrCast(frame), &GUID_WICPixelFormat32bppPBGRA, w.WICBitmapDitherTypeNone, null, 0, w.WICBitmapPaletteTypeCustom));
    var scaler: [*c]w.IWICBitmapScaler = null;
    try win.check(f.*.lpVtbl.*.CreateBitmapScaler.?(f, &scaler));
    defer win.release(scaler);
    // ponytail: a non-square override png is stretched to a square
    try win.check(scaler.*.lpVtbl.*.Initialize.?(scaler, @ptrCast(conv), px, px, 4)); // WICBitmapInterpolationModeHighQualityCubic (Win10+; missing in mingw headers)
    try win.check(scaler.*.lpVtbl.*.CopyPixels.?(scaler, null, @as(u32, px) * 4, @intCast(out.len * 4), @ptrCast(out.ptr)));
}

fn texture(dev: [*c]w.ID3D11Device, px: []const u32, side: usize) !u64 {
    var desc = std.mem.zeroes(w.D3D11_TEXTURE2D_DESC);
    desc.Width = @intCast(side);
    desc.Height = @intCast(side);
    desc.MipLevels = 1;
    desc.ArraySize = 1;
    desc.Format = w.DXGI_FORMAT_B8G8R8A8_UNORM;
    desc.SampleDesc.Count = 1;
    desc.Usage = w.D3D11_USAGE_IMMUTABLE;
    desc.BindFlags = w.D3D11_BIND_SHADER_RESOURCE;
    const sub: w.D3D11_SUBRESOURCE_DATA = .{ .pSysMem = px.ptr, .SysMemPitch = @intCast(side * 4), .SysMemSlicePitch = 0 };
    var tex: [*c]w.ID3D11Texture2D = null;
    try win.check(dev.*.lpVtbl.*.CreateTexture2D.?(dev, &desc, &sub, &tex));
    defer win.release(tex);
    var srv: [*c]w.ID3D11ShaderResourceView = null;
    try win.check(dev.*.lpVtbl.*.CreateShaderResourceView.?(dev, @ptrCast(tex), null, &srv));
    return @intFromPtr(srv);
}

test "every icon name has an embedded png master" {
    for (masters) |m| try std.testing.expectEqualSlices(u8, "\x89PNG", m[0..4]);
    try std.testing.expect(embedded_bytes > 100_000);
}
