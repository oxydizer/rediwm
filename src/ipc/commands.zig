// Canonical v1 command names and discovery metadata. Parameter extraction
// remains in protocol.zig; this module has no compositor dependencies.
const std = @import("std");
const protocol = @import("protocol.zig");

pub const CommandId = blk: {
    @setEvalBranchQuota(100_000);
    var names: []const []const u8 = &.{};
    for (.{ protocol.Request, protocol.Action }) |T| {
        for (std.meta.fields(T)) |field| {
            if (T == protocol.Request and isInternalRequest(field.name)) continue;
            var exists = false;
            for (names) |name| if (std.mem.eql(u8, name, field.name)) {
                exists = true;
            };
            if (!exists) names = names ++ .{field.name};
        }
    }
    break :blk @Enum(u16, .exhaustive, names, &std.simd.iota(u16, names.len));
};

pub fn isInternalRequest(comptime name: []const u8) bool {
    return std.mem.eql(u8, name, "action") or std.mem.eql(u8, name, "event_stream_filtered");
}

pub const Route = enum { query, action };
pub const CliSpec = struct { name: []const u8, aliases: []const []const u8 = &.{}, synopsis: []const u8 = "" };

pub const CommandSpec = struct {
    cli: ?CliSpec = null,
    action_cli: ?CliSpec = null,
    id: CommandId,
    kind: enum { query, action },
    description: []const u8,
    params_schema: []const u8 = "{}",
    units: ?[]const u8 = null,
    description_order: u8,
    /// Synthetic input or pixel access, refused unless `[ipc] automation` is
    /// on (`IpcServer.automation`).
    automation: bool = false,

    pub fn wire(comptime self: CommandSpec) []const u8 {
        return @tagName(self.id);
    }
};

// Canonical v1 names and internal parameter-parser routes.
pub const specs = [_]CommandSpec{
    .{
        .id = .version,
        .kind = .query,
        .description = "Get compositor build version",
        .params_schema = "{}",
        .description_order = 0,
        .cli = .{ .name = "version", .synopsis = "" },
    },
    .{
        .id = .capabilities,
        .kind = .query,
        .description = "List supported commands",
        .params_schema = "{}",
        .description_order = 1,
        .cli = .{ .name = "capabilities", .synopsis = "" },
    },
    .{
        .id = .describe_ipc,
        .kind = .query,
        .description = "Introspect IPC protocol capabilities and schemas",
        .params_schema = "{}",
        .description_order = 2,
        .cli = .{ .name = "describe", .synopsis = "", .aliases = &.{"describe-ipc"} },
    },
    .{
        .id = .windows,
        .kind = .query,
        .description = "List all open toplevel windows",
        .params_schema = "{}",
        .description_order = 3,
        .cli = .{ .name = "windows", .synopsis = "" },
    },
    .{
        .id = .outputs,
        .kind = .query,
        .description = "List all outputs/monitors",
        .params_schema = "{}",
        .description_order = 4,
        .cli = .{ .name = "outputs", .synopsis = "" },
    },
    .{
        .id = .focused_window,
        .kind = .query,
        .description = "Get the currently focused window",
        .params_schema = "{}",
        .description_order = 5,
        .cli = .{ .name = "focused-window", .synopsis = "" },
    },
    .{
        .id = .event_stream,
        .kind = .query,
        .description = "Subscribe to events, optionally filtered by window, output and event kinds",
        .params_schema = "{\"window_id\"?: number, \"output\"?: string, \"events\"?: string[]}",
        .description_order = 35,
        .cli = .{ .name = "event-stream", .synopsis = "[--events <e1,e2>] [--window <ID>] [--output <OUT>]" },
    },
    .{
        .id = .workspaces,
        .kind = .query,
        .description = "List workspaces",
        .params_schema = "{}",
        .description_order = 36,
        .cli = .{ .name = "workspaces", .synopsis = "" },
    },
    .{
        .id = .get_state,
        .kind = .query,
        .description = "Atomically get snapshot of windows, outputs, camera, shell",
        .params_schema = "{}",
        .description_order = 6,
        .cli = .{ .name = "state", .synopsis = "", .aliases = &.{"get-state"} },
    },
    .{
        .id = .get_window_debug,
        .kind = .query,
        .description = "Get detailed window geometry, decor, and serials",
        .params_schema = "{\"id\": number}",
        .description_order = 7,
        .cli = .{ .name = "window-debug", .synopsis = "<window_id>" },
    },
    .{
        .id = .get_shell_state,
        .kind = .query,
        .description = "Inspect shell panels, progress, and taskbars",
        .params_schema = "{\"output\"?: string}",
        .description_order = 8,
        .cli = .{ .name = "shell-state", .synopsis = "[--output <OUT>]" },
    },
    .{
        .id = .get_input_state,
        .kind = .query,
        .description = "Inspect pointer, focus, keys, buttons, and grabs",
        .params_schema = "{}",
        .description_order = 9,
        .cli = .{ .name = "input-state", .synopsis = "" },
    },
    .{
        .id = .hit_test,
        .kind = .query,
        .description = "Find scene target at layout coordinates",
        .params_schema = "{\"x\": number, \"y\": number, \"output\"?: string}",
        .description_order = 10,
        .cli = .{ .name = "hit-test", .synopsis = "<x> <y> [--output <OUT>]" },
    },
    .{
        .id = .get_scene_tree,
        .kind = .query,
        .description = "Traverse the compositor scene node hierarchy",
        .params_schema = "{\"max_depth\"?: number}",
        .description_order = 11,
        .cli = .{ .name = "scene-tree", .synopsis = "[--max-depth <N>]" },
    },
    .{
        .id = .get_layer_surfaces,
        .kind = .query,
        .description = "List active layer-shell surfaces",
        .params_schema = "{}",
        .description_order = 12,
        .cli = .{ .name = "layers", .synopsis = "" },
    },
    .{
        .id = .get_widget_tree,
        .kind = .query,
        .description = "Inspect semantic UI widget tree for open panel",
        .params_schema = "{\"panel\": string}",
        .description_order = 13,
        .cli = .{ .name = "widget-tree", .synopsis = "<panel>" },
    },
    .{
        .id = .get_config_status,
        .kind = .query,
        .description = "Get effective config and reload status",
        .params_schema = "{}",
        .description_order = 14,
        .cli = .{ .name = "config", .synopsis = "", .aliases = &.{"get-config"} },
    },
    .{
        .id = .get_runtime_info,
        .kind = .query,
        .description = "Compositor, wlroots, backend, and renderer info",
        .params_schema = "{}",
        .description_order = 15,
        .cli = .{ .name = "runtime", .synopsis = "", .aliases = &.{"get-runtime"} },
    },
    .{
        .id = .focus_window,
        .kind = .action,
        .description = "Focus a window by ID",
        .params_schema = "{\"id\": number}",
        .description_order = 37,
        .action_cli = .{ .name = "focus-window", .synopsis = "--id <ID>" },
    },
    .{
        .id = .close_window,
        .kind = .action,
        .description = "Close the specified window or the focused window",
        .params_schema = "{\"id\"?: number | null}",
        .description_order = 38,
        .action_cli = .{ .name = "close-window", .synopsis = "[--id <ID>]" },
    },
    .{
        .id = .move_window_to,
        .kind = .action,
        .description = "Move a window to layout coordinates or another output",
        .params_schema = "{\"id\": number, \"x\"?: number, \"y\"?: number, \"output\"?: string}",
        .description_order = 39,
        .action_cli = .{ .name = "move-window-to", .synopsis = "--id <ID> [--x <X> --y <Y>] [--output <OUTPUT>]" },
    },
    .{
        .id = .spawn,
        .kind = .action,
        .description = "Spawn a process with an argument vector",
        .params_schema = "{\"argv\": string[]}",
        .description_order = 40,
        .action_cli = .{ .name = "spawn", .synopsis = "[--] <COMMAND> [ARGS...]" },
    },
    .{
        .id = .move_cursor,
        .automation = true,
        .kind = .action,
        .description = "Move the pointer to layout coordinates",
        .params_schema = "{\"x\": number, \"y\": number, \"output\"?: string}",
        .description_order = 41,
        .action_cli = .{ .name = "move-cursor", .synopsis = "--x <X> --y <Y> [--output <OUTPUT>]" },
    },
    .{
        .id = .move_cursor_relative,
        .automation = true,
        .kind = .action,
        .description = "Move the pointer by a relative offset",
        .params_schema = "{\"dx\": number, \"dy\": number}",
        .description_order = 42,
        .action_cli = .{ .name = "move-cursor-relative", .synopsis = "--dx <DX> --dy <DY>" },
    },
    .{
        .id = .pointer_button,
        .automation = true,
        .kind = .action,
        .description = "Press or release a Linux pointer button code",
        .params_schema = "{\"button\": number, \"pressed\": bool}",
        .description_order = 43,
        .action_cli = .{ .name = "pointer-button", .synopsis = "--button <BUTTON> --pressed <true|false>" },
    },
    .{
        .id = .click,
        .automation = true,
        .kind = .action,
        .description = "Click a pointer button (defaults to left)",
        .params_schema = "{\"button\"?: number}",
        .description_order = 44,
        .action_cli = .{ .name = "click", .synopsis = "[--button <BUTTON>]" },
    },
    .{
        .id = .scroll,
        .automation = true,
        .kind = .action,
        .description = "Inject horizontal and vertical scroll deltas",
        .params_schema = "{\"dx\": number, \"dy\": number}",
        .description_order = 45,
        .action_cli = .{ .name = "scroll", .synopsis = "--dx <DX> --dy <DY>" },
    },
    .{
        .id = .key,
        .automation = true,
        .kind = .action,
        .description = "Press or release a Linux keycode",
        .params_schema = "{\"keycode\": number, \"pressed\": bool}",
        .description_order = 46,
        .action_cli = .{ .name = "key", .synopsis = "--keycode <KEYCODE> --pressed <true|false>" },
    },
    .{
        .id = .key_press,
        .automation = true,
        .kind = .action,
        .description = "Press and release a named key or chord",
        .params_schema = "{\"key\": string}",
        .description_order = 47,
        .action_cli = .{ .name = "key-press", .synopsis = "--key <KEY>" },
    },
    .{
        .id = .type_text,
        .automation = true,
        .kind = .action,
        .description = "Type text through synthetic keyboard input",
        .params_schema = "{\"text\": string}",
        .description_order = 48,
        .action_cli = .{ .name = "type-text", .synopsis = "--text <TEXT>" },
    },
    .{
        .id = .drag,
        .automation = true,
        .kind = .action,
        .description = "Drag a pointer button between layout coordinates",
        .params_schema = "{\"from_x\": number, \"from_y\": number, \"to_x\": number, \"to_y\": number, \"button\"?: number, \"output\"?: string}",
        .description_order = 49,
        .action_cli = .{ .name = "drag", .synopsis = "--from-x <X1> --from-y <Y1> --to-x <X2> --to-y <Y2> [--button <BUTTON>] [--output <OUTPUT>]" },
    },
    .{
        .id = .screenshot,
        .automation = true,
        .kind = .action,
        .description = "Capture an output or window, optionally cropping or saving PNG data",
        .params_schema = "{\"output\"?: string, \"window_id\"?: number, \"mode\"?: string, \"include_cursor\"?: bool, \"path\"?: string, \"crop\"?: {\"x\": number, \"y\": number, \"width\": number, \"height\": number}, \"crop_space\"?: string}",
        .description_order = 50,
        .action_cli = .{ .name = "screenshot", .synopsis = "[--output <OUTPUT>] [--window <ID>] [--mode <MODE>] [--include-cursor] [--path <PATH>] [--save <PATH>]" },
    },
    .{
        .id = .get_camera,
        .kind = .query,
        .description = "Get camera position, bounds and zoom",
        .params_schema = "{}",
        .description_order = 51,
    },
    .{
        .id = .set_camera,
        .kind = .action,
        .description = "Set camera position",
        .params_schema = "{\"x\": number, \"y\": number}",
        .description_order = 52,
    },
    .{
        .id = .reset_camera,
        .kind = .action,
        .description = "Reset camera position",
        .params_schema = "{}",
        .description_order = 53,
    },
    .{
        .id = .set_zoom,
        .kind = .action,
        .description = "Set camera zoom to a supported percentage",
        .params_schema = "{\"percent\": 100 | 85 | 70 | 55}",
        .description_order = 54,
    },
    .{
        .id = .open_appearance,
        .kind = .action,
        .description = "Open appearance settings",
        .params_schema = "{}",
        .description_order = 55,
    },
    .{
        .id = .set_master_volume,
        .kind = .action,
        .description = "Set master audio volume, clamped to 0 through 1",
        .params_schema = "{\"volume\": number}",
        .description_order = 56,
        .action_cli = .{ .name = "set-master-volume", .synopsis = "--volume <0.0-1.0>" },
    },
    .{
        .id = .toggle_mute,
        .kind = .action,
        .description = "Toggle master audio mute",
        .params_schema = "{}",
        .description_order = 57,
        .action_cli = .{ .name = "toggle-mute", .synopsis = "" },
    },
    .{
        .id = .set_app_volume,
        .kind = .action,
        .description = "Set an audio stream volume, clamped to 0 through 1",
        .params_schema = "{\"index\": number, \"volume\": number}",
        .description_order = 58,
        .action_cli = .{ .name = "set-app-volume", .synopsis = "--index <N> --volume <0.0-1.0>" },
    },
    .{
        .id = .set_app_mute,
        .kind = .action,
        .description = "Set an audio stream mute state",
        .params_schema = "{\"index\": number, \"muted\": bool}",
        .description_order = 59,
        .action_cli = .{ .name = "set-app-mute", .synopsis = "--index <N> --muted <true|false>" },
    },
    .{
        .id = .get_audio_state,
        .kind = .query,
        .description = "Inspect master audio and application streams",
        .params_schema = "{}",
        .description_order = 60,
        .action_cli = .{ .name = "get-audio-state", .synopsis = "" },
    },
    .{
        .id = .get_panel_stats,
        .kind = .query,
        .description = "Get panel painting and allocation counters",
        .params_schema = "{}",
        .description_order = 61,
        .action_cli = .{ .name = "get-panel-stats", .synopsis = "" },
    },
    .{
        .id = .reset_panel_stats,
        .kind = .action,
        .description = "Reset panel painting and allocation counters",
        .params_schema = "{}",
        .description_order = 62,
        .action_cli = .{ .name = "reset-panel-stats", .synopsis = "" },
    },
    .{
        .id = .set_anim_time,
        .kind = .action,
        .description = "Override animation time, or clear the override with null",
        .params_schema = "{\"ms\": number | null}",
        .description_order = 63,
        .action_cli = .{ .name = "set-anim-time", .synopsis = "--ms <N|null>" },
    },
    .{
        .id = .open_start_menu,
        .kind = .action,
        .description = "Open the start menu",
        .params_schema = "{}",
        .description_order = 64,
        .action_cli = .{ .name = "open-start-menu", .synopsis = "" },
    },
    .{
        .id = .open_control_center,
        .kind = .action,
        .description = "Open the control center",
        .params_schema = "{}",
        .description_order = 65,
        .action_cli = .{ .name = "open-control-center", .synopsis = "" },
    },
    .{
        .id = .open_power_menu,
        .kind = .action,
        .description = "Open the power menu",
        .params_schema = "{}",
        .description_order = 66,
        .action_cli = .{ .name = "open-power-menu", .synopsis = "" },
    },
    .{
        .id = .wait_for,
        .kind = .action,
        .description = "Wait deterministically for a typed state condition",
        .params_schema = "{\"condition\": any, \"timeout_ms\"?: number}",
        .units = "ms",
        .description_order = 16,
        .cli = .{ .name = "wait", .synopsis = "<condition> [--timeout <MS>] [--id <ID>] [--output <OUT>]" },
    },
    .{
        .id = .wait_for_frame,
        .kind = .action,
        .description = "Wait for output frame commit",
        .params_schema = "{\"output\"?: string, \"timeout_ms\"?: number}",
        .units = "ms",
        .description_order = 17,
        .cli = .{ .name = "wait-frame", .synopsis = "[--output <OUT>] [--timeout <MS>]" },
    },
    .{
        .id = .dump_buffer,
        .automation = true,
        .kind = .action,
        .description = "Inspect or dump compositor UI raster buffers",
        .params_schema = "{\"target\": string, \"window_id\"?: number, \"output\"?: string}",
        .description_order = 18,
        .cli = .{ .name = "dump-buffer", .synopsis = "<target> [--id <ID>] [--output <OUT>]" },
    },
    .{
        .id = .sample_pixels,
        .automation = true,
        .kind = .action,
        .description = "Read raw pixels from output framebuffer",
        .params_schema = "{\"output\"?: string, \"x\": number, \"y\": number, \"width\"?: number, \"height\"?: number}",
        .description_order = 19,
        .cli = .{ .name = "sample-pixels", .synopsis = "<x> <y> <width> <height> [--output <OUT>]" },
    },
    .{
        .id = .get_performance_stats,
        .kind = .query,
        .description = "Get commit, paint, and error performance counters",
        .params_schema = "{}",
        .description_order = 20,
        .cli = .{ .name = "perf", .synopsis = "", .aliases = &.{"get-perf"} },
    },
    .{
        .id = .reset_performance_stats,
        .kind = .action,
        .description = "Reset performance counters",
        .params_schema = "{}",
        .description_order = 21,
        .cli = .{ .name = "perf-reset", .synopsis = "" },
    },
    .{
        .id = .maximize_window,
        .kind = .action,
        .description = "Maximize a window",
        .params_schema = "{\"id\": number}",
        .description_order = 22,
        .cli = .{ .name = "maximize", .synopsis = "<id>" },
    },
    .{
        .id = .minimize_window,
        .kind = .action,
        .description = "Minimize a window",
        .params_schema = "{\"id\": number}",
        .description_order = 23,
        .cli = .{ .name = "minimize", .synopsis = "<id>" },
    },
    .{
        .id = .restore_window,
        .kind = .action,
        .description = "Restore a minimized/maximized window",
        .params_schema = "{\"id\": number}",
        .description_order = 24,
        .cli = .{ .name = "restore", .synopsis = "<id>" },
    },
    .{
        .id = .fullscreen_window,
        .kind = .action,
        .description = "Toggle or set window fullscreen",
        .params_schema = "{\"id\": number, \"output\"?: string}",
        .description_order = 25,
        .cli = .{ .name = "fullscreen", .synopsis = "<id> [--output <OUT>]" },
    },
    .{
        .id = .stop_xwayland,
        .kind = .action,
        .description = "Disconnect the compositor-owned Xwayland server",
        .params_schema = "{}",
        .description_order = 26,
    },
    .{
        .id = .set_window_size,
        .kind = .action,
        .description = "Request client resize",
        .params_schema = "{\"id\": number, \"width\": number, \"height\": number}",
        .units = "px",
        .description_order = 27,
    },
    .{
        .id = .set_window_zoom,
        .kind = .action,
        .description = "Set individual window zoom percentage",
        .params_schema = "{\"id\": number, \"percent\": number}",
        .units = "%",
        .description_order = 28,
        .cli = .{ .name = "set-zoom", .synopsis = "<id> <pct>" },
    },
    .{
        .id = .close_panel,
        .kind = .action,
        .description = "Close a shell panel",
        .params_schema = "{\"panel\": string}",
        .description_order = 29,
        .cli = .{ .name = "close-panel", .synopsis = "<panel>" },
    },
    .{
        .id = .reload_config,
        .kind = .action,
        .description = "Reload configuration file from disk",
        .params_schema = "{}",
        .description_order = 30,
        .cli = .{ .name = "reload", .synopsis = "" },
    },
    .{
        .id = .launch_app,
        .kind = .action,
        .description = "Launch an application by desktop file ID",
        .params_schema = "{\"desktop_id\": string}",
        .description_order = 31,
        .cli = .{ .name = "launch", .synopsis = "<desktop_id>" },
    },
    .{
        .id = .get_idle_state,
        .kind = .query,
        .description = "Inspect idle state, policy deadlines, and active inhibitors",
        .params_schema = "{}",
        .description_order = 32,
    },
    .{
        .id = .set_idle_config,
        .kind = .action,
        .description = "Configure idle timeouts and policy",
        .params_schema = "{\"enabled\"?: bool, \"blank_after_seconds\"?: number, \"suspend_after_seconds\"?: number}",
        .description_order = 33,
    },
    .{
        .id = .advance_idle_time,
        .kind = .action,
        .description = "Advance idle clock for testing",
        .params_schema = "{\"seconds\": number}",
        .description_order = 34,
    },
    .{
        .id = .stop_all_capture,
        .kind = .action,
        .description = "Stop all active screen-capture sessions",
        .params_schema = "{}",
        .description_order = 67,
    },
    .{
        .id = .get_capture_state,
        .kind = .query,
        .description = "Inspect active screen-capture sessions",
        .params_schema = "{}",
        .description_order = 68,
    },
    .{
        .id = .get_window_rules,
        .kind = .query,
        .description = "Inspect matched window rules and effective properties",
        .params_schema = "{\"id\": number}",
        .description_order = 69,
        .cli = .{ .name = "window-rules", .synopsis = "<window_id>" },
    },
    .{
        .id = .match_window_rules,
        .kind = .query,
        .description = "Dry-run match window rules against hypothetical window identity",
        .params_schema = "{\"app_id\"?: string, \"title\"?: string, \"x11_class\"?: string, \"x11_instance\"?: string, \"backend\"?: string, \"dialog\"?: boolean}",
        .description_order = 70,
        .cli = .{ .name = "match-window-rules", .synopsis = "[--app-id <ID>] [--title <TITLE>] [--class <CLASS>] [--instance <INST>] [--backend <xdg|xwayland>] [--dialog <true|false>]" },
    },
    .{
        .id = .get_night_light,
        .kind = .query,
        .description = "Inspect night light status and display color curves",
        .params_schema = "{}",
        .description_order = 71,
        .cli = .{ .name = "night-light", .synopsis = "" },
    },
    .{
        .id = .set_night_light_clock,
        .kind = .action,
        .description = "Override night light clock for testing",
        .params_schema = "{\"unix_seconds\"?: number}",
        .description_order = 72,
    },
    .{
        .id = .get_notifications,
        .kind = .query,
        .description = "Inspect active toasts, history, and DND status",
        .params_schema = "{}",
        .description_order = 73,
        .cli = .{ .name = "notifications", .synopsis = "" },
    },
    .{
        .id = .dismiss_notification,
        .kind = .action,
        .description = "Dismiss an active notification toast",
        .params_schema = "{\"id\": number, \"reason\"?: number}",
        .description_order = 74,
    },
    .{
        .id = .invoke_notification_action,
        .kind = .action,
        .description = "Invoke an action button on an active notification toast",
        .params_schema = "{\"id\": number, \"action_key\": string}",
        .description_order = 75,
    },
    .{
        .id = .set_dnd,
        .kind = .action,
        .description = "Enable or disable Do Not Disturb mode",
        .params_schema = "{\"enabled\": boolean}",
        .description_order = 76,
    },
    .{
        .id = .clear_notifications,
        .kind = .action,
        .description = "Clear closed notification history",
        .params_schema = "{}",
        .description_order = 77,
    },
    .{
        .id = .restart_shell,
        .kind = .action,
        .description = "Restart the compositor in place; disconnects all applications",
        .description_order = 78,
    },
    .{
        .id = .get_animations,
        .kind = .query,
        .description = "Inspect live animations: site, value, velocity, target, settled, curve",
        .params_schema = "{}",
        .description_order = 79,
    },
    .{
        .id = .pinch,
        .automation = true,
        .kind = .action,
        .description = "Inject a touchpad pinch gesture for camera zoom tests",
        .params_schema = "{\"phase\": \"begin\" | \"update\" | \"end\", \"scale\"?: number, \"dx\"?: number, \"dy\"?: number, \"rotation\"?: number, \"fingers\"?: number, \"cancelled\"?: boolean}",
        .description_order = 80,
    },
    .{
        .id = .swipe,
        .automation = true,
        .kind = .action,
        .description = "Inject a touchpad swipe gesture for camera pan tests",
        .params_schema = "{\"phase\": \"begin\" | \"update\" | \"end\", \"dx\"?: number, \"dy\"?: number, \"fingers\"?: number, \"cancelled\"?: boolean}",
        .description_order = 81,
    },
    .{
        .id = .undo,
        .kind = .action,
        .description = "Undo the last spatial action (move, resize, zoom, pan, or focus change)",
        .params_schema = "{}",
        .description_order = 82,
    },
    .{
        .id = .set_output_config,
        .kind = .action,
        .description = "Apply and persist output mode, transform, position, scale and enable policy; auto clears scale or position overrides",
        .params_schema = "{\"output\": string, \"width\"?: number, \"height\"?: number, \"refresh_mhz\"?: number, \"transform\"?: string, \"x\"?: number, \"y\"?: number, \"scale\"?: number | \"auto\", \"position\"?: \"auto\", \"enabled\"?: boolean, \"primary\"?: boolean}",
        .units = "width/height: device pixels; refresh_mhz: millihertz; x/y: logical pixels; scale: 1–3",
        .description_order = 83,
        .cli = .{ .name = "output-config", .synopsis = "<output> [--width <PX>] [--height <PX>] [--refresh-mhz <MHZ>] [--transform <normal|90|180|270|flipped|flipped_90|flipped_180|flipped_270>] [--x <X>] [--y <Y>] [--scale <1..3|auto>] [--position auto] [--enabled|--disabled] [--primary|--no-primary]" },
    },
    .{
        .id = .get_text_input,
        .kind = .query,
        .description = "Inspect input-method state and candidate placement without text contents",
        .description_order = 84,
        .cli = .{ .name = "text-input" },
    },
    .{
        .id = .get_keyboard_layouts,
        .kind = .query,
        .description = "Inspect layouts and zero-based active index of the last active non-synthetic keyboard",
        .description_order = 85,
        .cli = .{ .name = "keyboard-layouts" },
    },
    .{
        .id = .switch_layout,
        .kind = .action,
        .description = "Switch the active keyboard layout; index is zero-based",
        .params_schema = "{\"layout\": \"next\" | \"prev\" | number}",
        .description_order = 86,
        .cli = .{ .name = "switch-layout", .synopsis = "<next|prev|index>" },
    },
    .{
        .id = .list_panels,
        .kind = .query,
        .description = "List registered UI panels and their open state",
        .params_schema = "{}",
        .description_order = 87,
        .cli = .{ .name = "panels", .aliases = &.{"list-panels"}, .synopsis = "" },
    },
    .{
        .id = .click_widget,
        .automation = true,
        .kind = .action,
        .description = "Click a named widget in an open shell panel",
        .params_schema = "{\"path\": string, \"button\"?: number, \"at\"?: number | [number, number] | {\"x\": number, \"y\": number}}",
        .description_order = 88,
    },
    .{
        .id = .hover_widget,
        .automation = true,
        .kind = .action,
        .description = "Hover over a named widget in an open shell panel",
        .params_schema = "{\"path\": string, \"at\"?: number | [number, number] | {\"x\": number, \"y\": number}}",
        .description_order = 89,
    },
    .{ .id = .get_services, .kind = .query, .description = "Inspect system services, startup modes and boot activation times", .params_schema = "{}", .description_order = 90 },
    .{ .id = .set_service_mode, .kind = .action, .description = "Set boot startup policy; deferred is unsupported; on-demand requires an existing trigger", .params_schema = "{\"service\": string, \"mode\": \"on\" | \"deferred\" | \"on-demand\" | \"disabled\"}", .description_order = 91 },
    .{ .id = .get_sounds, .kind = .query, .description = "Inspect configured sound theme and registered sound events", .params_schema = "{}", .description_order = 92 },
    .{ .id = .play_sound, .kind = .action, .description = "Queue playback of an enabled sound event", .params_schema = "{\"event\": string}", .description_order = 93 },
    .{ .id = .get_wallpaper, .kind = .query, .description = "Inspect configured and displayed wallpaper and loading state", .params_schema = "{}", .description_order = 94 },
    .{ .id = .set_wallpaper, .kind = .action, .description = "Select and load wallpaper; empty path selects bundled default", .params_schema = "{\"path\": string, \"persist\"?: boolean}", .description_order = 95 },
    .{ .id = .get_theme, .kind = .query, .description = "Inspect effective theme tokens; colors are straight RGBA in 0..1", .params_schema = "{}", .description_order = 96 },
    .{ .id = .set_accent_color, .kind = .action, .description = "Apply accent color live and optionally save it", .params_schema = "{\"color\": \"#RRGGBB\" | \"#RRGGBBAA\", \"persist\"?: boolean}", .description_order = 97 },
    .{ .id = .get_processes, .kind = .query, .description = "Sample window-owning app processes for 200ms; CPU is 100 percent per logical CPU", .params_schema = "{}", .description_order = 98 },
    .{ .id = .set_night_light, .kind = .action, .description = "Apply night light settings respecting the configured schedule; temperature is 1700..10000 Kelvin", .params_schema = "{\"enabled\"?: boolean, \"temperature\"?: number, \"persist\"?: boolean}", .description_order = 99 },
};

pub fn RouteTag(comptime route: Route) type {
    comptime {
        @setEvalBranchQuota(200_000);
        var names: []const []const u8 = &.{};
        for (specs) |s| {
            if (@hasField(if (route == .query) protocol.Request else protocol.Action, @tagName(s.id))) {
                names = names ++ .{@tagName(s.id)};
            }
        }
        return @Enum(u8, .exhaustive, names, &std.simd.iota(u8, names.len));
    }
}

pub fn lookup(comptime route: Route, name: []const u8) ?RouteTag(route) {
    const map = comptime blk: {
        @setEvalBranchQuota(200_000);
        const Pair = struct { []const u8, RouteTag(route) };
        var pairs: []const Pair = &.{};
        for (specs) |s| {
            if (@hasField(if (route == .query) protocol.Request else protocol.Action, @tagName(s.id)))
                pairs = pairs ++ .{Pair{ s.wire(), @field(RouteTag(route), @tagName(s.id)) }};
        }
        break :blk std.StaticStringMap(RouteTag(route)).initComptime(pairs);
    };
    return map.get(name);
}

/// Whether `request` needs `[ipc] automation`. Internal requests
/// (`event_stream_filtered`) have no spec and never do.
pub fn requiresAutomation(request: protocol.Request) bool {
    return switch (request) {
        .action => |act| switch (act) {
            inline else => |_, tag| comptime automationCommand(@tagName(tag)),
        },
        inline else => |_, tag| comptime automationCommand(@tagName(tag)),
    };
}

fn automationCommand(comptime name: []const u8) bool {
    @setEvalBranchQuota(100_000);
    for (specs) |s| if (std.mem.eql(u8, @tagName(s.id), name)) return s.automation;
    return false;
}

pub const capabilities = blk: {
    @setEvalBranchQuota(100_000);
    var result: [specs.len][]const u8 = undefined;
    for (specs, 0..) |s, i| result[i] = s.wire();
    break :blk result;
};

pub const descriptions = blk: {
    var result: [specs.len]protocol.CommandDesc = undefined;
    for (specs) |s| result[s.description_order] = .{
        .name = @tagName(s.id),
        .kind = @tagName(s.kind),
        .description = s.description,
        .params_schema = s.params_schema,
        .units = s.units,
    };
    break :blk result;
};

comptime {
    @setEvalBranchQuota(800_000);
    for (std.meta.tags(CommandId)) |id| {
        var count: usize = 0;
        for (specs) |s| if (s.id == id) {
            count += 1;
        };
        if (count != 1) @compileError("expected one IPC spec for " ++ @tagName(id));
    }
    for (specs, 0..) |s, i| {
        if (s.description.len == 0 or s.params_schema.len == 0) @compileError("missing IPC description/schema");
        if (s.description_order >= specs.len) @compileError("invalid description order");
        for (specs[0..i]) |prev| {
            if (prev.description_order == s.description_order) @compileError("duplicate description order");
            if (std.mem.eql(u8, prev.wire(), s.wire())) @compileError("duplicate IPC wire name");
        }
    }
}

pub fn CliTag(comptime action_only: bool) type {
    comptime {
        @setEvalBranchQuota(100_000);
        var names: []const []const u8 = &.{};
        for (specs) |s| {
            const cli = if (action_only) s.action_cli else s.cli;
            if (cli != null) names = names ++ .{@tagName(s.id)};
        }
        return @Enum(u8, .exhaustive, names, &std.simd.iota(u8, names.len));
    }
}

pub fn lookupCli(comptime action_only: bool, name: []const u8) ?CliTag(action_only) {
    const map = comptime blk: {
        @setEvalBranchQuota(100_000);
        const Tag = CliTag(action_only);
        const Pair = struct { []const u8, Tag };
        var pairs: []const Pair = &.{};
        for (specs) |s| {
            if (if (action_only) s.action_cli else s.cli) |cli| {
                const names = &[_][]const u8{cli.name} ++ cli.aliases;
                for (names) |key| {
                    for (pairs) |pair| if (std.mem.eql(u8, key, pair[0])) {
                        @compileError("duplicate CLI spelling: " ++ key);
                    };
                    pairs = pairs ++ .{Pair{ key, @field(Tag, @tagName(s.id)) }};
                }
            }
        }
        break :blk std.StaticStringMap(Tag).initComptime(pairs);
    };
    return map.get(name);
}
