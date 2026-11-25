//! HDR on an `Output`: the `[[outputs]] hdr` and
//! `sdr_white` settings, what the display can do, whether the output pass
//! blends it in linear light (phase 2), and the HDR10 signal (phase 3): a
//! 10-bit render format and a PQ/BT.2020 image description committed with a
//! frame encoded for them, night light moved from the gamma table into the
//! encode, software cursors, and client gamma ramps refused. Decided per
//! frame (`hdr_policy.zig`); a refusal is remembered for the mode.

const std = @import("std");
const wlr = @import("wlroots");
const Output = @import("../Output.zig");
const Server = @import("../Server.zig");
const SceneOutput = @import("../scene_outputs.zig").SceneOutput;
const Encode = @import("../scene_output.zig").Encode;
const output_config = @import("config").output_config;
const policy = @import("hdr_policy.zig");
const edid_hdr = @import("edid_hdr.zig");
const night_color = @import("../night_light/color.zig");
const log = std.log.scoped(.output);

pub const Mode = output_config.Hdr;

pub const State = struct {
    policy: policy.State = .{},
    /// Software cursors are locked for the signal (wlroots' GLES2 cursor path
    /// cannot convert a cursor to PQ).
    cursor_locked: bool = false,
    /// The EDID's HDR static metadata, read the first time the signal is wanted.
    edid: ?edid_hdr.Static = null,
    edid_read: bool = false,
};

fn fourcc(code: *const [4]u8) u32 {
    return @as(u32, code[0]) | @as(u32, code[1]) << 8 | @as(u32, code[2]) << 16 | @as(u32, code[3]) << 24;
}
const format_sdr = fourcc("XR24"); // DRM_FORMAT_XRGB8888, wlroots' default
const formats_10bit = [_]u32{ fourcc("XR30"), fourcc("XB30") }; // XRGB2101010, XBGR2101010

/// The configured mode for this output; HDR is opt-in.
pub fn mode(output: *Output) Mode {
    return if (Output.configured(output.server, output.wlr_output)) |config| config.hdr else .off;
}

/// The configured SDR white level in nits.
pub fn sdrWhite(output: *Output) f32 {
    return if (Output.configured(output.server, output.wlr_output)) |config| config.sdr_white else output_config.sdr_white_default;
}

/// The white level the signal uses: the setting, capped at the peak the
/// display's EDID suggests for content, when it gives one.
pub fn sdrWhiteSent(output: *Output) f32 {
    const configured = sdrWhite(output);
    const peak = (output.hdr.edid orelse return configured).max_nits orelse return configured;
    return @floatCast(@min(@as(f64, configured), peak));
}

/// The display and driver can take an HDR10 signal: wlroots' DRM backend
/// fills these bits from the EDID and the connector's `Colorspace` and
/// `HDR_OUTPUT_METADATA` properties; other backends leave them empty.
pub fn supported(output: *Output) bool {
    const out = output.wlr_output;
    const pq: u32 = @intCast(@backingInt(wlr.color.TransferFunction.st2084_pq));
    const bt2020: u32 = @intCast(@backingInt(wlr.color.NamedPrimaries.bt2020));
    return out.supported_transfer_functions & pq != 0 and out.supported_primaries & bt2020 != 0;
}

/// The output has committed an HDR image description.
pub fn active(output: *Output) bool {
    return output.wlr_output.image_description != null;
}

/// The signal the next commit carries, or the output carries now.
pub fn signal(output: *Output) bool {
    return output.hdr.policy.pending orelse active(output);
}

/// The driver would not take the signal in this mode.
pub fn refused(output: *Output) bool {
    return output.hdr.policy.refused;
}

/// The output pass should blend this output in linear light: HDR is on, and
/// the output either can take HDR10 or is headless or nested, where the linear
/// pass, encoded back to sRGB, is how phase 2 is checked without a test hook.
/// A DRM display that cannot take HDR stays as it was. Never the greeter.
pub fn linearWanted(output: *Output) bool {
    if (output.server.greeter_mode or mode(output) != .on) return false;
    return !output.wlr_output.isDrm() or supported(output);
}

fn inputs(output: *Output) policy.Inputs {
    const out = output.wlr_output;
    return .{ .linear = linearWanted(output), .drm = out.isDrm(), .supported = supported(output), .lit = out.enabled and !output.power_off };
}

/// Before a frame: puts a switch of the signal on its state, after a test
/// commit, and has the output pass encode for what the commit will carry.
/// True when the frame must commit for it.
pub fn prepare(output: *Output, state: *wlr.Output.State) bool {
    const out = output.wlr_output;
    const key: policy.Key = .{ .width = out.width, .height = out.height, .refresh = out.refresh, .on = mode(output) == .on };
    var changes = false;
    if (policy.step(&output.hdr.policy, key, inputs(output), active(output))) |on| {
        if (on) {
            readEdid(output);
            if (enable(output, state)) {
                changes = true;
            } else {
                policy.refuse(&output.hdr.policy);
                log.warn("output '{s}': the driver refused an HDR10 signal in this mode; it stays SDR", .{out.name});
            }
        } else {
            state.allow_reconfiguration = true;
            state.setRenderFormat(format_sdr);
            changes = state.setImageDescription(null);
            if (!changes) output.hdr.policy.pending = null;
        }
        // The gamma table changes hands in the same commit: neutral under the
        // signal (night light moves into the encode, a client ramp is
        // refused), night light's again without it.
        if (changes) handOverGamma(output);
    }
    sync(output);
    return changes;
}

fn handOverGamma(output: *Output) void {
    if (signal(output)) if (output.color.external) |control| {
        control.fail();
        output.color.external = null;
    };
    output.color.key = null;
    output.server.night_light.retargetOutput(output);
}

// The first 10-bit format the driver takes with the description, tested
// without a buffer (wlroots allocates one for a render format change).
fn enable(output: *Output, state: *wlr.Output.State) bool {
    const description = imageDescription(output);
    for (formats_10bit) |format| {
        var copy = wlr.Output.State.init();
        defer copy.finish();
        copy.allow_reconfiguration = true;
        copy.setRenderFormat(format);
        if (!copy.setImageDescription(&description)) return false;
        if (!output.wlr_output.testState(&copy)) continue;
        state.allow_reconfiguration = true;
        state.setRenderFormat(format);
        return state.setImageDescription(&description);
    }
    return false;
}

/// PQ on BT.2020, with the display's own suggested range as mastering
/// metadata when its EDID gives one (zero is unknown).
fn imageDescription(output: *Output) wlr.Output.ImageDescription {
    var description: wlr.Output.ImageDescription = .{ .primaries = .bt2020, .transfer_function = .st2084_pq };
    wlr.color.primariesFromNamed(&description.mastering_display_primaries, .bt2020);
    if (output.hdr.edid) |edid| {
        if (edid.max_nits) |nits| {
            description.mastering_luminance.max = nits;
            description.max_cll = nits;
        }
        if (edid.min_nits) |nits| description.mastering_luminance.min = nits;
        if (edid.max_fall_nits) |nits| description.max_fall = nits;
    }
    return description;
}

/// A frame state was committed, or failed to. Only one that carries the
/// switch `prepare` put on it counts; the next `prepare` decides again.
pub fn committed(output: *Output, state: *const wlr.Output.State, success: bool) void {
    const asked = output.hdr.policy.pending orelse return;
    if (!state.committed.image_description) return;
    policy.committed(&output.hdr.policy, success, active(output));
    const now = active(output);
    const name = output.wlr_output.name;
    if (asked and now) {
        log.info("output '{s}': HDR10 on, SDR white at {d} cd/m²", .{ name, sdrWhiteSent(output) });
    } else if (asked and refused(output)) {
        log.warn("output '{s}': the HDR10 signal did not take; it stays SDR in this mode", .{name});
    } else if (!asked and !now) {
        log.info("output '{s}': HDR10 off", .{name});
    }
    if (now != output.hdr.cursor_locked) {
        output.wlr_output.lockSoftwareCursors(now);
        output.hdr.cursor_locked = now;
    }
    // A switch that did not take hands the gamma table back.
    if (now != asked) handOverGamma(output);
    sync(output);
}

/// Has the output pass blend `output` as wanted and encode for its signal.
/// Each call is cheap; a change repaints the output.
pub fn sync(output: *Output) void {
    const server = output.server;
    const scene_output = server.scene_outputs.get(output.wlr_output) orelse return;
    _ = server.output_renderer.setLinear(scene_output, linearWanted(output));
    _ = server.output_renderer.setEncode(scene_output, &encodeFor(output));
}

fn encodeFor(output: *Output) Encode {
    if (!signal(output)) {
        const white = sdrWhite(output);
        return .{ .sdr_white = if (white == output_config.sdr_white_default) 0 else white };
    }
    return .{ .pq = true, .sdr_white = sdrWhiteSent(output), .adjust = night_color.hdrAdjust(output.server.night_light.outputTemperature(output)) };
}

/// Hands the output pass what `sync` would for the output `scene_output`
/// draws, before each build (frames and captures alike).
pub fn syncLinear(server: *Server, scene_output: *SceneOutput) void {
    var it = server.outputs.iterator(.forward);
    while (it.next()) |output| {
        if (server.scene_outputs.get(output.wlr_output) != scene_output) continue;
        sync(output);
        return;
    }
}

/// After a settings change: syncs every output now, which repaints the ones
/// it changes, and asks each for a frame (which switches the signal).
pub fn syncAll(server: *Server) void {
    var it = server.outputs.iterator(.forward);
    while (it.next()) |output| {
        sync(output);
        output.wlr_output.scheduleFrame();
    }
}

/// A refused FP16 target or a failed PQ composition must not send SDR pixels
/// under the HDR signal. The next frame restores the SDR format and gamma.
pub fn buildFailed(output: *Output) void {
    policy.refuse(&output.hdr.policy);
    handOverGamma(output);
    output.wlr_output.scheduleFrame();
}

/// Capture from an output-sized composited image. A fullscreen HDR client's
/// scanout buffer can have a crop and has no retained SDR encode of its frame.
pub fn captureBuffer(output: *Output, scene_output: *SceneOutput, state: *wlr.Output.State, raw: bool) ?*wlr.Buffer {
    const pq = active(output);
    if (pq) output.wlr_output.lockAttachRender(true);
    defer if (pq) output.wlr_output.lockAttachRender(false);
    if (!output.server.buildOutputState(scene_output, state)) return null;
    if (!raw) {
        if (output.server.output_renderer.sdrCopy(scene_output)) |buffer| return buffer;
        if (pq) return null;
    }
    return state.buffer;
}

/// The last frame built for this output blended in linear light.
pub fn linear(output: *Output) bool {
    const scene_output = output.server.scene_outputs.get(output.wlr_output) orelse return false;
    return output.server.output_renderer.linear(scene_output);
}

/// The connector's EDID from sysfs (`card*-NAME/edid`, the connected one), once.
fn readEdid(output: *Output) void {
    if (output.hdr.edid_read) return;
    output.hdr.edid_read = true;
    const io = output.server.io;
    var dir = std.Io.Dir.cwd().openDir(io, "/sys/class/drm", .{ .iterate = true }) catch return;
    defer dir.close(io);
    const name = std.mem.span(output.wlr_output.name);
    var it = dir.iterate();
    while (it.next(io) catch return) |entry| {
        const dash = std.mem.indexOfScalar(u8, entry.name, '-') orelse continue;
        if (!std.mem.startsWith(u8, entry.name, "card") or !std.mem.eql(u8, entry.name[dash + 1 ..], name)) continue;
        var path_buf: [300]u8 = undefined;
        var status_buf: [16]u8 = undefined;
        const status_path = std.fmt.bufPrint(&path_buf, "{s}/status", .{entry.name}) catch continue;
        const status = dir.readFile(io, status_path, &status_buf) catch continue;
        if (!std.mem.startsWith(u8, status, "connected")) continue;
        var edid_buf: [4096]u8 = undefined;
        const edid_path = std.fmt.bufPrint(&path_buf, "{s}/edid", .{entry.name}) catch continue;
        const edid = dir.readFile(io, edid_path, &edid_buf) catch continue;
        output.hdr.edid = edid_hdr.parse(edid);
        if (output.hdr.edid) |found| {
            log.info("output '{s}': EDID HDR metadata: PQ {}, peak {?d:.0}, frame average {?d:.0}, min {?d:.3} cd/m²", .{ name, found.pq, found.max_nits, found.max_fall_nits, found.min_nits });
        }
        return;
    }
}
