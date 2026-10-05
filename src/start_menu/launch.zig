// Desktop entry command line parsing and process launching.
//
// Complies with the Freedesktop.org Desktop Entry Specification for Exec keys:
// handles quoting, escaping, field code expansions (%f, %u, %c, %i, %k, %%),
// terminal wrapping ($TERMINAL -e / foot -e), working directory, and environment setup.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const applications = @import("applications.zig");
const AppEntry = applications.AppEntry;
const Server = @import("../Server.zig");
const Toplevel = @import("../Toplevel.zig");
const events = @import("../ipc/events.zig");
const dbus = @import("dbus");
const wire = dbus.wire;
const log = std.log.scoped(.launch);
const app_scope = @import("../session/app_scope.zig");

pub const LaunchError = error{
    EmptyCommand,
    SpawnFailed,
    DbusUnavailable,
    DbusActivationFailed,
    EntryNoLongerAvailable,
};

/// Parses an Exec string into an argument vector according to the Desktop Entry Specification.
pub fn parseExec(
    allocator: Allocator,
    exec: []const u8,
    entry: ?*const AppEntry,
) ![]const []const u8 {
    return parseExecUris(allocator, exec, entry, &.{});
}

pub fn parseExecUris(allocator: Allocator, exec: []const u8, entry: ?*const AppEntry, uris: []const []const u8) ![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (argv.items) |arg| allocator.free(arg);
        argv.deinit(allocator);
    }

    var i: usize = 0;
    while (i < exec.len) {
        // Skip leading whitespace
        while (i < exec.len and (exec[i] == ' ' or exec[i] == '\t')) : (i += 1) {}
        if (i >= exec.len) break;

        var arg_buf: std.ArrayList(u8) = .empty;
        defer arg_buf.deinit(allocator);

        var in_double_quotes = false;
        var omit_arg = false;
        var icon_expansion = false;

        while (i < exec.len) {
            const ch = exec[i];

            if (!in_double_quotes and (ch == ' ' or ch == '\t')) {
                break;
            }

            if (ch == '"') {
                in_double_quotes = !in_double_quotes;
                i += 1;
                continue;
            }

            if (ch == '\\' and i + 1 < exec.len) {
                const next = exec[i + 1];
                if (in_double_quotes) {
                    if (next == '"' or next == '`' or next == '$' or next == '\\') {
                        try arg_buf.append(allocator, next);
                        i += 2;
                        continue;
                    }
                } else {
                    try arg_buf.append(allocator, next);
                    i += 2;
                    continue;
                }
            }

            if (ch == '%') {
                if (i + 1 < exec.len) {
                    const code = exec[i + 1];
                    i += 2;
                    switch (code) {
                        '%' => try arg_buf.append(allocator, '%'),
                        'c' => {
                            if (entry) |e| try arg_buf.appendSlice(allocator, e.name);
                        },
                        'k' => {
                            if (entry) |e| try arg_buf.appendSlice(allocator, e.desktop_file_path);
                        },
                        'i' => {
                            if (arg_buf.items.len == 0) {
                                icon_expansion = true;
                            } else if (entry) |e| {
                                if (e.icon) |ic| {
                                    try arg_buf.appendSlice(allocator, "--icon ");
                                    try arg_buf.appendSlice(allocator, ic);
                                }
                            }
                        },
                        'f', 'F', 'u', 'U' => {
                            if (arg_buf.items.len != 0 or in_double_quotes or (i < exec.len and exec[i] != ' ' and exec[i] != '\t')) return error.InvalidFieldCode;
                            const count = if (code == 'f' or code == 'u') @min(uris.len, 1) else uris.len;
                            for (uris[0..count]) |uri| {
                                const value = if (code == 'f' or code == 'F') try fileUriPath(allocator, uri) else try allocator.dupe(u8, uri);
                                errdefer allocator.free(value);
                                try argv.append(allocator, value);
                            }
                            omit_arg = true;
                        },
                        'd', 'D', 'n', 'N', 'v', 'm' => {
                            // When launching without a target file/URL, standalone field codes omit the arg
                            if (arg_buf.items.len == 0) {
                                omit_arg = true;
                            }
                        },
                        else => {},
                    }
                    continue;
                }
            }

            try arg_buf.append(allocator, ch);
            i += 1;
        }

        if (icon_expansion) {
            if (entry) |e| {
                if (e.icon) |ic| {
                    try argv.append(allocator, try allocator.dupe(u8, "--icon"));
                    try argv.append(allocator, try allocator.dupe(u8, ic));
                }
            }
            continue;
        }

        if (omit_arg and arg_buf.items.len == 0) {
            continue;
        }

        if (arg_buf.items.len > 0) {
            try argv.append(allocator, try arg_buf.toOwnedSlice(allocator));
        }
    }

    return argv.toOwnedSlice(allocator);
}

pub fn fileUriPath(allocator: Allocator, uri: []const u8) ![]u8 {
    const parsed = std.Uri.parse(uri) catch return error.InvalidUri;
    if (!std.ascii.eqlIgnoreCase(parsed.scheme, "file") or parsed.user != null or parsed.password != null or parsed.port != null) return error.NonLocalFileUri;
    if (parsed.host) |host| {
        const name = switch (host) {
            .raw, .percent_encoded => |value| value,
        };
        if (name.len != 0 and !std.ascii.eqlIgnoreCase(name, "localhost")) return error.NonLocalFileUri;
    }
    if (parsed.query != null) return error.InvalidUri;
    const encoded = switch (parsed.path) {
        .raw, .percent_encoded => |value| value,
    };
    if (encoded.len == 0 or encoded[0] != '/') return error.NonLocalFileUri;
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    var i: usize = 0;
    while (i < encoded.len) : (i += 1) {
        const byte = if (encoded[i] == '%') blk: {
            if (i + 2 >= encoded.len) return error.InvalidUri;
            const value = std.fmt.parseInt(u8, encoded[i + 1 .. i + 3], 16) catch return error.InvalidUri;
            i += 2;
            break :blk value;
        } else encoded[i];
        if (byte == 0) return error.InvalidUri;
        try result.append(allocator, byte);
    }
    return result.toOwnedSlice(allocator);
}

/// Builds the final argv with terminal emulator wrapping if required.
pub fn buildLaunchArgv(
    allocator: Allocator,
    entry: *const AppEntry,
    environ: std.process.Environ,
) ![]const []const u8 {
    return buildLaunchArgvUris(allocator, entry, environ, &.{}, null);
}

fn buildLaunchArgvUris(allocator: Allocator, entry: *const AppEntry, environ: std.process.Environ, uris: []const []const u8, terminal: ?*const AppEntry) ![]const []const u8 {
    const raw_argv = try parseExecUris(allocator, entry.exec, entry, uris);
    errdefer {
        for (raw_argv) |arg| allocator.free(arg);
        allocator.free(raw_argv);
    }

    if (raw_argv.len == 0) return error.EmptyCommand;

    if (!entry.terminal) {
        return raw_argv;
    }

    const prefix = try @import("../config_runtime/default_apps.zig").terminalPrefix(allocator, terminal, environ);
    defer allocator.free(prefix);
    errdefer for (prefix) |arg| allocator.free(arg);
    const result = try allocator.alloc([]const u8, prefix.len + raw_argv.len);
    @memcpy(result[0..prefix.len], prefix);
    @memcpy(result[prefix.len..], raw_argv);
    allocator.free(raw_argv);
    return result;
}

/// Spawns an application process.
pub fn launch(
    allocator: Allocator,
    server: *Server,
    entry: *const AppEntry,
) !void {
    return launchUris(allocator, server, entry, &.{});
}

pub fn launchUris(allocator: Allocator, server: *Server, entry: *const AppEntry, uris: []const []const u8) !void {
    if (uris.len > 128) return error.TooManyUris;
    for (uris) |uri| {
        if (uri.len > 8192 or std.mem.indexOfScalar(u8, uri, 0) != null or !std.unicode.utf8ValidateSlice(uri)) return error.InvalidUri;
        _ = std.Uri.parse(uri) catch return error.InvalidUri;
    }
    const snap = server.start_menu_catalog.retainSnapshot();
    defer snap.release();
    if (snap.provisional) {
        return launchRevalidated(allocator, server, entry, uris);
    }
    return launchReady(allocator, server, entry, uris);
}

fn launchRevalidated(
    allocator: Allocator,
    server: *Server,
    entry: *const AppEntry,
    uris: []const []const u8,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const content = Io.Dir.cwd().readFileAlloc(server.io, entry.desktop_file_path, a, .limited(512 * 1024)) catch {
        return error.EntryNoLongerAvailable;
    };
    const parsed = applications.parseDesktopFile(a, content, applications.Locale.fromEnv(server.environ)) orelse {
        return error.EntryNoLongerAvailable;
    };
    if (!applications.checkDesktopVisibility(parsed, server.environ.getPosix("XDG_CURRENT_DESKTOP"))) {
        return error.EntryNoLongerAvailable;
    }
    if (parsed.try_exec) |try_exec| {
        if (!applications.checkTryExec(try_exec, server.environ)) return error.EntryNoLongerAvailable;
    }
    const live = AppEntry{
        .id = entry.id,
        .desktop_file_path = entry.desktop_file_path,
        .name = parsed.name orelse entry.name,
        .generic_name = parsed.generic_name,
        .comment = parsed.comment,
        .icon = parsed.icon,
        .exec = parsed.exec orelse "",
        .path = parsed.path,
        .try_exec = parsed.try_exec,
        .terminal = parsed.terminal,
        .keywords = parsed.keywords orelse "",
        .categories = parsed.categories orelse "",
        .dbus_activatable = parsed.dbus_activatable,
    };
    return launchReady(allocator, server, &live, uris);
}

fn launchReady(
    allocator: Allocator,
    server: *Server,
    entry: *const AppEntry,
    uris: []const []const u8,
) !void {
    if (entry.dbus_activatable) {
        launchDbusActivatable(server, entry, uris) catch |err| {
            if (entry.exec.len == 0) return err;
            log.warn("D-Bus launch unavailable for {s}: {}; trying Exec", .{ entry.id, err });
            return launchExec(allocator, server, entry, uris);
        };
        return;
    }
    return launchExec(allocator, server, entry, uris);
}

fn launchExec(allocator: Allocator, server: *Server, entry: *const AppEntry, uris: []const []const u8) !void {
    if (entry.exec.len == 0) return error.EmptyCommand;

    const snapshot = server.start_menu_catalog.retainSnapshot();
    defer snapshot.release();
    const terminal = @import("../config_runtime/default_apps.zig").find(snapshot.entries, server.config.compositor.default_terminal);
    const argv = try buildLaunchArgvUris(allocator, entry, server.environ, uris, terminal);
    defer {
        for (argv) |arg| allocator.free(arg);
        allocator.free(argv);
    }

    const token = server.activation.createToken();
    const token_name = if (token) |t| std.mem.span(t.name()) else null;

    var placeholder: ?*Toplevel = null;
    if (server.config.compositor.placeholder_delay_ms > 0) {
        placeholder = Toplevel.createPlaceholder(server, entry, token_name) catch |err| blk: {
            log.warn("launchReady: could not create placeholder: {}", .{err});
            break :blk null;
        };
        if (token) |t| {
            if (placeholder) |ph| {
                t.data = @as(*anyopaque, @ptrCast(ph));
            }
        }
    }

    var env_map = try server.environ.createMap(allocator);
    defer env_map.deinit();
    try server.applyChildEnvWithToken(&env_map, token_name);

    // Set working directory if specified
    const cwd: std.process.Child.Cwd = if (entry.path) |p| (if (p.len > 0) .{ .path = p } else .inherit) else .inherit;

    const child = std.process.spawn(server.io, .{
        .argv = argv,
        .environ_map = &env_map,
        .cwd = cwd,
    }) catch |err| {
        if (placeholder) |ph| {
            ph.destroyNow();
        }
        return err;
    };

    const child_pid: ?i32 = child.id;
    server.launch_feedback.begin(.{ .pid = child_pid orelse 0, .token = token_name, .desktop_id = entry.id, .startup_wm_class = entry.startup_wm_class });
    if (placeholder) |ph| {
        if (child_pid) |p| {
            ph.backend.placeholder.setPid(ph, p);
        }
    }
    if (child_pid) |p| {
        app_scope.place(server, p, trimDesktopSuffix(entry.id));
        if (server.services) |s| s.trackChild(p) catch {};
    }

    if (server.ipc) |ipc| {
        events.onLaunchStarted(ipc, entry.id, child_pid, if (placeholder) |ph| ph.id else null);
    }
}

/// Every request owns its entry/URIs across catalog reload and IPC arena release.
/// Its timer completes outside bus dispatch, including disconnect and teardown.
pub const Pending = struct {
    server: *Server,
    arena: std.heap.ArenaAllocator,
    entry: AppEntry,
    uris: []const []const u8,
    conn: *dbus.Connection,
    timer: ?*@import("wayland").server.wl.EventSource = null,
    token: ?[]const u8 = null,
    failed: bool = false,
    closing: bool = false,

    pub fn destroy(self: *Pending) void {
        self.closing = true;
        if (self.timer) |timer| timer.remove();
        self.conn.destroy();
        self.arena.deinit();
        @import("../main.zig").gpa.destroy(self);
    }

    fn finish(self: *Pending, failed: bool) void {
        if (self.closing) return;
        self.failed = failed;
        self.timer.?.timerUpdate(1) catch {};
    }

    fn hello(owner: ?*anyopaque, _: *dbus.Connection, result: dbus.Connection.Failure!wire.Message) void {
        const self: *Pending = @ptrCast(@alignCast(owner.?));
        if (self.closing) return;
        const response = result catch return self.finish(true);
        if (response.kind != .method_return) return self.finish(true);
        self.activate() catch self.finish(true);
    }

    fn activate(self: *Pending) !void {
        const allocator = self.arena.allocator();
        const name = trimDesktopSuffix(self.entry.id);
        const path = try makeObjectPath(allocator, name);
        var body = wire.Writer{ .allocator = allocator };
        defer body.deinit();
        try writeActivationBody(&body, self.uris, self.token);
        _ = try self.conn.call(name, path, "org.freedesktop.Application", if (self.uris.len == 0) "Activate" else "Open", if (self.uris.len == 0) "a{sv}" else "asa{sv}", &body, self, reply, 5000);
    }

    fn reply(owner: ?*anyopaque, _: *dbus.Connection, result: dbus.Connection.Failure!wire.Message) void {
        const self: *Pending = @ptrCast(@alignCast(owner.?));
        const message = result catch return self.finish(true);
        self.finish(message.kind != .method_return);
    }

    fn complete(self: *Pending) c_int {
        const server = self.server;
        for (server.pending_launches.items, 0..) |pending, i| {
            if (pending == self) {
                _ = server.pending_launches.swapRemove(i);
                break;
            }
        }
        defer self.destroy();
        if (self.failed) {
            if (self.token) |token| server.launch_feedback.endToken(token);
            log.warn("D-Bus activation failed for {s}; attempting Exec fallback", .{self.entry.id});
            launchExec(self.arena.allocator(), server, &self.entry, self.uris) catch |err| {
                log.err("could not launch {s}: {}", .{ self.entry.id, err });
                if (server.notifications) |manager| {
                    _ = manager.postNotification("RediWM", 0, "dialog-error", "Application could not be started", self.entry.name, &.{}, 1, false, false, 8000, "", null) catch {};
                }
            };
        }
        return 0;
    }
};

fn launchDbusActivatable(server: *Server, entry: *const AppEntry, uris: []const []const u8) !void {
    // No host activation from a nested compositor. Isolated integration tests
    // explicitly opt into their private bus, as other session consumers do.
    const policy = @import("../session/activation.zig");
    if (!policy.shouldPublish(policy.viewFromEnviron(server.environ)) and
        !policy.isTruthy(server.environ.getPosix("REDIWM_FORCE_DBUS"))) return error.DbusUnavailable;
    if (server.pending_launches.items.len >= 32) return error.TooManyLaunches;
    const allocator = @import("../main.zig").gpa;
    const self = try allocator.create(Pending);
    errdefer allocator.destroy(self);
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    var owned = entry.*;
    inline for (@typeInfo(AppEntry).@"struct".fields) |field| {
        if (field.type == []const u8) @field(owned, field.name) = try a.dupe(u8, @field(entry, field.name));
        if (field.type == ?[]const u8) {
            if (@field(entry, field.name)) |value| @field(owned, field.name) = try a.dupe(u8, value);
        }
    }
    const owned_uris = try a.alloc([]const u8, uris.len);
    for (uris, owned_uris) |uri, *target| target.* = try a.dupe(u8, uri);
    const conn = try dbus.Connection.openSession(allocator, server.wl_server.getEventLoop(), server.environ);
    errdefer conn.destroy();
    const token = server.activation.createToken();
    const token_name = if (token) |t| try a.dupe(u8, std.mem.span(t.name())) else null;
    self.* = .{ .server = server, .arena = arena, .entry = owned, .uris = owned_uris, .conn = conn, .token = token_name };
    self.timer = try server.wl_server.getEventLoop().addTimer(*Pending, Pending.complete, self);
    errdefer self.timer.?.remove();
    try server.pending_launches.append(allocator, self);
    errdefer _ = server.pending_launches.pop();
    _ = try conn.hello(self, Pending.hello);
    server.launch_feedback.begin(.{ .token = token_name, .desktop_id = owned.id, .startup_wm_class = owned.startup_wm_class });
    if (server.ipc) |ipc| events.onLaunchStarted(ipc, entry.id, null, null);
}

fn writeActivationBody(body: *wire.Writer, uris: []const []const u8, token: ?[]const u8) !void {
    if (uris.len != 0) {
        const list = try body.beginArray(4);
        for (uris) |uri| try body.string(uri);
        try body.endArray(list);
    }
    const dict = try body.beginArray(8);
    if (token) |value| {
        inline for (.{ "activation-token", "desktop-startup-id" }) |key| {
            try body.alignTo(8);
            try body.string(key);
            try body.variant("s");
            try body.string(value);
        }
    }
    try body.endArray(dict);
}

fn trimDesktopSuffix(id: []const u8) []const u8 {
    if (std.mem.endsWith(u8, id, ".desktop")) {
        return id[0 .. id.len - ".desktop".len];
    }
    return id;
}

fn makeObjectPath(allocator: Allocator, service_name: []const u8) ![]const u8 {
    const out = try allocator.alloc(u8, service_name.len + 1);
    out[0] = '/';
    for (service_name, 0..) |ch, i| {
        out[i + 1] = switch (ch) {
            '.' => '/',
            '-' => '_',
            else => ch,
        };
    }
    return out;
}

test "parseExec standard quoting and field code omission" {
    const parsed = try parseExec(std.testing.allocator, "gedit --new-window %U", null);
    defer {
        for (parsed) |arg| std.testing.allocator.free(arg);
        std.testing.allocator.free(parsed);
    }
    try std.testing.expectEqual(@as(usize, 2), parsed.len);
    try std.testing.expectEqualStrings("gedit", parsed[0]);
    try std.testing.expectEqualStrings("--new-window", parsed[1]);
}

test "parseExec double quotes and escaped spaces" {
    const parsed = try parseExec(std.testing.allocator, "\"my app\" \\\"quoted\\\" second", null);
    defer {
        for (parsed) |arg| std.testing.allocator.free(arg);
        std.testing.allocator.free(parsed);
    }
    try std.testing.expectEqual(@as(usize, 3), parsed.len);
    try std.testing.expectEqualStrings("my app", parsed[0]);
    try std.testing.expectEqualStrings("\"quoted\"", parsed[1]);
    try std.testing.expectEqualStrings("second", parsed[2]);
}

test "parseExec expands field code %c and literal %%" {
    const entry = AppEntry{
        .id = "app.desktop",
        .desktop_file_path = "/usr/share/applications/app.desktop",
        .name = "My Application",
        .exec = "foo --name=%c %%",
    };
    const parsed = try parseExec(std.testing.allocator, entry.exec, &entry);
    defer {
        for (parsed) |arg| std.testing.allocator.free(arg);
        std.testing.allocator.free(parsed);
    }
    try std.testing.expectEqual(@as(usize, 3), parsed.len);
    try std.testing.expectEqualStrings("foo", parsed[0]);
    try std.testing.expectEqualStrings("--name=My Application", parsed[1]);
    try std.testing.expectEqualStrings("%", parsed[2]);
}

test "parseExec expands %i to --icon argument" {
    const entry = AppEntry{
        .id = "app.desktop",
        .desktop_file_path = "/usr/share/applications/app.desktop",
        .name = "App",
        .icon = "firefox",
        .exec = "firefox %i",
    };
    const parsed = try parseExec(std.testing.allocator, entry.exec, &entry);
    defer {
        for (parsed) |arg| std.testing.allocator.free(arg);
        std.testing.allocator.free(parsed);
    }
    try std.testing.expectEqual(@as(usize, 3), parsed.len);
    try std.testing.expectEqualStrings("firefox", parsed[0]);
    try std.testing.expectEqualStrings("--icon", parsed[1]);
    try std.testing.expectEqualStrings("firefox", parsed[2]);
}

test "buildLaunchArgv wraps terminal application" {
    const entry = AppEntry{
        .id = "top.desktop",
        .desktop_file_path = "/usr/share/applications/top.desktop",
        .name = "Top",
        .exec = "htop",
        .terminal = true,
    };
    const environ = std.process.Environ.empty;
    const argv = try buildLaunchArgv(std.testing.allocator, &entry, environ);
    defer {
        for (argv) |arg| std.testing.allocator.free(arg);
        std.testing.allocator.free(argv);
    }
    try std.testing.expectEqual(@as(usize, 3), argv.len);
    try std.testing.expectEqualStrings("foot", argv[0]);
    try std.testing.expectEqualStrings("-e", argv[1]);
    try std.testing.expectEqualStrings("htop", argv[2]);
}

test "application object path converts dashes and dots" {
    const path = try makeObjectPath(std.testing.allocator, "org.example.Photo-Viewer");
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/org/example/Photo_Viewer", path);
}

test "application URI expansion preserves arguments and decodes local files" {
    const a = std.testing.allocator;
    const argv = try parseExecUris(a, "viewer %F -- %U", null, &.{"file:///tmp/a%20b.txt"});
    defer {
        for (argv) |arg| a.free(arg);
        a.free(argv);
    }
    try std.testing.expectEqual(@as(usize, 4), argv.len);
    try std.testing.expectEqualStrings("/tmp/a b.txt", argv[1]);
    try std.testing.expectEqualStrings("file:///tmp/a%20b.txt", argv[3]);
    try std.testing.expectError(error.NonLocalFileUri, fileUriPath(a, "file://remote/tmp/file"));
    try std.testing.expectError(error.InvalidUri, fileUriPath(a, "file:///tmp/%00"));
}

test "application Activate and Open bodies carry activation platform data" {
    const a = std.testing.allocator;
    inline for (.{ false, true }) |open| {
        var body = wire.Writer{ .allocator = a };
        defer body.deinit();
        try writeActivationBody(&body, if (open) &.{"file:///tmp/a%20b"} else &.{}, "token");
        var encoded = try wire.encode(a, .method_call, 0, 1, .{
            .path = "/org/example/App",
            .member = if (open) "Open" else "Activate",
            .signature = if (open) "asa{sv}" else "a{sv}",
        }, &body);
        defer encoded.deinit();
        var reader = (try wire.decode(encoded.bytes.items)).body;
        if (open) {
            var uris = try reader.array(4);
            try std.testing.expectEqualStrings("file:///tmp/a%20b", try uris.string());
            try uris.done();
        }
        var dict = try reader.array(8);
        inline for (.{ "activation-token", "desktop-startup-id" }) |key| {
            try dict.alignTo(8);
            try std.testing.expectEqualStrings(key, try dict.string());
            try std.testing.expectEqualStrings("s", try dict.signature());
            try std.testing.expectEqualStrings("token", try dict.string());
        }
        try dict.done();
        try reader.done();
    }
}

/// Explicit + launch: no splash and no generic D-Bus Activate (which may
/// simply focus an existing window). Prefer the desktop file's new-window
/// action, otherwise execute its regular command and verify a new map.
pub fn launchNewWindow(allocator: Allocator, server: *Server, entry: *const AppEntry, token: []const u8) !i32 {
    const bytes = try Io.Dir.cwd().readFileAlloc(server.io, entry.desktop_file_path, allocator, .limited(512 * 1024));
    defer allocator.free(bytes);
    return launchNewWindowBytes(allocator, server, entry, token, bytes);
}

fn launchNewWindowBytes(allocator: Allocator, server: *Server, entry: *const AppEntry, token: []const u8, bytes: []const u8) !i32 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const parsed = applications.parseDesktopFile(a, bytes, applications.Locale.fromEnv(server.environ)) orelse return error.EntryNoLongerAvailable;
    if (!applications.checkDesktopVisibility(parsed, server.environ.getPosix("XDG_CURRENT_DESKTOP"))) return error.EntryNoLongerAvailable;
    var live = entry.*;
    live.exec = parsed.exec orelse "";
    live.path = parsed.path;
    live.terminal = parsed.terminal;
    var in_action = false;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.startsWith(u8, line, "[")) in_action = std.mem.eql(u8, line, "[Desktop Action new-window]") or std.mem.eql(u8, line, "[Desktop Action NewWindow]");
        if (in_action and std.mem.startsWith(u8, line, "Exec=")) {
            live.exec = line[5..];
            break;
        }
    }
    if (live.exec.len == 0) return error.EmptyCommand;
    const snapshot = server.start_menu_catalog.retainSnapshot();
    defer snapshot.release();
    const terminal = @import("../config_runtime/default_apps.zig").find(snapshot.entries, server.config.compositor.default_terminal);
    const argv = try buildLaunchArgvUris(a, &live, server.environ, &.{}, terminal);
    var env_map = try server.environ.createMap(a);
    defer env_map.deinit();
    try server.applyChildEnvWithToken(&env_map, token);
    const cwd: std.process.Child.Cwd = if (live.path) |p| (if (p.len > 0) .{ .path = p } else .inherit) else .inherit;
    const child = try std.process.spawn(server.io, .{ .argv = argv, .environ_map = &env_map, .cwd = cwd });
    const pid = child.id orelse return error.SpawnFailed;
    server.launch_feedback.begin(.{ .pid = pid, .token = token, .desktop_id = entry.id, .startup_wm_class = entry.startup_wm_class });
    app_scope.place(server, pid, trimDesktopSuffix(entry.id));
    if (server.services) |services| services.trackChild(pid) catch {};
    if (server.ipc) |ipc| events.onLaunchStarted(ipc, entry.id, pid, null);
    return pid;
}
