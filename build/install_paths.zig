//! Runtime paths are independent of Zig's output/staging directory.
const std = @import("std");

/// Where RediWM's own system configuration lives (`rediwm/dm.conf`, the PAM
/// policy, CUPS's client.conf): `/etc`, but `/usr/local/etc` for ports.
pub fn defaultSysconfdir(os: std.Target.Os.Tag) []const u8 {
    return if (os == .freebsd) "/usr/local/etc" else "/etc";
}

/// Runtime state of system services (the display manager's marker directory).
pub fn defaultRundir(os: std.Target.Os.Tag) []const u8 {
    return if (os == .freebsd) "/var/run" else "/run";
}

pub const Layout = struct {
    prefix: []const u8,
    sysconfdir: []const u8,
    options: *std.Build.Module,

    pub fn init(b: *std.Build, os: std.Target.Os.Tag) Layout {
        const raw = b.option([]const u8, "install-prefix", "Runtime installation prefix (default /usr/local; --prefix only selects build output)") orelse "/usr/local";
        const normalized = normalize(b, "install-prefix", raw);
        const prefix = std.mem.trimEnd(u8, normalized, "/");
        const sysconfdir = std.mem.trimEnd(u8, normalize(b, "sysconfdir", b.option([]const u8, "sysconfdir", b.fmt("System configuration directory (default {s}; {s} when targeting FreeBSD)", .{ defaultSysconfdir(.linux), defaultSysconfdir(.freebsd) })) orelse defaultSysconfdir(os)), "/");
        const rundir = std.mem.trimEnd(u8, normalize(b, "rundir", b.option([]const u8, "rundir", b.fmt("Runtime state directory (default {s}; {s} when targeting FreeBSD)", .{ defaultRundir(.linux), defaultRundir(.freebsd) })) orelse defaultRundir(os)), "/");
        const options = b.addOptions();
        options.addOption(bool, "git_integration", b.option(bool, "git-integration", "Enable Files Git integration") orelse true);
        options.addOption([]const u8, "prefix", prefix);
        options.addOption([]const u8, "sysconfdir", sysconfdir);
        options.addOption([]const u8, "rundir", rundir);
        options.addOption([]const u8, "bin", b.fmt("{s}/bin", .{prefix}));
        options.addOption([]const u8, "data", b.fmt("{s}/share", .{prefix}));
        options.addOption([]const u8, "search_path", b.fmt("{s}/bin:/usr/local/sbin:/usr/local/bin:/usr/bin:/bin", .{prefix}));
        options.addOption([]const u8, "data_dirs", b.fmt("{s}/share:/usr/local/share:/usr/share", .{prefix}));
        const manifest = b.addWriteFiles().add("install-prefix", b.fmt("{s}\n", .{normalized}));
        b.getInstallStep().dependOn(&b.addInstallFileWithDir(manifest, .prefix, "install-prefix").step);
        return .{ .prefix = prefix, .sysconfdir = sysconfdir, .options = options.createModule() };
    }
};

/// These paths appear in shell commands, desktop files, XML, systemd units and
/// C string literals. Reject metacharacters rather than giving each format
/// different escaping semantics. Never allow a staging path to be inferred here.
fn normalize(b: *std.Build, name: []const u8, raw: []const u8) []const u8 {
    if (raw.len == 0 or raw[0] != '/') std.debug.panic("{s} must be absolute", .{name});
    for (raw) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and std.mem.indexOfScalar(u8, "/_-+.", ch) == null)
            std.debug.panic("{s} supports only letters, digits, /, _, -, + and .", .{name});
    }
    var parts = std.mem.splitScalar(u8, raw, '/');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) std.debug.panic("{s} must not contain . or .. components", .{name});
    }
    return std.fs.path.resolve(b.allocator, &.{raw}) catch @panic("out of memory");
}

pub fn configure(b: *std.Build, path: []const u8, prefix: []const u8) std.Build.LazyPath {
    b.dependOnFileContents(b.path(path));
    var dir = b.root.openDir(b.graph.io, ".", .{}) catch @panic("cannot open source directory");
    defer dir.close(b.graph.io);
    const bytes = dir.readFileAlloc(b.graph.io, path, b.allocator, .limited(1024 * 1024)) catch @panic("cannot read installation template");
    const contents = std.mem.replaceOwned(u8, b.allocator, bytes, "@BINDIR@", b.fmt("{s}/bin", .{prefix})) catch @panic("out of memory");
    return b.addWriteFiles().add(std.fs.path.basename(path), contents);
}
