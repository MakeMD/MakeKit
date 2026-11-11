//! Fira Sans subsets embedded in every kit app (module "kit_fonts" in build.zig; loaded by app.zig).
pub const regular = @embedFile("FiraSans-Regular.ttf");
pub const semibold = @embedFile("FiraSans-SemiBold.ttf");
