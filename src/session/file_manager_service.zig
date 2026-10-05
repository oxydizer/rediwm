//! org.freedesktop.FileManager1: browsers' "show in folder" and similar calls.
//! Every request opens the folder in the File Manager chosen in Settings
//! (built-in Files by default) instead of whatever the bus would activate.
const std = @import("std");
const dbus = @import("dbus");
const wire = dbus.wire;
const Server = @import("../Server.zig");
const launch = @import("../start_menu/launch.zig");
const defaults = @import("../config_runtime/default_apps.zig");
const gpa = @import("../main.zig").gpa;
const log = std.log.scoped(.file_manager_service);

const bus_name = "org.freedesktop.FileManager1";
const object_path = "/org/freedesktop/FileManager1";
const max_folders = 8;

pub fn register(conn: *dbus.Connection, server: *Server) !void {
    inline for (.{ "ShowFolders", "ShowItems", "ShowItemProperties" }) |member| {
        try conn.register(.{ .path = object_path, .interface = bus_name, .member = member, .owner = server, .callback = show });
    }
}

pub fn requestName(conn: *dbus.Connection) void {
    // A restarted compositor takes the name over from the instance it replaces.
    _ = conn.requestName(bus_name, 7, null, onRequestName) catch |err| {
        log.warn("RequestName {s} failed: {}", .{ bus_name, err });
    };
}

fn onRequestName(_: ?*anyopaque, _: *dbus.Connection, result: dbus.Connection.Failure!wire.Message) void {
    const msg = result catch |err| {
        log.warn("RequestName {s} reply failed: {}", .{ bus_name, err });
        return;
    };
    if (msg.headers.error_name) |name| log.warn("RequestName {s} refused: {s}", .{ bus_name, name });
}

fn show(owner: ?*anyopaque, conn: *dbus.Connection, msg: wire.Message) !void {
    const server: *Server = @ptrCast(@alignCast(owner.?));
    if (server.locker != null or server.greeter_mode) {
        try conn.replyError(msg, "org.freedesktop.DBus.Error.AccessDenied", "File manager is unavailable");
        return;
    }
    if (!std.mem.eql(u8, msg.headers.signature, "ass")) return error.InvalidArguments;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var reader = msg.body;
    var uris = try reader.array(4);
    _ = try reader.string(); // startup id
    try reader.done();
    // ShowFolders names folders; the other calls name items inside one.
    const items = !std.mem.eql(u8, msg.headers.member orelse "", "ShowFolders");
    var folders: std.ArrayList([]const u8) = .empty;
    while (uris.offset < uris.bytes.len) {
        const path = launch.fileUriPath(a, try uris.string()) catch continue;
        const folder = if (items) std.fs.path.dirname(path) orelse "/" else path;
        const seen = for (folders.items) |known| {
            if (std.mem.eql(u8, known, folder)) break true;
        } else false;
        if (!seen and folders.items.len < max_folders) try folders.append(a, folder);
    }
    for (folders.items) |folder| open(server, a, folder);
    const empty: wire.Writer = .{ .allocator = gpa };
    try conn.reply(msg, "", &empty);
}

fn open(server: *Server, a: std.mem.Allocator, folder: []const u8) void {
    const snapshot = server.start_menu_catalog.retainSnapshot();
    defer snapshot.release();
    const preferred = server.config.compositor.default_file_manager;
    const id = if (preferred.len > 0) preferred else "rediwm-files.desktop";
    if (defaults.find(snapshot.entries, id)) |entry| {
        const uri = fileUri(a, folder) catch return;
        launch.launchUris(gpa, server, entry, &.{uri}) catch |err| {
            log.warn("could not open {s} in {s}: {}", .{ folder, id, err });
        };
        return;
    }
    // Not installed as a desktop entry: run the built-in browser directly.
    const command = std.fmt.allocPrint(a, "rediwm-files '{s}'", .{std.mem.replaceOwned(u8, a, folder, "'", "'\\''") catch return}) catch return;
    @import("../config_runtime/actions.zig").spawnProcess(server, command);
}

fn fileUri(a: std.mem.Allocator, path: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, "file://");
    for (path) |byte| {
        if (std.ascii.isAlphanumeric(byte) or std.mem.indexOfScalar(u8, "/-._~", byte) != null) {
            try out.append(a, byte);
        } else try out.print(a, "%{X:0>2}", .{byte});
    }
    return out.toOwnedSlice(a);
}
