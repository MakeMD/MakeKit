# MakeKit

Shared Zig 0.17.1 foundation for MakeCleaner and MakePack: Win32 window + D3D11 + Dear ImGui 1.93 (docking) with
an idle-friendly loop, theme/fonts/DPI, small widgets (`ui`), Win32/COM helpers (`win`), background jobs (`jobs`),
translated Windows headers (`w`), the dear_bindings ImGui C API (`im`) and a named-pipe GUI automation server.

- Use it: in your `build.zig.zon` add `.makekit = .{ .path = "../MakeKit" }`, then in `build.zig`
  `const kit = b.dependency("makekit", .{ .target = target, .optimize = optimize });` and
  `exe_mod.addImport("kit", kit.module("kit"));` (full example: docs/ZIG-0.17-NOTES.md, section K0).
- Build: `zig build` (lib), `zig build test`, `zig build demo`, `zig build run-demo` (Zig at `%LOCALAPPDATA%\Programs\zig\0.17.1`).
- Smoke test: `powershell -ExecutionPolicy Bypass -File tools\smoke.ps1` (opens the demo on `\\.\DISPLAY1`, prints `SMOKE OK`).
- Read docs/ZIG-0.17-NOTES.md before writing code: verified Zig 0.17 idioms + kit usage. Versions: third_party/imgui/VERSION.
