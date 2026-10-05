//! rediwm-dm main entry point.
//! Handles `--worker <fd>`, `--test`, or standard root display manager daemon mode.
const std = @import("std");
const config_mod = @import("config.zig");
const daemon_mod = @import("daemon.zig");
const worker_mod = @import("worker.zig");

pub const std_options: std.Options = .{
    .log_level = .info,
};

fn printUsage() void {
    const usage =
        \\Usage: rediwm-dm [OPTIONS]
        \\
        \\A lightweight, root-level Wayland display manager for RediWM.
        \\
        \\Options:
        \\  -h, --help               Show this help message and exit
        \\  --conf <PATH>            Path to dm.conf (default: /etc/rediwm/dm.conf)
        \\  --test                   Run in headless test mode (no real VT switching)
        \\  --confdir <DIR>          Custom PAM configuration directory (for testing)
        \\  --data-dir <DIR>         Look up sessions in <DIR>/wayland-sessions (testing)
        \\  --marker <PATH>          Custom path for autologin marker file
        \\
    ;
    const c = @cImport({ @cInclude("unistd.h"); });
    _ = c.write(1, usage.ptr, usage.len);
}

pub fn main(init: std.process.Init) u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const raw_args = init.minimal.args.vector;
    var is_worker = false;
    var worker_ctrl_fd: c_int = -1;
    var greeter_fd: c_int = -1;
    var is_test = false;
    var confdir: ?[]const u8 = null;
    var conf_path: []const u8 = "/etc/rediwm/dm.conf";
    var marker_path: []const u8 = "/run/rediwm-dm/autologin-done";
    var marker_override = false;
    var data_dir: ?[]const u8 = null;

    var i: usize = 1;
    while (i < raw_args.len) : (i += 1) {
        const arg = std.mem.span(raw_args[i]);
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printUsage();
            return 0;
        } else if (std.mem.eql(u8, arg, "--worker")) {
            is_worker = true;
            if (i + 1 < raw_args.len) {
                i += 1;
                worker_ctrl_fd = std.fmt.parseInt(c_int, std.mem.span(raw_args[i]), 10) catch -1;
            }
        } else if (std.mem.eql(u8, arg, "--greeter-fd")) {
            if (i + 1 < raw_args.len) {
                i += 1;
                greeter_fd = std.fmt.parseInt(c_int, std.mem.span(raw_args[i]), 10) catch -1;
            }
        } else if (std.mem.eql(u8, arg, "--confdir")) {
            if (i + 1 < raw_args.len) {
                i += 1;
                confdir = std.mem.span(raw_args[i]);
            }
        } else if (std.mem.eql(u8, arg, "--conf")) {
            if (i + 1 < raw_args.len) {
                i += 1;
                conf_path = std.mem.span(raw_args[i]);
            }
        } else if (std.mem.eql(u8, arg, "--marker")) {
            if (i + 1 < raw_args.len) {
                i += 1;
                marker_path = std.mem.span(raw_args[i]);
                marker_override = true;
            }
        } else if (std.mem.eql(u8, arg, "--data-dir")) {
            if (i + 1 < raw_args.len) {
                i += 1;
                data_dir = std.mem.span(raw_args[i]);
            }
        } else if (std.mem.eql(u8, arg, "--test")) {
            is_test = true;
        }
    }

    // The test hooks never run as root: `--test` skips the session's
    // privilege drop and accepts any account, and the overrides choose the
    // PAM policy and the session files. Unprivileged test runs keep them.
    if (std.os.linux.geteuid() == 0 and (is_test or confdir != null or data_dir != null or marker_override)) {
        std.log.err("rediwm-dm: --test, --confdir, --data-dir and --marker are for unprivileged tests only", .{});
        return 1;
    }

    if (is_worker) {
        if (worker_ctrl_fd < 0) {
            std.log.err("rediwm-dm: worker missing control fd", .{});
            return 1;
        }
        return worker_mod.runWorker(worker_ctrl_fd, greeter_fd, confdir, is_test) catch |err| {
            std.log.err("worker failed: {}", .{err});
            return 1;
        };
    }

    // A broken config must not leave the machine without a login screen.
    const conf = config_mod.Config.load(a, init.io, conf_path) catch |err| blk: {
        std.log.warn("cannot load config from {s}: {}, using defaults", .{ conf_path, err });
        break :blk config_mod.Config{};
    };

    var daemon = daemon_mod.Daemon.init(conf, init.io, is_test, confdir);
    daemon.marker_path = marker_path;
    if (data_dir) |dir| {
        const dirs = a.alloc([]const u8, 1) catch return 1;
        dirs[0] = dir;
        daemon.search_dirs = dirs;
    }

    daemon.run() catch |err| {
        std.log.err("rediwm-dm fatal error: {}", .{err});
        return 1;
    };

    return 0;
}
