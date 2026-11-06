const std = @import("std");
const protocol = @import("protocol");
const msg_cli = @import("msg_cli.zig");
const msg_doctor = @import("msg_doctor.zig");
const msg_reply = @import("msg_reply.zig");
const msg_usage = @import("msg_usage.zig");
const msg_parse = @import("msg_parse.zig");
const msg_request = @import("msg_request.zig");
pub const CliOptions = msg_cli.CliOptions;
pub const Command = msg_cli.Command;
pub const parseButtonNameOrInt = msg_cli.parseButtonNameOrInt;
pub const usageError = msg_cli.usageError;
pub const parseAnimMs = msg_cli.parseAnimMs;
pub const FlagParser = msg_cli.FlagParser;
pub const sendDoctorQuery = msg_doctor.sendDoctorQuery;
pub const nowUs = msg_doctor.nowUs;
pub const runDoctor = msg_doctor.runDoctor;
pub const printUnwrappedJson = msg_reply.printUnwrappedJson;
pub const printJsonValue = msg_reply.printJsonValue;
pub const printOut = msg_reply.printOut;
pub const printTextReply = msg_reply.printTextReply;
pub const local_commands = msg_usage.local_commands;
pub const TopCommandTag = msg_usage.TopCommandTag;
pub const lookupTopCommand = msg_usage.lookupTopCommand;
pub const printUsage = msg_usage.printUsage;
pub const printCommandHelp = msg_usage.printCommandHelp;
pub const parseCommand = msg_parse.parseCommand;
pub const buildRequest = msg_request.buildRequest;

pub fn closeFd(fd: std.posix.fd_t) void {
    _ = std.c.close(fd);
}

extern "c" fn strerror(errnum: c_int) [*:0]const u8;

/// The libc text for why the libc call that returned `rc` failed ("Operation not
/// permitted"). Call it before anything else that could touch errno.
pub fn errnoText(rc: anytype) []const u8 {
    return std.mem.span(strerror(@intFromEnum(std.posix.errno(rc))));
}

pub fn getEnv(key: [*:0]const u8) ?[]const u8 {
    if (std.c.getenv(key)) |ptr| {
        return std.mem.span(ptr);
    }
    return null;
}

pub fn main(init: std.process.Init) void {
    const allocator = std.heap.c_allocator;

    runMsg(init, allocator) catch |err| {
        std.debug.print("error: {}\n", .{err});
        std.process.exit(1);
    };
}

pub fn runMsg(init: std.process.Init, allocator: std.mem.Allocator) !void {
    const raw_args = init.minimal.args.vector;
    if (raw_args.len < 2) {
        printUsage();
        std.process.exit(1);
    }

    var opts = CliOptions{};
    var arg_idx: usize = 1;
    const cli: FlagParser = .{ .args = raw_args, .idx = &arg_idx, .opts = &opts, .allocator = allocator };

    // Parse options and subcommand
    while (arg_idx < raw_args.len) {
        const arg = std.mem.span(raw_args[arg_idx]);
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage();
            return;
        } else if (std.mem.eql(u8, arg, "--json")) {
            opts.json = true;
            arg_idx += 1;
        } else if (std.mem.eql(u8, arg, "--timeout") or std.mem.eql(u8, arg, "-t")) {
            arg_idx += 1;
            if (arg_idx >= raw_args.len) {
                std.debug.print("error: --timeout requires milliseconds\n", .{});
                std.process.exit(1);
            }
            opts.timeout_ms = std.fmt.parseInt(u64, std.mem.span(raw_args[arg_idx]), 10) catch null;
            arg_idx += 1;
        } else if (std.mem.eql(u8, arg, "--raw")) {
            arg_idx += 1;
            if (arg_idx < raw_args.len and !std.mem.startsWith(u8, std.mem.span(raw_args[arg_idx]), "-")) {
                opts.command = .{ .raw = std.mem.span(raw_args[arg_idx]) };
                arg_idx += 1;
            } else {
                var stdin_buf = std.ArrayList(u8).empty;
                var in_chunk: [4096]u8 = undefined;
                while (true) {
                    const nr = std.posix.system.read(std.posix.STDIN_FILENO, &in_chunk, in_chunk.len);
                    if (nr <= 0) break;
                    try stdin_buf.appendSlice(allocator, in_chunk[0..@intCast(nr)]);
                }
                opts.command = .{ .raw = stdin_buf.items };
            }
        } else if (std.mem.eql(u8, arg, "--socket") or std.mem.eql(u8, arg, "-s")) {
            arg_idx += 1;
            if (arg_idx >= raw_args.len) {
                std.debug.print("error: --socket requires a path\n", .{});
                std.process.exit(1);
            }
            opts.socket_path = std.mem.span(raw_args[arg_idx]);
            arg_idx += 1;
        } else if (opts.command == null) {
            try parseCommand(cli, arg);
        } else {
            arg_idx += 1;
        }
    }

    const command = opts.command orelse {
        printUsage();
        std.process.exit(1);
    };

    const socket_path = opts.socket_path orelse getEnv("REDIWM_SOCKET") orelse blk: {
        if (getEnv("XDG_RUNTIME_DIR")) |xdg_dir| {
            if (getEnv("WAYLAND_DISPLAY")) |display| {
                break :blk try std.fmt.allocPrint(allocator, "{s}/rediwm-{s}.sock", .{ xdg_dir, display });
            }
        }
        // rediwm never listens in a shared directory, where another user could plant a socket.
        usageError("no IPC socket: set REDIWM_SOCKET, or XDG_RUNTIME_DIR and WAYLAND_DISPLAY");
    };

    if (command == .doctor) {
        try runDoctor(socket_path, allocator, opts.json);
        return;
    }

    const c = std.posix.system;

    const sock_type = std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC;
    const sock_fd = c.socket(std.posix.AF.UNIX, sock_type, 0);
    if (sock_fd < 0) {
        std.debug.print("error: could not create socket\n", .{});
        std.process.exit(1);
    }
    defer closeFd(sock_fd);

    var addr: std.posix.sockaddr.un = .{ .family = std.posix.AF.UNIX, .path = undefined };
    @memset(&addr.path, 0);
    if (socket_path.len >= 107) {
        std.debug.print("error: socket path too long: {s}\n", .{socket_path});
        std.process.exit(1);
    }
    @memcpy(addr.path[0..socket_path.len], socket_path);
    const addr_len = @as(std.posix.socklen_t, @intCast(@offsetOf(std.posix.sockaddr.un, "path") + socket_path.len + 1));

    const connect_rc = c.connect(sock_fd, @ptrCast(&addr), addr_len);
    if (connect_rc < 0) {
        std.debug.print("error: failed to connect to socket {s}: {s}\n", .{ socket_path, errnoText(connect_rc) });
        std.process.exit(1);
    }

    var effective_timeout_ms = opts.timeout_ms;
    if (effective_timeout_ms == null) {
        switch (command) {
            .wait => |p| {
                if (p.timeout_ms) |t| effective_timeout_ms = t + 2000;
            },
            .wait_frame => |p| {
                if (p.timeout_ms) |t| effective_timeout_ms = t + 2000;
            },
            else => {},
        }
    }

    if (effective_timeout_ms) |t_ms| {
        const tv = std.posix.timeval{
            .sec = @intCast(t_ms / 1000),
            .usec = @intCast((t_ms % 1000) * 1000),
        };
        _ = c.setsockopt(sock_fd, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, @ptrCast(&tv), @sizeOf(std.posix.timeval));
        _ = c.setsockopt(sock_fd, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, @ptrCast(&tv), @sizeOf(std.posix.timeval));
    }

    // Construct JSON request string
    var req_buf = try buildRequest(allocator, command);
    defer req_buf.deinit(allocator);

    _ = c.write(sock_fd, req_buf.items.ptr, req_buf.items.len);

    if (command == .event_stream) {
        var read_buf: [4096]u8 = undefined;
        while (true) {
            const nread = c.read(sock_fd, &read_buf, read_buf.len);
            if (nread <= 0) break;
            _ = c.write(std.posix.STDOUT_FILENO, &read_buf, @intCast(nread));
        }
        return;
    }

    // Read single line reply
    var reply_buf = std.ArrayList(u8).empty;
    defer reply_buf.deinit(allocator);

    var tmp: [1024]u8 = undefined;
    while (true) {
        const nread_res = c.read(sock_fd, &tmp, tmp.len);
        if (nread_res <= 0) break;
        const nread: usize = @intCast(nread_res);
        try reply_buf.appendSlice(allocator, tmp[0..nread]);
        if (std.mem.indexOfScalar(u8, reply_buf.items, '\n') != null) break;
    }

    const trimmed_reply = std.mem.trim(u8, reply_buf.items, " \t\r\n");
    if (trimmed_reply.len == 0) {
        std.debug.print("error: empty reply from compositor\n", .{});
        std.process.exit(1);
    }

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed_reply, .{}) catch {
        std.debug.print("error: invalid JSON reply from compositor: {s}\n", .{trimmed_reply});
        std.process.exit(1);
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        std.debug.print("error: malformed reply: {s}\n", .{trimmed_reply});
        std.process.exit(1);
    }

    if (parsed.value.object.get("Err")) |err_val| {
        if (err_val == .string) {
            std.debug.print("error: {s}\n", .{err_val.string});
        } else {
            std.debug.print("error: unknown error reply\n", .{});
        }
        std.process.exit(1);
    }

    if (parsed.value.object.get("error")) |err_val| {
        if (err_val == .string) {
            std.debug.print("error: {s}\n", .{err_val.string});
        } else {
            std.debug.print("error: unknown error reply\n", .{});
        }
        std.process.exit(1);
    }

    const ok_val = parsed.value.object.get("Ok") orelse {
        std.debug.print("error: reply missing Ok/Err: {s}\n", .{trimmed_reply});
        std.process.exit(1);
    };

    var is_timeout = false;
    if (ok_val == .object) {
        if (ok_val.object.get("WaitFor")) |wf| {
            if (wf == .object) {
                if (wf.object.get("timed_out")) |to| {
                    if (to == .bool and to.bool) is_timeout = true;
                }
            }
        } else if (ok_val.object.get("WaitForFrame")) |wff| {
            if (wff == .object) {
                if (wff.object.get("timed_out")) |to| {
                    if (to == .bool and to.bool) is_timeout = true;
                }
            }
        }
    }

    if (opts.save_path) |save_path| {
        if (ok_val == .object and ok_val.object.get("Screenshot") != null) {
            const sc_obj = ok_val.object.get("Screenshot").?;
            if (sc_obj == .object and sc_obj.object.get("data") != null) {
                const data_val = sc_obj.object.get("data").?;
                if (data_val == .string) {
                    const b64_str = data_val.string;
                    const decoder = std.base64.standard.Decoder;
                    const decoded_len = decoder.calcSizeForSlice(b64_str) catch {
                        std.debug.print("error: invalid base64 data\n", .{});
                        std.process.exit(1);
                    };
                    const raw_bytes = try allocator.alloc(u8, decoded_len);
                    defer allocator.free(raw_bytes);
                    decoder.decode(raw_bytes, b64_str) catch {
                        std.debug.print("error: base64 decode error\n", .{});
                        std.process.exit(1);
                    };

                    const save_fd = std.posix.openat(std.posix.AT.FDCWD, save_path, .{
                        .ACCMODE = .WRONLY,
                        .CREAT = true,
                        .EXCL = true,
                        .CLOEXEC = true,
                        .NOFOLLOW = true,
                    }, 0o644) catch |err| {
                        std.debug.print("error: could not create save file {s}: {}\n", .{ save_path, err });
                        std.process.exit(1);
                    };
                    defer _ = c.close(save_fd);
                    var save_written: usize = 0;
                    while (save_written < raw_bytes.len) {
                        const n = c.write(save_fd, raw_bytes.ptr + save_written, raw_bytes.len - save_written);
                        if (n <= 0) {
                            std.debug.print("error: write failed to {s}\n", .{save_path});
                            std.process.exit(1);
                        }
                        save_written += @intCast(n);
                    }
                    if (!opts.json) {
                        std.debug.print("Screenshot saved to {s}\n", .{save_path});
                        return;
                    }
                }
            }
        }
    }

    if (opts.json) {
        switch (command) {
            .windows => try printUnwrappedJson(ok_val, "Windows"),
            .outputs => try printUnwrappedJson(ok_val, "Outputs"),
            .focused_window => try printUnwrappedJson(ok_val, "FocusedWindow"),
            .workspaces => try printUnwrappedJson(ok_val, "Workspaces"),
            .version => try printUnwrappedJson(ok_val, "Version"),
            .capabilities => try printUnwrappedJson(ok_val, "Capabilities"),
            .state => try printUnwrappedJson(ok_val, "State"),
            .describe => try printUnwrappedJson(ok_val, "DescribeIPC"),
            .window_debug => try printUnwrappedJson(ok_val, "WindowDebug"),
            .window_rules => try printUnwrappedJson(ok_val, "WindowRules"),
            .match_window_rules => try printUnwrappedJson(ok_val, "MatchWindowRules"),
            .shell_state => try printUnwrappedJson(ok_val, "ShellState"),
            .keyboard_layouts => try printUnwrappedJson(ok_val, "KeyboardLayouts"),
            .text_input => try printUnwrappedJson(ok_val, "TextInput"),
            .input_state => try printUnwrappedJson(ok_val, "InputState"),
            .hit_test => try printUnwrappedJson(ok_val, "HitTest"),
            .scene_tree => try printUnwrappedJson(ok_val, "SceneTree"),
            .layers => try printUnwrappedJson(ok_val, "LayerSurfaces"),
            .panels => try printUnwrappedJson(ok_val, "ListPanels"),
            .widget_tree => try printUnwrappedJson(ok_val, "WidgetTree"),
            .config => try printUnwrappedJson(ok_val, "ConfigStatus"),
            .runtime => try printUnwrappedJson(ok_val, "RuntimeInfo"),
            .perf => try printUnwrappedJson(ok_val, "PerformanceStats"),
            .wait => try printUnwrappedJson(ok_val, "WaitFor"),
            .wait_frame => try printUnwrappedJson(ok_val, "WaitForFrame"),
            .dump_buffer => try printUnwrappedJson(ok_val, "DumpBuffer"),
            .sample_pixels => try printUnwrappedJson(ok_val, "SamplePixels"),
            .night_light => try printUnwrappedJson(ok_val, "NightLight"),
            .notifications => try printUnwrappedJson(ok_val, "Notifications"),
            else => try printJsonValue(ok_val),
        }
    } else {
        printTextReply(ok_val);
    }

    if (is_timeout) {
        std.process.exit(1);
    }
}
