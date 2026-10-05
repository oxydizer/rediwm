//! Shared UI, rendering and interaction. No compositor imports.
pub const layout = @import("layout.zig");
pub const measure = @import("measure.zig");
pub const arrange = @import("arrange.zig");
pub const paint = @import("paint.zig");
pub const window_chrome = @import("window_chrome.zig");
pub const theme = @import("theme.zig");
pub const input = @import("input.zig");

pub const widgets = struct {
    pub const scrollbar = @import("widgets/scrollbar.zig");
    pub const select = @import("widgets/select.zig");
    pub const button = @import("widgets/button.zig");
    pub const checkbox = @import("widgets/checkbox.zig");
    pub const checkbox_list = @import("widgets/checkbox_list.zig");
    pub const field = @import("widgets/field.zig");
    pub const avatar = @import("widgets/avatar.zig");
    pub const dialog = @import("widgets/dialog.zig");
    pub const secret_input = @import("widgets/secret_input.zig");
    pub const text_input = @import("widgets/text_input.zig");
    pub const scroll_container = @import("widgets/scroll_container.zig");
    pub const toggle = @import("widgets/toggle.zig");
    pub const battery = @import("widgets/battery.zig");
    pub const slider = @import("widgets/slider.zig");
    pub const segmented = @import("widgets/segmented.zig");
    pub const swatch = @import("widgets/swatch.zig");
    pub const stepper = @import("widgets/stepper.zig");
    pub const arrangement = @import("widgets/arrangement.zig");
};
pub const anim = @import("anim.zig");
pub const cairo = @import("cairo.zig");
pub const client_cursor = @import("client_cursor.zig");
pub const context_menu = @import("context_menu.zig");
pub const font_fallback = @import("font_fallback.zig");
pub const hover_glide = @import("hover_glide.zig");
pub const key_repeat = @import("key_repeat.zig");
pub const sdf = @import("sdf.zig");
pub const shell_icons = @import("shell_icons.zig");
pub const text = @import("text.zig");
pub const theme_presets = @import("theme_presets.zig");
pub const wheel = @import("wheel.zig");

test {
    @import("std").testing.refAllDecls(@This());
    @import("std").testing.refAllDecls(widgets);
}
