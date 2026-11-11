# MakeKit

Shared Zig 0.17.1 foundation for MakeCleaner and MakePack: Win32 window + D3D11 + Dear ImGui 1.93 (docking) with
an idle-friendly loop, the "Carbon Mint" dark theme + 39-icon set (`icons`, masters in icons/), the embedded Fira Sans UI font (third_party/fonts, OFL) + compact metrics/DPI, small widgets (`ui`), Win32/COM helpers (`win`), background jobs (`jobs`),
translated Windows headers (`w`), the dear_bindings ImGui C API (`im`), a named-pipe GUI automation server and the
update client (`update`) for `MakeUpdate.exe`, the only networked binary (WinHTTP, GitHub releases; notes K11).

- Use it: in your `build.zig.zon` add `.makekit = .{ .path = "../MakeKit" }`, then in `build.zig`
  `const kit = b.dependency("makekit", .{ .target = target, .optimize = optimize });` and
  `exe_mod.addImport("kit", kit.module("kit"));` (full example: docs/ZIG-0.17-NOTES.md, section K0).
- Build: `zig build` (lib + zig-out/bin/MakeUpdate.exe), `zig build test`, `zig build demo`, `zig build run-demo` (Zig at `%LOCALAPPDATA%\Programs\zig\0.17.1`).
- Smoke test: `powershell -ExecutionPolicy Bypass -File tools\smoke.ps1` (opens the demo on `\\.\DISPLAY1`, prints `SMOKE OK`).
- Update test: `powershell -ExecutionPolicy Bypass -File tools\update-e2e.ps1` (MakeUpdate against a local fake
  GitHub + a fake setup, then the demo's update banner; never contacts GitHub; prints `UPDATE-E2E OK`).
- Read docs/ZIG-0.17-NOTES.md before writing code: verified Zig 0.17 idioms + kit usage. Versions: third_party/VERSION-imgui.txt.
