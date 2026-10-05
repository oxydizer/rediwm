//! A per-request, compositor-owned `ext_image_capture_source_v1` that
//! renders only `Toplevel.content_tree`'s own subtree, independent of
//! whatever else is compositing on top of it in the live scene.
//!
//! This exists because `wlr_ext_image_capture_source_v1_create_with_scene_node`
//! (the wlroots 0.20 helper `manager.zig` tried first) does not provide that
//! isolation in practice: empirically, via a real two-window protocol test
//! (`run_window_occlusion_case` in tests/capture.py), a capture of a window
//! sitting *underneath* another one returned the occluding window's pixels,
//! not its own. The helper's synthetic render target is never registered
//! with this compositor's backend (`Server.newOutput` never sees it, so
//! it isn't our own scene-attachment logic at fault) — it appears to
//! composite the live scene at the node's on-screen position rather than
//! rendering the node's subtree in isolation. That directly fails
//! docs/screen-sharing.md's "Occlusion and camera pan must not reveal
//! another window or crop the chosen one," which for a screen-sharing
//! feature is a real content-leak risk, not a cosmetic bug.
//!
//! The owned source adapter stays small on purpose: no
//! general transform stack, no damage tracking, no output attachment —
//! just `wlr_scene_node_for_each_buffer` (the primitive wlroots itself
//! documents for screen recorders that need exactly this) walked into an
//! owned swapchain buffer once per `request_frame`.
const std = @import("std");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const col = @import("../color.zig");
const pixman = @import("pixman");
const explicit_sync = @import("../explicit_sync.zig");

const Output = @import("../Output.zig");
const Toplevel = @import("../Toplevel.zig");
const gpa = @import("../main.zig").gpa;

const log = std.log.scoped(.capture);

const DRM_FORMAT_ARGB8888: u32 = 0x34325241;

// Not bound in the pinned zig-wlroots package; declared directly the same
// way every other binding file in that package declares its extern fns.
// Fills in the well-known CIE1931 xy chromaticities for a named primary set
// so `wlr.RenderPass.TextureOptions.primaries` isn't left pointing at
// uninitialized memory.
extern fn wlr_color_primaries_from_named(out: *wlr.color.Primaries, named: wlr.color.NamedPrimaries) void;

pub const WindowCaptureSource = struct {
    base: wlr.ExtImageCaptureSourceV1,
    manager: *@import("manager.zig").Manager,
    /// Stable id, not a live `*Toplevel`: resolved back through
    /// `Server.findToplevelById` on every render, so this struct's
    /// lifetime never depends on the toplevel outliving it.
    window_id: u64,
    /// `&toplevel.content_tree.node` — the capture root. Never
    /// `frame_tree`/`shadow_tree`: docs/screen-sharing.md's "Separate
    /// monitor and window semantics" excludes server decorations, shadows,
    /// and backdrop glass, which can sample unrelated windows.
    content_node: *wlr.SceneNode,
    node_destroy: wl.Listener(void) = .init(handleNodeDestroy),

    swapchain: ?*wlr.Swapchain = null,
    swap_width: c_int = 0,
    swap_height: c_int = 0,
    /// Set once per (re)created swapchain, right after the first successful
    /// `acquire()` from it — see `renderFrame`'s comment on why constraints
    /// can't be derived before a real buffer exists to inspect.
    constraints_set: bool = false,
    /// Locked with the swapchain's own lock; unlocked when replaced or on
    /// destroy. `copy_frame` blits from this into whatever buffer the
    /// client attached to its frame request.
    last_buffer: ?*wlr.Buffer = null,

    link: wl.list.Link = undefined,

    const impl: wlr.ExtImageCaptureSourceV1.Interface = .{
        .start = null,
        .stop = null,
        .request_frame = requestFrame,
        .copy_frame = copyFrame,
        .get_pointer_cursor = null,
    };

    pub fn create(manager: *@import("manager.zig").Manager, toplevel: *Toplevel) !*WindowCaptureSource {
        const self = try gpa.create(WindowCaptureSource);
        errdefer gpa.destroy(self);
        self.* = .{
            .base = undefined,
            .manager = manager,
            .window_id = toplevel.id,
            .content_node = &toplevel.content_tree.node,
        };
        self.base.init(&impl);
        toplevel.content_tree.node.events.destroy.add(&self.node_destroy);
        // The core ext-image-copy-capture machinery sends a session's
        // initial buffer_size/shm_format/dmabuf_format/done burst right
        // when the session is created — using whatever constraints the
        // source already has *at that moment* — not lazily on the first
        // `request_frame`. `request.accept()` (this function's only
        // caller) can be immediately followed by the client creating a
        // session, so constraints must already be real before this
        // returns, not just before the first frame is requested.
        self.renderFrame() catch |err| {
            log.warn("window capture source (window {d}): initial render failed: {}", .{ toplevel.id, err });
        };
        return self;
    }

    fn handleNodeDestroy(listener: *wl.Listener(void)) void {
        const self: *WindowCaptureSource = @fieldParentPtr("node_destroy", listener);
        self.destroy();
    }

    /// Tears itself down when the window closes. `base.finish()` emits
    /// `events.destroy` itself (the stage-0 spike's gotcha note — listeners
    /// on a source's `destroy`/`constraints_update` must be gone before
    /// `finish()`'s own list teardown runs — implies as much); the core
    /// ext-image-copy-capture session machinery listens for that internally
    /// and sends any live client a graceful `stopped` event, no forced
    /// disconnect needed for this path (unlike minimizing, which hides the
    /// frame without destroying anything and so still needs
    /// `Manager.stopForWindow`'s hard fallback — see `Toplevel.minimize`).
    fn destroy(self: *WindowCaptureSource) void {
        self.node_destroy.link.remove();
        self.link.remove();
        if (self.last_buffer) |b| b.unlock();
        if (self.swapchain) |sc| sc.destroy();
        self.base.finish();
        gpa.destroy(self);
    }

    const Geometry = struct { x: i32, y: i32, width: i32, height: i32 };

    /// The window's own logical content box (xdg_surface geometry), in
    /// content_tree-local coordinates. Popups/subsurfaces overflowing this
    /// box are cropped by the destination buffer's own size for now — a
    /// documented v1 simplification, matching the plan's allowance that
    /// "a documented 1x logical raster is acceptable" before promising
    /// full popup-bounds correctness.
    fn geometry(self: *WindowCaptureSource) ?Geometry {
        const toplevel = self.manager.server.findToplevelById(self.window_id) orelse return null;
        const box = toplevel.clientSurfaceGeometry();
        if (box.width <= 0 or box.height <= 0) return null;
        return .{ .x = box.x, .y = box.y, .width = box.width, .height = box.height };
    }

    fn requestFrame(source: *wlr.ExtImageCaptureSourceV1, schedule_frame: bool) callconv(.c) void {
        // v1: always render immediately. Real damage-driven scheduling
        // (docs/screen-sharing.md's "demand/damage-driven
        // capture") is a stage-4 reliability concern, not a stage-3
        // correctness one; this is simple and correct, just not maximally
        // efficient against a fast-polling consumer.
        _ = schedule_frame;
        const self: *WindowCaptureSource = @fieldParentPtr("base", source);
        self.renderFrame() catch |err| {
            log.warn("window capture source (window {d}): render failed: {}", .{ self.window_id, err });
        };
    }

    const RenderCtx = struct {
        pass: *wlr.RenderPass,
        renderer: *wlr.Renderer,
        read_fence: ?*explicit_sync.ReadFence,
        primaries: *const wlr.color.Primaries,
        off_x: i32,
        off_y: i32,
    };

    fn renderFrame(self: *WindowCaptureSource) !void {
        const geom = self.geometry() orelse return error.NoGeometry;
        const server = self.manager.server;

        if (self.swapchain == null or self.swap_width != geom.width or self.swap_height != geom.height) {
            if (self.swapchain) |sc| sc.destroy();
            self.swapchain = null;
            const format = pickFormat(server.renderer);
            self.swapchain = try wlr.Swapchain.create(server.allocator, geom.width, geom.height, @constCast(format));
            self.swap_width = geom.width;
            self.swap_height = geom.height;
            self.constraints_set = false;
        }

        const buffer = try self.swapchain.?.acquire();
        // Deriving shm/dmabuf constraints needs a real allocated buffer to
        // inspect (its concrete modifier/stride aren't known from the
        // swapchain's candidate format list alone) — calling this before
        // the first `acquire()` above left `shm_formats_len` at 0 and the
        // client's session never got a `shm_format` event at all.
        if (!self.constraints_set) {
            _ = self.base.setContraintsFromSwapchain(self.swapchain.?, server.renderer);
            self.constraints_set = true;
        }
        // The window may be hidden or culled, so no output render covers
        // explicit-sync buffers this pass reads; it signals its own release.
        var pass_options: wlr.Renderer.BufferPassOptions = .{};
        explicit_sync.ReadFence.begin(server.read_fence, &pass_options);
        const pass = server.renderer.beginBufferPass(buffer, &pass_options) catch |err| {
            explicit_sync.ReadFence.end(server.read_fence, false);
            buffer.unlock();
            return err;
        };

        // Clear to transparent first: areas the window's own buffers don't
        // cover (e.g. while resizing) must not show stale content from a
        // previous, differently-shaped render into a reused swapchain slot.
        pass.addRect(&.{
            .box = .{ .x = 0, .y = 0, .width = geom.width, .height = geom.height },
            .color = col.Premul.transparent.renderColor(),
            .clip = null,
            .blend_mode = .none,
        });

        var primaries: wlr.color.Primaries = undefined;
        wlr_color_primaries_from_named(&primaries, .srgb);
        var ctx: RenderCtx = .{
            .pass = pass,
            .renderer = server.renderer,
            .read_fence = server.read_fence,
            .primaries = &primaries,
            .off_x = geom.x,
            .off_y = geom.y,
        };
        self.content_node.forEachBuffer(*RenderCtx, renderNodeBuffer, &ctx);

        const submitted = pass.submit();
        explicit_sync.ReadFence.end(server.read_fence, submitted);
        if (!submitted) {
            buffer.unlock();
            return error.RenderFailed;
        }

        if (self.last_buffer) |old| old.unlock();
        self.last_buffer = buffer;

        var damage: pixman.Region32 = undefined;
        damage.initRect(0, 0, @intCast(geom.width), @intCast(geom.height));
        defer damage.deinit();
        var frame_event: wlr.ExtImageCaptureSourceV1.event.Frame = .{ .damage = &damage };
        self.base.events.frame.emit(&frame_event);
    }

    /// `wlr_scene_node_for_each_buffer` gives `sx`/`sy` relative to the
    /// node we started from (`content_node`), already accounting for every
    /// ancestor's position up to (not including) it — exactly the "render
    /// only this subtree" primitive wlroots documents for screen recorders.
    /// Only enabled/visible buffers are visited, matching how the compositor
    /// already relies on `setEnabled(false)` to hide nodes from real output
    /// rendering elsewhere (e.g. `screenshot/capture.zig`'s isolation mode).
    fn renderNodeBuffer(scene_buffer: *wlr.SceneBuffer, sx: c_int, sy: c_int, ctx: *RenderCtx) void {
        const buf = scene_buffer.buffer orelse return;
        const texture = wlr.Texture.fromBuffer(ctx.renderer, buf) orelse return;
        defer texture.destroy();
        if (wlr.SceneSurface.tryFromBuffer(scene_buffer)) |scene_surface| {
            explicit_sync.ReadFence.note(ctx.read_fence, scene_surface.surface);
        }

        var alpha = scene_buffer.opacity;
        var luminance_multiplier: f32 = 1.0;
        ctx.pass.addTexture(&.{
            .texture = texture,
            .src_box = scene_buffer.src_box,
            .dst_box = .{
                .x = sx - ctx.off_x,
                .y = sy - ctx.off_y,
                .width = scene_buffer.dst_width,
                .height = scene_buffer.dst_height,
            },
            .alpha = &alpha,
            .clip = null,
            .transform = scene_buffer.transform,
            .filter_mode = scene_buffer.filter_mode,
            .blend_mode = .premultiplied,
            .transfer_function = .srgb,
            .primaries = ctx.primaries,
            .color_encoding = .none,
            .color_range = .full,
            .luminance_multiplier = &luminance_multiplier,
            .wait_timeline = scene_buffer.private.wait_timeline,
            .wait_point = scene_buffer.private.wait_point,
        });
    }

    fn copyFrame(
        source: *wlr.ExtImageCaptureSourceV1,
        dst_frame: *wlr.ExtImageCopyCaptureFrameV1,
        frame_event: *wlr.ExtImageCaptureSourceV1.event.Frame,
    ) callconv(.c) void {
        _ = frame_event;
        const self: *WindowCaptureSource = @fieldParentPtr("base", source);
        // Only reachable after a successful `renderFrame` set `last_buffer`
        // and emitted `events.frame` — the only thing that causes the core
        // ext-image-copy-capture machinery to call `copy_frame` at all — so
        // this is defensive, not a real path (a failed render never emits).
        const buf = self.last_buffer orelse {
            log.warn("window capture source (window {d}): copy_frame called with no rendered buffer", .{self.window_id});
            return;
        };
        dst_frame.copyBuffer(buf, self.manager.server.renderer);
        var now = Output.timestamp();
        dst_frame.ready(.normal, &now);
    }
};

fn pickFormat(renderer: *wlr.Renderer) *const wlr.DrmFormat {
    const set = renderer.getTextureFormats(renderer.render_buffer_caps).?;
    return set.get(DRM_FORMAT_ARGB8888);
}
