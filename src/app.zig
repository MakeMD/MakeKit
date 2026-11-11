//! Win32 window + D3D11 device + Dear ImGui context/backends + theme + idle-friendly main loop.
//! One App (window) per process.
const std = @import("std");
const im = @import("im");
const w = @import("w");
const win = @import("win.zig");
const automation = @import("automation.zig");
const kit_icons = @import("icons.zig");
const kit_fonts = @import("kit_fonts");

const Allocator = std.mem.Allocator;

// ---------------------------------------------------------------- backends (dear_bindings C wrappers, compiled into the imgui lib)
extern fn cImGui_ImplWin32_Init(hwnd: ?*anyopaque) bool;
extern fn cImGui_ImplWin32_Shutdown() void;
extern fn cImGui_ImplWin32_NewFrame() void;
extern fn cImGui_ImplWin32_WndProcHandler(hwnd: w.HWND, msg: w.UINT, wp: w.WPARAM, lp: w.LPARAM) w.LRESULT;
extern fn cImGui_ImplDX11_Init(device: [*c]w.ID3D11Device, ctx: [*c]w.ID3D11DeviceContext) bool;
extern fn cImGui_ImplDX11_Shutdown() void;
extern fn cImGui_ImplDX11_NewFrame() void;
extern fn cImGui_ImplDX11_RenderDrawData(draw_data: *im.ImDrawData) void;
extern fn mkte_end_frame() void; // src/te_hooks.cpp

// ---------------------------------------------------------------- theme

/// Colors as 0xRRGGBB.
pub const Palette = struct {
    bg: u32,
    surface: u32,
    line: u32,
    text: u32,
    muted: u32,
    accent: u32,
    accent_dark: u32,
    accent_soft: u32,
    danger: u32,
    rail: u32,
    rail_text: u32,
    rail_hover: u32,
    rail_selected: u32,
};

pub const palettes = struct {
    /// "Carbon Mint": the one dark theme of MakeCleaner and MakePack. Electric mint on anthracite.
    /// Contrast (WCAG): text/bg 10.0, text/surface 7.9, text/accent_soft 6.3, muted/bg 5.9, muted/surface 4.7,
    /// bg-on-accent 9.7, bg-on-accent_dark 6.7, rail_text/rail_selected 6.2 (checked by the test below).
    pub const carbon: Palette = .{
        .bg = 0x2D3436,
        .surface = 0x3B4447,
        .line = 0x4A5458,
        .text = 0xDFE6E9,
        .muted = 0xA8B3B7,
        .accent = 0x00FFC2, // text ON mint = bg (anthracite), see ui.primaryButton
        .accent_dark = 0x00D6A3,
        .accent_soft = 0x25594F, // mint 18 % over bg: selection
        .danger = 0xFF7675,
        .rail = 0x23292B,
        .rail_text = 0xC3CCD0,
        .rail_hover = 0x2F3639,
        .rail_selected = 0x1E4942, // mint 15 % over rail
    };
};

/// 0xRRGGBB + alpha -> ImVec4.
pub fn color(c: u32, alpha: f32) im.ImVec4 {
    return .{
        .x = @as(f32, @floatFromInt((c >> 16) & 0xFF)) / 255.0,
        .y = @as(f32, @floatFromInt((c >> 8) & 0xFF)) / 255.0,
        .z = @as(f32, @floatFromInt(c & 0xFF)) / 255.0,
        .w = alpha,
    };
}

/// 0xRRGGBB -> packed ImU32 (for ImDrawList calls).
pub fn colorU32(c: u32) u32 {
    return 0xFF000000 | ((c & 0xFF) << 16) | (c & 0xFF00) | ((c >> 16) & 0xFF);
}

/// Blend 0xRRGGBB `a` toward `b` by `t` (0..1).
pub fn mix(a: u32, b: u32, t: f32) u32 {
    var out: u32 = 0;
    inline for (.{ 16, 8, 0 }) |sh| {
        const ca: f32 = @floatFromInt((a >> sh) & 0xFF);
        const cb: f32 = @floatFromInt((b >> sh) & 0xFF);
        out |= @as(u32, @intFromFloat(@round(ca + (cb - ca) * t))) << sh;
    }
    return out;
}

/// Writes palette colors + MakeKit sizes (unscaled, 96 DPI) into `style`.
pub fn applyTheme(style: *im.ImGuiStyle, p: Palette) void {
    im.ImGui_StyleColorsDark(style); // sane defaults for anything not listed
    const c = &style.Colors;
    const C = struct {
        fn set(cs: *[im.ImGuiCol_COUNT]im.ImVec4, idx: c_int, v: im.ImVec4) void {
            cs[@intCast(idx)] = v;
        }
    };
    const s = C.set;
    const frame = mix(p.bg, p.rail, 0.6); // inputs sit a bit deeper than the window
    s(c, im.ImGuiCol_Text, color(p.text, 1));
    s(c, im.ImGuiCol_TextDisabled, color(p.muted, 1));
    s(c, im.ImGuiCol_WindowBg, color(p.bg, 1));
    s(c, im.ImGuiCol_ChildBg, color(p.surface, 1));
    s(c, im.ImGuiCol_PopupBg, color(p.surface, 1)); // popups, modals, tooltips, combos
    s(c, im.ImGuiCol_Border, color(p.line, 1));
    s(c, im.ImGuiCol_BorderShadow, color(0, 0));
    s(c, im.ImGuiCol_FrameBg, color(frame, 1));
    s(c, im.ImGuiCol_FrameBgHovered, color(mix(frame, p.accent, 0.08), 1));
    s(c, im.ImGuiCol_FrameBgActive, color(mix(frame, p.accent, 0.15), 1));
    s(c, im.ImGuiCol_TitleBg, color(p.rail, 1));
    s(c, im.ImGuiCol_TitleBgActive, color(p.rail, 1));
    s(c, im.ImGuiCol_TitleBgCollapsed, color(p.rail, 1));
    s(c, im.ImGuiCol_MenuBarBg, color(p.rail, 1));
    s(c, im.ImGuiCol_ScrollbarBg, color(0, 0));
    s(c, im.ImGuiCol_ScrollbarGrab, color(mix(p.line, p.muted, 0.45), 1)); // a thumb you can see on bg and surface
    s(c, im.ImGuiCol_ScrollbarGrabHovered, color(p.muted, 1));
    s(c, im.ImGuiCol_ScrollbarGrabActive, color(p.text, 1));
    s(c, im.ImGuiCol_CheckMark, color(p.accent, 1)); // mint tick on a soft box: solid mint stays for primary + focus
    s(c, im.ImGuiCol_CheckboxSelectedBg, color(p.accent_soft, 1));
    s(c, im.ImGuiCol_SliderGrab, color(p.accent, 1));
    s(c, im.ImGuiCol_SliderGrabActive, color(p.accent_dark, 1));
    s(c, im.ImGuiCol_Button, color(p.surface, 1));
    s(c, im.ImGuiCol_ButtonHovered, color(mix(p.surface, p.accent, 0.10), 1));
    s(c, im.ImGuiCol_ButtonActive, color(mix(p.surface, p.accent, 0.22), 1));
    s(c, im.ImGuiCol_Header, color(p.accent_soft, 1)); // selected rows / tree nodes
    s(c, im.ImGuiCol_HeaderHovered, color(mix(p.bg, p.accent, 0.10), 1));
    s(c, im.ImGuiCol_HeaderActive, color(mix(p.bg, p.accent, 0.24), 1));
    s(c, im.ImGuiCol_Separator, color(p.line, 1));
    s(c, im.ImGuiCol_SeparatorHovered, color(p.accent, 0.7));
    s(c, im.ImGuiCol_SeparatorActive, color(p.accent, 1));
    s(c, im.ImGuiCol_ResizeGrip, color(p.line, 0.5));
    s(c, im.ImGuiCol_ResizeGripHovered, color(p.accent, 0.6));
    s(c, im.ImGuiCol_ResizeGripActive, color(p.accent, 0.9));
    s(c, im.ImGuiCol_InputTextCursor, color(p.accent, 1));
    s(c, im.ImGuiCol_Tab, color(p.bg, 1));
    s(c, im.ImGuiCol_TabHovered, color(mix(p.surface, p.accent, 0.10), 1));
    s(c, im.ImGuiCol_TabSelected, color(p.surface, 1));
    s(c, im.ImGuiCol_TabSelectedOverline, color(p.accent, 1));
    s(c, im.ImGuiCol_TabDimmed, color(p.bg, 1));
    s(c, im.ImGuiCol_TabDimmedSelected, color(p.surface, 1));
    s(c, im.ImGuiCol_TabDimmedSelectedOverline, color(p.accent, 1)); // same active tab whether focused or not
    s(c, im.ImGuiCol_DockingPreview, color(p.accent, 0.5));
    s(c, im.ImGuiCol_DockingEmptyBg, color(p.rail, 1));
    s(c, im.ImGuiCol_PlotLines, color(p.accent, 1));
    s(c, im.ImGuiCol_PlotLinesHovered, color(p.accent_dark, 1));
    s(c, im.ImGuiCol_PlotHistogram, color(p.accent, 1)); // ProgressBar fill
    s(c, im.ImGuiCol_PlotHistogramHovered, color(p.accent_dark, 1));
    s(c, im.ImGuiCol_TableHeaderBg, color(p.surface, 1));
    s(c, im.ImGuiCol_TableBorderStrong, color(p.line, 1));
    s(c, im.ImGuiCol_TableBorderLight, color(mix(p.bg, p.line, 0.6), 1));
    s(c, im.ImGuiCol_TableRowBg, color(0, 0));
    s(c, im.ImGuiCol_TableRowBgAlt, color(mix(p.bg, p.surface, 0.35), 1));
    s(c, im.ImGuiCol_TextLink, color(p.accent, 1));
    s(c, im.ImGuiCol_TextSelectedBg, color(p.accent, 0.25));
    s(c, im.ImGuiCol_TreeLines, color(p.line, 1));
    s(c, im.ImGuiCol_DragDropTarget, color(p.accent, 1));
    s(c, im.ImGuiCol_DragDropTargetBg, color(p.accent, 0.08));
    s(c, im.ImGuiCol_UnsavedMarker, color(p.accent, 1));
    s(c, im.ImGuiCol_NavCursor, color(p.accent, 1));
    s(c, im.ImGuiCol_NavWindowingHighlight, color(p.accent, 0.7));
    s(c, im.ImGuiCol_NavWindowingDimBg, color(0x000000, 0.45));
    s(c, im.ImGuiCol_ModalWindowDimBg, color(0x000000, 0.45));

    // Compact metrics for the 14 px base font (96 DPI; ScaleAllSizes on DPI change): frames (buttons,
    // inputs, combos, tabs) 24 px, check/radio boxes 14 px (im.h -> mkui_* wrappers), text table rows 22 px.
    style.WindowPadding = .{ .x = 12, .y = 12 };
    style.FramePadding = .{ .x = 8, .y = 5 };
    style.ItemSpacing = .{ .x = 8, .y = 6 };
    style.ItemInnerSpacing = .{ .x = 6, .y = 6 };
    style.CellPadding = .{ .x = 8, .y = 4 };
    style.IndentSpacing = 16;
    style.GrabMinSize = 10;
    style.WindowRounding = 4;
    style.ChildRounding = 4;
    style.FrameRounding = 4;
    style.PopupRounding = 4;
    style.GrabRounding = 4;
    style.TabRounding = 4;
    style.TabBarOverlineSize = 2; // drawn with ImGuiTabBarFlags_DrawSelectedOverline (the kit tab look)
    style.ScrollbarRounding = 4;
    style.ScrollbarSize = 12;
    style.WindowBorderSize = 1;
    style.ChildBorderSize = 1;
    style.PopupBorderSize = 1;
    style.FrameBorderSize = 1;
    style.WindowTitleAlign = .{ .x = 0, .y = 0.5 };
}

// ---------------------------------------------------------------- config / callbacks

pub const Config = struct {
    /// UTF-8 window title.
    title: []const u8 = "MakeKit",
    /// Initial / minimum client size in logical pixels (scaled by monitor DPI).
    size: [2]i32 = .{ 1100, 720 },
    min_size: [2]i32 = .{ 640, 420 },
    palette: Palette = palettes.carbon,
    /// Base font size in logical pixels (Fira Sans has a large x-height: 14 reads like Segoe UI 15-16).
    font_size: f32 = 14,
    /// Icon resource id from the app's .rc (`1 ICON "app.ico"` -> 1). null = default icon.
    icon_id: ?u16 = null,
    /// imgui.ini path (UTF-8); null = do not persist ImGui window state.
    ini_file: ?[:0]const u8 = null,
};

pub const Callbacks = struct {
    /// Opaque app state, read back with `app.userData(T)`.
    user: ?*anyopaque = null,
    /// Called once per frame between ImGui_NewFrame and ImGui_Render.
    frame: *const fn (app: *App) void,
    /// Window close requested (X button, Alt+F4). Return false to veto (e.g. open a confirm modal,
    /// then call `app.quit()` when the user confirms). null = always close.
    close_requested: ?*const fn (app: *App) bool = null,
    /// Files dropped from Explorer. `paths` (UTF-8) and their memory are valid only during the call;
    /// `pos` is in ImGui (client) coordinates.
    files_dropped: ?*const fn (app: *App, paths: []const []const u8, pos: im.ImVec2) void = null,
};

pub const Fonts = struct {
    regular: *im.ImFont,
    /// Fira Sans SemiBold. Use `ImGui_PushFontFloat(app.fonts.bold, size)` for titles.
    bold: *im.ImFont,
    /// True when the icon font (Segoe Fluent Icons / MDL2 Assets) was merged into both fonts.
    icons: bool,
};

const WM_APP_WAKE: w.UINT = 0x8000 + 1; // WM_APP + 1

// ---------------------------------------------------------------- App

pub const App = struct {
    gpa: Allocator,
    cfg: Config,
    hwnd: w.HWND = null,
    device: [*c]w.ID3D11Device = null,
    context: [*c]w.ID3D11DeviceContext = null,
    swapchain: [*c]w.IDXGISwapChain = null,
    rtv: [*c]w.ID3D11RenderTargetView = null,
    /// True when running on the WARP software rasterizer (no usable GPU, some RDP setups).
    warp: bool = false,
    dpi: u32 = 96,
    fonts: Fonts = undefined,
    base_style: im.ImGuiStyle = undefined,
    cb: Callbacks = .{ .frame = noFrame },
    frame_count: u64 = 0,

    pending_frames: u32 = 3,
    animating: bool = false,
    last_activity_ms: u64 = 0,
    resize: ?[2]u32 = null,
    minimized: bool = false,
    quitting: bool = false,
    ready: bool = false,
    qpc_freq: i64 = 1,
    qpc_last: i64 = 0,

    /// Creates the window (hidden until `run`), the D3D11 device and the ImGui context.
    pub fn init(gpa: Allocator, cfg: Config) !*App {
        if (g_app != null) return error.AlreadyRunning;
        const app = try gpa.create(App);
        errdefer gpa.destroy(app);
        app.* = .{ .gpa = gpa, .cfg = cfg };
        g_app = app;
        errdefer g_app = null;

        try win.comInitSta(); // file dialogs / recycle bin need COM on the UI thread
        try app.createWindow();
        errdefer _ = w.DestroyWindow(app.hwnd);
        try app.createDevice();
        errdefer app.releaseDevice();

        _ = im.ImGui_CreateContext(null);
        _ = im.CIMGUI_CHECKVERSION(); // asserts that Zig and C++ agree on struct layouts
        const io = im.ImGui_GetIO();
        io.*.IniFilename = if (cfg.ini_file) |f| f.ptr else null;
        io.*.ConfigFlags |= im.ImGuiConfigFlags_NavEnableKeyboard;
        io.*.ConfigWindowsMoveFromTitleBarOnly = true;

        const style = im.ImGui_GetStyle();
        applyTheme(style, cfg.palette);
        style.*.FontSizeBase = cfg.font_size;
        app.base_style = style.*;
        app.fonts = loadFonts(cfg.font_size);
        app.applyDpi(w.GetDpiForWindow(app.hwnd));

        _ = cImGui_ImplWin32_Init(app.hwnd);
        _ = cImGui_ImplDX11_Init(app.device, app.context);
        var f: w.LARGE_INTEGER = undefined;
        _ = w.QueryPerformanceFrequency(&f);
        app.qpc_freq = f.QuadPart;
        app.ready = true;

        if (automation.wanted(gpa)) try automation.start(app);
        return app;
    }

    pub fn deinit(app: *App) void {
        automation.stop();
        app.ready = false;
        kit_icons.releaseAll();
        cImGui_ImplDX11_Shutdown();
        cImGui_ImplWin32_Shutdown();
        im.ImGui_DestroyContext(null);
        app.releaseDevice();
        if (app.hwnd != null) _ = w.DestroyWindow(app.hwnd);
        win.comUninit();
        g_app = null;
        app.gpa.destroy(app);
    }

    /// Shows the window and runs the message/render loop until the window is closed.
    pub fn run(app: *App, cb: Callbacks) void {
        app.cb = cb;
        const quiet = automation.active or display_env_set;
        _ = w.ShowWindow(app.hwnd, if (quiet) w.SW_SHOWNOACTIVATE else w.SW_SHOWDEFAULT);
        _ = w.UpdateWindow(app.hwnd);
        var msg: w.MSG = undefined;
        while (true) {
            if (!app.wantsFrame()) {
                const r = w.MsgWaitForMultipleObjectsEx(0, null, app.idleTimeout(), @intCast(w.QS_ALLINPUT), @intCast(w.MWMO_INPUTAVAILABLE));
                if (r == w.WAIT_TIMEOUT) app.pending_frames = 1;
            }
            while (w.PeekMessageW(&msg, null, 0, 0, @intCast(w.PM_REMOVE)) != 0) {
                if (msg.message == w.WM_QUIT) return;
                _ = w.TranslateMessage(&msg);
                _ = w.DispatchMessageW(&msg);
            }
            if (app.minimized and !automation.busy()) {
                app.pending_frames = 0;
                continue;
            }
            if (!app.wantsFrame()) continue;
            app.renderFrame();
            if (app.pending_frames > 0) app.pending_frames -= 1;
        }
    }

    /// Thread-safe: asks the UI thread to render a few frames (e.g. worker progress changed).
    pub fn wake(app: *App) void {
        _ = w.PostMessageW(app.hwnd, WM_APP_WAKE, 0, 0);
    }

    /// UI thread: render at least `n` more frames without waiting for input.
    pub fn requestFrames(app: *App, n: u32) void {
        app.pending_frames = @max(app.pending_frames, n);
    }

    /// UI thread: render continuously (vsync-paced) while on, e.g. for an indeterminate spinner.
    pub fn animate(app: *App, on: bool) void {
        app.animating = on;
    }

    /// Closes the window without asking `close_requested`. Safe from the UI thread.
    pub fn quit(app: *App) void {
        app.quitting = true;
        _ = w.PostMessageW(app.hwnd, w.WM_CLOSE, 0, 0);
    }

    /// DPI scale (1.0 = 96 DPI).
    pub fn scale(app: *const App) f32 {
        return @as(f32, @floatFromInt(app.dpi)) / 96.0;
    }

    pub fn userData(app: *App, comptime T: type) *T {
        return @ptrCast(@alignCast(app.cb.user.?));
    }

    pub fn setTitle(app: *App, title: []const u8) void {
        const t = win.toW(app.gpa, title) catch return;
        defer app.gpa.free(t);
        _ = w.SetWindowTextW(app.hwnd, t.ptr);
    }

    fn wantsFrame(app: *App) bool {
        return app.pending_frames > 0 or app.animating or automation.busy();
    }

    fn idleTimeout(app: *App) w.DWORD {
        const now = w.GetTickCount64();
        // Low-rate tail after input so hover delays / tooltips / ImGui animations settle.
        if (now -% app.last_activity_ms < 1500) return 100;
        // Caret blink. Not under automation: nothing ever focuses the window away from a text field there,
        // so the blink would cost ~1 % CPU for good.
        if (app.ready and !automation.active and im.ImGui_GetIO().*.WantTextInput) return 500;
        return w.INFINITE;
    }

    fn renderFrame(app: *App) void {
        if (app.resize) |sz| {
            app.resize = null;
            if (app.rtv != null) win.release(app.rtv);
            app.rtv = null;
            _ = app.swapchain.*.lpVtbl.*.ResizeBuffers.?(app.swapchain, 0, sz[0], sz[1], w.DXGI_FORMAT_UNKNOWN, 0);
            app.createRenderTarget();
        }
        cImGui_ImplDX11_NewFrame();
        if (automation.active) {
            // Automation owns mouse/keyboard: skip the Win32 backend (it polls the real cursor and
            // modifier keys); do its two essential jobs here.
            const io = im.ImGui_GetIO();
            var rc: w.RECT = undefined;
            _ = w.GetClientRect(app.hwnd, &rc);
            io.*.DisplaySize = .{ .x = @floatFromInt(rc.right - rc.left), .y = @floatFromInt(rc.bottom - rc.top) };
            var now: w.LARGE_INTEGER = undefined;
            _ = w.QueryPerformanceCounter(&now);
            const dt = if (app.qpc_last == 0) 1.0 / 60.0 else @as(f32, @floatFromInt(now.QuadPart - app.qpc_last)) / @as(f32, @floatFromInt(app.qpc_freq));
            io.*.DeltaTime = @max(dt, 0.0001);
            app.qpc_last = now.QuadPart;
            automation.beforeNewFrame(app);
        } else {
            cImGui_ImplWin32_NewFrame();
        }
        im.ImGui_NewFrame();
        app.cb.frame(app);
        im.ImGui_Render();
        mkte_end_frame();

        const bg = color(app.cfg.palette.bg, 1);
        const clear = [4]f32{ bg.x, bg.y, bg.z, 1 };
        const ctx = app.context;
        ctx.*.lpVtbl.*.OMSetRenderTargets.?(ctx, 1, &app.rtv, null);
        ctx.*.lpVtbl.*.ClearRenderTargetView.?(ctx, app.rtv, &clear);
        cImGui_ImplDX11_RenderDrawData(im.ImGui_GetDrawData());
        if (automation.active) automation.afterRender(app);
        const hr = app.swapchain.*.lpVtbl.*.Present.?(app.swapchain, 1, 0);
        if (hr == w.DXGI_ERROR_DEVICE_REMOVED or hr == w.DXGI_ERROR_DEVICE_RESET) app.recreateDevice();
        app.frame_count += 1;
    }

    // ---- window

    fn createWindow(app: *App) !void {
        const hinst = w.GetModuleHandleW(null);
        const class_name = win.L("MakeKitWindow");
        var wc = std.mem.zeroes(w.WNDCLASSEXW);
        wc.cbSize = @sizeOf(w.WNDCLASSEXW);
        wc.lpfnWndProc = wndProc;
        wc.hInstance = hinst;
        wc.hCursor = w.LoadCursorW(null, intResource(32512)); // IDC_ARROW: MAKEINTRESOURCE/A-W macros do not translate
        wc.hIcon = if (app.cfg.icon_id) |id| w.LoadIconW(hinst, intResource(id)) else w.LoadIconW(null, intResource(32512)); // IDI_APPLICATION
        wc.lpszClassName = class_name;
        // A second App in the same process (after deinit) finds the class still registered.
        if (w.RegisterClassExW(&wc) == 0 and w.GetLastError() != w.ERROR_CLASS_ALREADY_EXISTS) return error.RegisterClassFailed;

        const title = try win.toW(app.gpa, app.cfg.title);
        defer app.gpa.free(title);
        const target = targetMonitor(app.gpa);
        const style: w.DWORD = @intCast(w.WS_OVERLAPPEDWINDOW);
        const x: c_int = if (target) |m| m.left + 16 else w.CW_USEDEFAULT;
        const y: c_int = if (target) |m| m.top + 16 else w.CW_USEDEFAULT;
        app.hwnd = w.CreateWindowExW(0, class_name, title.ptr, style, x, y, 800, 600, null, null, hinst, null);
        if (app.hwnd == null) return error.CreateWindowFailed;
        // Dark native title bar; Win11 also takes the caption colour (COLORREF = 0x00BBGGRR). Older: ignored.
        const dark: w.WINBOOL = 1;
        _ = w.DwmSetWindowAttribute(app.hwnd, 20, &dark, @sizeOf(w.WINBOOL)); // DWMWA_USE_IMMERSIVE_DARK_MODE
        const caption: w.DWORD = colorU32(app.cfg.palette.bg) & 0xFFFFFF;
        _ = w.DwmSetWindowAttribute(app.hwnd, 35, &caption, @sizeOf(w.DWORD)); // DWMWA_CAPTION_COLOR

        // Now that the window lives on its monitor we know the DPI: size (and center) it.
        const dpi = w.GetDpiForWindow(app.hwnd);
        var rc: w.RECT = .{ .left = 0, .top = 0, .right = scaleI(app.cfg.size[0], dpi), .bottom = scaleI(app.cfg.size[1], dpi) };
        _ = w.AdjustWindowRectExForDpi(&rc, style, 0, 0, dpi);
        const ww = rc.right - rc.left;
        const wh = rc.bottom - rc.top;
        if (target) |m| {
            const cx = m.left + @divTrunc(m.right - m.left - ww, 2);
            const cy = m.top + @divTrunc(m.bottom - m.top - wh, 2);
            _ = w.SetWindowPos(app.hwnd, null, cx, @max(cy, m.top), ww, wh, @intCast(w.SWP_NOZORDER | w.SWP_NOACTIVATE));
        } else {
            _ = w.SetWindowPos(app.hwnd, null, 0, 0, ww, wh, @intCast(w.SWP_NOZORDER | w.SWP_NOACTIVATE | w.SWP_NOMOVE));
        }

        w.DragAcceptFiles(app.hwnd, 1);
        // Let Explorer (medium integrity) drop onto us when we run elevated.
        _ = w.ChangeWindowMessageFilterEx(app.hwnd, w.WM_DROPFILES, w.MSGFLT_ALLOW, null);
        _ = w.ChangeWindowMessageFilterEx(app.hwnd, 0x0049, w.MSGFLT_ALLOW, null); // WM_COPYGLOBALDATA
    }

    // ---- D3D11

    fn createDevice(app: *App) !void {
        var sd = std.mem.zeroes(w.DXGI_SWAP_CHAIN_DESC);
        sd.BufferCount = 2;
        sd.BufferDesc.Format = w.DXGI_FORMAT_R8G8B8A8_UNORM;
        sd.BufferUsage = @intCast(w.DXGI_USAGE_RENDER_TARGET_OUTPUT);
        sd.OutputWindow = app.hwnd;
        sd.SampleDesc.Count = 1;
        sd.Windowed = 1;
        sd.SwapEffect = w.DXGI_SWAP_EFFECT_FLIP_DISCARD;
        const levels = [_]w.D3D_FEATURE_LEVEL{ w.D3D_FEATURE_LEVEL_11_0, w.D3D_FEATURE_LEVEL_10_0 };
        var got: w.D3D_FEATURE_LEVEL = 0;
        var hr: w.HRESULT = -1;
        for ([_]w.D3D_DRIVER_TYPE{ w.D3D_DRIVER_TYPE_HARDWARE, w.D3D_DRIVER_TYPE_WARP }) |dt| {
            hr = w.D3D11CreateDeviceAndSwapChain(null, dt, null, 0, &levels, levels.len, w.D3D11_SDK_VERSION, &sd, &app.swapchain, &app.device, &got, &app.context);
            if (hr >= 0) {
                app.warp = dt == w.D3D_DRIVER_TYPE_WARP;
                break;
            }
        }
        try win.check(hr);
        // No Alt+Enter fullscreen.
        var factory: [*c]w.IDXGIFactory = null;
        if (app.swapchain.*.lpVtbl.*.GetParent.?(app.swapchain, &w.IID_IDXGIFactory, @ptrCast(&factory)) >= 0) {
            _ = factory.*.lpVtbl.*.MakeWindowAssociation.?(factory, app.hwnd, @intCast(w.DXGI_MWA_NO_ALT_ENTER));
            win.release(factory);
        }
        app.createRenderTarget();
    }

    fn createRenderTarget(app: *App) void {
        var back: [*c]w.ID3D11Texture2D = null;
        if (app.swapchain.*.lpVtbl.*.GetBuffer.?(app.swapchain, 0, &w.IID_ID3D11Texture2D, @ptrCast(&back)) < 0) return;
        defer win.release(back);
        _ = app.device.*.lpVtbl.*.CreateRenderTargetView.?(app.device, @ptrCast(back), null, &app.rtv);
    }

    fn releaseDevice(app: *App) void {
        win.release(app.rtv);
        win.release(app.swapchain);
        win.release(app.context);
        win.release(app.device);
        app.rtv = null;
        app.swapchain = null;
        app.context = null;
        app.device = null;
    }

    /// GPU reset / driver update / RDP session switch: rebuild the device and the DX11 backend.
    fn recreateDevice(app: *App) void {
        cImGui_ImplDX11_Shutdown();
        kit_icons.releaseAll();
        app.releaseDevice();
        app.createDevice() catch return; // ponytail: keep running blind; next Present retries nothing
        _ = cImGui_ImplDX11_Init(app.device, app.context);
    }

    // ---- DPI / fonts

    fn applyDpi(app: *App, dpi: u32) void {
        app.dpi = dpi;
        const s = app.scale();
        const style = im.ImGui_GetStyle();
        style.* = app.base_style;
        im.ImGuiStyle_ScaleAllSizes(style, s);
        style.*.FontScaleDpi = s;
        kit_icons.releaseAll(); // re-decoded lazily at the new pixel sizes
    }
};

var g_app: ?*App = null;
var display_env_set = false;

/// The running App (null before init / after deinit). Lets workers call `wakeGlobal`.
pub fn current() ?*App {
    return g_app;
}

/// Thread-safe wake of the running app; no-op when there is none.
pub fn wakeGlobal() void {
    if (g_app) |a| a.wake();
}

fn noFrame(app: *App) void {
    _ = app;
}

fn scaleI(v: i32, dpi: u32) i32 {
    return @intCast(@divTrunc(@as(i64, v) * dpi, 96));
}

fn intResource(id: u16) w.LPCWSTR {
    @setRuntimeSafety(false); // MAKEINTRESOURCEW: an integer smuggled in a pointer
    return @ptrFromInt(@as(usize, id));
}

/// MAKEKIT_DISPLAY=\\.\DISPLAY1 -> that monitor's work area (null when unset/unknown).
fn targetMonitor(gpa: Allocator) ?w.RECT {
    const name = (win.getEnv(gpa, "MAKEKIT_DISPLAY") catch null) orelse return null;
    defer gpa.free(name);
    display_env_set = true;
    const wname = win.toW(gpa, name) catch return null;
    defer gpa.free(wname);
    var ctx: struct { want: []const u16, found: ?w.RECT = null } = .{ .want = wname };
    const Enum = struct {
        fn cb(hmon: w.HMONITOR, _: w.HDC, _: w.LPRECT, lp: w.LPARAM) callconv(.c) w.WINBOOL {
            const c: *@TypeOf(ctx) = @ptrFromInt(@as(usize, @bitCast(lp)));
            var mi = std.mem.zeroes(w.MONITORINFOEXW);
            mi.unnamed_0.cbSize = @sizeOf(w.MONITORINFOEXW);
            if (w.GetMonitorInfoW(hmon, @ptrCast(&mi)) == 0) return 1;
            const dev = std.mem.sliceTo(&mi.szDevice, 0);
            if (std.ascii.eqlIgnoreCase(std.mem.sliceAsBytes(dev), std.mem.sliceAsBytes(c.want))) {
                c.found = mi.unnamed_0.rcWork;
                return 0;
            }
            return 1;
        }
    };
    _ = w.EnumDisplayMonitors(null, null, Enum.cb, @bitCast(@intFromPtr(&ctx)));
    return ctx.found;
}

const icon_ranges = [_]im.ImWchar{ 0xE700, 0xF8FF, 0 };

/// Embedded Fira Sans (Regular / SemiBold) + merged Segoe Fluent/MDL2 icons (PUA) + merged Segoe UI as the
/// fallback for everything the Fira subset lacks (merged sources are searched in order, baselines aligned).
fn loadFonts(size: f32) Fonts {
    const atlas = im.ImGui_GetIO().*.Fonts;
    var dir_w: [260]u16 = undefined;
    const n = w.GetWindowsDirectoryW(&dir_w, dir_w.len);
    var dir_buf: [600]u8 = undefined;
    const dir_len = std.unicode.wtf16LeToWtf8(&dir_buf, dir_w[0..n]);
    const dir = dir_buf[0..dir_len];

    const regular = addEmbedded(atlas, kit_fonts.regular, size);
    const icons = mergeIcons(atlas, dir, size);
    mergeFallback(atlas, dir, "segoeui.ttf", size);
    const bold = addEmbedded(atlas, kit_fonts.semibold, size);
    _ = mergeIcons(atlas, dir, size);
    mergeFallback(atlas, dir, "segoeuib.ttf", size);
    return .{ .regular = regular, .bold = bold, .icons = icons };
}

/// C++ `ImFontConfig()` defaults (dear_bindings has no constructor).
fn fontConfig(merge: bool) im.ImFontConfig {
    var cfg = std.mem.zeroes(im.ImFontConfig);
    cfg.FontDataOwnedByAtlas = true;
    cfg.GlyphMaxAdvanceX = std.math.floatMax(f32);
    cfg.RasterizerMultiply = 1;
    cfg.RasterizerDensity = 1;
    cfg.ExtraSizeScale = 1;
    cfg.MergeMode = merge;
    return cfg;
}

fn addEmbedded(atlas: *im.ImFontAtlas, ttf: []const u8, size: f32) *im.ImFont {
    var cfg = fontConfig(false);
    cfg.FontDataOwnedByAtlas = false; // static data: the atlas must not free it
    const f: ?*im.ImFont = im.ImFontAtlas_AddFontFromMemoryTTF(atlas, @constCast(ttf.ptr), @intCast(ttf.len), size, &cfg, null);
    return f.?; // ponytail: the embedded TTF is known-good; a bad one asserts inside ImGui first
}

fn fontPath(buf: []u8, dir: []const u8, file: []const u8) ?[:0]const u8 {
    const p = std.mem.printSentinel(buf, "{s}\\Fonts\\{s}", .{ dir, file }, 0) catch return null;
    var wbuf: [600]u16 = undefined;
    const wl = std.unicode.wtf8ToWtf16Le(&wbuf, p) catch return null;
    wbuf[wl] = 0;
    if (w.GetFileAttributesW(@ptrCast(&wbuf)) == w.INVALID_FILE_ATTRIBUTES) return null; // ImGui asserts on a missing file
    return p;
}

/// Merges a %WINDIR%\Fonts face (all its glyphs) into the last font; used only for code points earlier sources lack.
fn mergeFallback(atlas: *im.ImFontAtlas, dir: []const u8, file: []const u8, size: f32) void {
    var buf: [600]u8 = undefined;
    const p = fontPath(&buf, dir, file) orelse return;
    var cfg = fontConfig(true);
    _ = im.ImFontAtlas_AddFontFromFileTTF(atlas, p.ptr, size, &cfg, null);
}

/// Merges Segoe Fluent Icons (Win11) or Segoe MDL2 Assets (Win10) PUA glyphs into the last font.
fn mergeIcons(atlas: *im.ImFontAtlas, dir: []const u8, size: f32) bool {
    var buf: [600]u8 = undefined;
    const p = fontPath(&buf, dir, "SegoeIcons.ttf") orelse fontPath(&buf, dir, "segmdl2.ttf") orelse return false;
    var cfg = fontConfig(true);
    cfg.GlyphRanges = &icon_ranges;
    cfg.GlyphOffset = .{ .x = 0, .y = 2 }; // MDL2/Fluent glyphs sit high next to the text
    return im.ImFontAtlas_AddFontFromFileTTF(atlas, p.ptr, size, &cfg, null) != null; // size = reference for GlyphOffset (fonts stay dynamic)
}

// ---------------------------------------------------------------- WndProc

fn wndProc(hwnd: w.HWND, msg: w.UINT, wp: w.WPARAM, lp: w.LPARAM) callconv(.c) w.LRESULT {
    const app = g_app orelse return w.DefWindowProcW(hwnd, msg, wp, lp);
    if (app.hwnd == null or hwnd != app.hwnd) return w.DefWindowProcW(hwnd, msg, wp, lp);
    app.pending_frames = @max(app.pending_frames, 3);
    app.last_activity_ms = w.GetTickCount64();

    if (app.ready) {
        // In automation mode real mouse/keyboard/focus never reach ImGui: tests can't be disturbed.
        if (!(automation.active and automation.isUserInput(msg))) {
            if (cImGui_ImplWin32_WndProcHandler(hwnd, msg, wp, lp) != 0) return 1;
        }
    }

    switch (msg) {
        w.WM_SIZE => {
            if (wp == w.SIZE_MINIMIZED) {
                app.minimized = true;
            } else {
                app.minimized = false;
                const lpu: usize = @bitCast(lp);
                app.resize = .{ @intCast(lpu & 0xFFFF), @intCast((lpu >> 16) & 0xFFFF) };
            }
            return 0;
        },
        w.WM_GETMINMAXINFO => {
            const mmi: *w.MINMAXINFO = @ptrFromInt(@as(usize, @bitCast(lp)));
            const dpi = w.GetDpiForWindow(hwnd);
            var rc: w.RECT = .{ .left = 0, .top = 0, .right = scaleI(app.cfg.min_size[0], dpi), .bottom = scaleI(app.cfg.min_size[1], dpi) };
            _ = w.AdjustWindowRectExForDpi(&rc, @intCast(w.WS_OVERLAPPEDWINDOW), 0, 0, dpi);
            mmi.ptMinTrackSize = .{ .x = rc.right - rc.left, .y = rc.bottom - rc.top };
            return 0;
        },
        w.WM_DPICHANGED => {
            const r: *const w.RECT = @ptrFromInt(@as(usize, @bitCast(lp)));
            _ = w.SetWindowPos(hwnd, null, r.left, r.top, r.right - r.left, r.bottom - r.top, @intCast(w.SWP_NOZORDER | w.SWP_NOACTIVATE));
            if (app.ready) app.applyDpi(@intCast(wp & 0xFFFF));
            return 0;
        },
        w.WM_CLOSE => {
            if (!app.quitting) if (app.cb.close_requested) |f| if (!f(app)) return 0;
            _ = w.DestroyWindow(hwnd);
            return 0;
        },
        w.WM_DESTROY => {
            app.hwnd = null;
            w.PostQuitMessage(0);
            return 0;
        },
        w.WM_DROPFILES => {
            const hdrop: w.HDROP = @ptrFromInt(wp);
            defer w.DragFinish(hdrop);
            if (app.cb.files_dropped) |f| dropFiles(app, hdrop, f);
            return 0;
        },
        w.WM_SYSCOMMAND => if ((wp & 0xFFF0) == w.SC_KEYMENU) return 0, // no Alt menu beep
        w.WM_ERASEBKGND => return 1,
        WM_APP_WAKE => return 0,
        else => {},
    }
    return w.DefWindowProcW(hwnd, msg, wp, lp);
}

fn dropFiles(app: *App, hdrop: w.HDROP, f: *const fn (*App, []const []const u8, im.ImVec2) void) void {
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const count = w.DragQueryFileW(hdrop, 0xFFFFFFFF, null, 0);
    const paths = a.alloc([]const u8, count) catch return;
    for (paths, 0..) |*p, i| {
        const len = w.DragQueryFileW(hdrop, @intCast(i), null, 0);
        const buf = a.alloc(u16, len + 1) catch return;
        _ = w.DragQueryFileW(hdrop, @intCast(i), buf.ptr, len + 1);
        p.* = win.fromW(a, buf[0..len]) catch return;
    }
    var pt: w.POINT = .{ .x = 0, .y = 0 };
    _ = w.DragQueryPoint(hdrop, &pt);
    f(app, paths, .{ .x = @floatFromInt(pt.x), .y = @floatFromInt(pt.y) });
}

fn contrast(a: u32, b: u32) f32 {
    const L = struct {
        fn lum(c: u32) f32 {
            var sum: f32 = 0;
            inline for (.{ 16, 8, 0 }, .{ 0.2126, 0.7152, 0.0722 }) |sh, k| {
                const v = @as(f32, @floatFromInt((c >> sh) & 0xFF)) / 255.0;
                sum += k * (if (v <= 0.03928) v / 12.92 else std.math.pow(f32, (v + 0.055) / 1.055, 2.4));
            }
            return sum;
        }
    };
    const la = L.lum(a);
    const lb = L.lum(b);
    return (@max(la, lb) + 0.05) / (@min(la, lb) + 0.05);
}

test "carbon palette: every text/background pair >= 4.5:1 (WCAG AA)" {
    const p = palettes.carbon;
    const alt_row = mix(p.bg, p.surface, 0.35);
    const pairs = [_][2]u32{
        .{ p.text, p.bg },                           .{ p.text, p.surface },                 .{ p.text, p.rail },
        .{ p.text, p.accent_soft },                  .{ p.text, alt_row },                   .{ p.text, mix(p.bg, p.rail, 0.6) },
        .{ p.text, mix(p.surface, p.accent, 0.22) }, .{ p.text, mix(p.bg, p.accent, 0.24) }, .{ p.muted, p.bg },
        .{ p.muted, p.surface },                     .{ p.muted, p.rail },                   .{ p.muted, alt_row },
        .{ p.bg, p.accent },                         .{ p.bg, p.accent_dark },               .{ p.accent, p.bg },
        .{ p.accent, p.surface },                    .{ p.danger, p.bg },                    .{ p.rail_text, p.rail },
        .{ p.rail_text, p.rail_hover },              .{ p.rail_text, p.rail_selected },      .{ p.accent, p.accent_soft }, // tick
        .{ p.bg, p.danger },                         .{ p.bg, mix(p.danger, 0xFFFFFF, 0.2) }, // danger button
    };
    for (pairs) |pr| try std.testing.expect(contrast(pr[0], pr[1]) >= 4.5);
}
