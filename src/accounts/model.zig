//! Unprivileged view of login -- accounts and local groups for Settings.
const std = @import("std");
const ws = @import("../session/wayland_sessions.zig");
const c = @cImport({
    @cInclude("pwd.h");
    @cInclude("grp.h");
    @cInclude("unistd.h");
});

pub const User = struct {
    name: []const u8,
    full_name: []const u8,
    home: []const u8,
    uid: u32,
    primary_gid: u32,
    is_current: bool = false,
    admin: bool = false,
    local: bool = false,
    groups: []const []const u8 = &.{},
};

pub const Group = struct {
    name: []const u8,
    gid: u32,
    admin: bool = false,
    local: bool = false,
    members: []const []const u8 = &.{},
};

pub const Snapshot = struct {
    users: []User,
    groups: []Group,
    sessions: []const ws.Session,
    autologin_user: ?[]const u8 = null,
    autologin_session: ?[]const u8 = null,
};

pub fn load(a: std.mem.Allocator, io: std.Io) !Snapshot {
    const range = ws.readLoginDefs(io);
    const local_passwd = std.Io.Dir.cwd().readFileAlloc(io, "/etc/passwd", a, .limited(1024 * 1024)) catch "";
    defer if (local_passwd.len > 0) a.free(local_passwd);
    const local_group_file = std.Io.Dir.cwd().readFileAlloc(io, "/etc/group", a, .limited(1024 * 1024)) catch "";
    defer if (local_group_file.len > 0) a.free(local_group_file);
    var users: std.ArrayList(User) = .empty;
    var groups: std.ArrayList(Group) = .empty;
    c.setgrent();
    defer c.endgrent();
    while (c.getgrent()) |gr| {
        const name = try a.dupe(u8, std.mem.span(gr.*.gr_name));
        var duplicate_group = false;
        for (groups.items) |existing| duplicate_group = duplicate_group or std.mem.eql(u8, existing.name, name);
        if (duplicate_group) continue;
        var members: std.ArrayList([]const u8) = .empty;
        const gr_members = gr.*.gr_mem;
        if (gr_members != null) {
            var i: usize = 0;
            while (gr_members[i]) |member| : (i += 1) try members.append(a, try a.dupe(u8, std.mem.span(member)));
        }
        try groups.append(a, .{
            .name = name,
            .gid = gr.*.gr_gid,
            .local = groupFileContains(local_group_file, name),
            .members = try members.toOwnedSlice(a),
        });
    }
    const admin_name: ?[]const u8 = if (hasLocalGroup(groups.items, "wheel")) "wheel" else if (hasLocalGroup(groups.items, "sudo")) "sudo" else null;
    const admin_gid: ?u32 = if (admin_name) |name| groupGid(groups.items, name) else null;
    if (admin_name) |admin| for (groups.items) |*group| {
        if (std.mem.eql(u8, group.name, admin)) group.admin = true;
    };

    c.setpwent();
    defer c.endpwent();
    while (c.getpwent()) |pw| {
        const shell = if (pw.*.pw_shell) |s| std.mem.span(s) else "";
        if (!ws.loginAccount(range, pw.*.pw_uid, shell)) continue;
        const name = std.mem.span(pw.*.pw_name);
        var duplicate = false;
        for (users.items) |u| duplicate = duplicate or std.mem.eql(u8, u.name, name);
        if (duplicate) continue;
        const gecos = if (pw.*.pw_gecos) |g| std.mem.span(g) else "";
        try users.append(a, .{
            .name = try a.dupe(u8, name),
            .full_name = try a.dupe(u8, gecos[0 .. std.mem.indexOfScalar(u8, gecos, ',') orelse gecos.len]),
            .home = try a.dupe(u8, if (pw.*.pw_dir) |d| std.mem.span(d) else ""),
            .uid = pw.*.pw_uid,
            .primary_gid = pw.*.pw_gid,
            .is_current = pw.*.pw_uid == c.getuid(),
            .admin = (if (admin_gid) |gid| pw.*.pw_gid == gid else false) or (if (admin_name) |admin| groupMember(groups.items, admin, name) else false),
            .local = localPasswdContains(local_passwd, name),
        });
    }
    std.mem.sort(User, users.items, {}, struct {
        fn less(_: void, lhs: User, rhs: User) bool {
            return lhs.uid < rhs.uid;
        }
    }.less);
    for (users.items) |*user| {
        var memberships: std.ArrayList([]const u8) = .empty;
        for (groups.items) |group| {
            if (group.gid == user.primary_gid or contains(group.members, user.name)) try memberships.append(a, group.name);
        }
        user.groups = try memberships.toOwnedSlice(a);
    }

    const config = std.Io.Dir.cwd().readFileAlloc(io, "/etc/rediwm/dm.conf", a, .limited(64 * 1024)) catch "";
    defer if (config.len > 0) a.free(config);
    const auto = try parseAutologin(a, config);
    const sessions = ws.loadSessions(a, io, "/usr/local/share:/usr/share", "/usr/local/bin:/usr/bin:/bin") catch &.{};
    return .{ .users = users.items, .groups = groups.items, .sessions = sessions, .autologin_user = auto.user, .autologin_session = auto.session };
}

fn localPasswdContains(bytes: []const u8, name: []const u8) bool {
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.mem.eql(u8, line[0..colon], name)) return true;
    }
    return false;
}

fn groupFileContains(bytes: []const u8, name: []const u8) bool {
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.mem.eql(u8, line[0..colon], name)) return true;
    }
    return false;
}

fn groupMember(groups: []const Group, name: []const u8, username: []const u8) bool {
    for (groups) |group| if (std.mem.eql(u8, group.name, name)) {
        return contains(group.members, username);
    };
    return false;
}

fn contains(values: []const []const u8, target: []const u8) bool {
    for (values) |value| if (std.mem.eql(u8, value, target)) return true;
    return false;
}

const Autologin = struct { user: ?[]const u8 = null, session: ?[]const u8 = null };

fn parseAutologin(a: std.mem.Allocator, bytes: []const u8) !Autologin {
    var result: Autologin = .{};
    var lines = std.mem.tokenizeScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        var line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.indexOfScalar(u8, line, '#')) |hash| line = std.mem.trimEnd(u8, line[0..hash], " \t\r");
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t\r");
        if (value.len == 0) continue;
        if (std.mem.eql(u8, key, "autologin_user")) result.user = try a.dupe(u8, value);
        if (std.mem.eql(u8, key, "autologin_session")) result.session = try a.dupe(u8, value);
    }
    return result;
}

fn hasLocalGroup(groups: []const Group, name: []const u8) bool {
    for (groups) |group| if (group.local and std.mem.eql(u8, group.name, name)) return true;
    return false;
}

fn groupGid(groups: []const Group, name: []const u8) ?u32 {
    for (groups) |group| if (std.mem.eql(u8, group.name, name)) return group.gid;
    return null;
}
