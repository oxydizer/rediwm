//! Server outputs: bringing up a new output.

const std = @import("std");
const Server = @import("../Server.zig");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const Output = @import("../Output.zig");
const geometry = @import("../geometry.zig");
const log = std.log.scoped(.compositor);

pub fn newOutput(listener: *wl.Listener(*wlr.Output), wlr_output: *wlr.Output) void {
    const server: *Server = @fieldParentPtr("new_output", listener);

    // wlroots' own `wlr_ext_image_capture_source_v1_create_with_scene_node`
    // (capture/manager.zig, stage 3 window capture) creates a private
    // `non_desktop` output to render a captured scene node, and drives it
    // entirely itself. Before this check existed, this handler treated it
    // like any other monitor — enabling it, attaching the *whole* scene via
    // `Output.create`, and adding it to the layout — which raced wlroots'
    // own internal rendering and made a window capture show whatever
    // happened to be on top on the real desktop instead of that window's
    // own isolated content (caught by `run_window_occlusion_case`: a
    // captured background window showed its occluder's color). `non_desktop`
    // is the standard wlroots signal (also used for VR/HMD outputs) that a
    // compositor must leave an output alone rather than treat it as a
    // desktop monitor.
    if (wlr_output.non_desktop) {
        @import("../extra_protocols.zig").rediwm_protocols_offer(server.extra_protocols, wlr_output);
        log.debug("newOutput: excluding non-desktop output {s} from desktop layout", .{wlr_output.name});
        return;
    }

    if (!wlr_output.initRender(server.allocator, server.renderer)) {
        log.err("newOutput: initRender failed for {s}", .{wlr_output.name});
        return;
    }

    var state = wlr.Output.State.init();
    defer state.finish();

    state.setEnabled(true);
    const saved = Output.configuredMode(server, wlr_output);
    const preferred = if (saved) |mode| mode.advertised else wlr_output.preferredMode() orelse wlr_output.modes.first();
    const output_scale = if (saved) |mode|
        Output.scaleForDimensions(server, wlr_output, mode.width, mode.height)
    else
        Output.scaleForMode(server, wlr_output, preferred);
    state.setScale(output_scale);
    // Rotated now, so the size others are placed around is final at once.
    state.setTransform(Output.wlTransform(Output.configuredTransform(server, wlr_output)));
    if (saved) |mode| {
        mode.setState(&state);
    } else if (preferred) |mode| {
        // A real display's mode is already in device pixels; the scale only
        // changes the logical size derived from it.
        state.setMode(mode);
    } else {
        // Backends without modes (nested, headless) size themselves as though
        // the scale were 1, so the buffer has to be enlarged to match it.
        state.setCustomMode(
            geometry.devicePixels(wlr_output.width, output_scale),
            geometry.devicePixels(wlr_output.height, output_scale),
            0,
        );
    }
    if (!wlr_output.commitState(&state)) {
        // A preferred mode can exceed available link bandwidth. Try only
        // modes advertised by this connector before giving up on the display.
        var modes = wlr_output.modes.iterator(.forward);
        var recovered = false;
        while (modes.next()) |mode| {
            if (mode == preferred) continue;
            state.setMode(mode);
            state.setScale(Output.scaleForMode(server, wlr_output, mode));
            if (wlr_output.commitState(&state)) {
                recovered = true;
                log.warn("output {s}: preferred mode rejected; using {d}x{d}@{d} mHz", .{ wlr_output.name, mode.width, mode.height, mode.refresh });
                break;
            }
        }
        if (!recovered) {
            log.err("newOutput: no usable mode for {s}", .{wlr_output.name});
            return;
        }
    }

    log.info("output {s}: {d}x{d}@{d:.2} Hz, {d}x{d} mm, scale {d}", .{ wlr_output.name, wlr_output.width, wlr_output.height, @as(f64, @floatFromInt(wlr_output.refresh)) / 1000, wlr_output.phys_width, wlr_output.phys_height, wlr_output.scale });

    Output.create(server, wlr_output) catch |err| {
        log.err("newOutput: could not create output {s}: {}", .{ wlr_output.name, err });
        wlr_output.destroy();
        return;
    };
    if (server.xwayland) |xw| xw.refreshScale();
}
