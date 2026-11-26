//! Standalone Calculator Wayland host: the app kit's window around `App`.
const std = @import("std");
const App = @import("app.zig").App;

pub fn run(init: std.process.Init) !void {
    var app: App = .{};
    defer app.deinit();
    try @import("app_kit").window.run(App, &app, init, .{
        .app_id = "rediwm-calculator",
        .default_width = 360,
        .default_height = 500,
        .min_width = 280,
        .min_height = 420,
    });
}
