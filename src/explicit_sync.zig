// Explicit synchronization (wp_linux_drm_syncobj_v1) for client buffers read
// outside wlr_scene's output rendering. See explicit_sync.c.
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");

extern fn rediwm_explicit_sync_supported(renderer: *wlr.Renderer, backend_timeline: bool) bool;
pub fn supported(renderer: *wlr.Renderer, backend: *wlr.Backend) bool {
    return rediwm_explicit_sync_supported(renderer, backend.features.timeline);
}
extern fn rediwm_surface_explicit_sync(surface: *wlr.Surface) bool;
pub const surfaceUsesIt = rediwm_surface_explicit_sync;

/// Release points for GPU passes that sample client buffers. Every function
/// accepts null (no timeline support) and then does nothing.
pub const ReadFence = opaque {
    extern fn rediwm_read_fence_create(renderer: *wlr.Renderer, loop: *wl.EventLoop) ?*ReadFence;
    pub const create = rediwm_read_fence_create;
    extern fn rediwm_read_fence_destroy(fence: ?*ReadFence) void;
    pub const destroy = rediwm_read_fence_destroy;
    extern fn rediwm_read_fence_begin(fence: ?*ReadFence, options: *wlr.Renderer.BufferPassOptions) void;
    pub const begin = rediwm_read_fence_begin;
    extern fn rediwm_read_fence_note(fence: ?*ReadFence, surface: *wlr.Surface) void;
    pub const note = rediwm_read_fence_note;
    extern fn rediwm_read_fence_end(fence: ?*ReadFence, submitted: bool) void;
    pub const end = rediwm_read_fence_end;
};

/// Readiness of a surface's current buffer for CPU reads, which cannot wait
/// on the GPU; `ready` is called from the event loop once a pending buffer is.
pub const AcquireWait = opaque {
    extern fn rediwm_acquire_wait_create(loop: *wl.EventLoop, ready: *const fn (?*anyopaque) callconv(.c) void, data: ?*anyopaque) ?*AcquireWait;
    pub const create = rediwm_acquire_wait_create;
    extern fn rediwm_acquire_wait_destroy(wait: ?*AcquireWait) void;
    pub const destroy = rediwm_acquire_wait_destroy;
    extern fn rediwm_acquire_wait_ready(wait: ?*AcquireWait, surface: *wlr.Surface) bool;
    pub const ready = rediwm_acquire_wait_ready;
    extern fn rediwm_acquire_wait_cancel(wait: ?*AcquireWait) void;
    pub const cancel = rediwm_acquire_wait_cancel;
};
