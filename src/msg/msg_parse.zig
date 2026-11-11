//! Parsing a subcommand and its arguments into `CliOptions.command`.

const std = @import("std");
const msg_usage = @import("msg_usage.zig");
const msg_cli = @import("msg_cli.zig");
const protocol = @import("protocol");
const parseButtonNameOrInt = msg_cli.parseButtonNameOrInt;
const usageError = msg_cli.usageError;
const parseAnimMs = msg_cli.parseAnimMs;
const FlagParser = msg_cli.FlagParser;
const lookupTopCommand = msg_usage.lookupTopCommand;

/// Parses the subcommand named by `arg` and its arguments into
/// `cli.opts.command`, advancing `cli.idx`.
pub fn parseCommand(cli: FlagParser, arg: []const u8) !void {
    const raw_args = cli.args;
    const opts = cli.opts;
    const allocator = cli.allocator;
    const arg_idx = cli.idx;
    const tag = lookupTopCommand(arg) orelse {
        std.debug.print("error: unknown command '{s}'\n", .{arg});
        std.process.exit(1);
    };
    switch (tag) {
        .raw => {
            arg_idx.* += 1;
            if (arg_idx.* < raw_args.len and !std.mem.eql(u8, std.mem.span(raw_args[arg_idx.*]), "-")) {
                opts.command = .{ .raw = std.mem.span(raw_args[arg_idx.*]) };
                arg_idx.* += 1;
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
            arg_idx.* += 1;
        },
        .describe_ipc => {
            opts.command = .describe;
            arg_idx.* += 1;
        },
        .doctor => {
            opts.command = .doctor;
            arg_idx.* += 1;
        },
        .get_window_debug => {
            arg_idx.* += 1;
            if (arg_idx.* >= raw_args.len) {
                std.debug.print("error: window-debug requires <window_id>\n", .{});
                std.process.exit(1);
            }
            const wid = std.fmt.parseInt(u64, std.mem.span(raw_args[arg_idx.*]), 10) catch {
                std.debug.print("error: invalid window id\n", .{});
                std.process.exit(1);
            };
            arg_idx.* += 1;
            opts.command = .{ .window_debug = .{ .id = wid } };
        },
        .get_window_rules => {
            arg_idx.* += 1;
            if (arg_idx.* >= raw_args.len) {
                std.debug.print("error: window-rules requires <window_id>\n", .{});
                std.process.exit(1);
            }
            const wid = std.fmt.parseInt(u64, std.mem.span(raw_args[arg_idx.*]), 10) catch {
                std.debug.print("error: invalid window id\n", .{});
                std.process.exit(1);
            };
            arg_idx.* += 1;
            opts.command = .{ .window_rules = .{ .id = wid } };
        },
        .match_window_rules => {
            arg_idx.* += 1;
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
            arg_idx.* += 1;
        },
        .get_notifications => {
            opts.command = .notifications;
            arg_idx.* += 1;
        },
        .get_shell_state => {
            arg_idx.* += 1;
            opts.command = cli.command(.shell_state, .{.output}, .{});
        },
        .get_keyboard_layouts => {
            opts.command = .keyboard_layouts;
            arg_idx.* += 1;
        },
        .switch_layout => {
            arg_idx.* += 1;
            if (arg_idx.* >= raw_args.len) return error.InvalidArguments;
            const value = std.mem.span(raw_args[arg_idx.*]);
            opts.command = .{ .switch_layout = if (std.ascii.eqlIgnoreCase(value, "next")) .next else if (std.ascii.eqlIgnoreCase(value, "prev")) .prev else .{ .index = std.fmt.parseInt(u32, value, 10) catch return error.InvalidArguments } };
            arg_idx.* += 1;
        },
        .get_input_sources => {
            opts.command = .input_sources;
            arg_idx.* += 1;
        },
        .switch_input_source => {
            arg_idx.* += 1;
            if (arg_idx.* >= raw_args.len) return error.InvalidArguments;
            const value = std.mem.span(raw_args[arg_idx.*]);
            opts.command = .{ .switch_input_source = if (std.ascii.eqlIgnoreCase(value, "next")) .next else if (std.ascii.eqlIgnoreCase(value, "prev")) .prev else .{ .index = std.fmt.parseInt(u32, value, 10) catch return error.InvalidArguments } };
            arg_idx.* += 1;
        },
        .get_text_input => {
            opts.command = .text_input;
            arg_idx.* += 1;
        },
        .get_input_state => {
            opts.command = .input_state;
            arg_idx.* += 1;
        },
        .hit_test => {
            arg_idx.* += 1;
            if (arg_idx.* + 1 >= raw_args.len) {
                std.debug.print("error: hit-test requires <x> <y>\n", .{});
                std.process.exit(1);
            }
            const x = std.fmt.parseInt(i32, std.mem.span(raw_args[arg_idx.*]), 10) catch {
                std.debug.print("error: invalid x coordinate\n", .{});
                std.process.exit(1);
            };
            arg_idx.* += 1;
            const y = std.fmt.parseInt(i32, std.mem.span(raw_args[arg_idx.*]), 10) catch {
                std.debug.print("error: invalid y coordinate\n", .{});
                std.process.exit(1);
            };
            arg_idx.* += 1;
            opts.command = cli.command(.hit_test, .{.output}, .{ .x = x, .y = y });
        },
        .get_scene_tree => {
            arg_idx.* += 1;
            opts.command = cli.command(.scene_tree, .{.max_depth}, .{});
        },
        .get_layer_surfaces => {
            opts.command = .layers;
            arg_idx.* += 1;
        },
        .list_panels => {
            opts.command = .panels;
            arg_idx.* += 1;
        },
        .get_widget_tree => {
            arg_idx.* += 1;
            if (arg_idx.* >= raw_args.len) {
                std.debug.print("error: widget-tree requires <panel>\n", .{});
                std.process.exit(1);
            }
            const panel = std.mem.span(raw_args[arg_idx.*]);
            arg_idx.* += 1;
            opts.command = .{ .widget_tree = .{ .panel = panel } };
        },
        .get_config_status => {
            opts.command = .config;
            arg_idx.* += 1;
        },
        .get_runtime_info => {
            opts.command = .runtime;
            arg_idx.* += 1;
        },
        .get_performance_stats => {
            opts.command = .perf;
            arg_idx.* += 1;
        },
        .reset_performance_stats => {
            opts.command = .perf_reset;
            arg_idx.* += 1;
        },
        .wait_for => {
            arg_idx.* += 1;
            if (arg_idx.* >= raw_args.len) {
                std.debug.print("error: wait requires <condition>\n", .{});
                std.process.exit(1);
            }
            const cond = std.mem.span(raw_args[arg_idx.*]);
            arg_idx.* += 1;
            opts.command = cli.command(.wait, .{
                .{ .field = "timeout_ms", .names = .{"--timeout"} },
                .{ .field = "window_id", .names = .{"--id"} },
                .output,
            }, .{ .condition = cond });
        },
        .wait_for_frame => {
            arg_idx.* += 1;
            opts.command = cli.command(.wait_frame, .{ .output, .{ .field = "timeout_ms", .names = .{"--timeout"} } }, .{});
        },
        .dump_buffer => {
            arg_idx.* += 1;
            if (arg_idx.* >= raw_args.len) {
                std.debug.print("error: dump-buffer requires <target>\n", .{});
                std.process.exit(1);
            }
            const tgt = std.mem.span(raw_args[arg_idx.*]);
            arg_idx.* += 1;
            opts.command = cli.command(.dump_buffer, .{ .{ .field = "window_id", .names = .{"--id"} }, .output }, .{ .target = tgt });
        },
        .sample_pixels => {
            arg_idx.* += 1;
            if (arg_idx.* + 3 >= raw_args.len) {
                std.debug.print("error: sample-pixels requires <x> <y> <width> <height>\n", .{});
                std.process.exit(1);
            }
            const x = std.fmt.parseInt(i32, std.mem.span(raw_args[arg_idx.*]), 10) catch 0;
            arg_idx.* += 1;
            const y = std.fmt.parseInt(i32, std.mem.span(raw_args[arg_idx.*]), 10) catch 0;
            arg_idx.* += 1;
            const w = std.fmt.parseInt(u32, std.mem.span(raw_args[arg_idx.*]), 10) catch 1;
            arg_idx.* += 1;
            const h = std.fmt.parseInt(u32, std.mem.span(raw_args[arg_idx.*]), 10) catch 1;
            arg_idx.* += 1;
            opts.command = cli.command(.sample_pixels, .{.output}, .{ .x = x, .y = y, .width = w, .height = h });
        },
        .set_output_config => {
            arg_idx.* += 1;
            if (arg_idx.* >= raw_args.len) return error.MissingOutput;
            var patch = protocol.OutputConfigPatch{ .output = std.mem.span(raw_args[arg_idx.*]) };
            arg_idx.* += 1;
            while (arg_idx.* < raw_args.len) : (arg_idx.* += 1) {
                const option = std.mem.span(raw_args[arg_idx.*]);
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
                if (arg_idx.* + 1 >= raw_args.len) return error.MissingOptionValue;
                arg_idx.* += 1;
                const value = std.mem.span(raw_args[arg_idx.*]);
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
            arg_idx.* += 1;
            if (arg_idx.* >= raw_args.len) {
                std.debug.print("error: maximize requires <id>\n", .{});
                std.process.exit(1);
            }
            const id = std.fmt.parseInt(u64, std.mem.span(raw_args[arg_idx.*]), 10) catch 0;
            arg_idx.* += 1;
            opts.command = .{ .maximize = .{ .id = id } };
        },
        .minimize_window => {
            arg_idx.* += 1;
            if (arg_idx.* >= raw_args.len) {
                std.debug.print("error: minimize requires <id>\n", .{});
                std.process.exit(1);
            }
            const id = std.fmt.parseInt(u64, std.mem.span(raw_args[arg_idx.*]), 10) catch 0;
            arg_idx.* += 1;
            opts.command = .{ .minimize = .{ .id = id } };
        },
        .restore_window => {
            arg_idx.* += 1;
            if (arg_idx.* >= raw_args.len) {
                std.debug.print("error: restore requires <id>\n", .{});
                std.process.exit(1);
            }
            const id = std.fmt.parseInt(u64, std.mem.span(raw_args[arg_idx.*]), 10) catch 0;
            arg_idx.* += 1;
            opts.command = .{ .restore = .{ .id = id } };
        },
        .fullscreen_window => {
            arg_idx.* += 1;
            if (arg_idx.* >= raw_args.len) {
                std.debug.print("error: fullscreen requires <id>\n", .{});
                std.process.exit(1);
            }
            const id = std.fmt.parseInt(u64, std.mem.span(raw_args[arg_idx.*]), 10) catch 0;
            arg_idx.* += 1;
            opts.command = .{ .fullscreen = .{ .id = id } };
        },
        .set_window_zoom => {
            arg_idx.* += 1;
            if (arg_idx.* + 1 >= raw_args.len) {
                std.debug.print("error: set-zoom requires <id> <percent>\n", .{});
                std.process.exit(1);
            }
            const id = std.fmt.parseInt(u64, std.mem.span(raw_args[arg_idx.*]), 10) catch 0;
            arg_idx.* += 1;
            const pct = std.fmt.parseInt(u8, std.mem.span(raw_args[arg_idx.*]), 10) catch 100;
            arg_idx.* += 1;
            opts.command = .{ .set_zoom = .{ .id = id, .percent = pct } };
        },
        .close_panel => {
            arg_idx.* += 1;
            if (arg_idx.* >= raw_args.len) {
                std.debug.print("error: close-panel requires <panel>\n", .{});
                std.process.exit(1);
            }
            const panel = std.mem.span(raw_args[arg_idx.*]);
            arg_idx.* += 1;
            opts.command = .{ .close_panel = .{ .panel = panel } };
        },
        .reload_config => {
            opts.command = .reload;
            arg_idx.* += 1;
        },
        .launch_app => {
            arg_idx.* += 1;
            if (arg_idx.* >= raw_args.len) {
                std.debug.print("error: launch requires <desktop_id>\n", .{});
                std.process.exit(1);
            }
            const did = std.mem.span(raw_args[arg_idx.*]);
            arg_idx.* += 1;
            opts.command = .{ .launch = .{ .desktop_id = did } };
        },
        .version => {
            opts.command = .version;
            arg_idx.* += 1;
        },
        .capabilities => {
            opts.command = .capabilities;
            arg_idx.* += 1;
        },
        .windows => {
            opts.command = .windows;
            arg_idx.* += 1;
        },
        .outputs => {
            opts.command = .outputs;
            arg_idx.* += 1;
        },
        .focused_window => {
            opts.command = .focused_window;
            arg_idx.* += 1;
        },
        .workspaces => {
            opts.command = .workspaces;
            arg_idx.* += 1;
        },
        .event_stream => {
            arg_idx.* += 1;
            opts.command = cli.command(.event_stream, .{ .events, .{ .field = "window_id", .names = .{"--window"} }, .output }, .{});
        },
        .action => {
            arg_idx.* += 1;
            if (arg_idx.* >= raw_args.len) {
                std.debug.print("error: action requires a subcommand\n", .{});
                std.process.exit(1);
            }
            const act_cmd = std.mem.span(raw_args[arg_idx.*]);
            arg_idx.* += 1;

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
                    if (arg_idx.* < raw_args.len and std.mem.eql(u8, std.mem.span(raw_args[arg_idx.*]), "--")) {
                        arg_idx.* += 1;
                    }
                    var argv_list = std.ArrayList([]const u8).empty;
                    while (arg_idx.* < raw_args.len) : (arg_idx.* += 1) {
                        const a = std.mem.span(raw_args[arg_idx.*]);
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
}
