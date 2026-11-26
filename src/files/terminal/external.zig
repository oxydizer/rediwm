//! Launches an independent configured terminal in a real directory.
const std = @import("std");
const App = @import("../app.zig").App;
const defaults = @import("../../config_runtime/default_apps.zig");
const apps = @import("../../start_menu/applications.zig");
const launcher = @import("../../start_menu/launch.zig");

pub fn launch(self: *App) !void {
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const prefs = defaults.load(a, self.io, self.environ);
    const catalogue = try apps.scanAll(a, self.io, self.environ);
    const entry = defaults.find(catalogue.entries, prefs.terminal);
    const args = if (entry) |e| try launcher.parseExec(a, e.exec, e) else try launcher.parseExec(a, self.environ.getPosix("TERMINAL") orelse "foot", null);
    if (args.len == 0) return error.EmptyCommand;
    // Theme flags use the same helper as compositor terminal launches.
    const wrapped = try @import("config").terminal_theme.wrap(a, self.io, args, @import("ui").theme.global, @import("app_kit").settings.terminalOpacity());
    var helper_buf: [4096]u8 = undefined;
    const helper = try self.terminalHelper("rediwm-files-terminal", &helper_buf);
    const argv = try a.alloc([]const u8, wrapped.len + 4);
    argv[0] = helper;
    argv[1] = if (self.terminalScopes()) "1" else "0";
    argv[2] = self.terminal.directory orelse self.home_dir;
    argv[3] = "--external";
    @memcpy(argv[4..], wrapped);
    var child = try std.process.spawn(self.io, .{ .argv = argv });
    self.children.add(self.allocator, child.id.?) catch |err| {
        child.kill(self.io);
        return err;
    };
}
