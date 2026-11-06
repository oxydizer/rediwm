//! rediwm-msg doctor: the health report.

const std = @import("std");
const protocol = @import("protocol");
const closeFd = @import("main.zig").closeFd;
const errnoText = @import("main.zig").errnoText;

pub fn sendDoctorQuery(sock_fd: std.posix.fd_t, query: []const u8, allocator: std.mem.Allocator) ?std.json.Parsed(std.json.Value) {
    const c = std.posix.system;
    var req_buf: [128]u8 = undefined;
    const req = std.fmt.bufPrint(&req_buf, "{{\"version\":1,\"id\":1,\"command\":\"{s}\"}}\n", .{query}) catch return null;
    if (c.write(sock_fd, req.ptr, req.len) <= 0) return null;

    var line = std.ArrayList(u8).empty;
    defer line.deinit(allocator);

    var tmp: [512]u8 = undefined;
    while (true) {
        const nr = c.read(sock_fd, &tmp, tmp.len);
        if (nr <= 0) break;
        line.appendSlice(allocator, tmp[0..@intCast(nr)]) catch return null;
        if (std.mem.indexOfScalar(u8, line.items, '\n') != null) break;
    }

    const trimmed = std.mem.trim(u8, line.items, " \t\r\n");
    if (trimmed.len == 0) return null;
    return std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch null;
}

pub fn nowUs() i64 {
    var ts: std.posix.timespec = undefined;
    _ = std.posix.system.clock_gettime(std.posix.CLOCK.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1_000_000 + @divTrunc(ts.nsec, 1000);
}

pub fn runDoctor(socket_path: []const u8, allocator: std.mem.Allocator, is_json: bool) !void {
    const c = std.posix.system;
    const start_time = nowUs();

    const sock_type = std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC;
    const sock_fd = c.socket(std.posix.AF.UNIX, sock_type, 0);
    if (sock_fd < 0) {
        if (is_json) {
            std.debug.print("{{\"status\":\"error\",\"error\":\"could not create socket\",\"socket\":{f}}}\n", .{std.json.fmt(socket_path, .{})});
        } else {
            std.debug.print("rediwm doctor\n=============\n[✗] Socket: {s} (could not create socket)\n", .{socket_path});
        }
        std.process.exit(1);
    }
    defer closeFd(sock_fd);

    var addr: std.posix.sockaddr.un = .{ .family = std.posix.AF.UNIX, .path = undefined };
    @memset(&addr.path, 0);
    if (socket_path.len >= 107) {
        if (is_json) {
            std.debug.print("{{\"status\":\"error\",\"error\":\"socket path too long\",\"socket\":{f}}}\n", .{std.json.fmt(socket_path, .{})});
        } else {
            std.debug.print("rediwm doctor\n=============\n[✗] Socket: {s} (socket path too long)\n", .{socket_path});
        }
        std.process.exit(1);
    }
    @memcpy(addr.path[0..socket_path.len], socket_path);
    const addr_len = @as(std.posix.socklen_t, @intCast(@offsetOf(std.posix.sockaddr.un, "path") + socket_path.len + 1));

    const tv = std.posix.timeval{ .sec = 2, .usec = 0 };
    _ = c.setsockopt(sock_fd, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, @ptrCast(&tv), @sizeOf(std.posix.timeval));
    _ = c.setsockopt(sock_fd, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, @ptrCast(&tv), @sizeOf(std.posix.timeval));

    const connect_rc = c.connect(sock_fd, @ptrCast(&addr), addr_len);
    if (connect_rc < 0) {
        // The errno tells these apart: a missing or refused socket means no compositor,
        // EPERM/EACCES means something (a sandbox, file modes) forbids the connection.
        const reason = errnoText(connect_rc);
        const hint = switch (std.posix.errno(connect_rc)) {
            .NOENT, .CONNREFUSED => ", compositor not running or socket path invalid",
            else => "",
        };
        if (is_json) {
            std.debug.print("{{\"status\":\"error\",\"error\":\"connection failed\",\"reason\":{f},\"socket\":{f}}}\n", .{ std.json.fmt(reason, .{}), std.json.fmt(socket_path, .{}) });
        } else {
            std.debug.print(
                \\rediwm doctor
                \\=============
                \\[✗] Socket: {s} (connection failed: {s}{s})
                \\
            , .{ socket_path, reason, hint });
        }
        std.process.exit(1);
    }

    const connect_time = nowUs();
    const connect_latency_us = connect_time - start_time;

    const ver_p = sendDoctorQuery(sock_fd, "version", allocator);
    defer if (ver_p) |p| p.deinit();
    const run_p = sendDoctorQuery(sock_fd, "get_runtime_info", allocator);
    defer if (run_p) |p| p.deinit();
    const state_p = sendDoctorQuery(sock_fd, "get_state", allocator);
    defer if (state_p) |p| p.deinit();
    const conf_p = sendDoctorQuery(sock_fd, "get_config_status", allocator);
    defer if (conf_p) |p| p.deinit();
    const perf_p = sendDoctorQuery(sock_fd, "get_performance_stats", allocator);
    defer if (perf_p) |p| p.deinit();

    if (is_json) {
        var list = std.ArrayList(u8).empty;
        defer list.deinit(allocator);
        var bw = protocol.BufferWriter{ .list = &list, .allocator = allocator };
        try bw.print("{{\"status\":\"ok\",\"socket\":{f},\"connect_latency_us\":{d}", .{ std.json.fmt(socket_path, .{}), connect_latency_us });
        if (ver_p) |p| {
            if (p.value == .object and p.value.object.get("Ok") != null) {
                try bw.print(",\"version\":{f}", .{std.json.fmt(p.value.object.get("Ok").?, .{})});
            }
        }
        if (run_p) |p| {
            if (p.value == .object and p.value.object.get("Ok") != null) {
                try bw.print(",\"runtime\":{f}", .{std.json.fmt(p.value.object.get("Ok").?, .{})});
            }
        }
        if (state_p) |p| {
            if (p.value == .object and p.value.object.get("Ok") != null) {
                try bw.print(",\"state\":{f}", .{std.json.fmt(p.value.object.get("Ok").?, .{})});
            }
        }
        if (conf_p) |p| {
            if (p.value == .object and p.value.object.get("Ok") != null) {
                try bw.print(",\"config\":{f}", .{std.json.fmt(p.value.object.get("Ok").?, .{})});
            }
        }
        if (perf_p) |p| {
            if (p.value == .object and p.value.object.get("Ok") != null) {
                try bw.print(",\"perf\":{f}", .{std.json.fmt(p.value.object.get("Ok").?, .{})});
            }
        }
        try bw.writeAll("}\n");
        _ = c.write(std.posix.STDOUT_FILENO, list.items.ptr, list.items.len);
        return;
    }

    var list = std.ArrayList(u8).empty;
    defer list.deinit(allocator);
    var bw = protocol.BufferWriter{ .list = &list, .allocator = allocator };

    try bw.writeAll("rediwm doctor\n=============\n");
    try bw.print("[✓] Socket: {s} (connected in {d:.2}ms)\n", .{ socket_path, @as(f64, @floatFromInt(connect_latency_us)) / 1000.0 });

    if (ver_p) |p| {
        if (p.value == .object and p.value.object.get("Ok") != null) {
            const ok = p.value.object.get("Ok").?;
            if (ok == .object and ok.object.get("Version") != null) {
                const v = ok.object.get("Version").?;
                if (v == .string) {
                    try bw.print("[✓] Compositor: rediwm {s}\n", .{v.string});
                }
            }
        }
    }

    if (run_p) |p| {
        if (p.value == .object and p.value.object.get("Ok") != null) {
            const ok = p.value.object.get("Ok").?;
            if (ok == .object and ok.object.get("RuntimeInfo") != null) {
                const ri = ok.object.get("RuntimeInfo").?;
                if (ri == .object) {
                    const backend = if (ri.object.get("backend")) |b| if (b == .string) b.string else "?" else "?";
                    const renderer = if (ri.object.get("renderer")) |r| if (r == .string) r.string else "?" else "?";
                    const session = if (ri.object.get("session_id")) |s| if (s == .string) s.string else "" else "";
                    try bw.print("[✓] Backend: {s} (renderer: {s}, session: {s})\n", .{ backend, renderer, session });
                }
            }
        }
    }

    if (state_p) |p| {
        if (p.value == .object and p.value.object.get("Ok") != null) {
            const ok = p.value.object.get("Ok").?;
            if (ok == .object and ok.object.get("State") != null) {
                const st = ok.object.get("State").?;
                if (st == .object) {
                    const wins = if (st.object.get("windows")) |w| if (w == .array) w.array.items.len else 0 else 0;
                    const outs = if (st.object.get("outputs")) |o| if (o == .array) o.array.items.len else 0 else 0;
                    const f_id = if (st.object.get("focused_window_id")) |f| if (f == .integer) f.integer else null else null;
                    if (f_id) |fid| {
                        try bw.print("[✓] State: {d} window(s) mapped, {d} output(s) active, focused window: [{d}]\n", .{ wins, outs, fid });
                    } else {
                        try bw.print("[✓] State: {d} window(s) mapped, {d} output(s) active, no focused window\n", .{ wins, outs });
                    }
                }
            }
        }
    }

    if (conf_p) |p| {
        if (p.value == .object and p.value.object.get("Ok") != null) {
            const ok = p.value.object.get("Ok").?;
            if (ok == .object and ok.object.get("ConfigStatus") != null) {
                const cs = ok.object.get("ConfigStatus").?;
                if (cs == .object) {
                    const path = if (cs.object.get("config_path")) |cp| if (cp == .string) cp.string else "<default>" else "<default>";
                    const res = if (cs.object.get("last_reload_result")) |lr| if (lr == .string) lr.string else "ok" else "ok";
                    const err_msg = if (cs.object.get("last_reload_error")) |le| if (le == .string) le.string else null else null;
                    if (err_msg) |em| {
                        try bw.print("[!] Config: {s} (error: {s})\n", .{ path, em });
                    } else {
                        try bw.print("[✓] Config: {s} (status: {s})\n", .{ path, res });
                    }
                }
            }
        }
    }

    if (perf_p) |p| {
        if (p.value == .object and p.value.object.get("Ok") != null) {
            const ok = p.value.object.get("Ok").?;
            if (ok == .object and ok.object.get("PerformanceStats") != null) {
                const ps = ok.object.get("PerformanceStats").?;
                if (ps == .object) {
                    const commits = if (ps.object.get("output_commits")) |c_val| if (c_val == .integer) c_val.integer else 0 else 0;
                    const tb_paints = if (ps.object.get("titlebar_paints")) |tp| if (tp == .integer) tp.integer else 0 else 0;
                    const pnl_paints = if (ps.object.get("panel_paints")) |pp| if (pp == .integer) pp.integer else 0 else 0;
                    try bw.print("[✓] Performance: {d} commits, {d} titlebar paints, {d} panel paints\n", .{ commits, tb_paints, pnl_paints });
                }
            }
        }
    }

    try bw.writeAll("All systems operational.\n");
    _ = c.write(std.posix.STDOUT_FILENO, list.items.ptr, list.items.len);
}
