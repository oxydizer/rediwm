//! Runtime paths are independent of Zig's output/staging directory.
const std = @import("std");

pub const Layout = struct {
    prefix: []const u8,
    options: *std.Build.Module,

    pub fn init(b: *std.Build) Layout {
        const raw = b.option([]const u8, "install-prefix", "Runtime installation prefix (default /usr/local; --prefix only selects build output)") orelse "/usr/local";
        // These paths appear in shell commands, desktop files, XML and systemd
        // units. Reject metacharacters rather than giving each format different
        // escaping semantics. Never allow a staging path to be inferred here.
        if (raw.len == 0 or raw[0] != '/') @panic("install-prefix must be absolute");
        for (raw) |ch| {
            if (!std.ascii.isAlphanumeric(ch) and std.mem.indexOfScalar(u8, "/_-+.", ch) == null)
                @panic("install-prefix supports only letters, digits, /, _, -, + and .");
        }
        var parts = std.mem.splitScalar(u8, raw, '/');
        while (parts.next()) |part| {
            if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) @panic("install-prefix must not contain . or .. components");
        }
        const normalized = std.fs.path.resolve(b.allocator, &.{raw}) catch @panic("out of memory");
        const prefix = std.mem.trimEnd(u8, normalized, "/");
        const options = b.addOptions();
        options.addOption(bool, "git_integration", b.option(bool, "git-integration", "Enable Files Git integration") orelse true);
        options.addOption([]const u8, "prefix", prefix);
        options.addOption([]const u8, "bin", b.fmt("{s}/bin", .{prefix}));
        options.addOption([]const u8, "data", b.fmt("{s}/share", .{prefix}));
        options.addOption([]const u8, "search_path", b.fmt("{s}/bin:/usr/local/sbin:/usr/local/bin:/usr/bin:/bin", .{prefix}));
        options.addOption([]const u8, "data_dirs", b.fmt("{s}/share:/usr/local/share:/usr/share", .{prefix}));
        const manifest = b.addWriteFiles().add("install-prefix", b.fmt("{s}\n", .{normalized}));
        b.getInstallStep().dependOn(&b.addInstallFileWithDir(manifest, .prefix, "install-prefix").step);
        return .{ .prefix = prefix, .options = options.createModule() };
    }
};

pub fn configure(b: *std.Build, path: []const u8, prefix: []const u8) std.Build.LazyPath {
    b.dependOnFileContents(b.path(path));
    var dir = b.root.openDir(b.graph.io, ".", .{}) catch @panic("cannot open source directory");
    defer dir.close(b.graph.io);
    const bytes = dir.readFileAlloc(b.graph.io, path, b.allocator, .limited(1024 * 1024)) catch @panic("cannot read installation template");
    const contents = std.mem.replaceOwned(u8, b.allocator, bytes, "@BINDIR@", b.fmt("{s}/bin", .{prefix})) catch @panic("out of memory");
    return b.addWriteFiles().add(std.fs.path.basename(path), contents);
}
