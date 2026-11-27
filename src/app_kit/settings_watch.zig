//! Theme changes wake the UI through file watching, including while sampling is
//! paused or suspended. Watch parent directories so atomic saves work too.
const std = @import("std");
const platform = @import("platform");
const ui = @import("ui");
const settings = @import("settings.zig");
const a = std.heap.c_allocator;
pub const Watch = struct {
    watcher: platform.watch.Watcher,
    settings: settings.Settings,
    io: std.Io,
    pub fn init(io: std.Io, env: std.process.Environ) !Watch {
        var watcher = platform.watch.Watcher.init() catch return error.ThemeWatchFailed;
        errdefer watcher.deinit();
        var self: Watch = .{ .watcher = watcher, .settings = try settings.Settings.init(a, env), .io = io };
        self.arm();
        _ = self.apply();
        return self;
    }
    pub fn deinit(self: *Watch) void {
        self.settings.deinit(a);
        self.watcher.deinit();
    }
    /// The descriptor to poll for a change.
    pub fn fd(self: *const Watch) c_int {
        return self.watcher.fd;
    }
    fn arm(self: *Watch) void {
        self.settings.watch(self.watcher);
    }
    fn apply(self: *Watch) bool {
        if (self.settings.reload(a, self.io)) |update| {
            update.apply();
            ui.anim.applySettings(self.settings.animations);
            ui.input.caret_config.motion_ms = self.settings.caret_motion_ms;
            return true;
        }
        return false;
    }
    pub fn poll(self: *Watch) bool {
        if (!self.watcher.flush()) return false;
        self.arm();
        return self.apply();
    }
};
