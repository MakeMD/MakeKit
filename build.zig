const std = @import("std");
const Translator = @import("translate_c").Translator;

// Consumers:
//   const kit = b.dependency("makekit", .{ .target = target, .optimize = optimize });
//   exe_mod.addImport("kit", kit.module("kit"));
//   exe.win32_manifest = kit.namedLazyPath("manifest");   // or reference it from your .rc
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{ .default_target = .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu } });
    const optimize = b.standardOptimizeOption(.{});

    // ---- Dear ImGui (+ dear_bindings C API, backends, test-engine hooks) as one static C++ lib
    const imgui_mod = b.createModule(.{ .target = target, .optimize = optimize, .link_libcpp = true });
    for ([_][]const u8{ "src/c", "third_party/imgui", "third_party/imgui/backends", "third_party/dear_bindings", "third_party/dear_bindings/backends" }) |p|
        imgui_mod.addIncludePath(b.path(p));
    imgui_mod.addCSourceFiles(.{
        .files = &.{
            "third_party/imgui/imgui.cpp",
            "third_party/imgui/imgui_draw.cpp",
            "third_party/imgui/imgui_tables.cpp",
            "third_party/imgui/imgui_widgets.cpp",
            "third_party/imgui/imgui_demo.cpp",
            "third_party/imgui/backends/imgui_impl_win32.cpp",
            "third_party/imgui/backends/imgui_impl_dx11.cpp",
            "third_party/dear_bindings/dcimgui.cpp",
            "third_party/dear_bindings/backends/dcimgui_impl_win32.cpp",
            "third_party/dear_bindings/backends/dcimgui_impl_dx11.cpp",
            "src/te_hooks.cpp",
        },
        .flags = &.{
            "-std=c++17",
            "-fno-exceptions",
            "-fno-rtti",
            "-fno-sanitize=undefined", // imgui does float->int truncations UBSan flags (ImTrunc64 on first frame)
            "-DIMGUI_USER_CONFIG=\"makekit_imconfig.h\"",
            "-DUNICODE",
            "-D_UNICODE",
        },
    });
    for ([_][]const u8{ "user32", "gdi32", "imm32", "dwmapi", "d3d11", "dxgi", "d3dcompiler_47" }) |l|
        imgui_mod.linkSystemLibrary(l, .{});
    const imgui = b.addLibrary(.{ .name = "imgui", .root_module = imgui_mod });

    // ---- C -> Zig translation (translate_c package; @cImport is gone in 0.17)
    const tc = b.dependency("translate_c", .{});
    const im_t: Translator = .init(tc, .{ .name = "im", .c_source_file = b.path("src/c/im.h"), .target = target, .optimize = optimize });
    im_t.addIncludePath(b.path("src/c"));
    im_t.addIncludePath(b.path("third_party/dear_bindings"));
    im_t.addIncludePath(b.path("third_party/imgui"));
    im_t.mod.linkLibrary(imgui);

    const w_t: Translator = .init(tc, .{ .name = "w", .c_source_file = b.path("src/c/win.h"), .target = target, .optimize = optimize });
    for ([_][]const u8{ "kernel32", "user32", "gdi32", "shell32", "ole32", "oleaut32", "advapi32", "uuid", "dwmapi", "d3d11", "dxgi", "dxguid", "ntdll", "comdlg32", "wbemuuid" }) |l|
        w_t.mod.linkSystemLibrary(l, .{});

    // ---- public module "kit"
    const kit = b.addModule("kit", .{
        .root_source_file = b.path("src/kit.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "im", .module = im_t.mod },
            .{ .name = "w", .module = w_t.mod },
            // icon masters live in icons/, outside src/: @embedFile must stay inside its module
            .{ .name = "kit_icons", .module = b.createModule(.{ .root_source_file = b.path("icons/embed.zig") }) },
            .{ .name = "kit_fonts", .module = b.createModule(.{ .root_source_file = b.path("third_party/fonts/embed.zig") }) },
        },
    });
    b.addNamedLazyPath("manifest", b.path("res/app.manifest"));
    b.addNamedLazyPath("res", b.path("res"));
    b.installArtifact(imgui); // `zig build` = the lib

    // ---- MakeUpdate.exe: the one networked helper (WinHTTP only; no imgui, no `w`). Consumers install it
    // next to their exe: b.installArtifact(kit.artifact("MakeUpdate")) (docs/ZIG-0.17-NOTES.md K11).
    const updater_mod = b.createModule(.{ .root_source_file = b.path("src/updater/main.zig"), .target = target, .optimize = optimize });
    updater_mod.linkSystemLibrary("winhttp", .{});
    const updater = b.addExecutable(.{ .name = "MakeUpdate", .root_module = updater_mod });
    const install_updater = b.addInstallArtifact(updater, .{});
    b.getInstallStep().dependOn(&install_updater.step); // = b.installArtifact: what kit.artifact("MakeUpdate") finds

    // ---- tests: kit unit tests + compiled cheat-sheet snippets
    const test_step = b.step("test", "Run unit tests and docs/notes_check.zig");
    const kit_tests = b.addTest(.{ .name = "kit-test", .root_module = kit });
    test_step.dependOn(&b.addRunArtifact(kit_tests).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .name = "updater-test", .root_module = updater_mod })).step);
    const notes_mod = b.createModule(.{
        .root_source_file = b.path("docs/notes_check.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "kit", .module = kit }},
    });
    const notes_tests = b.addTest(.{ .name = "notes-test", .root_module = notes_mod });
    test_step.dependOn(&b.addRunArtifact(notes_tests).step);

    // ---- demo / smoke-test exe
    const demo_mod = b.createModule(.{
        .root_source_file = b.path("demo/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "kit", .module = kit }},
    });
    const demo = b.addExecutable(.{ .name = "makekit-demo", .root_module = demo_mod, .win32_manifest = b.path("res/app.manifest") });
    demo.subsystem = .windows;
    const install_demo = b.addInstallArtifact(demo, .{});
    const demo_step = b.step("demo", "Build the demo exe (+ MakeUpdate.exe next to it)");
    demo_step.dependOn(&install_demo.step);
    demo_step.dependOn(&install_updater.step);
    const run_demo = b.addRunArtifact(demo);
    run_demo.step.dependOn(demo_step);
    b.step("run-demo", "Run the demo").dependOn(&run_demo.step);
}
