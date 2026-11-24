//! HDR on an `Output` (docs/plans/hdr.md): the `[[outputs]] hdr` and
//! `sdr_white` settings, what the display can do, and whether the output pass
//! blends it in linear light (phase 2, encoded back to sRGB until phase 3
//! sends PQ; no image description is committed yet, so `active` stays false).

const wlr = @import("wlroots");
const Output = @import("../Output.zig");
const Server = @import("../Server.zig");
const SceneOutput = @import("../scene_outputs.zig").SceneOutput;
const output_config = @import("config").output_config;

pub const Mode = output_config.Hdr;

/// The configured mode for this output; HDR is opt-in.
pub fn mode(output: *Output) Mode {
    return if (Output.configured(output.server, output.wlr_output)) |config| config.hdr else .off;
}

/// The configured SDR white level in nits.
pub fn sdrWhite(output: *Output) f32 {
    return if (Output.configured(output.server, output.wlr_output)) |config| config.sdr_white else output_config.sdr_white_default;
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

/// The output pass should blend this output in linear light: HDR is on, and
/// the output either can take HDR10 or is headless or nested, where the linear
/// pass, encoded back to sRGB, is how phase 2 is checked without a test hook.
/// A DRM display that cannot take HDR stays as it was. Never the greeter.
pub fn linearWanted(output: *Output) bool {
    if (output.server.greeter_mode or mode(output) != .on) return false;
    return !output.wlr_output.isDrm() or supported(output);
}

/// Hands the output pass `linearWanted` for the output `scene_output` draws,
/// before each build (frames and captures alike); the pass does nothing when
/// it is unchanged.
pub fn syncLinear(server: *Server, scene_output: *SceneOutput) void {
    var it = server.outputs.iterator(.forward);
    while (it.next()) |output| {
        if (server.scene_outputs.get(output.wlr_output) != scene_output) continue;
        _ = server.output_renderer.setLinear(scene_output, linearWanted(output));
        return;
    }
}

/// After a settings change: hands every output its `linearWanted` now, which
/// repaints the outputs it changes, and asks each for a frame.
pub fn syncAll(server: *Server) void {
    var it = server.outputs.iterator(.forward);
    while (it.next()) |output| {
        const scene_output = server.scene_outputs.get(output.wlr_output) orelse continue;
        _ = server.output_renderer.setLinear(scene_output, linearWanted(output));
        output.wlr_output.scheduleFrame();
    }
}

/// The last frame built for this output blended in linear light.
pub fn linear(output: *Output) bool {
    const scene_output = output.server.scene_outputs.get(output.wlr_output) orelse return false;
    return output.server.output_renderer.linear(scene_output);
}
