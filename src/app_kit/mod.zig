//! What a standalone RediWM app is built from, inside this repository or in
//! another one that depends on it as a Zig package (docs/app-kit.md): the
//! shared widgets, the user's theme and settings with live reloads, and a
//! window host that runs an App. No compositor imports.
pub const window_buffer = @import("window_buffer.zig");
pub const window = @import("window.zig");
pub const settings = @import("settings.zig");
pub const settings_watch = @import("settings_watch.zig");

/// The modules an app needs beside the kit, so a dependent package imports one.
pub const ui = @import("ui");
pub const i18n = @import("i18n");
pub const c = @import("c_gfx");
pub const wayland = @import("wayland");
pub const memory = @import("memory");
