//! Unprivileged theme archive helper; the compositor never links libarchive.
const std = @import("std");
const packs = @import("config").theme_pack;
const theme = @import("ui").theme;
const archive = @import("files/archive.zig");

// `native.c` calls the exported syscall policy.
comptime {
    _ = @import("theme_helper/syscall_policy.zig");
}
extern fn rediwm_theme_stage_isolated([*:0]const u8, [*:0]const u8) c_int;
extern fn rediwm_theme_validate_isolated([*:0]const u8) c_int;
extern fn rediwm_theme_rollback([*:0]const u8, [*:0]const u8) c_int;
extern fn rediwm_theme_publish([*:0]const u8, [*:0]const u8) c_int;
extern fn rediwm_theme_pack([*:0]const u8, [*:0]const u8) c_int;
extern fn rediwm_theme_copy([*:0]const u8, [*:0]const u8) c_int;
extern fn rediwm_theme_problem() [*:0]const u8;
extern fn mkdtemp([*:0]u8) ?[*:0]u8;
extern fn execvp([*:0]const u8, [*:null]const ?[*:0]const u8) c_int;
const a = std.heap.c_allocator;

export fn rediwm_theme_safe_path(path: [*:0]const u8) c_int {
    const raw = std.mem.span(path);
    if (raw.len == 0 or raw[0] == '/' or std.mem.indexOfAny(u8, raw, "\"\n\r\t") != null) return 0;
    const normalized = archive.normalize(a, raw) catch return 0;
    defer a.free(normalized);
    return @intFromBool(normalized.len > 0);
}

fn native(rc: c_int) !void {
    if (rc == 0) return;
    std.debug.print("{s}\n", .{rediwm_theme_problem()});
    return error.PackValidationFailed;
}
fn z(path: []const u8) ![:0]u8 {
    return a.dupeSentinel(u8, path, 0);
}
fn validate(io: std.Io, root: []const u8, id: []const u8) !packs.Pack {
    const path = try std.fs.path.join(a, &.{ root, "theme.toml" });
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1 << 20));
    const p = packs.parse(a, bytes, id, root) catch |err| {
        std.debug.print("{s}: {s}\n", .{ path, @errorName(err) });
        return err;
    };
    try native(rediwm_theme_validate_isolated((try z(root)).ptr));
    if (p.tokens.start_button_icon.len > 0) _ = try packs.asset(a, io, root, p.tokens.start_button_icon[root.len + 1 ..]);
    if (p.wallpaper.len > 0) _ = try packs.asset(a, io, root, try std.fs.path.join(a, &.{ "wallpapers", p.wallpaper }));
    if (std.mem.eql(u8, p.cursor_theme, "pack")) _ = try packs.asset(a, io, root, "cursors/index.theme");
    return p;
}
fn unwrap(io: std.Io, stage: []const u8) ![]const u8 {
    const manifest = try std.fs.path.join(a, &.{ stage, "theme.toml" });
    if (std.Io.Dir.cwd().access(io, manifest, .{})) |_| return stage else |_| {}
    var dir = try std.Io.Dir.cwd().openDir(io, stage, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    const entry = (try it.next(io)) orelse return error.MissingManifest;
    if (entry.kind != .directory) return error.MissingManifest;
    const root = try std.fs.path.join(a, &.{ stage, entry.name });
    if ((try it.next(io)) != null) return error.MultipleArchiveRoots;
    return root;
}

fn copyArtwork(io: std.Io, pack: packs.Pack, destination: []const u8) !void {
    if (pack.root.len == 0) return;
    // Pack icon/glyph overrides are flat directories. Preserve them when
    // saving a customised look so its artwork does not silently disappear.
    for ([_][]const u8{ "icons", "glyphs" }) |folder| {
        const source = packs.asset(a, io, pack.root, folder) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        var directory = try std.Io.Dir.cwd().openDir(io, source, .{ .iterate = true });
        defer directory.close(io);
        var entries = directory.iterate();
        while (try entries.next(io)) |entry| {
            const relative = try std.fs.path.join(a, &.{ folder, entry.name });
            const path = try packs.asset(a, io, pack.root, relative);
            const target = try std.fs.path.join(a, &.{ destination, relative });
            try native(rediwm_theme_copy((try z(path)).ptr, (try z(target)).ptr));
        }
    }
}
fn cursorLink(io: std.Io, env: std.process.Environ, p: packs.Pack, destination: []const u8, prepare: bool) !void {
    const data = if (env.getPosix("XDG_DATA_HOME")) |d| d else try std.fs.path.join(a, &.{ env.getPosix("HOME") orelse return error.NoHome, ".local/share" });
    const icons = try std.fs.path.join(a, &.{ data, "icons" });
    const link = try std.fmt.allocPrint(a, "{s}/rediwm-{s}-cursors", .{ icons, p.id });
    const stat = std.Io.Dir.cwd().statFile(io, link, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (stat) |s| if (s.kind != .sym_link) return error.CursorLinkCollision;
    if (!std.mem.eql(u8, p.cursor_theme, "pack")) {
        if (!prepare and stat != null) try std.Io.Dir.cwd().deleteFile(io, link);
        return;
    }
    try std.Io.Dir.cwd().createDirPath(io, icons);
    if (prepare) return;
    const temp = try std.fmt.allocPrintSentinel(a, "{s}/.rediwm-cursor-XXXXXX", .{icons}, 0);
    if (mkdtemp(temp.ptr) == null) return error.CursorLinkFailed;
    defer std.Io.Dir.cwd().deleteTree(io, temp) catch {};
    const child = try std.fs.path.join(a, &.{ temp, "cursor" });
    try std.Io.Dir.cwd().symLink(io, try std.fs.path.join(a, &.{ destination, "cursors" }), child, .{});
    try std.Io.Dir.rename(.cwd(), child, .cwd(), link, io);
}
fn run(init: std.process.Init) !void {
    if (std.posix.system.geteuid() == 0) return error.RunAsDesktopUser;
    const io = init.io;
    const args = init.minimal.args.vector;
    if (args.len < 3) return error.Usage;
    const verb = std.mem.span(args[1]);
    const input = std.mem.span(args[2]);
    if (std.mem.eql(u8, verb, "terminal")) {
        if (!std.mem.eql(u8, std.fs.path.basename(input), "foot")) return error.UnsupportedTerminal;
        var palette: theme.Theme = .{};
        var opacity: ?f32 = null;
        if (@import("config").path.resolvePath(init.minimal.environ, a)) |path| {
            if (@import("config").loader.load(path, a, io, init.minimal.environ)) |cfg| {
                palette = cfg.theme;
                opacity = cfg.compositor.terminal_opacity;
            } else |_| {}
        } else |_| {}
        const terminal = @import("config").terminal_theme;
        const raw = try a.alloc([]const u8, args.len - 2);
        for (raw, args[2..]) |*dest, arg| dest.* = std.mem.span(arg);
        var command: []const []const u8 = raw;
        if (terminal.enabled(palette, opacity)) {
            // Probe an empty config, never the user's. This work happens only
            // in the short-lived helper, outside the compositor event loop.
            const probe = std.process.run(a, io, .{
                .argv = &.{ input, "--check-config", "--config=/dev/null", "--override=colors-dark.foreground=ffffff" },
                .stdout_limit = .limited(4096),
                .stderr_limit = .limited(4096),
                .timeout = .{ .duration = .{ .raw = .fromSeconds(2), .clock = .awake } },
            }) catch null;
            const modern = if (probe) |p| p.term == .exited and p.term.exited == 0 else false;
            command = try terminal.argv(a, raw, palette, opacity, modern);
        }
        const argv = try a.allocSentinel(?[*:0]const u8, command.len, null);
        for (argv, command) |*dest, arg| dest.* = (try a.dupeSentinel(u8, arg, 0)).ptr;
        _ = execvp(argv[0].?, argv.ptr);
        return error.TerminalExecFailed;
    }
    if (std.mem.eql(u8, verb, "validate")) {
        const p = try validate(io, input, std.fs.path.basename(input));
        _ = std.posix.system.write(1, p.id.ptr, p.id.len);
        _ = std.posix.system.write(1, "\n", 1);
        return;
    }
    if (std.mem.eql(u8, verb, "pack")) {
        if (args.len != 4) return error.Usage;
        _ = try validate(io, input, std.fs.path.basename(input));
        try native(rediwm_theme_pack(args[2], args[3]));
        return;
    }
    const home = try packs.userDir(a, init.minimal.environ);
    try std.Io.Dir.cwd().createDirPath(io, home);
    if (std.mem.eql(u8, verb, "remove")) {
        if (!packs.validId(input)) return error.InvalidPackId;
        const path = try std.fs.path.join(a, &.{ home, input });
        const st = try std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false });
        if (st.kind != .directory) return error.InvalidPack;
        // A broken pack is still removable; the validated ID contains no path.
        try cursorLink(io, init.minimal.environ, .{ .id = input, .name = input, .bytes = "" }, path, false);
        var changed_config: ?[]const u8 = null;
        // A command-line removal follows the same active-pack fallback as UI.
        if (@import("config").path.resolvePath(init.minimal.environ, a)) |config_path| {
            var active = @import("config").loader.load(config_path, a, io, init.minimal.environ) catch null;
            if (active) |*cfg| {
                defer cfg.deinit();
                if (std.mem.eql(u8, cfg.theme_base, input)) {
                    changed_config = config_path;
                    try @import("config").setting_save.selectTheme(a, io, config_path, "rediwm-dark", false);
                }
            }
        } else |_| {}
        try std.Io.Dir.cwd().deleteTree(io, path);
        // Notify readers after deletion, including a pack shadowing a built-in ID.
        if (changed_config) |config_path| {
            const bytes = try std.Io.Dir.cwd().readFileAlloc(io, config_path, a, .limited(1 << 20));
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = config_path, .data = bytes });
        }
        return;
    }
    if (!std.mem.eql(u8, verb, "install") and !std.mem.eql(u8, verb, "export") and !std.mem.eql(u8, verb, "share")) return error.Usage;
    const template = try std.fmt.allocPrintSentinel(a, "{s}/.staging-XXXXXX", .{home}, 0);
    if (mkdtemp(template.ptr) == null) return error.StagingFailed;
    const stage = std.mem.span(template.ptr);
    defer std.Io.Dir.cwd().deleteTree(io, stage) catch {};
    var root: []const u8 = stage;
    var fallback = std.fs.path.basename(input);
    if (std.mem.eql(u8, verb, "export") or std.mem.eql(u8, verb, "share")) {
        // export <id> <config> <wallpaper> <logo>; asset paths are frozen by caller.
        if ((std.mem.eql(u8, verb, "share") and args.len != 7) or (std.mem.eql(u8, verb, "export") and args.len != 6) or !packs.validId(input)) return error.Usage;
        const cfg = try @import("config").loader.load(std.mem.span(args[3]), a, io, init.minimal.environ);
        if (cfg.theme_pack) |pack| try copyArtwork(io, pack, stage);
        var t = cfg.theme;
        if (std.mem.span(args[5]).len > 0) {
            const ext = if (std.ascii.endsWithIgnoreCase(std.mem.span(args[5]), ".svg")) ".svg" else ".png";
            const dest = try std.fmt.allocPrint(a, "{s}/logo{s}", .{ stage, ext });
            try native(rediwm_theme_copy(args[5], (try z(dest)).ptr));
            t.start_button_icon = "";
        }
        var bytes: std.ArrayList(u8) = .empty;
        try bytes.appendSlice(a, try std.fmt.allocPrint(a, "[meta]\nformat = 1\nid = \"{s}\"\nname = \"{s}\"\n", .{ input, input }));
        try theme.writeInto(a, &bytes, t);
        if (std.mem.span(args[5]).len > 0) try bytes.appendSlice(a, if (std.ascii.endsWithIgnoreCase(std.mem.span(args[5]), ".svg")) "start_button_icon = \"logo.svg\"\n" else "start_button_icon = \"logo.png\"\n");
        if (cfg.taskbar_theme) |bar| try theme.writeTaskbarInto(a, &bytes, bar);
        try packs.Layout.write(a, &bytes, cfg.compositor);
        try bytes.appendSlice(a, if (cfg.compositor.dark_mode) "[assets]\ncolor_scheme = \"dark\"\n" else "[assets]\ncolor_scheme = \"light\"\n");
        if (std.mem.span(args[4]).len > 0) {
            const name = std.fs.path.basename(std.mem.span(args[4]));
            if (!packs.relative(name)) return error.UnsafeAssetPath;
            const dest = try std.fs.path.join(a, &.{ stage, "wallpapers", name });
            try native(rediwm_theme_copy(args[4], (try z(dest)).ptr));
            try bytes.appendSlice(a, try std.fmt.allocPrint(a, "wallpaper = \"{s}\"\n", .{name}));
        }
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ stage, "theme.toml" }), .data = bytes.items });
    } else {
        try native(rediwm_theme_stage_isolated(args[2], template.ptr));
        root = try unwrap(io, stage);
        if (!std.mem.eql(u8, root, stage)) fallback = std.fs.path.basename(root) else if (std.mem.lastIndexOfScalar(u8, fallback, '.')) |dot| fallback = fallback[0..dot];
    }
    const p = try validate(io, root, fallback);
    const destination = try std.fs.path.join(a, &.{ home, p.id });
    // Replacing requires an explicit flag; Appearance provides the confirmation.
    if (std.Io.Dir.cwd().access(io, destination, .{})) |_| {
        if (args.len != 4 or !std.mem.eql(u8, std.mem.span(args[3]), "--replace")) {
            std.debug.print("Replace {s} {s}?\n", .{ p.name, p.version });
            return error.AlreadyInstalled;
        }
    } else |_| {}
    try cursorLink(io, init.minimal.environ, p, destination, true);
    try native(rediwm_theme_publish((try z(root)).ptr, (try z(destination)).ptr));
    cursorLink(io, init.minimal.environ, p, destination, false) catch |err| {
        try native(rediwm_theme_rollback((try z(root)).ptr, (try z(destination)).ptr));
        return err;
    };
    if (std.mem.eql(u8, verb, "share")) try native(rediwm_theme_pack((try z(destination)).ptr, args[6]));
    _ = std.posix.system.write(1, p.id.ptr, p.id.len);
    _ = std.posix.system.write(1, "\n", 1);
}

pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        if (err != error.Usage) {
            std.debug.print("rediwm-theme: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        }
        std.debug.print("rediwm-theme: {s}\nUsage: rediwm-theme install <zip|directory> [--replace] | validate <directory> | pack <directory> <out.rediwm-theme> | remove <id> | export <id> <config> <wallpaper> <logo>\n", .{@errorName(err)});
        std.process.exit(1);
    };
}
