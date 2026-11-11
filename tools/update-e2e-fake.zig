//! Stand-in for a setup exe / the relaunched app in tools/update-e2e.ps1: writes its arguments to
//! %MAKEUPDATE_E2E_DIR%\<exe name>.txt and exits 0. Never installs anything. With MAKEUPDATE_E2E_PROBE=<path>
//! it adds a line "probe:present" / "probe:absent" (is MakeUpdate.exe in the app folder while the setup runs?).
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const dir = init.environ_map.get("MAKEUPDATE_E2E_DIR") orelse return error.NoMarkerDir;
    const args = try init.minimal.args.toSlice(arena);
    const self = try std.process.executablePathAlloc(init.io, arena);
    const path = try std.Io.Dir.path.join(arena, &.{ dir, try arena.print("{s}.txt", .{std.Io.Dir.path.basename(self)}) });
    var text = try std.mem.join(arena, "\n", args[1..]);
    if (init.environ_map.get("MAKEUPDATE_E2E_PROBE")) |probe| {
        const there = if (std.Io.Dir.accessAbsolute(init.io, probe, .{})) |_| "present" else |_| "absent";
        text = try arena.print("{s}\nprobe:{s}", .{ text, there });
    }
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = path, .data = text });
}
