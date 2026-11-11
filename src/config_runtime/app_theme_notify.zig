//! GTK's Wayland backend reads GSettings outside sandboxes. Portal clients
//! receive a Settings signal separately, after the worker completes.
const std = @import("std");
const app = @import("config").app_theme;
const a = std.heap.c_allocator;

pub fn gtk(io: std.Io, env: std.process.Environ, home: []const u8, name: []const u8) !bool {
    // A private/headless environment without a bus must not activate the host
    // user's dconf service. settings.ini still provides the startup fallback.
    const bus: []const u8 = env.getPosix("DBUS_SESSION_BUS_ADDRESS") orelse "";
    if (bus.len == 0) return false;
    const helper = try app.executable(a, io, env, "gsettings") orelse return false;
    defer a.free(helper);
    var map = try env.createMap(a);
    defer map.deinit();
    const backup = try std.fs.path.join(a, &.{ home, "rediwm/gtk-theme.gsettings-backup" });
    defer a.free(backup);
    const old = try app.readOptional(a, io, backup);
    defer if (old) |bytes| a.free(bytes);
    if (old == null) {
        const result = try run(io, &map, &.{ helper, "get", "org.gnome.desktop.interface", "gtk-theme" });
        defer a.free(result.stdout);
        defer a.free(result.stderr);
        if (result.term != .exited or result.term.exited != 0) return false;
        var arena: std.heap.ArenaAllocator = .init(a);
        defer arena.deinit();
        var tx = app.Transaction{ .a = arena.allocator(), .io = io };
        try tx.add(backup, result.stdout, false);
        try tx.commit();
    }
    const result = try run(io, &map, &.{ helper, "set", "org.gnome.desktop.interface", "gtk-theme", name });
    defer a.free(result.stdout);
    defer a.free(result.stderr);
    return result.term == .exited and result.term.exited == 0;
}

fn run(io: std.Io, env: *const std.process.Environ.Map, argv: []const []const u8) !std.process.RunResult {
    return std.process.run(a, io, .{
        .argv = argv,
        .environ_map = env,
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(2), .clock = .awake } },
    });
}
