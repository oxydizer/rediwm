//! Shared application preferences. Workers read them only when launching work.
const std = @import("std");
const apps = @import("../start_menu/applications.zig");
const launch = @import("../start_menu/launch.zig");
pub const Kind = enum { file_manager, terminal };
pub const Preferences = struct { file_manager: []const u8 = "", terminal: []const u8 = "" };

pub fn matches(entry: apps.AppEntry, kind: Kind) bool {
    const category = if (kind == .file_manager) "FileManager" else "TerminalEmulator";
    var parts = std.mem.splitScalar(u8, entry.categories, ';');
    while (parts.next()) |part| if (std.mem.eql(u8, part, category)) return true;
    return kind == .file_manager and std.mem.eql(u8, entry.id, "rediwm-files.desktop");
}

pub fn find(entries: []const apps.AppEntry, id: []const u8) ?*const apps.AppEntry {
    for (entries) |*entry| if (std.mem.eql(u8, entry.id, id)) return entry;
    return null;
}

/// Returned strings belong to the caller's launch arena.
pub fn load(a: std.mem.Allocator, io: std.Io, env: std.process.Environ) Preferences {
    const path = @import("config").path.resolvePath(env, a) catch return .{};
    defer a.free(path);
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1 << 20)) catch return .{};
    defer a.free(bytes);
    var result: Preferences = .{};
    var section = false;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    const theme = @import("ui").theme;
    line_loop: while (lines.next()) |raw| {
        const line = theme.stripComment(std.mem.trim(u8, raw, " \t\r"));
        if (std.mem.startsWith(u8, line, "[")) {
            section = std.mem.eql(u8, line, "[compositor]");
            continue;
        }
        if (!section) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        inline for (.{ "file_manager", "terminal" }) |name| {
            if (std.mem.eql(u8, key, "default_" ++ name)) {
                const value = theme.unquote(std.mem.trim(u8, line[eq + 1 ..], " \t")) catch continue :line_loop;
                @field(result, name) = a.dupe(u8, value) catch "";
            }
        }
    }
    return result;
}

/// Terminal desktop Exec may include flags (and quoted paths). Keep its argv.
/// GNOME-family terminals use --; most others implement -e.
pub fn terminalPrefix(a: std.mem.Allocator, entry: ?*const apps.AppEntry, env: std.process.Environ) ![]const []const u8 {
    const argv = if (entry) |e| try launch.parseExec(a, e.exec, e) else blk: {
        const fallback = try a.alloc([]const u8, 1);
        errdefer a.free(fallback);
        fallback[0] = try a.dupe(u8, env.getPosix("TERMINAL") orelse "foot");
        break :blk fallback;
    };
    errdefer {
        for (argv) |arg| a.free(arg);
        a.free(argv);
    }
    if (argv.len == 0) return error.EmptyCommand;
    const exe = std.fs.path.basename(argv[0]);
    const id = if (entry) |e| e.id else "";
    const flag = if (std.mem.eql(u8, exe, "gnome-terminal") or std.mem.eql(u8, exe, "kgx") or
        std.mem.eql(u8, id, "org.gnome.Terminal.desktop") or std.mem.eql(u8, id, "org.gnome.Console.desktop"))
        "--"
    else if (std.mem.eql(u8, exe, "xfce4-terminal") or std.mem.eql(u8, exe, "mate-terminal") or std.mem.eql(u8, exe, "terminator"))
        "-x"
    else
        "-e";
    const result = try a.alloc([]const u8, argv.len + 1);
    errdefer a.free(result);
    @memcpy(result[0..argv.len], argv);
    result[argv.len] = try a.dupe(u8, flag);
    a.free(argv);
    return result;
}
