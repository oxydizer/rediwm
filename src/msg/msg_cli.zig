//! rediwm-msg command line: options, the command union and flag parsing.

const std = @import("std");
const protocol = @import("protocol");

pub const CliOptions = struct {
    socket_path: ?[]const u8 = null,
    json: bool = false,
    save_path: ?[]const u8 = null,
    timeout_ms: ?u64 = null,
    command: ?Command = null,
};

pub const Command = union(enum) {
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
    input_sources,
    switch_input_source: protocol.LayoutTarget,
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

pub fn parseButtonNameOrInt(arg: []const u8) ?u32 {
    if (std.mem.eql(u8, arg, "left")) return 0x110;
    if (std.mem.eql(u8, arg, "right")) return 0x111;
    if (std.mem.eql(u8, arg, "middle")) return 0x112;
    return std.fmt.parseInt(u32, arg, 10) catch null;
}

pub fn usageError(comptime message: []const u8) noreturn {
    std.debug.print("error: " ++ message ++ "\n", .{});
    std.process.exit(1);
}

pub fn parseAnimMs(arg: []const u8) ??i64 {
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
pub const FlagParser = struct {
    args: []const [*:0]const u8,
    idx: *usize,
    opts: *CliOptions,
    allocator: std.mem.Allocator,

    /// `?T` when some payload field has neither a default nor a preset; null
    /// then means a required flag was missing or unparsable.
    pub fn Result(comptime T: type, comptime Preset: type) type {
        const info = @typeInfo(T).@"struct";
        for (info.field_names, info.field_attrs) |name, attrs| {
            if (attrs.default_value_ptr == null and !@hasField(Preset, name)) return ?T;
        }
        return T;
    }

    pub fn parse(p: FlagParser, comptime T: type, comptime spec: anytype, preset: anytype) Result(T, @TypeOf(preset)) {
        const info = @typeInfo(T).@"struct";
        comptime for (info.field_names, info.field_attrs) |name, attrs| {
            if (attrs.default_value_ptr == null and !@hasField(@TypeOf(preset), name) and !hasEntry(spec, name))
                @compileError("required field '" ++ name ++ "' of " ++ @typeName(T) ++ " has no flag or preset");
        };

        var out: T = undefined;
        var given = std.StaticBitSet(info.field_names.len).empty;
        inline for (info.field_names, info.field_types, info.field_attrs, 0..) |name, FieldType, attrs, i| {
            if (@hasField(@TypeOf(preset), name)) {
                @field(out, name) = @field(preset, name);
                given.set(i);
            } else if (attrs.defaultValue(FieldType)) |d| @field(out, name) = d;
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
                            if (p.value(entry, info.field_types[i], text)) |v| {
                                @field(out, name) = v;
                                given.set(i);
                            } else {
                                if (info.field_attrs[i].defaultValue(info.field_types[i])) |d| @field(out, name) = d;
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
                        if (p.value(entry, info.field_types[i], a)) |v| {
                            @field(out, info.field_names[i]) = v;
                            given.set(i);
                        }
                    }
                }
            }
        }

        if (Result(T, @TypeOf(preset)) != T) {
            inline for (info.field_attrs, 0..) |attrs, i| {
                if (attrs.default_value_ptr == null and !given.isSet(i)) return null;
            }
        }
        return out;
    }

    /// Parses the payload of `tag` and wraps it in its `Command`.
    pub fn command(p: FlagParser, comptime tag: std.meta.Tag(Command), comptime spec: anytype, preset: anytype) CommandResult(tag, @TypeOf(preset)) {
        const payload = p.parse(@FieldType(Command, @tagName(tag)), spec, preset);
        if (CommandResult(tag, @TypeOf(preset)) == Command) return @unionInit(Command, @tagName(tag), payload);
        return @unionInit(Command, @tagName(tag), payload orelse return null);
    }

    pub fn CommandResult(comptime tag: std.meta.Tag(Command), comptime Preset: type) type {
        return if (Result(@FieldType(Command, @tagName(tag)), Preset) == @FieldType(Command, @tagName(tag))) Command else ?Command;
    }

    /// Consumes the rest of a subcommand that takes no options.
    pub fn rest(p: FlagParser) void {
        _ = p.parse(struct {}, .{}, .{});
    }

    pub fn value(p: FlagParser, comptime entry: anytype, comptime V: type, text: []const u8) ?V {
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
    pub fn list(p: FlagParser, text: []const u8) ?[]const []const u8 {
        var items = std.ArrayList([]const u8).empty;
        var it = std.mem.splitScalar(u8, text, ',');
        while (it.next()) |part| {
            const trimmed = std.mem.trim(u8, part, " \t");
            if (trimmed.len > 0) items.append(p.allocator, trimmed) catch return null;
        }
        return items.toOwnedSlice(p.allocator) catch null;
    }

    pub fn entryField(comptime entry: anytype) []const u8 {
        return if (@typeInfo(@TypeOf(entry)) == .enum_literal) @tagName(entry) else entry.field;
    }

    pub fn entryFlag(comptime entry: anytype, comptime option: []const u8) bool {
        if (@typeInfo(@TypeOf(entry)) == .enum_literal or !@hasField(@TypeOf(entry), option)) return false;
        return @field(entry, option);
    }

    pub fn entryNames(comptime entry: anytype) []const []const u8 {
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

    pub fn hasEntry(comptime spec: anytype, comptime field: []const u8) bool {
        inline for (spec) |entry| {
            if (std.mem.eql(u8, entryField(entry), field)) return true;
        }
        return false;
    }

    pub fn fieldIndex(comptime T: type, comptime name: []const u8) usize {
        return std.meta.fieldIndex(T, name) orelse @compileError(@typeName(T) ++ " has no field '" ++ name ++ "'");
    }

    pub fn matchesAny(arg: []const u8, comptime names: []const []const u8) bool {
        inline for (names) |n| {
            if (std.mem.eql(u8, arg, n)) return true;
        }
        return false;
    }
};
