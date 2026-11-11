//! The 128 px icon masters, embedded (module "kit_icons" in build.zig; kit.icons decodes them).
pub fn png(comptime name: []const u8) []const u8 {
    return @embedFile(name ++ ".png");
}
