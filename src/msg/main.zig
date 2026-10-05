const std = @import("std");
const protocol = @import("protocol");

fn closeFd(fd: std.posix.fd_t) void {
    _ = std.c.close(fd);
}

fn getEnv(key: [*:0]const u8) ?[]const u8 {
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

const CliOptions = struct {
    socket_path: ?[]const u8 = null,
    json: bool = false,
    save_path: ?[]const u8 = null,
    timeout_ms: ?u64 = null,
    command: ?Command = null,
};

const Command = union(enum) {
    raw: []const u8,
    version,
    capabilities,
    windows,
    outputs,
    output_config: protocol.OutputConfigPatch,
    focused_window,
    workspaces,
    event_stream: struct { events: ?[]const []const u8 = null, window_id: ?u64 = null, output: ?[]const u8 = null },
    state,
    describe,
    doctor,
    window_debug: struct { id: u64 },
    window_rules: struct { id: u64 },
    match_window_rules: protocol.MatchWindowRulesParams,
    night_light,
    shell_state: struct { output: ?[]const u8 = null },
    input_state,
    text_input,
    keyboard_layouts,
    switch_layout: protocol.LayoutTarget,
    hit_test: struct { x: i32, y: i32, output: ?[]const u8 = null },
    scene_tree: struct { max_depth: ?u32 = null },
    layers,
    panels,
    widget_tree: struct { panel: []const u8 },
    config,
    runtime,
    perf,
    perf_reset,
    wait: struct { condition: []const u8, timeout_ms: ?u64 = null, window_id: ?u64 = null, output: ?[]const u8 = null },
    wait_frame: struct { output: ?[]const u8 = null, timeout_ms: ?u64 = null },
    dump_buffer: struct { target: []const u8, window_id: ?u64 = null, output: ?[]const u8 = null },
    sample_pixels: struct { x: i32, y: i32, width: u32 = 1, height: u32 = 1, output: ?[]const u8 = null },
    maximize: struct { id: u64 },
    minimize: struct { id: u64 },
    restore: struct { id: u64 },
    fullscreen: struct { id: u64, output: ?[]const u8 = null },
    set_zoom: struct { id: u64, percent: u8 },
    close_panel: struct { panel: []const u8 },
    reload,
    launch: struct { desktop_id: []const u8 },
    focus_window: struct { id: u64 },
    close_window: struct { id: ?u64 = null },
    move_window_to: struct { id: u64, x: ?i32 = null, y: ?i32 = null, output: ?[]const u8 = null },
    spawn: struct { argv: []const []const u8 },
    move_cursor: struct { x: i32, y: i32, output: ?[]const u8 = null },
    move_cursor_relative: struct { dx: i32, dy: i32 },
    pointer_button: struct { button: u32, pressed: bool },
    click: struct { button: u32 = 0x110 },
    scroll: struct { dx: f64 = 0, dy: f64 = 0 },
    key: struct { keycode: u32, pressed: bool },
    key_press: struct { key: []const u8 },
    type_text: struct { text: []const u8 },
    drag: struct { from_x: i32, from_y: i32, to_x: i32, to_y: i32, button: u32 = 0x110, output: ?[]const u8 = null },
    screenshot: protocol.ScreenshotParams,
    set_master_volume: struct { volume: f32 },
    toggle_mute,
    set_app_volume: struct { index: u32, volume: f32 },
    set_app_mute: struct { index: u32, muted: bool },
    get_audio_state,
    get_panel_stats,
    reset_panel_stats,
    set_anim_time: struct { ms: ?i64 },
    open_start_menu,
    open_control_center,
    open_power_menu,
    notifications,
};

fn parseButtonNameOrInt(arg: []const u8) ?u32 {
    if (std.mem.eql(u8, arg, "left")) return 0x110;
    if (std.mem.eql(u8, arg, "right")) return 0x111;
    if (std.mem.eql(u8, arg, "middle")) return 0x112;
    return std.fmt.parseInt(u32, arg, 10) catch null;
}

fn usageError(comptime message: []const u8) noreturn {
    std.debug.print("error: " ++ message ++ "\n", .{});
    std.process.exit(1);
}

fn parseAnimMs(arg: []const u8) ??i64 {
    if (std.mem.eql(u8, arg, "null")) return @as(?i64, null);
    return std.fmt.parseInt(i64, arg, 10) catch null;
}

/// Parses the trailing `--flag value` options of a subcommand into its
/// `Command` payload, deriving everything else from the payload type.
///
/// Each `spec` entry names an accepted payload field. `.field` derives the flag
/// from the field name (`from_x` → `--from-x`) and parses the value by field
/// type. A struct entry `.{ .field = "window_id", ... }` can add:
///   .names = .{ "--id", "-w" }  flags used instead of the derived one
///   .parse = f                  `fn ([]const u8) ?FieldType` value parser
///   .bare = true                an unflagged argument fills the field if unset
///   .presence = true            takes no value; the flag sets a bool field
///   .cli = true                 the field belongs to `CliOptions` instead
///
/// `preset` holds fields already read from positional arguments. A value that
/// fails to parse restores the field default, `--json` is accepted anywhere
/// and unknown arguments are ignored.
const FlagParser = struct {
    args: []const [*:0]const u8,
    idx: *usize,
    opts: *CliOptions,
    allocator: std.mem.Allocator,

    /// `?T` when some payload field has neither a default nor a preset; null
    /// then means a required flag was missing or unparsable.
    fn Result(comptime T: type, comptime Preset: type) type {
        for (std.meta.fields(T)) |f| {
            if (f.default_value_ptr == null and !@hasField(Preset, f.name)) return ?T;
        }
        return T;
    }

    fn parse(p: FlagParser, comptime T: type, comptime spec: anytype, preset: anytype) Result(T, @TypeOf(preset)) {
        const fields = std.meta.fields(T);
        comptime for (fields) |f| {
            if (f.default_value_ptr == null and !@hasField(@TypeOf(preset), f.name) and !hasEntry(spec, f.name))
                @compileError("required field '" ++ f.name ++ "' of " ++ @typeName(T) ++ " has no flag or preset");
        };

        var out: T = undefined;
        var given = std.StaticBitSet(fields.len).initEmpty();
        inline for (fields, 0..) |f, i| {
            if (@hasField(@TypeOf(preset), f.name)) {
                @field(out, f.name) = @field(preset, f.name);
                given.set(i);
            } else if (f.defaultValue()) |d| @field(out, f.name) = d;
        }

        args: while (p.idx.* < p.args.len) : (p.idx.* += 1) {
            const a = std.mem.span(p.args[p.idx.*]);
            if (std.mem.eql(u8, a, "--json")) {
                p.opts.json = true;
                continue;
            }
            inline for (spec) |entry| {
                const name = comptime entryField(entry);
                if (matchesAny(a, comptime entryNames(entry))) {
                    if (comptime entryFlag(entry, "presence")) {
                        @field(out, name) = true;
                        given.set(comptime fieldIndex(T, name));
                        continue :args;
                    }
                    if (p.idx.* + 1 < p.args.len) {
                        p.idx.* += 1;
                        const text = std.mem.span(p.args[p.idx.*]);
                        if (comptime entryFlag(entry, "cli")) {
                            if (p.value(entry, @FieldType(CliOptions, name), text)) |v| @field(p.opts, name) = v;
                        } else {
                            const i = comptime fieldIndex(T, name);
                            if (p.value(entry, fields[i].type, text)) |v| {
                                @field(out, name) = v;
                                given.set(i);
                            } else {
                                if (fields[i].defaultValue()) |d| @field(out, name) = d;
                                given.unset(i);
                            }
                        }
                        continue :args;
                    }
                }
            }
            inline for (spec) |entry| {
                if (comptime entryFlag(entry, "bare")) {
                    const i = comptime fieldIndex(T, entryField(entry));
                    if (!given.isSet(i)) {
                        if (p.value(entry, fields[i].type, a)) |v| {
                            @field(out, fields[i].name) = v;
                            given.set(i);
                        }
                    }
                }
            }
        }

        if (Result(T, @TypeOf(preset)) != T) {
            inline for (fields, 0..) |f, i| {
                if (f.default_value_ptr == null and !given.isSet(i)) return null;
            }
        }
        return out;
    }

    /// Parses the payload of `tag` and wraps it in its `Command`.
    fn command(p: FlagParser, comptime tag: std.meta.Tag(Command), comptime spec: anytype, preset: anytype) CommandResult(tag, @TypeOf(preset)) {
        const payload = p.parse(@FieldType(Command, @tagName(tag)), spec, preset);
        if (CommandResult(tag, @TypeOf(preset)) == Command) return @unionInit(Command, @tagName(tag), payload);
        return @unionInit(Command, @tagName(tag), payload orelse return null);
    }

    fn CommandResult(comptime tag: std.meta.Tag(Command), comptime Preset: type) type {
        return if (Result(@FieldType(Command, @tagName(tag)), Preset) == @FieldType(Command, @tagName(tag))) Command else ?Command;
    }

    /// Consumes the rest of a subcommand that takes no options.
    fn rest(p: FlagParser) void {
        _ = p.parse(struct {}, .{}, .{});
    }

    fn value(p: FlagParser, comptime entry: anytype, comptime V: type, text: []const u8) ?V {
        if (@typeInfo(@TypeOf(entry)) != .enum_literal and @hasField(@TypeOf(entry), "parse")) return entry.parse(text);
        const Base = switch (@typeInfo(V)) {
            .optional => |o| o.child,
            else => V,
        };
        const v: Base = switch (Base) {
            []const u8 => text,
            bool => std.mem.eql(u8, text, "true") or std.mem.eql(u8, text, "1"),
            []const []const u8 => p.list(text) orelse return null,
            else => switch (@typeInfo(Base)) {
                .int => std.fmt.parseInt(Base, text, 10) catch return null,
                .float => std.fmt.parseFloat(Base, text) catch return null,
                else => @compileError("unsupported flag type " ++ @typeName(Base)),
            },
        };
        return v;
    }

    /// A comma-separated list with blank items dropped.
    fn list(p: FlagParser, text: []const u8) ?[]const []const u8 {
        var items = std.ArrayList([]const u8).empty;
        var it = std.mem.splitScalar(u8, text, ',');
        while (it.next()) |part| {
            const trimmed = std.mem.trim(u8, part, " \t");
            if (trimmed.len > 0) items.append(p.allocator, trimmed) catch return null;
        }
        return items.toOwnedSlice(p.allocator) catch null;
    }

    fn entryField(comptime entry: anytype) []const u8 {
        return if (@typeInfo(@TypeOf(entry)) == .enum_literal) @tagName(entry) else entry.field;
    }

    fn entryFlag(comptime entry: anytype, comptime option: []const u8) bool {
        if (@typeInfo(@TypeOf(entry)) == .enum_literal or !@hasField(@TypeOf(entry), option)) return false;
        return @field(entry, option);
    }

    fn entryNames(comptime entry: anytype) []const []const u8 {
        if (@typeInfo(@TypeOf(entry)) == .enum_literal or !@hasField(@TypeOf(entry), "names")) {
            const field = entryField(entry);
            var name: [field.len + 2]u8 = ("--" ++ field).*;
            std.mem.replaceScalar(u8, name[2..], '_', '-');
            const final = name;
            return &.{&final};
        }
        var names: [entry.names.len][]const u8 = undefined;
        inline for (&names, entry.names) |*n, src| n.* = src;
        const final = names;
        return &final;
    }

    fn hasEntry(comptime spec: anytype, comptime field: []const u8) bool {
        inline for (spec) |entry| {
            if (std.mem.eql(u8, entryField(entry), field)) return true;
        }
        return false;
    }

    fn fieldIndex(comptime T: type, comptime name: []const u8) usize {
        return std.meta.fieldIndex(T, name) orelse @compileError(@typeName(T) ++ " has no field '" ++ name ++ "'");
    }

    fn matchesAny(arg: []const u8, comptime names: []const []const u8) bool {
        inline for (names) |n| {
            if (std.mem.eql(u8, arg, n)) return true;
        }
        return false;
    }
};

fn sendDoctorQuery(sock_fd: std.posix.fd_t, query: []const u8, allocator: std.mem.Allocator) ?std.json.Parsed(std.json.Value) {
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

fn nowUs() i64 {
    var ts: std.posix.timespec = undefined;
    _ = std.posix.system.clock_gettime(std.posix.CLOCK.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1_000_000 + @divTrunc(ts.nsec, 1000);
}

fn runDoctor(socket_path: []const u8, allocator: std.mem.Allocator, is_json: bool) !void {
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

    if (c.connect(sock_fd, @ptrCast(&addr), addr_len) < 0) {
        if (is_json) {
            std.debug.print("{{\"status\":\"error\",\"error\":\"connection refused\",\"socket\":{f}}}\n", .{std.json.fmt(socket_path, .{})});
        } else {
            std.debug.print(
                \\\rediwm doctor
                \\\=============
                \\\[✗] Socket: {s} (connection failed: compositor not running or socket path invalid)
                \\\
            , .{socket_path});
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

fn printUnwrappedJson(ok_val: std.json.Value, key: []const u8) !void {
    if (ok_val == .object) {
        if (ok_val.object.get(key)) |inner| {
            try printJsonValue(inner);
            return;
        }
    }
    try printJsonValue(ok_val);
}

fn runMsg(init: std.process.Init, allocator: std.mem.Allocator) !void {
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
            const tag = lookupTopCommand(arg) orelse {
                std.debug.print("error: unknown command '{s}'\n", .{arg});
                std.process.exit(1);
            };
            switch (tag) {
                .raw => {
                    arg_idx += 1;
                    if (arg_idx < raw_args.len and !std.mem.eql(u8, std.mem.span(raw_args[arg_idx]), "-")) {
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
                },
                .get_state => {
                    opts.command = .state;
                    arg_idx += 1;
                },
                .describe_ipc => {
                    opts.command = .describe;
                    arg_idx += 1;
                },
                .doctor => {
                    opts.command = .doctor;
                    arg_idx += 1;
                },
                .get_window_debug => {
                    arg_idx += 1;
                    if (arg_idx >= raw_args.len) {
                        std.debug.print("error: window-debug requires <window_id>\n", .{});
                        std.process.exit(1);
                    }
                    const wid = std.fmt.parseInt(u64, std.mem.span(raw_args[arg_idx]), 10) catch {
                        std.debug.print("error: invalid window id\n", .{});
                        std.process.exit(1);
                    };
                    arg_idx += 1;
                    opts.command = .{ .window_debug = .{ .id = wid } };
                },
                .get_window_rules => {
                    arg_idx += 1;
                    if (arg_idx >= raw_args.len) {
                        std.debug.print("error: window-rules requires <window_id>\n", .{});
                        std.process.exit(1);
                    }
                    const wid = std.fmt.parseInt(u64, std.mem.span(raw_args[arg_idx]), 10) catch {
                        std.debug.print("error: invalid window id\n", .{});
                        std.process.exit(1);
                    };
                    arg_idx += 1;
                    opts.command = .{ .window_rules = .{ .id = wid } };
                },
                .match_window_rules => {
                    arg_idx += 1;
                    opts.command = cli.command(.match_window_rules, .{
                        .app_id,
                        .title,
                        .{ .field = "x11_class", .names = .{"--class"} },
                        .{ .field = "x11_instance", .names = .{"--instance"} },
                        .backend,
                        .dialog,
                    }, .{});
                },
                .get_night_light => {
                    opts.command = .night_light;
                    arg_idx += 1;
                },
                .get_notifications => {
                    opts.command = .notifications;
                    arg_idx += 1;
                },
                .get_shell_state => {
                    arg_idx += 1;
                    opts.command = cli.command(.shell_state, .{.output}, .{});
                },
                .get_keyboard_layouts => {
                    opts.command = .keyboard_layouts;
                    arg_idx += 1;
                },
                .switch_layout => {
                    arg_idx += 1;
                    if (arg_idx >= raw_args.len) return error.InvalidArguments;
                    const value = std.mem.span(raw_args[arg_idx]);
                    opts.command = .{ .switch_layout = if (std.ascii.eqlIgnoreCase(value, "next")) .next else if (std.ascii.eqlIgnoreCase(value, "prev")) .prev else .{ .index = std.fmt.parseInt(u32, value, 10) catch return error.InvalidArguments } };
                    arg_idx += 1;
                },
                .get_text_input => {
                    opts.command = .text_input;
                    arg_idx += 1;
                },
                .get_input_state => {
                    opts.command = .input_state;
                    arg_idx += 1;
                },
                .hit_test => {
                    arg_idx += 1;
                    if (arg_idx + 1 >= raw_args.len) {
                        std.debug.print("error: hit-test requires <x> <y>\n", .{});
                        std.process.exit(1);
                    }
                    const x = std.fmt.parseInt(i32, std.mem.span(raw_args[arg_idx]), 10) catch {
                        std.debug.print("error: invalid x coordinate\n", .{});
                        std.process.exit(1);
                    };
                    arg_idx += 1;
                    const y = std.fmt.parseInt(i32, std.mem.span(raw_args[arg_idx]), 10) catch {
                        std.debug.print("error: invalid y coordinate\n", .{});
                        std.process.exit(1);
                    };
                    arg_idx += 1;
                    opts.command = cli.command(.hit_test, .{.output}, .{ .x = x, .y = y });
                },
                .get_scene_tree => {
                    arg_idx += 1;
                    opts.command = cli.command(.scene_tree, .{.max_depth}, .{});
                },
                .get_layer_surfaces => {
                    opts.command = .layers;
                    arg_idx += 1;
                },
                .list_panels => {
                    opts.command = .panels;
                    arg_idx += 1;
                },
                .get_widget_tree => {
                    arg_idx += 1;
                    if (arg_idx >= raw_args.len) {
                        std.debug.print("error: widget-tree requires <panel>\n", .{});
                        std.process.exit(1);
                    }
                    const panel = std.mem.span(raw_args[arg_idx]);
                    arg_idx += 1;
                    opts.command = .{ .widget_tree = .{ .panel = panel } };
                },
                .get_config_status => {
                    opts.command = .config;
                    arg_idx += 1;
                },
                .get_runtime_info => {
                    opts.command = .runtime;
                    arg_idx += 1;
                },
                .get_performance_stats => {
                    opts.command = .perf;
                    arg_idx += 1;
                },
                .reset_performance_stats => {
                    opts.command = .perf_reset;
                    arg_idx += 1;
                },
                .wait_for => {
                    arg_idx += 1;
                    if (arg_idx >= raw_args.len) {
                        std.debug.print("error: wait requires <condition>\n", .{});
                        std.process.exit(1);
                    }
                    const cond = std.mem.span(raw_args[arg_idx]);
                    arg_idx += 1;
                    opts.command = cli.command(.wait, .{
                        .{ .field = "timeout_ms", .names = .{"--timeout"} },
                        .{ .field = "window_id", .names = .{"--id"} },
                        .output,
                    }, .{ .condition = cond });
                },
                .wait_for_frame => {
                    arg_idx += 1;
                    opts.command = cli.command(.wait_frame, .{ .output, .{ .field = "timeout_ms", .names = .{"--timeout"} } }, .{});
                },
                .dump_buffer => {
                    arg_idx += 1;
                    if (arg_idx >= raw_args.len) {
                        std.debug.print("error: dump-buffer requires <target>\n", .{});
                        std.process.exit(1);
                    }
                    const tgt = std.mem.span(raw_args[arg_idx]);
                    arg_idx += 1;
                    opts.command = cli.command(.dump_buffer, .{ .{ .field = "window_id", .names = .{"--id"} }, .output }, .{ .target = tgt });
                },
                .sample_pixels => {
                    arg_idx += 1;
                    if (arg_idx + 3 >= raw_args.len) {
                        std.debug.print("error: sample-pixels requires <x> <y> <width> <height>\n", .{});
                        std.process.exit(1);
                    }
                    const x = std.fmt.parseInt(i32, std.mem.span(raw_args[arg_idx]), 10) catch 0;
                    arg_idx += 1;
                    const y = std.fmt.parseInt(i32, std.mem.span(raw_args[arg_idx]), 10) catch 0;
                    arg_idx += 1;
                    const w = std.fmt.parseInt(u32, std.mem.span(raw_args[arg_idx]), 10) catch 1;
                    arg_idx += 1;
                    const h = std.fmt.parseInt(u32, std.mem.span(raw_args[arg_idx]), 10) catch 1;
                    arg_idx += 1;
                    opts.command = cli.command(.sample_pixels, .{.output}, .{ .x = x, .y = y, .width = w, .height = h });
                },
                .set_output_config => {
                    arg_idx += 1;
                    if (arg_idx >= raw_args.len) return error.MissingOutput;
                    var patch = protocol.OutputConfigPatch{ .output = std.mem.span(raw_args[arg_idx]) };
                    arg_idx += 1;
                    while (arg_idx < raw_args.len) : (arg_idx += 1) {
                        const option = std.mem.span(raw_args[arg_idx]);
                        if (std.mem.eql(u8, option, "--json")) {
                            opts.json = true;
                            continue;
                        }
                        if (std.mem.eql(u8, option, "--enabled")) {
                            patch.enabled = true;
                            continue;
                        }
                        if (std.mem.eql(u8, option, "--disabled")) {
                            patch.enabled = false;
                            continue;
                        }
                        if (std.mem.eql(u8, option, "--primary")) {
                            patch.primary = true;
                            continue;
                        }
                        if (std.mem.eql(u8, option, "--no-primary")) {
                            patch.primary = false;
                            continue;
                        }
                        if (arg_idx + 1 >= raw_args.len) return error.MissingOptionValue;
                        arg_idx += 1;
                        const value = std.mem.span(raw_args[arg_idx]);
                        if (std.mem.eql(u8, option, "--scale")) {
                            if (std.mem.eql(u8, value, "auto")) {
                                patch.auto_scale = true;
                            } else {
                                patch.scale = try std.fmt.parseFloat(f32, value);
                            }
                        } else if (std.mem.eql(u8, option, "--position")) {
                            if (!std.mem.eql(u8, value, "auto")) return error.InvalidPosition;
                            patch.auto_position = true;
                        } else if (std.mem.eql(u8, option, "--transform")) {
                            patch.transform = protocol.parseOutputTransform(value) catch return error.InvalidTransform;
                        } else {
                            var matched = false;
                            inline for (.{ "width", "height", "refresh_mhz", "x", "y" }, .{ "--width", "--height", "--refresh-mhz", "--x", "--y" }) |field, flag| {
                                if (std.mem.eql(u8, option, flag)) {
                                    @field(patch, field) = try std.fmt.parseInt(i32, value, 10);
                                    matched = true;
                                }
                            }
                            if (!matched) return error.UnknownOutputOption;
                        }
                    }
                    try patch.validate();
                    opts.command = .{ .output_config = patch };
                },
                .maximize_window => {
                    arg_idx += 1;
                    if (arg_idx >= raw_args.len) {
                        std.debug.print("error: maximize requires <id>\n", .{});
                        std.process.exit(1);
                    }
                    const id = std.fmt.parseInt(u64, std.mem.span(raw_args[arg_idx]), 10) catch 0;
                    arg_idx += 1;
                    opts.command = .{ .maximize = .{ .id = id } };
                },
                .minimize_window => {
                    arg_idx += 1;
                    if (arg_idx >= raw_args.len) {
                        std.debug.print("error: minimize requires <id>\n", .{});
                        std.process.exit(1);
                    }
                    const id = std.fmt.parseInt(u64, std.mem.span(raw_args[arg_idx]), 10) catch 0;
                    arg_idx += 1;
                    opts.command = .{ .minimize = .{ .id = id } };
                },
                .restore_window => {
                    arg_idx += 1;
                    if (arg_idx >= raw_args.len) {
                        std.debug.print("error: restore requires <id>\n", .{});
                        std.process.exit(1);
                    }
                    const id = std.fmt.parseInt(u64, std.mem.span(raw_args[arg_idx]), 10) catch 0;
                    arg_idx += 1;
                    opts.command = .{ .restore = .{ .id = id } };
                },
                .fullscreen_window => {
                    arg_idx += 1;
                    if (arg_idx >= raw_args.len) {
                        std.debug.print("error: fullscreen requires <id>\n", .{});
                        std.process.exit(1);
                    }
                    const id = std.fmt.parseInt(u64, std.mem.span(raw_args[arg_idx]), 10) catch 0;
                    arg_idx += 1;
                    opts.command = .{ .fullscreen = .{ .id = id } };
                },
                .set_window_zoom => {
                    arg_idx += 1;
                    if (arg_idx + 1 >= raw_args.len) {
                        std.debug.print("error: set-zoom requires <id> <percent>\n", .{});
                        std.process.exit(1);
                    }
                    const id = std.fmt.parseInt(u64, std.mem.span(raw_args[arg_idx]), 10) catch 0;
                    arg_idx += 1;
                    const pct = std.fmt.parseInt(u8, std.mem.span(raw_args[arg_idx]), 10) catch 100;
                    arg_idx += 1;
                    opts.command = .{ .set_zoom = .{ .id = id, .percent = pct } };
                },
                .close_panel => {
                    arg_idx += 1;
                    if (arg_idx >= raw_args.len) {
                        std.debug.print("error: close-panel requires <panel>\n", .{});
                        std.process.exit(1);
                    }
                    const panel = std.mem.span(raw_args[arg_idx]);
                    arg_idx += 1;
                    opts.command = .{ .close_panel = .{ .panel = panel } };
                },
                .reload_config => {
                    opts.command = .reload;
                    arg_idx += 1;
                },
                .launch_app => {
                    arg_idx += 1;
                    if (arg_idx >= raw_args.len) {
                        std.debug.print("error: launch requires <desktop_id>\n", .{});
                        std.process.exit(1);
                    }
                    const did = std.mem.span(raw_args[arg_idx]);
                    arg_idx += 1;
                    opts.command = .{ .launch = .{ .desktop_id = did } };
                },
                .version => {
                    opts.command = .version;
                    arg_idx += 1;
                },
                .capabilities => {
                    opts.command = .capabilities;
                    arg_idx += 1;
                },
                .windows => {
                    opts.command = .windows;
                    arg_idx += 1;
                },
                .outputs => {
                    opts.command = .outputs;
                    arg_idx += 1;
                },
                .focused_window => {
                    opts.command = .focused_window;
                    arg_idx += 1;
                },
                .workspaces => {
                    opts.command = .workspaces;
                    arg_idx += 1;
                },
                .event_stream => {
                    arg_idx += 1;
                    opts.command = cli.command(.event_stream, .{ .events, .{ .field = "window_id", .names = .{"--window"} }, .output }, .{});
                },
                .action => {
                    arg_idx += 1;
                    if (arg_idx >= raw_args.len) {
                        std.debug.print("error: action requires a subcommand\n", .{});
                        std.process.exit(1);
                    }
                    const act_cmd = std.mem.span(raw_args[arg_idx]);
                    arg_idx += 1;

                    const action_tag = protocol.commands.lookupCli(true, act_cmd) orelse {
                        std.debug.print("error: unknown action '{s}'\n", .{act_cmd});
                        std.process.exit(1);
                    };
                    switch (action_tag) {
                        .focus_window => {
                            opts.command = cli.command(.focus_window, .{.{ .field = "id", .bare = true }}, .{}) orelse
                                usageError("focus-window requires --id <u64>");
                        },
                        .close_window => {
                            opts.command = cli.command(.close_window, .{.{ .field = "id", .bare = true }}, .{});
                        },
                        .move_window_to => {
                            const cmd = cli.command(.move_window_to, .{ .id, .x, .y, .output }, .{});
                            const move = if (cmd) |c| c.move_window_to else null;
                            if (move == null or ((move.?.x == null or move.?.y == null) and move.?.output == null))
                                usageError("move-window-to requires --id <id> plus --x/--y or --output <output>");
                            opts.command = cmd;
                        },
                        .spawn => {
                            if (arg_idx < raw_args.len and std.mem.eql(u8, std.mem.span(raw_args[arg_idx]), "--")) {
                                arg_idx += 1;
                            }
                            var argv_list = std.ArrayList([]const u8).empty;
                            while (arg_idx < raw_args.len) : (arg_idx += 1) {
                                const a = std.mem.span(raw_args[arg_idx]);
                                if (std.mem.eql(u8, a, "--json") and argv_list.items.len == 0) {
                                    opts.json = true;
                                } else {
                                    try argv_list.append(allocator, a);
                                }
                            }
                            if (argv_list.items.len == 0) {
                                std.debug.print("error: spawn requires a command\n", .{});
                                std.process.exit(1);
                            }
                            opts.command = .{ .spawn = .{ .argv = argv_list.items } };
                        },
                        .move_cursor => {
                            opts.command = cli.command(.move_cursor, .{ .x, .y, .output }, .{}) orelse
                                usageError("move-cursor requires --x <x> --y <y>");
                        },
                        .move_cursor_relative => {
                            opts.command = cli.command(.move_cursor_relative, .{ .dx, .dy }, .{}) orelse
                                usageError("move-cursor-relative requires --dx <dx> --dy <dy>");
                        },
                        .pointer_button => {
                            opts.command = cli.command(.pointer_button, .{ .{ .field = "button", .parse = parseButtonNameOrInt }, .pressed }, .{}) orelse
                                usageError("pointer-button requires --button <button> --pressed <true|false>");
                        },
                        .click => {
                            opts.command = cli.command(.click, .{.{ .field = "button", .parse = parseButtonNameOrInt }}, .{});
                        },
                        .scroll => {
                            opts.command = cli.command(.scroll, .{ .dx, .dy }, .{});
                        },
                        .key => {
                            opts.command = cli.command(.key, .{ .keycode, .pressed }, .{}) orelse
                                usageError("key requires --keycode <keycode> --pressed <true|false>");
                        },
                        .key_press => {
                            opts.command = cli.command(.key_press, .{.{ .field = "key", .bare = true }}, .{}) orelse
                                usageError("key-press requires --key <keyname>");
                        },
                        .type_text => {
                            opts.command = cli.command(.type_text, .{.{ .field = "text", .bare = true }}, .{}) orelse
                                usageError("type-text requires --text <text>");
                        },
                        .drag => {
                            opts.command = cli.command(.drag, .{
                                .from_x,
                                .from_y,
                                .to_x,
                                .to_y,
                                .{ .field = "button", .parse = parseButtonNameOrInt },
                                .output,
                            }, .{}) orelse usageError("drag requires --from-x <x> --from-y <y> --to-x <x> --to-y <y>");
                        },
                        .screenshot => {
                            opts.command = cli.command(.screenshot, .{
                                .{ .field = "output", .names = .{ "--output", "-o" } },
                                .{ .field = "window_id", .names = .{ "--window", "--window-id", "--id", "-w" } },
                                .{ .field = "mode", .names = .{ "--mode", "-m" } },
                                .{ .field = "include_cursor", .presence = true },
                                .path,
                                .{ .field = "save_path", .names = .{"--save"}, .cli = true },
                            }, .{});
                        },
                        .set_master_volume => {
                            opts.command = cli.command(.set_master_volume, .{.volume}, .{}) orelse
                                usageError("set-master-volume requires --volume <0.0-1.0>");
                        },
                        .toggle_mute => {
                            cli.rest();
                            opts.command = .toggle_mute;
                        },
                        .set_app_volume => {
                            opts.command = cli.command(.set_app_volume, .{ .index, .volume }, .{}) orelse
                                usageError("set-app-volume requires --index <N> --volume <0.0-1.0>");
                        },
                        .set_app_mute => {
                            opts.command = cli.command(.set_app_mute, .{ .index, .muted }, .{}) orelse
                                usageError("set-app-mute requires --index <N> --muted <true|false>");
                        },
                        .get_audio_state => {
                            cli.rest();
                            opts.command = .get_audio_state;
                        },
                        .get_panel_stats => {
                            cli.rest();
                            opts.command = .get_panel_stats;
                        },
                        .reset_panel_stats => {
                            opts.command = .reset_panel_stats;
                        },
                        .set_anim_time => {
                            opts.command = cli.command(.set_anim_time, .{.{ .field = "ms", .parse = parseAnimMs }}, .{}) orelse
                                usageError("set-anim-time requires --ms <N|null>");
                        },
                        .open_start_menu => {
                            opts.command = .open_start_menu;
                        },
                        .open_control_center => {
                            opts.command = .open_control_center;
                        },
                        .open_power_menu => {
                            opts.command = .open_power_menu;
                        },
                    }
                },
            }
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

    if (c.connect(sock_fd, @ptrCast(&addr), addr_len) < 0) {
        std.debug.print("error: failed to connect to socket {s}\n", .{socket_path});
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
    var req_buf = std.ArrayList(u8).empty;
    defer req_buf.deinit(allocator);

    switch (command) {
        .doctor => unreachable,
        .version => try req_buf.appendSlice(allocator, "{\"version\":1,\"command\":\"version\"}\n"),
        .capabilities => try req_buf.appendSlice(allocator, "{\"version\":1,\"command\":\"capabilities\"}\n"),
        .windows => try req_buf.appendSlice(allocator, "{\"version\":1,\"command\":\"windows\"}\n"),
        .outputs => try req_buf.appendSlice(allocator, "{\"version\":1,\"command\":\"outputs\"}\n"),
        .focused_window => try req_buf.appendSlice(allocator, "{\"version\":1,\"command\":\"focused_window\"}\n"),
        .workspaces => try req_buf.appendSlice(allocator, "{\"version\":1,\"command\":\"workspaces\"}\n"),
        .event_stream => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            if (p.events != null or p.window_id != null or p.output != null) {
                try bw.writeAll("{\"version\":1,\"command\":\"event_stream\",\"params\":{");
                var comma = false;
                if (p.events) |evs| {
                    try bw.writeAll("\"events\":[");
                    for (evs, 0..) |ev, i| {
                        if (i > 0) try bw.writeByte(',');
                        try bw.print("{f}", .{std.json.fmt(ev, .{})});
                    }
                    try bw.writeByte(']');
                    comma = true;
                }
                if (p.window_id) |wid| {
                    if (comma) try bw.writeByte(',');
                    try bw.print("\"window_id\":{d}", .{wid});
                    comma = true;
                }
                if (p.output) |out| {
                    if (comma) try bw.writeByte(',');
                    try bw.print("\"output\":{f}", .{std.json.fmt(out, .{})});
                    comma = true;
                }
                try bw.writeAll("}}\n");
            } else {
                try bw.writeAll("{\"version\":1,\"command\":\"event_stream\"}\n");
            }
        },
        .focus_window => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            try bw.print("{{\"version\":1,\"command\":\"focus_window\",\"params\":{{\"id\":{d}}}}}\n", .{p.id});
        },
        .close_window => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            if (p.id) |id| {
                try bw.print("{{\"version\":1,\"command\":\"close_window\",\"params\":{{\"id\":{d}}}}}\n", .{id});
            } else {
                try bw.writeAll("{\"version\":1,\"command\":\"close_window\"}\n");
            }
        },
        .move_window_to => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            try bw.print("{{\"version\":1,\"command\":\"move_window_to\",\"params\":{{\"id\":{d}", .{p.id});
            if (p.x) |x| if (p.y) |y| try bw.print(",\"x\":{d},\"y\":{d}", .{ x, y });
            if (p.output) |output| try bw.print(",\"output\":{f}", .{std.json.fmt(output, .{})});
            try bw.writeAll("}}\n");
        },
        .spawn => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            try bw.writeAll("{\"version\":1,\"command\":\"spawn\",\"params\":{\"argv\":[");
            for (p.argv, 0..) |arg, i| {
                if (i > 0) try bw.writeByte(',');
                try bw.print("{f}", .{std.json.fmt(arg, .{})});
            }
            try bw.writeAll("]}}\n");
        },
        .move_cursor => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            if (p.output) |out| {
                try bw.print("{{\"version\":1,\"command\":\"move_cursor\",\"params\":{{\"x\":{d},\"y\":{d},\"output\":{f}}}}}\n", .{ p.x, p.y, std.json.fmt(out, .{}) });
            } else {
                try bw.print("{{\"version\":1,\"command\":\"move_cursor\",\"params\":{{\"x\":{d},\"y\":{d}}}}}\n", .{ p.x, p.y });
            }
        },
        .move_cursor_relative => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            try bw.print("{{\"version\":1,\"command\":\"move_cursor_relative\",\"params\":{{\"dx\":{d},\"dy\":{d}}}}}\n", .{ p.dx, p.dy });
        },
        .pointer_button => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            try bw.print("{{\"version\":1,\"command\":\"pointer_button\",\"params\":{{\"button\":{d},\"pressed\":{s}}}}}\n", .{ p.button, if (p.pressed) "true" else "false" });
        },
        .click => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            try bw.print("{{\"version\":1,\"command\":\"click\",\"params\":{{\"button\":{d}}}}}\n", .{p.button});
        },
        .scroll => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            try bw.print("{{\"version\":1,\"command\":\"scroll\",\"params\":{{\"dx\":{d},\"dy\":{d}}}}}\n", .{ p.dx, p.dy });
        },
        .key => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            try bw.print("{{\"version\":1,\"command\":\"key\",\"params\":{{\"keycode\":{d},\"pressed\":{s}}}}}\n", .{ p.keycode, if (p.pressed) "true" else "false" });
        },
        .key_press => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            try bw.print("{{\"version\":1,\"command\":\"key_press\",\"params\":{{\"key\":{f}}}}}\n", .{std.json.fmt(p.key, .{})});
        },
        .type_text => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            try bw.print("{{\"version\":1,\"command\":\"type_text\",\"params\":{{\"text\":{f}}}}}\n", .{std.json.fmt(p.text, .{})});
        },
        .drag => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            if (p.output) |out| {
                try bw.print("{{\"version\":1,\"command\":\"drag\",\"params\":{{\"from_x\":{d},\"from_y\":{d},\"to_x\":{d},\"to_y\":{d},\"button\":{d},\"output\":{f}}}}}\n", .{ p.from_x, p.from_y, p.to_x, p.to_y, p.button, std.json.fmt(out, .{}) });
            } else {
                try bw.print("{{\"version\":1,\"command\":\"drag\",\"params\":{{\"from_x\":{d},\"from_y\":{d},\"to_x\":{d},\"to_y\":{d},\"button\":{d}}}}}\n", .{ p.from_x, p.from_y, p.to_x, p.to_y, p.button });
            }
        },
        .screenshot => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            try bw.writeAll("{\"version\":1,\"command\":\"screenshot\",\"params\":{");
            var comma = false;
            if (p.output) |out| {
                try bw.print("\"output\":{f}", .{std.json.fmt(out, .{})});
                comma = true;
            }
            if (p.window_id) |wid| {
                if (comma) try bw.writeByte(',');
                try bw.print("\"window_id\":{d}", .{wid});
                comma = true;
            }
            if (p.mode) |m| {
                if (comma) try bw.writeByte(',');
                try bw.print("\"mode\":{f}", .{std.json.fmt(m, .{})});
                comma = true;
            }
            if (p.include_cursor) {
                if (comma) try bw.writeByte(',');
                try bw.writeAll("\"include_cursor\":true");
                comma = true;
            }
            if (p.path) |path| {
                if (comma) try bw.writeByte(',');
                try bw.print("\"path\":{f}", .{std.json.fmt(path, .{})});
                comma = true;
            }
            try bw.writeAll("}}\n");
        },
        .set_master_volume => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            try bw.print("{{\"version\":1,\"command\":\"set_master_volume\",\"params\":{{\"volume\":{d}}}}}\n", .{p.volume});
        },
        .toggle_mute => try req_buf.appendSlice(allocator, "{\"version\":1,\"command\":\"toggle_mute\"}\n"),
        .set_app_volume => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            try bw.print("{{\"version\":1,\"command\":\"set_app_volume\",\"params\":{{\"index\":{d},\"volume\":{d}}}}}\n", .{ p.index, p.volume });
        },
        .set_app_mute => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            try bw.print("{{\"version\":1,\"command\":\"set_app_mute\",\"params\":{{\"index\":{d},\"muted\":{s}}}}}\n", .{ p.index, if (p.muted) "true" else "false" });
        },
        .get_audio_state => try req_buf.appendSlice(allocator, "{\"version\":1,\"command\":\"get_audio_state\"}\n"),
        .get_panel_stats => try req_buf.appendSlice(allocator, "{\"version\":1,\"command\":\"get_panel_stats\"}\n"),
        .reset_panel_stats => try req_buf.appendSlice(allocator, "{\"version\":1,\"command\":\"reset_panel_stats\"}\n"),
        .set_anim_time => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            if (p.ms) |ms| {
                try bw.print("{{\"version\":1,\"command\":\"set_anim_time\",\"params\":{{\"ms\":{d}}}}}\n", .{ms});
            } else {
                try bw.writeAll("{\"version\":1,\"command\":\"set_anim_time\",\"params\":{\"ms\":null}}\n");
            }
        },
        .open_start_menu => try req_buf.appendSlice(allocator, "{\"version\":1,\"command\":\"open_start_menu\"}\n"),
        .open_control_center => try req_buf.appendSlice(allocator, "{\"version\":1,\"command\":\"open_control_center\"}\n"),
        .open_power_menu => try req_buf.appendSlice(allocator, "{\"version\":1,\"command\":\"open_power_menu\"}\n"),
        .raw => |r| {
            try req_buf.appendSlice(allocator, r);
            if (!std.mem.endsWith(u8, r, "\n")) {
                try req_buf.append(allocator, '\n');
            }
        },
        .state => try req_buf.appendSlice(allocator, "{\"version\":1,\"command\":\"get_state\"}\n"),
        .describe => try req_buf.appendSlice(allocator, "{\"version\":1,\"command\":\"describe_ipc\"}\n"),
        .window_debug => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            try bw.print("{{\"version\":1,\"command\":\"get_window_debug\",\"params\":{{\"id\":{d}}}}}\n", .{p.id});
        },
        .window_rules => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            try bw.print("{{\"version\":1,\"command\":\"get_window_rules\",\"params\":{{\"id\":{d}}}}}\n", .{p.id});
        },
        .match_window_rules => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            try bw.writeAll("{\"version\":1,\"command\":\"match_window_rules\",\"params\":{");
            var comma = false;
            if (p.app_id) |app| {
                try bw.print("\"app_id\":{f}", .{std.json.fmt(app, .{})});
                comma = true;
            }
            if (p.title) |t| {
                if (comma) try bw.writeByte(',');
                try bw.print("\"title\":{f}", .{std.json.fmt(t, .{})});
                comma = true;
            }
            if (p.x11_class) |cls| {
                if (comma) try bw.writeByte(',');
                try bw.print("\"x11_class\":{f}", .{std.json.fmt(cls, .{})});
                comma = true;
            }
            if (p.x11_instance) |inst| {
                if (comma) try bw.writeByte(',');
                try bw.print("\"x11_instance\":{f}", .{std.json.fmt(inst, .{})});
                comma = true;
            }
            if (p.backend) |b| {
                if (comma) try bw.writeByte(',');
                try bw.print("\"backend\":{f}", .{std.json.fmt(b, .{})});
                comma = true;
            }
            if (p.dialog) |d| {
                if (comma) try bw.writeByte(',');
                try bw.print("\"dialog\":{}", .{d});
            }
            try bw.writeAll("}}\n");
        },
        .night_light => try req_buf.appendSlice(allocator, "{\"version\":1,\"command\":\"get_night_light\"}\n"),
        .notifications => try req_buf.appendSlice(allocator, "{\"version\":1,\"command\":\"get_notifications\"}\n"),
        .shell_state => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            if (p.output) |out| {
                try bw.print("{{\"version\":1,\"command\":\"get_shell_state\",\"params\":{{\"output\":{f}}}}}\n", .{std.json.fmt(out, .{})});
            } else {
                try bw.writeAll("{\"version\":1,\"command\":\"get_shell_state\"}\n");
            }
        },
        .keyboard_layouts => try req_buf.appendSlice(allocator, "{\"version\":1,\"command\":\"get_keyboard_layouts\"}\n"),
        .switch_layout => |target| {
            const bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            try bw.writeAll("{\"version\":1,\"command\":\"switch_layout\",\"params\":{\"layout\":");
            switch (target) {
                .next => try bw.writeAll("\"next\""),
                .prev => try bw.writeAll("\"prev\""),
                .index => |idx| try bw.print("{d}", .{idx}),
            }
            try bw.writeAll("}}\n");
        },
        .text_input => try req_buf.appendSlice(allocator, "{\"version\":1,\"command\":\"get_text_input\"}\n"),
        .input_state => try req_buf.appendSlice(allocator, "{\"version\":1,\"command\":\"get_input_state\"}\n"),
        .hit_test => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            if (p.output) |out| {
                try bw.print("{{\"version\":1,\"command\":\"hit_test\",\"params\":{{\"x\":{d},\"y\":{d},\"output\":{f}}}}}\n", .{ p.x, p.y, std.json.fmt(out, .{}) });
            } else {
                try bw.print("{{\"version\":1,\"command\":\"hit_test\",\"params\":{{\"x\":{d},\"y\":{d}}}}}\n", .{ p.x, p.y });
            }
        },
        .scene_tree => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            if (p.max_depth) |md| {
                try bw.print("{{\"version\":1,\"command\":\"get_scene_tree\",\"params\":{{\"max_depth\":{d}}}}}\n", .{md});
            } else {
                try bw.writeAll("{\"version\":1,\"command\":\"get_scene_tree\"}\n");
            }
        },
        .layers => try req_buf.appendSlice(allocator, "{\"version\":1,\"command\":\"get_layer_surfaces\"}\n"),
        .panels => try req_buf.appendSlice(allocator, "{\"version\":1,\"command\":\"list_panels\"}\n"),
        .widget_tree => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            try bw.print("{{\"version\":1,\"command\":\"get_widget_tree\",\"params\":{{\"panel\":{f}}}}}\n", .{std.json.fmt(p.panel, .{})});
        },
        .config => try req_buf.appendSlice(allocator, "{\"version\":1,\"command\":\"get_config_status\"}\n"),
        .runtime => try req_buf.appendSlice(allocator, "{\"version\":1,\"command\":\"get_runtime_info\"}\n"),
        .perf => try req_buf.appendSlice(allocator, "{\"version\":1,\"command\":\"get_performance_stats\"}\n"),
        .perf_reset => try req_buf.appendSlice(allocator, "{\"version\":1,\"command\":\"reset_performance_stats\"}\n"),
        .wait => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            try bw.print("{{\"version\":1,\"command\":\"wait_for\",\"params\":{{\"condition\":{f}", .{std.json.fmt(p.condition, .{})});
            if (p.timeout_ms) |t| try bw.print(",\"timeout_ms\":{d}", .{t});
            if (p.window_id) |wid| try bw.print(",\"window_id\":{d}", .{wid});
            if (p.output) |out| try bw.print(",\"output\":{f}", .{std.json.fmt(out, .{})});
            try bw.writeAll("}}\n");
        },
        .wait_frame => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            try bw.writeAll("{\"version\":1,\"command\":\"wait_for_frame\",\"params\":{");
            var comma = false;
            if (p.output) |out| {
                try bw.print("\"output\":{f}", .{std.json.fmt(out, .{})});
                comma = true;
            }
            if (p.timeout_ms) |t| {
                if (comma) try bw.writeByte(',');
                try bw.print("\"timeout_ms\":{d}", .{t});
            }
            try bw.writeAll("}}\n");
        },
        .dump_buffer => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            try bw.print("{{\"version\":1,\"command\":\"dump_buffer\",\"params\":{{\"target\":{f}", .{std.json.fmt(p.target, .{})});
            if (p.window_id) |wid| try bw.print(",\"window_id\":{d}", .{wid});
            if (p.output) |out| try bw.print(",\"output\":{f}", .{std.json.fmt(out, .{})});
            try bw.writeAll("}}\n");
        },
        .sample_pixels => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            try bw.print("{{\"version\":1,\"command\":\"sample_pixels\",\"params\":{{\"x\":{d},\"y\":{d},\"width\":{d},\"height\":{d}", .{ p.x, p.y, p.width, p.height });
            if (p.output) |out| try bw.print(",\"output\":{f}", .{std.json.fmt(out, .{})});
            try bw.writeAll("}}\n");
        },
        .output_config => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            try bw.print("{{\"version\":1,\"command\":\"set_output_config\",\"params\":{{\"output\":{f}", .{std.json.fmt(p.output, .{})});
            inline for (.{ "width", "height", "refresh_mhz", "x", "y", "scale" }) |field| {
                if (@field(p, field)) |value| try bw.print(",\"{s}\":{d}", .{ field, value });
            }
            if (p.auto_scale) try bw.writeAll(",\"scale\":\"auto\"");
            if (p.auto_position) try bw.writeAll(",\"position\":\"auto\"");
            if (p.enabled) |value| try bw.print(",\"enabled\":{s}", .{if (value) "true" else "false"});
            if (p.primary) |value| try bw.print(",\"primary\":{s}", .{if (value) "true" else "false"});
            if (p.transform) |value| try bw.print(",\"transform\":\"{s}\"", .{protocol.outputTransformName(value)});
            try bw.writeAll("}}\n");
        },
        .maximize => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            try bw.print("{{\"version\":1,\"command\":\"maximize_window\",\"params\":{{\"id\":{d}}}}}\n", .{p.id});
        },
        .minimize => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            try bw.print("{{\"version\":1,\"command\":\"minimize_window\",\"params\":{{\"id\":{d}}}}}\n", .{p.id});
        },
        .restore => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            try bw.print("{{\"version\":1,\"command\":\"restore_window\",\"params\":{{\"id\":{d}}}}}\n", .{p.id});
        },
        .fullscreen => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            if (p.output) |out| {
                try bw.print("{{\"version\":1,\"command\":\"fullscreen_window\",\"params\":{{\"id\":{d},\"output\":{f}}}}}\n", .{ p.id, std.json.fmt(out, .{}) });
            } else {
                try bw.print("{{\"version\":1,\"command\":\"fullscreen_window\",\"params\":{{\"id\":{d}}}}}\n", .{p.id});
            }
        },
        .set_zoom => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            try bw.print("{{\"version\":1,\"command\":\"set_window_zoom\",\"params\":{{\"id\":{d},\"percent\":{d}}}}}\n", .{ p.id, p.percent });
        },
        .close_panel => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            try bw.print("{{\"version\":1,\"command\":\"close_panel\",\"params\":{{\"panel\":{f}}}}}\n", .{std.json.fmt(p.panel, .{})});
        },
        .reload => try req_buf.appendSlice(allocator, "{\"version\":1,\"command\":\"reload_config\"}\n"),
        .launch => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            try bw.print("{{\"version\":1,\"command\":\"launch_app\",\"params\":{{\"desktop_id\":{f}}}}}\n", .{std.json.fmt(p.desktop_id, .{})});
        },
    }

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

fn printJsonValue(val: std.json.Value) !void {
    const c = std.posix.system;
    var list = std.ArrayList(u8).empty;
    defer list.deinit(std.heap.c_allocator);
    var bw = protocol.BufferWriter{ .list = &list, .allocator = std.heap.c_allocator };
    try bw.print("{f}\n", .{std.json.fmt(val, .{})});
    _ = c.write(std.posix.STDOUT_FILENO, list.items.ptr, list.items.len);
}

fn printOut(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    if (std.fmt.bufPrint(&buf, fmt, args)) |s| {
        _ = std.posix.system.write(std.posix.STDOUT_FILENO, s.ptr, s.len);
    } else |_| {
        if (std.fmt.allocPrint(std.heap.c_allocator, fmt, args)) |s| {
            defer std.heap.c_allocator.free(s);
            _ = std.posix.system.write(std.posix.STDOUT_FILENO, s.ptr, s.len);
        } else |_| {}
    }
}

fn printTextReply(val: std.json.Value) void {
    switch (val) {
        .string => |s| printOut("{s}\n", .{s}),
        .object => |obj| {
            if (obj.get("Version")) |v| {
                if (v == .string) printOut("rediwm {s}\n", .{v.string});
            } else if (obj.get("Capabilities")) |caps| {
                printOut("Capabilities:\n", .{});
                if (caps == .array) {
                    for (caps.array.items) |c_val| {
                        if (c_val == .string) printOut("  - {s}\n", .{c_val.string});
                    }
                }
            } else if (obj.get("Windows")) |wins| {
                if (wins == .array) {
                    printOut("Windows ({d}):\n", .{wins.array.items.len});
                    for (wins.array.items) |w| {
                        if (w == .object) {
                            const id = if (w.object.get("id")) |i| if (i == .integer) i.integer else 0 else 0;
                            const title = if (w.object.get("title")) |t| if (t == .string) t.string else "<no title>" else "<no title>";
                            const app = if (w.object.get("app_id")) |a| if (a == .string) a.string else "<no app_id>" else "<no app_id>";
                            const focused = if (w.object.get("is_focused")) |f| if (f == .bool) f.bool else false else false;
                            const urgent = if (w.object.get("is_urgent")) |u| if (u == .bool) u.bool else false else false;
                            const min = if (w.object.get("is_minimized")) |m| if (m == .bool) m.bool else false else false;
                            const x = if (w.object.get("x")) |i| if (i == .integer) i.integer else 0 else 0;
                            const y = if (w.object.get("y")) |i| if (i == .integer) i.integer else 0 else 0;
                            const w_px = if (w.object.get("width")) |i| if (i == .integer) i.integer else 0 else 0;
                            const h_px = if (w.object.get("height")) |i| if (i == .integer) i.integer else 0 else 0;

                            printOut("  [{d}] {s} ({s}) at ({d},{d}) size {d}x{d}{s}{s}{s}\n", .{
                                id,
                                title,
                                app,
                                x,
                                y,
                                w_px,
                                h_px,
                                if (focused) " [focused]" else "",
                                if (min) " [minimized]" else "",
                                if (urgent) " [urgent]" else "",
                            });
                        }
                    }
                }
            } else if (obj.get("Outputs")) |outs| {
                if (outs == .array) {
                    printOut("Outputs ({d}):\n", .{outs.array.items.len});
                    for (outs.array.items) |o| {
                        if (o == .object) {
                            const name = if (o.object.get("name")) |n| if (n == .string) n.string else "?" else "?";
                            const lw = if (o.object.get("logical_width")) |i| if (i == .integer) i.integer else 0 else 0;
                            const lh = if (o.object.get("logical_height")) |i| if (i == .integer) i.integer else 0 else 0;
                            const scale = if (o.object.get("scale")) |s| if (s == .float) s.float else 1.0 else 1.0;
                            const focused = if (o.object.get("is_focused")) |f| if (f == .bool) f.bool else false else false;
                            printOut("  {s}: {d}x{d} @ scale {d:.1}{s}\n", .{ name, lw, lh, scale, if (focused) " [focused]" else "" });
                        }
                    }
                }
            } else if (obj.get("FocusedWindow")) |fw| {
                if (fw == .null) {
                    printOut("No window focused\n", .{});
                } else if (fw == .object) {
                    const id = if (fw.object.get("id")) |i| if (i == .integer) i.integer else 0 else 0;
                    const title = if (fw.object.get("title")) |t| if (t == .string) t.string else "<no title>" else "<no title>";
                    printOut("Focused window [{d}]: {s}\n", .{ id, title });
                }
            } else if (obj.get("Workspaces")) |workspaces| {
                if (workspaces == .array) for (workspaces.array.items) |workspace| {
                    if (workspace != .object) continue;
                    const id = workspace.object.get("id") orelse continue;
                    const name = workspace.object.get("name") orelse continue;
                    if (id == .integer and name == .string) printOut("Workspace [{d}]: {s}\n", .{ id.integer, name.string });
                };
            } else if (obj.get("PanelStats")) |ps| {
                if (ps == .object) {
                    const paints = if (ps.object.get("paints")) |v| if (v == .integer) v.integer else 0 else 0;
                    const allocated = if (ps.object.get("allocated_bytes")) |v| if (v == .integer) v.integer else 0 else 0;
                    const reused = if (ps.object.get("reused_bytes")) |v| if (v == .integer) v.integer else 0 else 0;
                    const paint_ns = if (ps.object.get("paint_ns")) |v| if (v == .integer) v.integer else 0 else 0;
                    printOut("Panel paints: {d}\nAllocated bytes: {d}\nReused bytes: {d}\nPaint ns: {d}\n", .{ paints, allocated, reused, paint_ns });
                }
            } else if (obj.get("AudioState")) |as| {
                if (as == .object) {
                    const vol = if (as.object.get("master_volume")) |v| if (v == .float) v.float else 0 else 0;
                    const muted = if (as.object.get("master_muted")) |m| if (m == .bool) m.bool else false else false;
                    const sink = if (as.object.get("default_sink")) |s| if (s == .string) s.string else "?" else "?";
                    printOut("Output: {s}\nMaster volume: {d:.0}%{s}\n", .{ sink, vol * 100, if (muted) " (muted)" else "" });
                    if (as.object.get("streams")) |streams| {
                        if (streams == .array) {
                            for (streams.array.items) |st| {
                                if (st != .object) continue;
                                const name = if (st.object.get("name")) |n| if (n == .string) n.string else "?" else "?";
                                const svol = if (st.object.get("volume")) |v| if (v == .float) v.float else 0 else 0;
                                const smuted = if (st.object.get("muted")) |m| if (m == .bool) m.bool else false else false;
                                printOut("  {s}: {d:.0}%{s}\n", .{ name, svol * 100, if (smuted) " (muted)" else "" });
                            }
                        }
                    }
                }
            } else if (obj.get("Screenshot")) |sc| {
                if (sc == .object) {
                    const w = if (sc.object.get("width")) |i| if (i == .integer) i.integer else 0 else 0;
                    const h = if (sc.object.get("height")) |i| if (i == .integer) i.integer else 0 else 0;
                    const out_n = if (sc.object.get("output_name")) |n| if (n == .string) n.string else "?" else "?";
                    const mode_s = if (sc.object.get("capture_mode")) |m| if (m == .string) m.string else "?" else "?";
                    const seq = if (sc.object.get("frame_seq")) |s| if (s == .integer) s.integer else 0 else 0;

                    if (sc.object.get("path")) |p| {
                        if (p == .string) {
                            printOut("Screenshot saved: {s} ({d}x{d}, output {s}, mode {s}, frame {d})\n", .{ p.string, w, h, out_n, mode_s, seq });
                            return;
                        }
                    }
                    printOut("Screenshot {d}x{d} (output {s}, mode {s}, frame {d})\n", .{ w, h, out_n, mode_s, seq });
                }
            } else if (obj.get("DescribeIPC")) |d| {
                if (d == .object) {
                    const backend = if (d.object.get("backend")) |b| if (b == .string) b.string else "?" else "?";
                    const renderer = if (d.object.get("renderer")) |r| if (r == .string) r.string else "?" else "?";
                    printOut("Compositor backend: {s}, renderer: {s}\n", .{ backend, renderer });
                    if (d.object.get("commands")) |cmds| {
                        if (cmds == .array) {
                            printOut("Available commands ({d}):\n", .{cmds.array.items.len});
                            for (cmds.array.items) |cmd| {
                                if (cmd == .object) {
                                    const name = if (cmd.object.get("name")) |n| if (n == .string) n.string else "?" else "?";
                                    const kind = if (cmd.object.get("kind")) |k| if (k == .string) k.string else "?" else "?";
                                    const desc = if (cmd.object.get("description")) |ds| if (ds == .string) ds.string else "" else "";
                                    printOut("  [{s}] {s} - {s}\n", .{ kind, name, desc });
                                }
                            }
                        }
                    }
                }
            } else if (obj.get("State")) |st| {
                if (st == .object) {
                    const seq = if (st.object.get("seq")) |s| if (s == .integer) s.integer else 0 else 0;
                    const session = if (st.object.get("session_id")) |s| if (s == .string) s.string else "" else "";
                    printOut("State (seq {d}, session {s}):\n", .{ seq, session });
                    if (st.object.get("windows")) |w| {
                        if (w == .array) printOut("  Windows: {d} mapped\n", .{w.array.items.len});
                    }
                    if (st.object.get("outputs")) |o| {
                        if (o == .array) printOut("  Outputs: {d} active\n", .{o.array.items.len});
                    }
                    if (st.object.get("focused_window_id")) |f| {
                        if (f == .integer) {
                            printOut("  Focused window: [{d}]\n", .{f.integer});
                        } else {
                            printOut("  Focused window: none\n", .{});
                        }
                    }
                }
            } else if (obj.get("WindowDebug")) |wd| {
                if (wd == .object) {
                    const id = if (wd.object.get("id")) |i| if (i == .integer) i.integer else 0 else 0;
                    const title = if (wd.object.get("title")) |t| if (t == .string) t.string else "<none>" else "<none>";
                    const app = if (wd.object.get("app_id")) |a| if (a == .string) a.string else "<none>" else "<none>";
                    const min = if (wd.object.get("minimized")) |m| if (m == .bool) m.bool else false else false;
                    const max = if (wd.object.get("maximized")) |m| if (m == .bool) m.bool else false else false;
                    const fs = if (wd.object.get("fullscreen")) |f| if (f == .bool) f.bool else false else false;
                    const zoom = if (wd.object.get("zoom_percent")) |z| if (z == .integer) z.integer else 100 else 100;
                    const bw = if (wd.object.get("buffer_width")) |w| if (w == .integer) w.integer else 0 else 0;
                    const bh = if (wd.object.get("buffer_height")) |h| if (h == .integer) h.integer else 0 else 0;
                    const bscale = if (wd.object.get("buffer_scale")) |s| if (s == .float) s.float else 1.0 else 1.0;
                    printOut("Window [{d}] \"{s}\" (app: {s}):\n", .{ id, title, app });
                    printOut("  State: minimized={}, maximized={}, fullscreen={}, zoom={d}%\n", .{ min, max, fs, zoom });
                    printOut("  Buffer: {d}x{d} @ scale {d:.1}\n", .{ bw, bh, bscale });
                    if (wd.object.get("client_box")) |cb| {
                        if (cb == .object) {
                            const cx = if (cb.object.get("x")) |v| if (v == .integer) v.integer else 0 else 0;
                            const cy = if (cb.object.get("y")) |v| if (v == .integer) v.integer else 0 else 0;
                            const cw = if (cb.object.get("width")) |v| if (v == .integer) v.integer else 0 else 0;
                            const ch = if (cb.object.get("height")) |v| if (v == .integer) v.integer else 0 else 0;
                            printOut("  Client box: ({d},{d}) {d}x{d}\n", .{ cx, cy, cw, ch });
                        }
                    }
                }
            } else if (obj.get("ShellState")) |ss| {
                if (ss == .object) {
                    printOut("Shell State:\n", .{});
                    const sm = ss.object.get("start_menu");
                    printOut("  Start menu: {s}\n", .{if (sm != null and sm.? != .null) "open" else "closed"});
                    const cc = ss.object.get("control_center");
                    printOut("  Control center: {s}\n", .{if (cc != null and cc.? != .null) "open" else "closed"});
                    const pm = ss.object.get("power_menu");
                    printOut("  Power menu: {s}\n", .{if (pm != null and pm.? != .null) "open" else "closed"});
                    if (ss.object.get("taskbars")) |tb| {
                        if (tb == .array) printOut("  Taskbars: {d} active\n", .{tb.array.items.len});
                    }
                }
            } else if (obj.get("InputState")) |is| {
                if (is == .object) {
                    const px = if (is.object.get("pointer_x")) |x| if (x == .float) x.float else 0 else 0;
                    const py = if (is.object.get("pointer_y")) |y| if (y == .float) y.float else 0 else 0;
                    const cm = if (is.object.get("cursor_mode")) |m| if (m == .string) m.string else "passthrough" else "passthrough";
                    printOut("Input State:\n", .{});
                    printOut("  Pointer: ({d:.1}, {d:.1}) mode: {s}\n", .{ px, py, cm });
                    if (is.object.get("pointer_focused_window_id")) |p_id| {
                        if (p_id == .integer) printOut("  Pointer focus: [{d}]\n", .{p_id.integer});
                    }
                    if (is.object.get("keyboard_focused_window_id")) |k_id| {
                        if (k_id == .integer) printOut("  Keyboard focus: [{d}]\n", .{k_id.integer});
                    }
                }
            } else if (obj.get("HitTest")) |ht| {
                if (ht == .object) {
                    const tt = if (ht.object.get("target_type")) |t| if (t == .string) t.string else "?" else "?";
                    const lx = if (ht.object.get("local_x")) |x| if (x == .float) x.float else 0 else 0;
                    const ly = if (ht.object.get("local_y")) |y| if (y == .float) y.float else 0 else 0;
                    printOut("Hit Test: target={s} local=({d:.1},{d:.1})", .{ tt, lx, ly });
                    if (ht.object.get("window_id")) |w| {
                        if (w == .integer) printOut(" window_id={d}", .{w.integer});
                    }
                    if (ht.object.get("widget")) |wg| {
                        if (wg == .string) printOut(" widget={s}", .{wg.string});
                    }
                    if (ht.object.get("output")) |out| {
                        if (out == .string) printOut(" output={s}", .{out.string});
                    }
                    printOut("\n", .{});
                }
            } else if (obj.get("SceneTree")) |st| {
                if (st == .object) {
                    const total = if (st.object.get("total_nodes")) |t| if (t == .integer) t.integer else 0 else 0;
                    printOut("Scene Tree ({d} nodes):\n", .{total});
                    if (st.object.get("nodes")) |nodes| {
                        if (nodes == .array) {
                            for (nodes.array.items) |node| {
                                if (node == .object) {
                                    const id = if (node.object.get("id")) |i| if (i == .integer) i.integer else 0 else 0;
                                    const role = if (node.object.get("role")) |r| if (r == .string) r.string else "?" else "?";
                                    const ntype = if (node.object.get("node_type")) |t| if (t == .string) t.string else "?" else "?";
                                    const en = if (node.object.get("enabled")) |e| if (e == .bool) e.bool else false else false;
                                    const nx = if (node.object.get("x")) |x| if (x == .integer) x.integer else 0 else 0;
                                    const ny = if (node.object.get("y")) |y| if (y == .integer) y.integer else 0 else 0;
                                    printOut("  [{d}] {s} ({s}) at ({d},{d}) enabled={}\n", .{ id, role, ntype, nx, ny, en });
                                }
                            }
                        }
                    }
                }
            } else if (obj.get("LayerSurfaces")) |ls| {
                if (ls == .object) {
                    if (ls.object.get("surfaces")) |surfs| {
                        if (surfs == .array) {
                            printOut("Layer Surfaces ({d}):\n", .{surfs.array.items.len});
                            for (surfs.array.items) |s| {
                                if (s == .object) {
                                    const ns = if (s.object.get("namespace")) |n| if (n == .string) n.string else "?" else "?";
                                    const layer = if (s.object.get("layer")) |l| if (l == .string) l.string else "?" else "?";
                                    const out = if (s.object.get("output")) |o| if (o == .string) o.string else "?" else "?";
                                    printOut("  [{s}] {s} on {s}\n", .{ layer, ns, out });
                                }
                            }
                        }
                    }
                }
            } else if (obj.get("WidgetTree")) |wt| {
                if (wt == .object) {
                    const pnl = if (wt.object.get("panel")) |p| if (p == .string) p.string else "?" else "?";
                    printOut("Widget Tree ({s}):\n", .{pnl});
                    if (wt.object.get("widgets")) |w_arr| {
                        if (w_arr == .array) {
                            for (w_arr.array.items) |w| {
                                if (w == .object) {
                                    const id = if (w.object.get("id")) |i| if (i == .integer) i.integer else 0 else 0;
                                    const role = if (w.object.get("role")) |r| if (r == .string) r.string else "?" else "?";
                                    const label = if (w.object.get("label")) |l| if (l == .string) l.string else "" else "";
                                    const path = if (w.object.get("path")) |p| if (p == .string) p.string else null else null;
                                    if (path) |p| {
                                        printOut("  [{d}] {s} path={s} \"{s}\"\n", .{ id, role, p, label });
                                    } else {
                                        printOut("  [{d}] {s} \"{s}\"\n", .{ id, role, label });
                                    }
                                }
                            }
                        }
                    }
                }
            } else if (obj.get("ListPanels")) |lp| {
                if (lp == .object) {
                    if (lp.object.get("panels")) |p_arr| {
                        if (p_arr == .array) {
                            printOut("Panels:\n", .{});
                            for (p_arr.array.items) |p| {
                                if (p == .object) {
                                    const name = if (p.object.get("name")) |n| if (n == .string) n.string else "?" else "?";
                                    const is_open = if (p.object.get("open")) |o| if (o == .bool) o.bool else false else false;
                                    printOut("  {s}: {s}\n", .{ name, if (is_open) "open" else "closed" });
                                }
                            }
                        }
                    }
                }
            } else if (obj.get("ConfigStatus")) |cs| {
                if (cs == .object) {
                    const path = if (cs.object.get("config_path")) |p| if (p == .string) p.string else "<default>" else "<default>";
                    const gen = if (cs.object.get("generation")) |g| if (g == .integer) g.integer else 0 else 0;
                    const res = if (cs.object.get("last_reload_result")) |r| if (r == .string) r.string else "ok" else "ok";
                    printOut("Config: {s} (generation {d}, status: {s})\n", .{ path, gen, res });
                    if (cs.object.get("last_reload_error")) |err_val| {
                        if (err_val == .string) printOut("  Error: {s}\n", .{err_val.string});
                    }
                }
            } else if (obj.get("RuntimeInfo")) |ri| {
                if (ri == .object) {
                    const comp = if (ri.object.get("compositor")) |c_val| if (c_val == .string) c_val.string else "rediwm" else "rediwm";
                    const ver = if (ri.object.get("version")) |v| if (v == .string) v.string else "0.1.0" else "0.1.0";
                    const wlv = if (ri.object.get("wlroots_version")) |w| if (w == .string) w.string else "0.20" else "0.20";
                    const backend = if (ri.object.get("backend")) |b| if (b == .string) b.string else "?" else "?";
                    const renderer = if (ri.object.get("renderer")) |r| if (r == .string) r.string else "?" else "?";
                    const session = if (ri.object.get("session_id")) |s| if (s == .string) s.string else "" else "";
                    printOut("{s} {s} (wlroots {s}, backend: {s}, renderer: {s}, session: {s})\n", .{ comp, ver, wlv, backend, renderer, session });
                }
            } else if (obj.get("PerformanceStats")) |ps| {
                if (ps == .object) {
                    const commits = if (ps.object.get("output_commits")) |c_val| if (c_val == .integer) c_val.integer else 0 else 0;
                    const failed = if (ps.object.get("output_failed_commits")) |f| if (f == .integer) f.integer else 0 else 0;
                    const fps = if (ps.object.get("fps")) |v| switch (v) {
                        .float => |f| f,
                        .integer => |i| @as(f64, @floatFromInt(i)),
                        else => 0,
                    } else 0;
                    const frame_ms = if (ps.object.get("frame_time_ms")) |v| switch (v) {
                        .float => |f| f,
                        .integer => |i| @as(f64, @floatFromInt(i)),
                        else => 0,
                    } else 0;
                    const missed = if (ps.object.get("missed_frames")) |v| if (v == .integer) v.integer else 0 else 0;
                    const tb_paints = if (ps.object.get("titlebar_paints")) |tp| if (tp == .integer) tp.integer else 0 else 0;
                    const ft_paints = if (ps.object.get("footer_paints")) |fp| if (fp == .integer) fp.integer else 0 else 0;
                    const edge_att = if (ps.object.get("edge_samples_attempted")) |v| if (v == .integer) v.integer else 0 else 0;
                    const edge_ok = if (ps.object.get("edge_samples_succeeded")) |v| if (v == .integer) v.integer else 0 else 0;
                    const edge_skip = if (ps.object.get("edge_samples_skipped")) |v| if (v == .integer) v.integer else 0 else 0;
                    const pnl_paints = if (ps.object.get("panel_paints")) |pp| if (pp == .integer) pp.integer else 0 else 0;
                    printOut("Performance Stats:\n", .{});
                    printOut("  {d:.1} commits/s, {d:.1} ms commit interval, {d} estimated missed\n", .{ fps, frame_ms, missed });
                    if (ps.object.get("frame_work")) |work| {
                        if (work == .object) {
                            inline for (.{ "cpu_frame", "taskbar_cpu", "chrome_cpu", "panels_cpu", "projection_cpu", "glass_cpu", "scene_commit_cpu", "gpu_elapsed" }) |name| {
                                if (work.object.get(name)) |duration| {
                                    if (duration == .object) {
                                        printOut("  {s}: {f}\n", .{ name, std.json.fmt(duration, .{}) });
                                    }
                                }
                            }
                            if (work.object.get("gpu_timing_available")) |available| {
                                if (available == .bool and !available.bool)
                                    printOut("  GPU timing unavailable on this renderer\n", .{});
                            }
                        }
                    }
                    printOut("  Output commits: {d} (failed: {d})\n", .{ commits, failed });
                    printOut("  Titlebar paints: {d}, Footer paints: {d}\n", .{ tb_paints, ft_paints });
                    printOut("  Edge samples: {d} attempted, {d} succeeded, {d} skipped\n", .{ edge_att, edge_ok, edge_skip });
                    printOut("  Panel paints: {d}\n", .{pnl_paints});
                }
            } else if (obj.get("WaitFor")) |wf| {
                if (wf == .object) {
                    const cond = if (wf.object.get("condition")) |c_val| if (c_val == .string) c_val.string else "?" else "?";
                    const elapsed = if (wf.object.get("elapsed_ms")) |e| if (e == .integer) e.integer else 0 else 0;
                    const timed_out = if (wf.object.get("timed_out")) |t| if (t == .bool) t.bool else false else false;
                    if (timed_out) {
                        printOut("Wait condition '{s}' timed out after {d}ms\n", .{ cond, elapsed });
                    } else {
                        printOut("Wait condition '{s}' satisfied in {d}ms\n", .{ cond, elapsed });
                    }
                }
            } else if (obj.get("WaitForFrame")) |wff| {
                if (wff == .object) {
                    const out = if (wff.object.get("output")) |o| if (o == .string) o.string else "?" else "?";
                    const seq = if (wff.object.get("frame_seq")) |s| if (s == .integer) s.integer else 0 else 0;
                    const elapsed = if (wff.object.get("elapsed_ms")) |e| if (e == .integer) e.integer else 0 else 0;
                    const timed_out = if (wff.object.get("timed_out")) |t| if (t == .bool) t.bool else false else false;
                    if (timed_out) {
                        printOut("Wait for frame on {s} timed out after {d}ms\n", .{ out, elapsed });
                    } else {
                        printOut("Frame {d} rendered on {s} in {d}ms\n", .{ seq, out, elapsed });
                    }
                }
            } else if (obj.get("DumpBuffer")) |db| {
                if (db == .object) {
                    const tgt = if (db.object.get("target")) |t| if (t == .string) t.string else "?" else "?";
                    const w = if (db.object.get("width")) |v| if (v == .integer) v.integer else 0 else 0;
                    const h = if (db.object.get("height")) |v| if (v == .integer) v.integer else 0 else 0;
                    const stride = if (db.object.get("stride")) |s| if (s == .integer) s.integer else 0 else 0;
                    printOut("Dumped buffer ({s}): {d}x{d}, stride {d}\n", .{ tgt, w, h, stride });
                }
            } else if (obj.get("SamplePixels")) |sp| {
                if (sp == .object) {
                    const out = if (sp.object.get("output")) |o| if (o == .string) o.string else "?" else "?";
                    const w = if (sp.object.get("width")) |v| if (v == .integer) v.integer else 0 else 0;
                    const h = if (sp.object.get("height")) |v| if (v == .integer) v.integer else 0 else 0;
                    printOut("Sampled {d}x{d} pixels on {s}\n", .{ w, h, out });
                }
            } else if (obj.get("WindowRules")) |wr| {
                if (wr == .object) {
                    const wid = if (wr.object.get("window_id")) |w| if (w == .integer) w.integer else 0 else 0;
                    printOut("Window Rules for [{d}]:\n", .{wid});
                    if (wr.object.get("matched_rules")) |mr| {
                        if (mr == .array) {
                            printOut("  Matched rules: [", .{});
                            for (mr.array.items, 0..) |item, i| {
                                if (i > 0) printOut(", ", .{});
                                if (item == .integer) printOut("{d}", .{item.integer});
                            }
                            printOut("]\n", .{});
                        }
                    }
                    if (wr.object.get("open")) |o| {
                        printOut("  Open rules: {f}\n", .{std.json.fmt(o, .{})});
                    }
                    if (wr.object.get("live")) |l| {
                        printOut("  Live rules: {f}\n", .{std.json.fmt(l, .{})});
                    }
                    if (wr.object.get("resolved_before_app_id")) |r| {
                        if (r == .bool) printOut("  Resolved before app_id: {}\n", .{r.bool});
                    }
                }
            } else if (obj.get("MatchWindowRules")) |mwr| {
                if (mwr == .object) {
                    printOut("Match Window Rules:\n", .{});
                    if (mwr.object.get("matched_rules")) |mr| {
                        if (mr == .array) {
                            printOut("  Matched rules: [", .{});
                            for (mr.array.items, 0..) |item, i| {
                                if (i > 0) printOut(", ", .{});
                                if (item == .integer) printOut("{d}", .{item.integer});
                            }
                            printOut("]\n", .{});
                        }
                    }
                    if (mwr.object.get("open")) |o| {
                        printOut("  Open rules: {f}\n", .{std.json.fmt(o, .{})});
                    }
                    if (mwr.object.get("live")) |l| {
                        printOut("  Live rules: {f}\n", .{std.json.fmt(l, .{})});
                    }
                }
            } else if (obj.get("NightLight")) |nl| {
                if (nl == .object) {
                    const enabled = if (nl.object.get("enabled")) |e| if (e == .bool) e.bool else false else false;
                    const sched = if (nl.object.get("schedule")) |s| if (s == .string) s.string else "?" else "?";
                    const phase = if (nl.object.get("phase")) |p| if (p == .string) p.string else "?" else "?";
                    const temp = if (nl.object.get("temperature")) |t| if (t == .integer) t.integer else 0 else 0;
                    const overridden = if (nl.object.get("clock_overridden")) |c| if (c == .bool) c.bool else false else false;
                    printOut("Night Light: {s} (schedule: {s}, phase: {s}, temp: {d}K", .{
                        if (enabled) "enabled" else "disabled",
                        sched,
                        phase,
                        temp,
                    });
                    if (overridden) {
                        printOut(", clock overridden", .{});
                    }
                    if (nl.object.get("next_change_unix")) |nc| {
                        if (nc == .integer) {
                            printOut(", next change: {d}", .{nc.integer});
                        }
                    }
                    printOut(")\n", .{});
                    if (nl.object.get("outputs")) |outs| {
                        if (outs == .array) {
                            for (outs.array.items) |out_item| {
                                if (out_item == .object) {
                                    const name = if (out_item.object.get("name")) |n| if (n == .string) n.string else "?" else "?";
                                    const gsize = if (out_item.object.get("gamma_size")) |g| if (g == .integer) g.integer else 0 else 0;
                                    const on = if (out_item.object.get("night_light")) |n| if (n == .bool) n.bool else false else false;
                                    const ot = if (out_item.object.get("temperature")) |t| if (t == .integer) t.integer else 0 else 0;
                                    const st = if (out_item.object.get("status")) |s| if (s == .string) s.string else "?" else "?";
                                    printOut("  {s}: status={s} gamma_size={d} night_light={s} temp={d}K", .{
                                        name,
                                        st,
                                        gsize,
                                        if (on) "on" else "off",
                                        ot,
                                    });
                                    if (out_item.object.get("gamma")) |gm| {
                                        if (gm == .float) {
                                            printOut(" gamma={d:.2}", .{gm.float});
                                        } else if (gm == .integer) {
                                            printOut(" gamma={d:.1}", .{@as(f64, @floatFromInt(gm.integer))});
                                        }
                                    }
                                    printOut("\n", .{});
                                }
                            }
                        }
                    }
                }
            } else if (obj.get("KeyboardLayouts")) |state| {
                printOut("Keyboard layouts:\n{f}\n", .{std.json.fmt(state, .{ .whitespace = .indent_2 })});
            } else if (obj.get("TextInput")) |state| {
                printOut("Text input:\n{f}\n", .{std.json.fmt(state, .{ .whitespace = .indent_2 })});
            } else if (obj.get("Notifications")) |notif_val| {
                if (notif_val == .object) {
                    const dnd = if (notif_val.object.get("dnd")) |d| if (d == .bool) d.bool else false else false;
                    printOut("Notifications (DND: {s}):\n", .{if (dnd) "on" else "off"});
                    if (notif_val.object.get("toasts")) |toasts| {
                        if (toasts == .array) {
                            printOut("Active Toasts ({d}):\n", .{toasts.array.items.len});
                            for (toasts.array.items) |item| {
                                if (item == .object) {
                                    const id = if (item.object.get("id")) |v| if (v == .integer) v.integer else 0 else 0;
                                    const app = if (item.object.get("app_name")) |v| if (v == .string) v.string else "" else "";
                                    const summary = if (item.object.get("summary")) |v| if (v == .string) v.string else "" else "";
                                    printOut("  [{d}] {s}: {s}\n", .{ id, app, summary });
                                }
                            }
                        }
                    }
                }
            } else {
                printOut("Handled\n", .{});
            }
        },
        else => printOut("Handled\n", .{}),
    }
}

const local_commands = .{
    .raw = .{ .synopsis = "[JSON|-]", .description = "Send raw JSON from an argument or stdin" },
    .doctor = .{ .synopsis = "", .description = "Run compositor and environment diagnostics" },
    .action = .{ .synopsis = "<command> [args]", .description = "Run one of the actions below" },
};

const TopCommandTag = blk: {
    @setEvalBranchQuota(20_000);
    for (protocol.commands.specs) |s| {
        if (s.cli) |cli| {
            for (std.meta.fields(@TypeOf(local_commands))) |field| {
                for (&[_][]const u8{cli.name} ++ cli.aliases) |name| {
                    if (std.mem.eql(u8, field.name, name)) @compileError("CLI name shadows local command: " ++ name);
                }
            }
        }
    }
    var names: []const []const u8 = &.{};
    for (std.meta.fields(@TypeOf(local_commands))) |field| names = names ++ .{field.name};
    for (std.meta.fields(protocol.commands.CliTag(false))) |field| names = names ++ .{field.name};
    break :blk @Enum(u8, .exhaustive, names, &std.simd.iota(u8, names.len));
};

fn lookupTopCommand(name: []const u8) ?TopCommandTag {
    inline for (std.meta.fields(@TypeOf(local_commands))) |field| {
        if (std.mem.eql(u8, name, field.name)) return @field(TopCommandTag, field.name);
    }
    const tag = protocol.commands.lookupCli(false, name) orelse return null;
    return @enumFromInt(@intFromEnum(tag) + std.meta.fields(@TypeOf(local_commands)).len);
}

fn printUsage() void {
    std.debug.print(
        \\rediwm-msg: IPC CLI for rediwm
        \\
        \\Usage: rediwm-msg [options] <command>
        \\
        \\Options:
        \\  -s, --socket <PATH>   Path to IPC Unix domain socket
        \\  -t, --timeout <MS>    Socket request/response timeout in ms
        \\  --raw [JSON]          Send raw JSON payload (from arg or stdin)
        \\  --json                Output JSON payload
        \\  -h, --help            Show help
        \\
        \\Commands:
        \\
    , .{});
    inline for (std.meta.fields(@TypeOf(local_commands))) |field| {
        const c = @field(local_commands, field.name);
        std.debug.print("  {s} {s}  {s}\n", .{ field.name, c.synopsis, c.description });
    }
    inline for (protocol.commands.specs) |s| {
        if (comptime s.cli) |cli| printCommandHelp("", cli, s.description);
    }
    std.debug.print("\nActions:\n", .{});
    inline for (protocol.commands.specs) |s| {
        if (comptime s.action_cli) |cli| printCommandHelp("action ", cli, s.description);
    }
    std.debug.print(
        "\nOther IPC commands (via raw JSON):\n" ++
            "  rediwm-msg raw '{{\"version\":1,\"command\":\"get_theme\"}}'\n" ++
            "  rediwm-msg raw '{{\"version\":1,\"command\":\"set_dnd\",\"params\":{{\"enabled\":true}}}}'\n",
        .{},
    );
    inline for (protocol.commands.specs) |s| {
        if (comptime s.cli == null and s.action_cli == null)
            std.debug.print("  {s}  {s}\n", .{ s.wire(), s.description });
    }
    std.debug.print("  Use 'rediwm-msg describe' for parameter schemas.\n", .{});
}

fn printCommandHelp(prefix: []const u8, cli: protocol.commands.CliSpec, description: []const u8) void {
    std.debug.print("  {s}{s} {s}  {s}", .{ prefix, cli.name, cli.synopsis, description });
    if (cli.aliases.len > 0) {
        std.debug.print(" (aliases:", .{});
        for (cli.aliases) |alias| std.debug.print(" {s}", .{alias});
        std.debug.print(")", .{});
    }
    std.debug.print("\n", .{});
}
