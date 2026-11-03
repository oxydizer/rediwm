//! Client-buffer synchronization for switcher thumbnails. Geometry and frame
//! callbacks stay with Switcher; the binding never changes output/scale feedback.
const sn = @import("../node.zig");
const wlr = @import("wlroots");

extern fn rediwm_switcher_preview_set_surface(preview: *sn.Buffer, surface: ?*wlr.Surface) bool;

/// Refresh on every source commit, and pass null to clear. The preview node owns
/// the binding; its destruction or the source's destruction detaches it safely.
pub const setSurface = rediwm_switcher_preview_set_surface;
