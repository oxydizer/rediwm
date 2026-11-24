//! HDR on an `Output` (docs/plans/hdr.md): the `[[outputs]] hdr` and
//! `sdr_white` settings and what the display can do. Phase 1 stops here:
//! nothing renders or commits differently yet, so `active` stays false.

const wlr = @import("wlroots");
const Output = @import("../Output.zig");
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
