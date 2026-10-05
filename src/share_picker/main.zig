//! rediwm-share-picker — xdpw dmenu chooser and portal diagnostics.
//!
//! `--xdpw-dmenu` is the production interface: labels on stdin, exactly one
//! selected label on stdout, logs on stderr, empty stdout on cancel. See
//! docs/screen-sharing.md, Installation and portal selection and xdg-desktop-portal-wlr(5).
const std = @import("std");

const child_env = @import("../child_env.zig");
const sources = @import("sources.zig");
const diagnose = @import("diagnose.zig");
const client = @import("client.zig");

const a = std.heap.c_allocator;

const usage =
    \\Usage: rediwm-share-picker [options]
    \\
    \\xdpw dmenu chooser for RediWM screen sharing. Labels on stdin are
    \\opaque selection values; stdout is exactly one of those lines, or
    \\empty if the request is cancelled.
    \\
    \\Options:
    \\  --xdpw-dmenu           Read source labels from stdin (default)
    \\  --select-index N       Choose stdin line N (0-based); no GUI
    \\  --select-label LABEL   Choose the first exact LABEL match; no GUI
    \\  --cancel               Decline without selecting a source
    \\  --diagnose             Print portal/capture environment diagnostics
    \\  -h, --help             Show this help
    \\
;

const Options = struct {
    xdpw_dmenu: bool = false,
    diagnose: bool = false,
    help: bool = false,
    sources: sources.Options = .{},
};

pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        std.debug.print("rediwm-share-picker: {}\n", .{err});
        std.process.exit(1);
    };
}

fn run(init: std.process.Init) !void {
    const opts = parseArgs(init.minimal.args.vector) catch {
        std.debug.print("{s}", .{usage});
        std.process.exit(2);
    };
    if (opts.help) {
        std.debug.print("{s}", .{usage});
        return;
    }
    if (opts.diagnose) {
        const status = try printDiagnose(init.io, init.minimal.environ);
        if (status != 0) std.process.exit(status);
        return;
    }

    const raw = try readStdin();
    defer a.free(raw);
    const labels = try sources.parseLines(a, raw);
    defer sources.freeLines(a, labels);

    const auto = opts.sources.cancel or opts.sources.select_index != null or opts.sources.select_label != null;
    const decision: sources.Decision = if (auto)
        sources.decide(labels, opts.sources)
    else if (init.minimal.environ.getPosix("WAYLAND_DISPLAY") != null)
        client.run(labels) catch |err| blk: {
            std.debug.print("rediwm-share-picker: GUI failed: {}\n", .{err});
            break :blk .cancel;
        }
    else blk: {
        std.debug.print("rediwm-share-picker: no WAYLAND_DISPLAY; pass --select-index or --cancel\n", .{});
        break :blk .cancel;
    };

    switch (decision) {
        .cancel => {},
        .select => |line| {
            if (std.posix.system.write(std.posix.STDOUT_FILENO, line.ptr, line.len) < 0) return error.StdoutWriteFailed;
            if (std.posix.system.write(std.posix.STDOUT_FILENO, "\n", 1) < 0) return error.StdoutWriteFailed;
        },
    }
}

fn parseArgs(argv: []const [*:0]const u8) !Options {
    var opts: Options = .{};
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = std.mem.span(argv[i]);
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            opts.help = true;
        } else if (std.mem.eql(u8, arg, "--xdpw-dmenu")) {
            opts.xdpw_dmenu = true;
        } else if (std.mem.eql(u8, arg, "--diagnose")) {
            opts.diagnose = true;
        } else if (std.mem.eql(u8, arg, "--cancel")) {
            opts.sources.cancel = true;
        } else if (std.mem.eql(u8, arg, "--select-index")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            opts.sources.select_index = std.fmt.parseInt(usize, std.mem.span(argv[i]), 10) catch return error.InvalidIndex;
        } else if (std.mem.startsWith(u8, arg, "--select-index=")) {
            opts.sources.select_index = std.fmt.parseInt(usize, arg["--select-index=".len..], 10) catch return error.InvalidIndex;
        } else if (std.mem.eql(u8, arg, "--select-label")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            opts.sources.select_label = std.mem.span(argv[i]);
        } else if (std.mem.startsWith(u8, arg, "--select-label=")) {
            opts.sources.select_label = arg["--select-label=".len..];
        } else {
            std.debug.print("rediwm-share-picker: unrecognized argument '{s}'\n", .{arg});
            return error.UnrecognizedArgument;
        }
    }
    return opts;
}

fn readStdin() ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(a);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = std.posix.system.read(std.posix.STDIN_FILENO, &chunk, chunk.len);
        if (n == 0) break;
        if (n < 0) return error.StdinReadFailed;
        try buf.appendSlice(a, chunk[0..@intCast(n)]);
    }
    return buf.toOwnedSlice(a);
}

fn printDiagnose(io: std.Io, environ: std.process.Environ) !u8 {
    var failed: u8 = 0;
    const wayland = environ.getPosix("WAYLAND_DISPLAY");
    const desktop = environ.getPosix("XDG_CURRENT_DESKTOP");
    const session = environ.getPosix("XDG_SESSION_TYPE");
    const runtime = environ.getPosix("XDG_RUNTIME_DIR");
    const bus = environ.getPosix("DBUS_SESSION_BUS_ADDRESS");

    try printCheck("WAYLAND_DISPLAY", wayland != null, wayland orelse "unset");
    if (wayland == null) failed += 1;

    const desktop_ok = if (desktop) |d| std.mem.indexOf(u8, d, child_env.desktop_name) != null else false;
    try printCheck("XDG_CURRENT_DESKTOP", desktop_ok, desktop orelse "unset (want rediwm)");
    if (!desktop_ok) failed += 1;

    const session_ok = if (session) |s| std.mem.eql(u8, s, child_env.session_type) else false;
    try printCheck("XDG_SESSION_TYPE", session_ok, session orelse "unset (want wayland)");

    try printCheck("XDG_RUNTIME_DIR", runtime != null, runtime orelse "unset");
    try printCheck("DBUS_SESSION_BUS_ADDRESS", bus != null, bus orelse "unset");

    if (try diagnose.findPortalsConf(a, io, environ)) |path| {
        defer a.free(path);
        try printCheck("rediwm-portals.conf", true, path);
    } else {
        try printCheck("rediwm-portals.conf", false, "not found on XDG_DATA_DIRS");
        failed += 1;
    }

    if (try diagnose.findXdpwConfig(a, io, environ)) |path| {
        defer a.free(path);
        try printCheck("xdpw config", true, path);
    } else {
        try printCheck("xdpw config", false, "not found (login session writes $XDG_CONFIG_HOME/xdg-desktop-portal-wlr/rediwm)");
    }

    if (try diagnose.findPicker(a, io, environ)) |path| {
        defer a.free(path);
        try printCheck("rediwm-share-picker", true, path);
    } else {
        try printCheck("rediwm-share-picker", false, "not on PATH");
        failed += 1;
    }

    if (try diagnose.which(a, io, environ, "xdg-desktop-portal")) |path| {
        defer a.free(path);
        try printCheck("xdg-desktop-portal", true, path);
    } else {
        try printCheck("xdg-desktop-portal", false, "not installed");
        failed += 1;
    }

    if (try diagnose.which(a, io, environ, "xdg-desktop-portal-wlr")) |path| {
        defer a.free(path);
        try printCheck("xdg-desktop-portal-wlr", true, path);
    } else {
        try printCheck("xdg-desktop-portal-wlr", false, "not installed (portal ScreenCast qualification skipped)");
        failed += 1;
    }

    if (try diagnose.pipewireSocket(a, io, environ)) |path| {
        defer a.free(path);
        try printCheck("pipewire socket", true, path);
    } else {
        try printCheck("pipewire socket", false, "XDG_RUNTIME_DIR/pipewire-0 missing");
    }

    if (failed == 0) {
        std.debug.print("status: ok\n", .{});
    } else {
        std.debug.print("status: degraded ({d} missing)\n", .{failed});
    }
    return 0;
}

fn printCheck(name: []const u8, ok: bool, detail: []const u8) !void {
    const mark: []const u8 = if (ok) "ok" else "MISSING";
    std.debug.print("{s}: {s} ({s})\n", .{ name, mark, detail });
}
