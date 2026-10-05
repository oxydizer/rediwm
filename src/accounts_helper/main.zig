//! Root-side account operations. The compositor supplies one bounded JSON
//! request on stdin; every value is treated as untrusted even under pkexec.
const std = @import("std");
const validation = @import("accounts_validation");
const dm_config = @import("dm_config");
const ws = @import("wayland_sessions");
const c = @cImport({
    @cUndef("_FORTIFY_SOURCE");
    @cDefine("_GNU_SOURCE", "1");
    @cInclude("pwd.h");
    @cInclude("grp.h");
    @cInclude("unistd.h");
    @cInclude("sys/mman.h");
    @cInclude("sys/stat.h");
    @cInclude("fcntl.h");
    @cInclude("errno.h");
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
});

const Request = struct {
    op: []const u8,
    username: ?[]const u8 = null,
    fullname: ?[]const u8 = null,
    password: ?[]const u8 = null,
    administrator: bool = false,
    delete_home: bool = false,
    groups: []const []const u8 = &.{},
    session: ?[]const u8 = null,
};

const a = std.heap.c_allocator;
const dm_conf_path = "/etc/rediwm/dm.conf";
const session_dirs = ws.standard_data_dirs;

pub fn main(init: std.process.Init) u8 {
    if (c.geteuid() != 0) return fail("must be run through pkexec");
    const caller_uid = callerUid() orelse return fail("missing pkexec caller identity");
    var input: std.ArrayList(u8) = .empty;
    defer wipe(input.items);
    while (true) {
        var chunk: [4096]u8 = undefined;
        const got = c.read(0, &chunk, chunk.len);
        if (got <= 0) break;
        const n: usize = @intCast(got);
        if (input.items.len + n > 16 * 1024) return fail("request too large");
        input.appendSlice(a, chunk[0..n]) catch return fail("out of memory");
    }
    var parsed = std.json.parseFromSlice(Request, a, input.items, .{ .allocate = .alloc_always }) catch return fail("invalid request");
    defer parsed.deinit();
    defer {
        if (parsed.value.password) |password| wipe(@constCast(password));
    }
    perform(init.io, caller_uid, parsed.value) catch |err| {
        std.log.err("account operation {s} failed: {s}", .{ parsed.value.op, @errorName(err) });
        return fail("account operation failed");
    };
    std.log.info("account operation {s} completed for caller uid {d}", .{ parsed.value.op, caller_uid });
    _ = c.write(1, "ok\n", 3);
    return 0;
}

fn fail(message: []const u8) u8 {
    _ = c.write(2, message.ptr, message.len);
    _ = c.write(2, "\n", 1);
    return 1;
}

fn wipe(bytes: []u8) void {
    for (bytes) |*byte| {
        const volatile_byte: *volatile u8 = byte;
        volatile_byte.* = 0;
    }
}

fn callerUid() ?u32 {
    const raw = c.getenv("PKEXEC_UID") orelse return null;
    const name = std.mem.span(raw);
    return std.fmt.parseInt(u32, name, 10) catch null;
}

fn perform(io: std.Io, caller_uid: u32, request: Request) !void {
    if (std.mem.eql(u8, request.op, "authorize")) return;
    if (std.mem.eql(u8, request.op, "set-autologin")) {
        const selected_user = request.username orelse "";
        const session = request.session orelse "";
        if (selected_user.len == 0) {
            try writeAutologin(io, null, null);
            return;
        }
        if (!validation.validUsername(selected_user) or session.len == 0) return error.InvalidAutologin;
        const auto_range = ws.readLoginDefs(io);
        const auto_account = lookupUser(selected_user) orelse return error.NoSuchUser;
        if (!validation.validLoginUid(auto_account.uid, auto_range.min, auto_range.max)) return error.NotLoginAccount;
        if ((try ws.lookupSession(a, io, session, session_dirs)) == null) return error.InvalidSession;
        try writeAutologin(io, selected_user, session);
        return;
    }
    const user = request.username orelse return error.MissingUsername;
    if (!validation.validUsername(user)) return error.InvalidUsername;
    const range = ws.readLoginDefs(io);
    if (std.mem.eql(u8, request.op, "create")) {
        const full = request.fullname orelse "";
        const password = request.password orelse return error.MissingPassword;
        if (!validation.validFullName(full) or !validation.validPassword(password)) return error.InvalidInput;
        if (lookupUser(user) != null) return error.UserExists;
        const admin = if (request.administrator) adminGroup() else null;
        if (request.administrator and admin == null) return error.NoAdminGroup;
        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(a);
        try args.appendSlice(a, &.{ try findTool(&.{ "/usr/sbin/useradd", "/usr/bin/useradd" }), "-m", "-c", full, "-s", "/bin/bash" });
        if (admin) |group| try args.appendSlice(a, &.{ "-G", group });
        try args.append(a, user);
        try run(io, args.items, null);
        const credential = try std.fmt.allocPrint(a, "{s}:{s}\n", .{ user, password });
        defer wipe(@constCast(credential));
        run(io, &.{try findTool(&.{ "/usr/sbin/chpasswd", "/usr/bin/chpasswd" })}, credential) catch {
            run(io, &.{ try findTool(&.{ "/usr/sbin/userdel", "/usr/bin/userdel" }), "-r", user }, null) catch {};
            return error.PasswordSetupFailed;
        };
        return;
    }

    const account = lookupUser(user) orelse return error.NoSuchUser;
    if (!validation.validLoginUid(account.uid, range.min, range.max)) return error.NotLoginAccount;
    if (!localAccount(user)) return error.NotLocalAccount;
    if (std.mem.eql(u8, request.op, "delete")) {
        if (account.uid == caller_uid) return error.CannotDeleteCaller;
        if (try userLoggedIn(io, user)) return error.UserLoggedIn;
        if (isAdmin(user) and (adminCount(io) <= 1 or isCaller(caller_uid, user))) return error.LastAdmin;
        try run(io, if (request.delete_home)
            &.{ try findTool(&.{ "/usr/sbin/userdel", "/usr/bin/userdel" }), "-r", user }
        else
            &.{ try findTool(&.{ "/usr/sbin/userdel", "/usr/bin/userdel" }), user }, null);
    } else if (std.mem.eql(u8, request.op, "set-password")) {
        const password = request.password orelse return error.MissingPassword;
        if (!validation.validPassword(password)) return error.InvalidPassword;
        const credential = try std.fmt.allocPrint(a, "{s}:{s}\n", .{ user, password });
        defer wipe(@constCast(credential));
        try run(io, &.{try findTool(&.{ "/usr/sbin/chpasswd", "/usr/bin/chpasswd" })}, credential);
    } else if (std.mem.eql(u8, request.op, "set-fullname")) {
        const full = request.fullname orelse return error.MissingFullName;
        if (!validation.validFullName(full)) return error.InvalidFullName;
        try run(io, &.{ try findTool(&.{ "/usr/sbin/usermod", "/usr/bin/usermod" }), "-c", full, user }, null);
    } else if (std.mem.eql(u8, request.op, "set-type")) {
        const group = adminGroup() orelse return error.NoAdminGroup;
        const currently_admin = isAdmin(user);
        if (currently_admin == request.administrator) return;
        if (request.administrator) {
            try run(io, &.{ try findTool(&.{ "/usr/bin/gpasswd", "/usr/sbin/gpasswd" }), "-a", user, group }, null);
        } else {
            if (account.gid == (lookupGroup(group) orelse return error.NoAdminGroup).gid) return error.PrimaryAdminGroup;
            if (adminCount(io) <= 1 or isCaller(caller_uid, user)) return error.LastAdmin;
            try run(io, &.{ try findTool(&.{ "/usr/bin/gpasswd", "/usr/sbin/gpasswd" }), "-d", user, group }, null);
        }
    } else if (std.mem.eql(u8, request.op, "set-groups")) {
        try setGroups(io, caller_uid, user, account.gid, request.groups);
    } else return error.UnknownOperation;
}

fn lookupUser(name: []const u8) ?struct { uid: u32, gid: u32 } {
    const z = a.dupeZ(u8, name) catch return null;
    defer a.free(z);
    const pw = c.getpwnam(z);
    if (pw == null) return null;
    return .{ .uid = pw.*.pw_uid, .gid = pw.*.pw_gid };
}

fn localAccount(name: []const u8) bool {
    return localNameFromPasswd(name);
}

fn localNameFromPasswd(name: []const u8) bool {
    const fd = c.open("/etc/passwd", c.O_RDONLY | c.O_CLOEXEC);
    if (fd < 0) return false;
    defer _ = c.close(fd);
    var bytes: [1024 * 1024]u8 = undefined;
    const n = c.read(fd, &bytes, bytes.len);
    if (n <= 0) return false;
    var lines = std.mem.splitScalar(u8, bytes[0..@intCast(n)], '\n');
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.mem.eql(u8, line[0..colon], name)) return true;
    }
    return false;
}

fn adminGroup() ?[]const u8 {
    if (lookupGroup("wheel") != null and localGroup("wheel")) return "wheel";
    if (lookupGroup("sudo") != null and localGroup("sudo")) return "sudo";
    return null;
}

const GroupInfo = struct { gid: u32, members: [*c][*c]u8 };

fn lookupGroup(name: []const u8) ?GroupInfo {
    const z = a.dupeZ(u8, name) catch return null;
    defer a.free(z);
    const group = c.getgrnam(z) orelse return null;
    return .{ .gid = group.*.gr_gid, .members = group.*.gr_mem };
}

fn groupContains(group_name: []const u8, user: []const u8, primary_gid: u32) bool {
    const group = lookupGroup(group_name) orelse return false;
    if (group.gid == primary_gid) return true;
    var i: usize = 0;
    while (group.members[i]) |member| : (i += 1) {
        if (std.mem.eql(u8, std.mem.span(member), user)) return true;
    }
    return false;
}

fn isAdmin(user: []const u8) bool {
    const group = adminGroup() orelse return false;
    const account = lookupUser(user) orelse return false;
    return groupContains(group, user, account.gid);
}

fn adminCount(io: std.Io) usize {
    const group_name = adminGroup() orelse return 0;
    const range = ws.readLoginDefs(io);
    var count: usize = 0;
    c.setpwent();
    defer c.endpwent();
    while (c.getpwent()) |pw| {
        const shell = if (pw.*.pw_shell) |value| std.mem.span(value) else "";
        if (!ws.loginAccount(range, pw.*.pw_uid, shell)) continue;
        const name = std.mem.span(pw.*.pw_name);
        if (groupContains(group_name, name, pw.*.pw_gid)) count += 1;
    }
    return count;
}

fn isCaller(uid: u32, target: []const u8) bool {
    const pw = c.getpwuid(uid) orelse return false;
    return std.mem.eql(u8, std.mem.span(pw.*.pw_name), target);
}

fn userLoggedIn(io: std.Io, user: []const u8) !bool {
    const loginctl = try findTool(&.{ "/usr/bin/loginctl", "/bin/loginctl" });
    var child = try std.process.spawn(io, .{
        .argv = &.{ loginctl, "show-user", "--property=Sessions", "--value", user },
        .stdout = .pipe,
        .stderr = .ignore,
    });
    const output_fd = child.stdout.?.handle;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(a);
    while (true) {
        var chunk: [256]u8 = undefined;
        const n = c.read(output_fd, &chunk, chunk.len);
        if (n < 0) {
            child.kill(io);
            _ = child.wait(io) catch {};
            return error.LogindQueryFailed;
        }
        if (n == 0) break;
        if (output.items.len + @as(usize, @intCast(n)) > 4096) {
            child.kill(io);
            _ = child.wait(io) catch {};
            return error.LogindResponseTooLarge;
        }
        try output.appendSlice(a, chunk[0..@intCast(n)]);
    }
    _ = c.close(output_fd);
    const result = try child.wait(io);
    if (result != .exited or result.exited != 0) return error.LogindQueryFailed;
    return std.mem.trim(u8, output.items, " \t\r\n").len > 0;
}

fn setGroups(io: std.Io, caller_uid: u32, user: []const u8, primary_gid: u32, desired: []const []const u8) !void {
    if (desired.len > 256) return error.TooManyGroups;
    var current: std.ArrayList([]const u8) = .empty;
    defer current.deinit(a);
    const admin = adminGroup();
    c.setgrent();
    defer c.endgrent();
    while (c.getgrent()) |group| {
        const name = std.mem.span(group.*.gr_name);
        if (!localGroup(name)) continue;
        if (group.*.gr_gid == primary_gid or !supplementaryMember(group.*, user)) continue;
        if (!validation.validGroupName(name)) return error.UnsafeExistingGroup;
        try current.append(a, try a.dupe(u8, name));
        if (current.items.len > 256) return error.TooManyCurrentGroups;
    }
    for (desired, 0..) |name, i| {
        if (!validation.validGroupName(name) or lookupGroup(name) == null or !localGroup(name)) return error.InvalidGroup;
        for (desired[0..i]) |previous| if (std.mem.eql(u8, previous, name)) return error.DuplicateGroup;
    }
    const current_admin = if (admin) |group| validation.containsName(current.items, group) else false;
    const desired_admin = if (admin) |group| validation.containsName(desired, group) else false;
    if (admin) |group| {
        if (groupGid(group) == primary_gid and !desired_admin) return error.PrimaryAdminGroup;
    }
    if (current_admin and !desired_admin and (adminCount(io) <= 1 or isCaller(caller_uid, user))) return error.LastAdmin;
    for (desired) |group| if (!validation.containsName(current.items, group)) {
        if (groupGid(group) == primary_gid) continue;
        try run(io, &.{ try findTool(&.{ "/usr/bin/gpasswd", "/usr/sbin/gpasswd" }), "-a", user, group }, null);
    };
    for (current.items) |group| if (!validation.containsName(desired, group)) {
        if (admin != null and std.mem.eql(u8, group, admin.?)) {
            if (adminCount(io) <= 1 or isCaller(caller_uid, user)) return error.LastAdmin;
        }
        try run(io, &.{ try findTool(&.{ "/usr/bin/gpasswd", "/usr/sbin/gpasswd" }), "-d", user, group }, null);
    };
}

fn supplementaryMember(group: c.struct_group, user: []const u8) bool {
    const members = group.gr_mem orelse return false;
    var i: usize = 0;
    while (members[i]) |member| : (i += 1) {
        if (std.mem.eql(u8, std.mem.span(member), user)) return true;
    }
    return false;
}

fn groupGid(name: []const u8) ?u32 {
    const group = lookupGroup(name) orelse return null;
    return group.gid;
}

fn localGroup(name: []const u8) bool {
    const fd = c.open("/etc/group", c.O_RDONLY | c.O_CLOEXEC);
    if (fd < 0) return false;
    defer _ = c.close(fd);
    var bytes: [1024 * 1024]u8 = undefined;
    const n = c.read(fd, &bytes, bytes.len);
    if (n <= 0) return false;
    var lines = std.mem.splitScalar(u8, bytes[0..@intCast(n)], '\n');
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.mem.eql(u8, line[0..colon], name)) return true;
    }
    return false;
}

fn findTool(paths: []const []const u8) ![]const u8 {
    for (paths) |path| {
        const z = try a.dupeZ(u8, path);
        defer a.free(z);
        if (c.access(z, c.X_OK) == 0) return path;
    }
    return error.ToolNotFound;
}

fn run(io: std.Io, argv: []const []const u8, stdin_bytes: ?[]const u8) !void {
    var input_fd: c_int = -1;
    defer {
        if (input_fd >= 0) _ = c.close(input_fd);
    }
    var options: std.process.SpawnOptions = .{ .argv = argv, .stdout = .ignore, .stderr = .ignore };
    if (stdin_bytes) |bytes| {
        input_fd = c.memfd_create("rediwm-accounts", c.MFD_CLOEXEC);
        if (input_fd < 0) return error.PipeFailed;
        var written: usize = 0;
        while (written < bytes.len) {
            const n = c.write(input_fd, bytes.ptr + written, bytes.len - written);
            if (n <= 0) return error.WriteFailed;
            written += @intCast(n);
        }
        if (c.lseek(input_fd, 0, c.SEEK_SET) < 0) return error.SeekFailed;
        options.stdin = .{ .file = .{ .handle = input_fd, .flags = .{ .nonblocking = false } } };
    } else options.stdin = .ignore;
    var child = try std.process.spawn(io, options);
    const result = try child.wait(io);
    if (result != .exited or result.exited != 0) return error.CommandFailed;
}

fn writeAutologin(io: std.Io, user: ?[]const u8, session: ?[]const u8) !void {
    const old = std.Io.Dir.cwd().readFileAlloc(io, dm_conf_path, a, .limited(64 * 1024)) catch |err| switch (err) {
        error.FileNotFound => try a.dupe(u8, ""),
        else => return err,
    };
    defer a.free(old);
    const new = try dm_config.rewriteAutologin(a, old, user, session);
    defer a.free(new);
    const temp = try std.fmt.allocPrintSentinel(a, "/etc/rediwm/.dm.conf.{d}.tmp", .{c.getpid()}, 0);
    defer a.free(temp);
    const fd = c.open(temp.ptr, c.O_WRONLY | c.O_CREAT | c.O_EXCL | c.O_CLOEXEC, @as(c_uint, 0o644));
    if (fd < 0) return error.TempFileFailed;
    var ok = false;
    defer {
        _ = c.close(fd);
        if (!ok) _ = c.unlink(temp.ptr);
    }
    var offset: usize = 0;
    while (offset < new.len) {
        const n = c.write(fd, new.ptr + offset, new.len - offset);
        if (n <= 0) return error.ConfigWriteFailed;
        offset += @intCast(n);
    }
    if (c.fsync(fd) != 0) return error.ConfigSyncFailed;
    if (c.rename(temp.ptr, dm_conf_path) != 0) return error.ConfigRenameFailed;
    ok = true;
    const dirfd = c.open("/etc/rediwm", c.O_RDONLY | c.O_DIRECTORY | c.O_CLOEXEC);
    if (dirfd >= 0) {
        defer _ = c.close(dirfd);
        if (c.fsync(dirfd) != 0) std.log.warn("could not sync /etc/rediwm after automatic-login update", .{});
    }
}
