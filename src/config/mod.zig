//! Configuration data, parsing and persistence. Runtime application lives in config_runtime/.
pub const animations = @import("animations.zig");
pub const default = @import("default.zig");
pub const keybinds = @import("keybinds.zig");
pub const keymap = @import("keymap.zig");
pub const loader = @import("loader.zig");
pub const output_config = @import("output_config.zig");
pub const output_save = @import("output_save.zig");
pub const output_transform = @import("output_transform.zig");
pub const path = @import("path.zig");
pub const portals = @import("portals.zig");
pub const sandbox_allow = @import("sandbox_allow.zig");
pub const schedule = @import("schedule.zig");
pub const setting_save = @import("setting_save.zig");
pub const shortcut_save = @import("shortcut_save.zig");
pub const taskbar_items = @import("taskbar_items.zig");
pub const types = @import("types.zig");
pub const window_rules = @import("window_rules.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
