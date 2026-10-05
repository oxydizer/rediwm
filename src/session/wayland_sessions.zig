//! Wayland session desktop entry discovery, parsing, validation and login rules.
//! Shared by rediwm-dm and rediwm --greeter so session resolution and rules can never disagree.
const std = @import("std");

pub const standard_data_dirs: []const []const u8 = &.{
    "/usr/local/share",
    "/usr/share",
};

pub const UidRange = struct { min: u32 = 1000, max: u32 = 60000 };

pub fn parseLoginDefs(bytes: []const u8) UidRange {
    var range: UidRange = .{};
    var lines = std.mem.tokenizeScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        var words = std.mem.tokenizeAny(u8, line, " \t\r");
        const key = words.next() orelse continue;
        const value = std.fmt.parseInt(u32, words.next() orelse continue, 10) catch continue;
        if (std.mem.eql(u8, key, "UID_MIN")) range.min = value;
        if (std.mem.eql(u8, key, "UID_MAX")) range.max = value;
    }
    return range;
}

/// The regular UID range from /etc/login.defs, or the usual defaults.
pub fn readLoginDefs(io: std.Io) UidRange {
    var buf: [256 * 1024]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, "/etc/login.defs", fba.allocator(), .limited(buf.len / 2)) catch return .{};
    return parseLoginDefs(bytes);
}

/// Accounts a person can log in to: the regular UID range with a real shell.
pub fn loginAccount(range: UidRange, uid: u32, shell: []const u8) bool {
    if (uid < range.min or uid > range.max) return false;
    const base = std.fs.path.basename(shell);
    return !std.mem.eql(u8, base, "nologin") and !std.mem.eql(u8, base, "false");
}

pub const Session = struct {
    /// Desktop file stem; becomes XDG_SESSION_DESKTOP, as with GDM.
    id: []const u8,
    name: []const u8,
    exec: []const u8,
    /// DesktopNames, ':'-separated for XDG_CURRENT_DESKTOP.
    desktops: []const u8,
};

pub const DesktopEntry = struct {
    name: []const u8 = "",
    exec: []const u8 = "",
    try_exec: []const u8 = "",
    desktop_names: []const u8 = "",
};

pub fn parseDesktopEntry(bytes: []const u8) ?DesktopEntry {
    var entry: DesktopEntry = .{};
    var in_group = false;
    var lines = std.mem.tokenizeScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') {
            in_group = std.mem.eql(u8, line, "[Desktop Entry]");
            continue;
        }
        if (!in_group) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (std.mem.eql(u8, key, "Name")) entry.name = value;
        if (std.mem.eql(u8, key, "Exec")) entry.exec = value;
        if (std.mem.eql(u8, key, "TryExec")) entry.try_exec = value;
        if (std.mem.eql(u8, key, "DesktopNames")) entry.desktop_names = value;
        if ((std.mem.eql(u8, key, "Hidden") or std.mem.eql(u8, key, "NoDisplay")) and std.mem.eql(u8, value, "true")) return null;
    }
    return if (entry.exec.len > 0) entry else null;
}

/// Sessions take no files or URLs; drop %f-style field codes.
pub fn stripFieldCodes(a: std.mem.Allocator, exec: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < exec.len) : (i += 1) {
        if (exec[i] == '%' and i + 1 < exec.len) {
            i += 1;
            if (exec[i] == '%') try out.append(a, '%');
            continue;
        }
        try out.append(a, exec[i]);
    }
    return std.mem.trim(u8, out.items, " \t");
}

pub fn desktopList(a: std.mem.Allocator, names: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, names, ";");
    const out = try a.dupe(u8, trimmed);
    std.mem.replaceScalar(u8, out, ';', ':');
    return out;
}

const c = @cImport({
    @cInclude("unistd.h");
});

fn isExecutable(path_z: [:0]const u8) bool {
    return c.access(path_z.ptr, c.X_OK) == 0;
}

pub fn executable(program: []const u8, search: []const u8) bool {
    var buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (std.mem.indexOfScalar(u8, program, '/') != null) {
        const z = std.fmt.bufPrintZ(&buf, "{s}", .{program}) catch return false;
        return isExecutable(z);
    }
    var dirs = std.mem.tokenizeScalar(u8, search, ':');
    while (dirs.next()) |dir| {
        const z = std.fmt.bufPrintZ(&buf, "{s}/{s}", .{ dir, program }) catch continue;
        if (isExecutable(z)) return true;
    }
    return false;
}

/// RediWM first, then by display name.
pub fn sessionLess(_: void, x: Session, y: Session) bool {
    const xr = std.mem.startsWith(u8, x.id, "rediwm");
    const yr = std.mem.startsWith(u8, y.id, "rediwm");
    if (xr != yr) return xr;
    if (xr and x.id.len != y.id.len) return x.id.len < y.id.len;
    return std.ascii.lessThanIgnoreCase(x.name, y.name);
}

/// Validates that a session id is a plain file stem: no '/', '\', null, '.' or '..'.
pub fn validateSessionId(id: []const u8) bool {
    if (id.len == 0) return false;
    if (std.mem.eql(u8, id, ".") or std.mem.eql(u8, id, "..")) return false;
    for (id) |b| {
        if (b == '/' or b == '\\' or b == 0) return false;
    }
    return true;
}

/// Resolves a single session id from the given search directories.
/// Returns null if the session id is invalid or not found.
pub fn lookupSession(a: std.mem.Allocator, io: std.Io, id: []const u8, search_dirs: []const []const u8) !?Session {
    if (!validateSessionId(id)) return null;
    var filename_buf: [256]u8 = undefined;
    const filename = std.fmt.bufPrint(&filename_buf, "{s}.desktop", .{id}) catch return null;

    for (search_dirs) |base| {
        const trimmed = std.mem.trimEnd(u8, base, "/");
        const full_path = std.fs.path.join(a, &.{ trimmed, "wayland-sessions", filename }) catch continue;
        defer a.free(full_path);
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, full_path, a, .limited(64 * 1024)) catch continue;
        defer a.free(bytes);
        const parsed = parseDesktopEntry(bytes) orelse continue;

        const owned_id = try a.dupe(u8, id);
        errdefer a.free(owned_id);
        const owned_name = try a.dupe(u8, if (parsed.name.len > 0) parsed.name else id);
        errdefer a.free(owned_name);
        const stripped_exec = try stripFieldCodes(a, parsed.exec);
        errdefer a.free(stripped_exec);
        const desktops = if (parsed.desktop_names.len > 0)
            try desktopList(a, parsed.desktop_names)
        else
            try a.dupe(u8, owned_id);

        return Session{
            .id = owned_id,
            .name = owned_name,
            .exec = stripped_exec,
            .desktops = desktops,
        };
    }
    return null;
}

/// Loads all valid sessions from colon-separated data_dirs.
pub fn loadSessions(a: std.mem.Allocator, io: std.Io, data_dirs: []const u8, search: []const u8) ![]Session {
    var sessions: std.ArrayList(Session) = .empty;
    var dirs = std.mem.tokenizeScalar(u8, data_dirs, ':');
    while (dirs.next()) |base| {
        const path = try std.fs.path.join(a, &.{ base, "wayland-sessions" });
        defer a.free(path);
        var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch null) |entry| {
            if (!std.mem.endsWith(u8, entry.name, ".desktop")) continue;
            const id = entry.name[0 .. entry.name.len - ".desktop".len];
            if (!validateSessionId(id)) continue;
            var seen = false;
            for (sessions.items) |s| seen = seen or std.mem.eql(u8, s.id, id);
            // Earlier data directories take precedence, as for any XDG lookup.
            if (seen) continue;
            const bytes = dir.readFileAlloc(io, entry.name, a, .limited(64 * 1024)) catch continue;
            defer a.free(bytes);
            const parsed = parseDesktopEntry(bytes) orelse continue;
            if (parsed.try_exec.len > 0 and !executable(parsed.try_exec, search)) continue;
            const owned_id = try a.dupe(u8, id);
            try sessions.append(a, .{
                .id = owned_id,
                .name = try a.dupe(u8, if (parsed.name.len > 0) parsed.name else id),
                .exec = try stripFieldCodes(a, parsed.exec),
                .desktops = if (parsed.desktop_names.len > 0) try desktopList(a, parsed.desktop_names) else owned_id,
            });
        }
    }
    std.mem.sort(Session, sessions.items, {}, sessionLess);
    return sessions.items;
}

test "desktop entries become sessions" {
    const a = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const entry = parseDesktopEntry(
        \\[Desktop Entry]
        \\Name=RediWM
        \\Name[de]=RediWM (de)
        \\Exec=/usr/local/bin/rediwm-session %U
        \\TryExec=/usr/local/bin/rediwm-session
        \\DesktopNames=rediwm;wlroots;
        \\[Desktop Action other]
        \\Exec=ignored
    ).?;
    try std.testing.expectEqualStrings("RediWM", entry.name);
    try std.testing.expectEqualStrings("/usr/local/bin/rediwm-session", try stripFieldCodes(arena.allocator(), entry.exec));
    try std.testing.expectEqualStrings("rediwm:wlroots", try desktopList(arena.allocator(), entry.desktop_names));
    try std.testing.expectEqualStrings("env A=100% sway", try stripFieldCodes(arena.allocator(), "env A=100%% sway %f"));
    try std.testing.expect(parseDesktopEntry("[Desktop Entry]\nExec=x\nNoDisplay=true\n") == null);
    try std.testing.expect(parseDesktopEntry("[Desktop Entry]\nName=No command\n") == null);
    var list = [_]Session{
        .{ .id = "sway", .name = "Sway", .exec = "", .desktops = "" },
        .{ .id = "rediwm-release-safe", .name = "RediWM (safe)", .exec = "", .desktops = "" },
        .{ .id = "labwc", .name = "labwc", .exec = "", .desktops = "" },
        .{ .id = "rediwm", .name = "RediWM", .exec = "", .desktops = "" },
    };
    std.mem.sort(Session, &list, {}, sessionLess);
    for ([_][]const u8{ "rediwm", "rediwm-release-safe", "labwc", "sway" }, list) |id, s| try std.testing.expectEqualStrings(id, s.id);
}

test "session id validation rules" {
    try std.testing.expect(validateSessionId("rediwm"));
    try std.testing.expect(validateSessionId("sway-wayland"));
    try std.testing.expect(!validateSessionId(""));
    try std.testing.expect(!validateSessionId("."));
    try std.testing.expect(!validateSessionId(".."));
    try std.testing.expect(!validateSessionId("foo/bar"));
    try std.testing.expect(!validateSessionId("../secret"));
    try std.testing.expect(!validateSessionId("foo\\bar"));
    try std.testing.expect(!validateSessionId("foo\x00bar"));
}

test "login defs accounts filtering" {
    const range = parseLoginDefs("# comment\nUID_MIN\t\t 1500\nUID_MAX 2000\nGID_MIN 100\n");
    try std.testing.expectEqual(@as(u32, 1500), range.min);
    try std.testing.expectEqual(@as(u32, 2000), range.max);
    try std.testing.expect(loginAccount(.{}, 1000, "/bin/bash"));
    try std.testing.expect(loginAccount(.{}, 1000, ""));
    try std.testing.expect(!loginAccount(.{}, 999, "/bin/bash"));
    try std.testing.expect(!loginAccount(.{}, 65534, "/bin/bash"));
    try std.testing.expect(!loginAccount(.{}, 1001, "/usr/bin/nologin"));
    try std.testing.expect(!loginAccount(.{}, 1001, "/bin/false"));
}
