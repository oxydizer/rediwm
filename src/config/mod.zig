//! Configuration data, parsing and persistence. Runtime application lives in config_runtime/.
pub const animations = @import("animations.zig");
pub const app_theme = @import("app_theme.zig");
pub const default = @import("default.zig");
pub const input_device = @import("input_device.zig");
pub const keybinds = @import("keybinds.zig");
pub const keymap = @import("keymap.zig");
pub const loader = @import("loader.zig");
pub const output_config = @import("output_config.zig");
pub const output_save = @import("output_save.zig");
pub const output_transform = @import("output_transform.zig");
pub const path = @import("path.zig");
pub const power = @import("power.zig");
pub const portals = @import("portals.zig");
pub const sandbox_allow = @import("sandbox_allow.zig");
pub const schedule = @import("schedule.zig");
pub const setting_save = @import("setting_save.zig");
pub const shortcut_save = @import("shortcut_save.zig");
pub const taskbar_items = @import("taskbar_items.zig");
pub const theme_pack = @import("theme_pack.zig");
pub const terminal_theme = @import("terminal_theme.zig");
pub const types = @import("types.zig");
pub const workspace_layout = @import("workspace_layout.zig");
pub const window_rules = @import("window_rules.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
