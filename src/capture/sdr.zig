//! SDR captures of outputs that blend in linear light (capture_sdr.h,
//! docs/plans/hdr.md phase 5): screencopy frames and ext-image-copy-capture
//! output sources copy an sRGB encode of the frame instead of a buffer that
//! may hold PQ.
const wlr = @import("wlroots");
const Renderer = @import("../scene_output.zig").Renderer;
const SceneOutputs = @import("../scene_outputs.zig").SceneOutputs;

extern var rediwm_capture_sdr_copies: u64;
/// Captures served from an SDR encode, for the performance stats.
pub const copies: *u64 = &rediwm_capture_sdr_copies;

pub const CaptureSdr = opaque {
    extern fn rediwm_capture_sdr_create(renderer: *Renderer, outputs: *SceneOutputs) ?*CaptureSdr;
    pub const create = rediwm_capture_sdr_create;
    extern fn rediwm_capture_sdr_destroy(sdr: ?*CaptureSdr) void;
    pub const destroy = rediwm_capture_sdr_destroy;
    extern fn rediwm_capture_sdr_wrap_source(sdr: *CaptureSdr, source: *wlr.ExtImageCaptureSourceV1) void;
    pub const wrapSource = rediwm_capture_sdr_wrap_source;
    extern fn rediwm_capture_sdr_source_output(sdr: *CaptureSdr, source: *wlr.ExtImageCaptureSourceV1) ?*wlr.Output;
    pub const sourceOutput = rediwm_capture_sdr_source_output;
    extern fn rediwm_capture_sdr_take_screencopy(sdr: *CaptureSdr, frame: *wlr.ScreencopyFrameV1) void;
    pub const takeScreencopy = rediwm_capture_sdr_take_screencopy;
};
