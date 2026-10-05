const std = @import("std");

const wlr = @import("wlroots");

const Server = @import("Server.zig");
const icon_theme = @import("icon_theme.zig");
const ui_theme = @import("ui").theme;

/// Debug builds check every allocation: a double free or a free of memory
/// from another allocator panics with both stack traces, and leaks are logged
/// when the compositor exits. Optimized builds (what gets installed) use libc.
pub const gpa = @import("memory").gpa;
pub const CompositorError = Server.CompositorError;

const log = std.log.scoped(.compositor);

// Optional global override. Physical displays otherwise choose their own scale;
// nested/headless outputs default to 1x (host density is not reliably exposed).
const scale_env = "REDIWM_SCALE";

pub fn main(init: std.process.Init) void {
    // Every client, helper and autostart item would inherit root. rediwm-dm
    // and rediwm-session run the compositor as the logged-in user; seat
    // access comes from logind, so root is never needed.
    if (std.os.linux.getuid() == 0 or std.os.linux.geteuid() == 0) {
        log.err("refusing to run as root; start rediwm as a regular user", .{});
        std.process.exit(1);
    }

    // Xwayland and other helper clients communicate over sockets. If one
    // dies between readiness and event dispatch, a write must report EPIPE
    // to wlroots instead of terminating the whole compositor with SIGPIPE.
    const ignore_sigpipe: std.posix.Sigaction = .{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.PIPE, &ignore_sigpipe, null);

    @import("session/activation.zig").setSessionFdInheritance(init.minimal.environ, false);
    wlr.log.init(.debug, null);
    // Runs last, on a normal exit only: restarts exec and fatal paths exit.
    defer if (@import("builtin").mode == .Debug) {
        if (@import("memory").deinit()) log.err("memory leaks reported above", .{});
    };

    // Remember the installed pathname before an update unlinks this executable.
    const executable = std.process.executablePathAlloc(init.io, gpa) catch |err| {
        log.err("could not resolve restart executable: {}", .{err});
        std.process.exit(1);
    };
    defer gpa.free(executable);
    const args = init.minimal.args.vector;
    const argv = gpa.allocSentinel(?[*:0]const u8, args.len, null) catch {
        std.process.exit(1);
    };
    defer gpa.free(argv);
    for (args, 0..) |arg, i| argv[i] = arg;

    while (true) {
        const restart = start(init) catch |err| {
            log.err("compositor failed to start: {s}", .{@errorName(err)});
            std.process.exit(1);
        };
        if (!restart) return;
        // start's defers have released the seat and removed the IPC/Wayland sockets.
        @import("session/activation.zig").setSessionFdInheritance(init.minimal.environ, true);
        const rc = std.os.linux.execve(executable.ptr, argv.ptr, init.minimal.environ.block.slice.ptr);
        @import("session/activation.zig").setSessionFdInheritance(init.minimal.environ, false);
        log.err("restart execve failed ({t}); restoring the current compositor", .{std.os.linux.errno(rc)});
    }
}

fn start(init: std.process.Init) !bool {
    @import("startup.zig").initOrigin(init.minimal.environ);
    const theme_path = ui_theme.resolvePath(init.minimal.environ);
    const argv = init.minimal.args.vector;
    // `rediwm --greeter` is rediwm-dm's greeter: no IPC, no autostart, no
    // command, and the lock screen stays up until rediwm-dm starts a session.
    const greeter = argv.len >= 2 and std.mem.eql(u8, std.mem.span(argv[1]), "--greeter");

    var server: Server = undefined;
    try server.init(
        readScale(init.minimal.environ),
        // Never freed: icon service workers read it until the process exits.
        // libc rather than `gpa`, so Debug leak reports leave it out.
        try icon_theme.resolveConfig(std.heap.c_allocator, init.minimal.environ),
        init.io,
        init.minimal.environ,
        theme_path,
        init.minimal.args.vector,
        greeter,
    );
    // Process-lifetime caches, emptied after the scene has dropped its buffers.
    defer @import("ui").text.deinit();
    defer @import("panel_buffer.zig").PanelBuffer.drainPool();
    defer @import("chrome.zig").clearShadowPatchCache();
    defer @import("ui").shell_icons.deinit();
    defer server.deinit();

    var buf: [11]u8 = undefined;
    const socket = server.wl_server.addSocketAuto(&buf) catch return error.SocketCreateFailed;
    @import("startup.zig").markSocketReady();

    if (!greeter) {
        server.initIpc(socket) catch |err| {
            log.err("failed to initialize IPC server: {}", .{err});
        };
        if (server.ipc != null) @import("startup.zig").markIpcReady();
    }
    defer server.deinitIpc();

    if (greeter) {
        @import("session/lock.zig").Lock.startGreeter(&server) catch |err| {
            log.err("cannot start the greeter: {}", .{err});
            return error.GreeterStartFailed;
        };
    } else if (@import("session/activation.zig").takeLockRequest(init.minimal.environ)) {
        // rediwm-session restarts a compositor that crashed while locked this
        // way: locked before the first frame, or not at all.
        _ = @import("session/lock.zig").Lock.create(&server, .builtin) catch |err| {
            log.err("cannot restore the lock after a crash: {}", .{err});
            return error.LockRestoreFailed;
        };
        log.info("restarted after a crash while locked; the session stays locked", .{});
    }
    server.backend.start() catch return error.BackendStartFailed;
    try server.session_startup.start(&server);
    if (server.session_startup.failure) |err| return err;

    log.info("Running compositor on WAYLAND_DISPLAY={s}", .{socket});
    server.wl_server.run();
    if (server.session_startup.failure) |err| return err;
    return server.restart_requested;
}

fn readScale(environ: std.process.Environ) ?f32 {
    const text = environ.getPosix(scale_env) orelse return null;
    if (std.mem.eql(u8, text, "auto")) return null;
    const value = std.fmt.parseFloat(f32, text) catch {
        log.err("readScale: ignoring " ++ scale_env ++ "={s}: not a number", .{text});
        return null;
    };
    if (!(value > 0) or value > 16) {
        log.err("readScale: ignoring " ++ scale_env ++ "={s}: out of range", .{text});
        return null;
    }
    log.info("rendering outputs at scale {d}", .{value});
    return value;
}
