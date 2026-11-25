//! The player's window: an xdg toplevel whose root surface is a black
//! single-pixel buffer (letterbox bars), with the video in a desynchronized
//! subsurface scaled by its viewport. Video commits never touch the root.
const std = @import("std");
const wl = @import("wayland").client.wl;
const wp = @import("wayland").client.wp;
const xdg = @import("wayland").client.xdg;
const zxdg = @import("wayland").client.zxdg;
const zwp = @import("wayland").client.zwp;
const Osd = @import("osd.zig").Osd;
const Drop = @import("drop.zig").Drop;
const Feedback = @import("feedback.zig").Feedback;
const Input = @import("keyboard.zig").Input;
const Pacing = @import("clock.zig").Pacing;
const a = std.heap.c_allocator;

pub const Coefficients = wp.ColorRepresentationSurfaceV1.Coefficients;
pub const Range = wp.ColorRepresentationSurfaceV1.Range;

/// How a video buffer is shown: its visible part and colour encoding.
pub const Frame = struct {
    buffer: *wl.Buffer,
    /// Visible rectangle in buffer pixels.
    crop_x: i32 = 0,
    crop_y: i32 = 0,
    crop_w: i32,
    crop_h: i32,
    coefficients: ?Coefficients = null,
    range: ?Range = null,
};

pub const Window = struct {
    display: *wl.Display,
    registry: *wl.Registry = undefined,
    compositor: ?*wl.Compositor = null,
    subcompositor: ?*wl.Subcompositor = null,
    shm: ?*wl.Shm = null,
    ten_bit: bool = false,
    input: Input = .{},
    osd: Osd = .{},
    subtitles: @import("subtitle_overlay.zig").Overlay = .{},
    drop: Drop = .{},
    scales: ?*wp.FractionalScaleManagerV1 = null,
    idle_manager: ?*zwp.IdleInhibitManagerV1 = null,
    inhibitor: ?*zwp.IdleInhibitorV1 = null,
    content_manager: ?*wp.ContentTypeManagerV1 = null,
    root_hint: ?*wp.ContentTypeV1 = null,
    video_hint: ?*wp.ContentTypeV1 = null,
    pacing: Pacing = .{},
    commit_timing: ?*wp.CommitTimingManagerV1 = null,
    wm_base: ?*xdg.WmBase = null,
    decoration_manager: ?*zxdg.DecorationManagerV1 = null,
    viewporter: ?*wp.Viewporter = null,
    single_pixel: ?*wp.SinglePixelBufferManagerV1 = null,
    dmabuf: ?*zwp.LinuxDmabufV1 = null,
    representation: ?*wp.ColorRepresentationManagerV1 = null,
    /// Coefficient and range pairs the compositor accepts.
    encodings: std.ArrayList(struct { Coefficients, Range }) = .empty,
    feedback: Feedback = .{},

    root: *wl.Surface = undefined,
    root_viewport: *wp.Viewport = undefined,
    black: *wl.Buffer = undefined,
    xdg_surface: *xdg.Surface = undefined,
    toplevel: *xdg.Toplevel = undefined,
    decoration: ?*zxdg.ToplevelDecorationV1 = null,
    video: *wl.Surface = undefined,
    subsurface: *wl.Subsurface = undefined,
    video_viewport: *wp.Viewport = undefined,
    video_encoding: ?*wp.ColorRepresentationSurfaceV1 = null,

    /// Logical window size, and the video's display aspect (w / h).
    width: i32 = 0,
    height: i32 = 0,
    aspect: f64 = 16.0 / 9.0,
    default_width: i32 = 960,
    default_height: i32 = 540,
    pending_width: i32 = 0,
    pending_height: i32 = 0,
    configured: bool = false,
    closed: bool = false,

    shown: ?Frame = null,
    sent_coefficients: ?Coefficients = null,
    sent_range: ?Range = null,

    /// Binds what the player needs and reads the dmabuf feedback, which
    /// names the device to decode on.
    pub fn connect(self: *Window) !void {
        self.input.osd = &self.osd;
        self.registry = try self.display.getRegistry();
        self.registry.setListener(*Window, registryEvent, self);
        if (self.display.roundtrip() != .SUCCESS) return error.DisplayFailed;
        if (self.compositor == null or self.subcompositor == null or self.wm_base == null or
            self.shm == null or self.viewporter == null or self.single_pixel == null) return error.MissingWaylandGlobals;
        if (self.dmabuf) |dmabuf| try self.feedback.listen(dmabuf);
        if (self.input.seat) |seat| try self.drop.bind(seat);
        // Feedback and colour capabilities.
        if (self.display.roundtrip() != .SUCCESS) return error.DisplayFailed;
    }

    /// Creates the surfaces and maps the window; after `connect` and
    /// `setVideoSize`.
    pub fn map(self: *Window, title: []const u8, app_id: [:0]const u8) !void {
        const compositor = self.compositor.?;
        self.root = try compositor.createSurface();
        self.root_viewport = try self.viewporter.?.getViewport(self.root);
        self.black = try self.single_pixel.?.createU32RgbaBuffer(0, 0, 0, std.math.maxInt(u32));
        self.video = try compositor.createSurface();
        self.subsurface = try self.subcompositor.?.getSubsurface(self.video, self.root);
        self.subsurface.setDesync();
        if (self.commit_timing) |manager| self.pacing.timer = manager.getTimer(self.video) catch null;
        self.video_viewport = try self.viewporter.?.getViewport(self.video);
        // Input goes to the root; the video never takes it.
        const empty = try compositor.createRegion();
        self.video.setInputRegion(empty);
        empty.destroy();
        if (self.representation) |manager| self.video_encoding = manager.getSurface(self.video) catch null;

        try self.subtitles.create(compositor, self.subcompositor.?, self.viewporter.?, self.root, self.shm.?);
        try self.osd.create(compositor, self.subcompositor.?, self.viewporter.?, self.root, self.shm.?, self.scales);
        if (self.input.cursor.manager == null) {
            self.input.cursor_theme = @import("ui").client_cursor.loadFallback(self.shm.?);
            self.input.cursor_surface = try compositor.createSurface();
        }
        if (self.content_manager) |mgr| {
            self.root_hint = try mgr.getSurfaceContentType(self.root);
            self.video_hint = try mgr.getSurfaceContentType(self.video);
            self.root_hint.?.setContentType(.video);
            self.video_hint.?.setContentType(.video);
        }
        self.xdg_surface = try self.wm_base.?.getXdgSurface(self.root);
        self.xdg_surface.setListener(*Window, xdgSurfaceEvent, self);
        self.toplevel = try self.xdg_surface.getToplevel();
        self.input.toplevel = self.toplevel;
        self.toplevel.setListener(*Window, toplevelEvent, self);
        self.toplevel.setAppId(app_id);
        self.setTitle(title);
        self.toplevel.setMinSize(160, 90);
        if (self.decoration_manager) |manager| {
            self.decoration = manager.getToplevelDecoration(self.toplevel) catch null;
            if (self.decoration) |decoration| decoration.setMode(.server_side);
        }
        self.root.commit();
    }

    pub fn setTitle(self: *Window, title: []const u8) void {
        var title_buf: [256]u8 = undefined;
        const n = @min(title.len, title_buf.len - 1);
        @memcpy(title_buf[0..n], title[0..n]);
        title_buf[n] = 0;
        self.toplevel.setTitle(title_buf[0..n :0]);
    }

    pub fn playing(self: *Window, active: bool) void {
        const mgr = self.idle_manager orelse return;
        const want = active and self.configured and self.shown != null;
        if (want and self.inhibitor == null) self.inhibitor = mgr.createInhibitor(self.video) catch null;
        if (!want and self.inhibitor != null) {
            self.inhibitor.?.destroy();
            self.inhibitor = null;
        }
    }

    pub fn deinit(self: *Window) void {
        self.playing(false);
        if (self.idle_manager) |mgr| mgr.destroy();
        if (self.root_hint) |hint| hint.destroy();
        if (self.video_hint) |hint| hint.destroy();
        if (self.content_manager) |mgr| mgr.destroy();
        self.drop.deinit();
        self.osd.deinit();
        self.subtitles.deinit();
        if (self.scales) |mgr| mgr.destroy();
        if (self.decoration) |decoration| decoration.destroy();
        self.input.deinit();
        if (self.pacing.pending) |fb| fb.destroy();
        if (self.pacing.timer) |timer| timer.destroy();
        if (self.commit_timing) |manager| manager.destroy();
        if (self.pacing.presentation) |mgr| mgr.destroy();
        self.toplevel.destroy();
        self.xdg_surface.destroy();
        if (self.video_encoding) |encoding| encoding.destroy();
        self.video_viewport.destroy();
        self.subsurface.destroy();
        self.video.destroy();
        self.black.destroy();
        self.root_viewport.destroy();
        self.root.destroy();
        self.feedback.deinit();
        self.encodings.deinit(a);
        self.registry.destroy();
    }

    /// Picks the first window size from the video's display size, shrunk to fit.
    pub fn setVideoSize(self: *Window, w: i32, h: i32) void {
        if (w <= 0 or h <= 0) return;
        self.aspect = @as(f64, @floatFromInt(w)) / @as(f64, @floatFromInt(h));
        const fit = @min(1.0, @min(1280.0 / @as(f64, @floatFromInt(w)), 800.0 / @as(f64, @floatFromInt(h))));
        self.default_width = @max(160, @as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(w)) * fit))));
        self.default_height = @max(90, @as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(h)) * fit))));
    }

    /// Shows `frame` in the video subsurface.
    pub fn show(self: *Window, frame: Frame, target: ?i64) void {
        if (!self.configured) return;
        const video = self.video;
        video.attach(frame.buffer, 0, 0);
        video.damageBuffer(0, 0, std.math.maxInt(i32), std.math.maxInt(i32));
        const old = self.shown;
        if (old == null or old.?.crop_x != frame.crop_x or old.?.crop_y != frame.crop_y or old.?.crop_w != frame.crop_w or old.?.crop_h != frame.crop_h) {
            self.video_viewport.setSource(.fromInt(@intCast(frame.crop_x)), .fromInt(@intCast(frame.crop_y)), .fromInt(@intCast(frame.crop_w)), .fromInt(@intCast(frame.crop_h)));
        }
        self.setEncoding(frame.coefficients, frame.range);
        self.shown = frame;
        if (target) |ns| self.pacing.timestamp(ns);
        video.commit();
    }

    fn setEncoding(self: *Window, coefficients: ?Coefficients, range: ?Range) void {
        if (coefficients != null and self.video_encoding == null) {
            if (self.representation) |mgr| self.video_encoding = mgr.getSurface(self.video) catch null;
        }
        const encoding = self.video_encoding orelse return;
        const want_c = coefficients orelse {
            // RGB buffers use the default representation. Destroying this
            // object clears the YUV metadata on the same surface commit.
            if (self.sent_coefficients != null) {
                encoding.destroy();
                self.video_encoding = null;
                self.sent_coefficients = null;
                self.sent_range = null;
            }
            return;
        };
        const want_r = range orelse return;
        if (self.sent_coefficients == want_c and self.sent_range == want_r) return;
        for (self.encodings.items) |pair| {
            if (pair[0] == want_c and pair[1] == want_r) {
                encoding.setCoefficientsAndRange(want_c, want_r);
                self.sent_coefficients = want_c;
                self.sent_range = want_r;
                return;
            }
        }
    }

    /// Lays out the root and the letterboxed video for the current size.
    pub fn layout(self: *Window) void {
        const w = self.width;
        const h = self.height;
        self.osd.resize(w, h);
        self.root_viewport.setDestination(w, h);
        self.root.attach(self.black, 0, 0);
        self.root.damageBuffer(0, 0, 1, 1);
        const fw: f64 = @floatFromInt(w);
        const fh: f64 = @floatFromInt(h);
        var vw = fw;
        var vh = fh;
        if (fw / fh > self.aspect) vw = fh * self.aspect else vh = fw / self.aspect;
        const dw: i32 = @max(1, @as(i32, @intFromFloat(@round(vw))));
        const dh: i32 = @max(1, @as(i32, @intFromFloat(@round(vh))));
        self.video_viewport.setDestination(dw, dh);
        // Position is parent state. Commit the new viewport on the child
        // without reattaching or rewriting the current buffer.
        self.video.commit();
        self.subtitles.video = .{ .x = @divTrunc(w - dw, 2), .y = @divTrunc(h - dh, 2), .w = dw, .h = dh };
        self.subtitles.dirty = true;
        self.subsurface.setPosition(self.subtitles.video.x, self.subtitles.video.y);
        self.root.commit();
    }

    fn registryEvent(registry: *wl.Registry, event: wl.Registry.Event, self: *Window) void {
        switch (event) {
            .global => |g| {
                const iface = std.mem.span(g.interface);
                self.input.cursor.bind(registry, g.name, iface, g.version);
                if (std.mem.eql(u8, iface, "wp_content_type_manager_v1")) {
                    self.content_manager = registry.bind(g.name, wp.ContentTypeManagerV1, 1) catch null;
                } else if (std.mem.eql(u8, iface, "zwp_idle_inhibit_manager_v1")) {
                    self.idle_manager = registry.bind(g.name, zwp.IdleInhibitManagerV1, 1) catch null;
                } else if (std.mem.eql(u8, iface, "wp_fractional_scale_manager_v1")) {
                    self.scales = registry.bind(g.name, wp.FractionalScaleManagerV1, 1) catch null;
                } else if (std.mem.eql(u8, iface, "wl_data_device_manager")) {
                    self.drop.manager = registry.bind(g.name, wl.DataDeviceManager, @min(3, g.version)) catch null;
                } else if (std.mem.eql(u8, iface, "wl_compositor")) {
                    self.compositor = registry.bind(g.name, wl.Compositor, @min(g.version, 5)) catch null;
                } else if (std.mem.eql(u8, iface, "wl_shm")) {
                    self.shm = registry.bind(g.name, wl.Shm, 1) catch return;
                    self.shm.?.setListener(*Window, shmEvent, self);
                } else if (std.mem.eql(u8, iface, "wl_seat") and g.version >= 5 and self.input.seat == null) {
                    self.input.seat = registry.bind(g.name, wl.Seat, 5) catch return;
                    self.input.seat.?.setListener(*Input, Input.seatEvent, &self.input);
                } else if (std.mem.eql(u8, iface, "wp_presentation")) {
                    self.pacing.presentation = registry.bind(g.name, wp.Presentation, @min(g.version, 2)) catch return;
                    self.pacing.presentation.?.setListener(*Pacing, Pacing.clockId, &self.pacing);
                } else if (std.mem.eql(u8, iface, "wp_commit_timing_manager_v1")) {
                    self.commit_timing = registry.bind(g.name, wp.CommitTimingManagerV1, 1) catch null;
                } else if (std.mem.eql(u8, iface, "wl_subcompositor")) {
                    self.subcompositor = registry.bind(g.name, wl.Subcompositor, 1) catch null;
                } else if (std.mem.eql(u8, iface, "xdg_wm_base")) {
                    self.wm_base = registry.bind(g.name, xdg.WmBase, @min(g.version, 2)) catch null;
                    if (self.wm_base) |wm| wm.setListener(*Window, wmBaseEvent, self);
                } else if (std.mem.eql(u8, iface, "zxdg_decoration_manager_v1")) {
                    self.decoration_manager = registry.bind(g.name, zxdg.DecorationManagerV1, 1) catch null;
                } else if (std.mem.eql(u8, iface, "wp_viewporter")) {
                    self.viewporter = registry.bind(g.name, wp.Viewporter, 1) catch null;
                } else if (std.mem.eql(u8, iface, "wp_single_pixel_buffer_manager_v1")) {
                    self.single_pixel = registry.bind(g.name, wp.SinglePixelBufferManagerV1, 1) catch null;
                } else if (std.mem.eql(u8, iface, "zwp_linux_dmabuf_v1") and g.version >= 4) {
                    self.dmabuf = registry.bind(g.name, zwp.LinuxDmabufV1, @min(g.version, 5)) catch null;
                } else if (std.mem.eql(u8, iface, "wp_color_representation_manager_v1")) {
                    self.representation = registry.bind(g.name, wp.ColorRepresentationManagerV1, 1) catch null;
                    if (self.representation) |manager| manager.setListener(*Window, representationEvent, self);
                }
            },
            .global_remove => {},
        }
    }

    fn shmEvent(_: *wl.Shm, ev: wl.Shm.Event, self: *Window) void {
        if (ev.format.format == .xrgb2101010) self.ten_bit = true;
    }

    fn representationEvent(_: *wp.ColorRepresentationManagerV1, event: wp.ColorRepresentationManagerV1.Event, self: *Window) void {
        switch (event) {
            .supported_coefficients_and_ranges => |pair| self.encodings.append(a, .{ pair.coefficients, pair.range }) catch {},
            .supported_alpha_mode, .done => {},
        }
    }

    fn wmBaseEvent(wm: *xdg.WmBase, event: xdg.WmBase.Event, _: *Window) void {
        switch (event) {
            .ping => |ev| wm.pong(ev.serial),
        }
    }

    fn xdgSurfaceEvent(surface: *xdg.Surface, event: xdg.Surface.Event, self: *Window) void {
        switch (event) {
            .configure => |ev| {
                surface.ackConfigure(ev.serial);
                const w = if (self.pending_width > 0) self.pending_width else if (self.width > 0) self.width else self.default_width;
                const h = if (self.pending_height > 0) self.pending_height else if (self.height > 0) self.height else self.default_height;
                const changed = !self.configured or w != self.width or h != self.height;
                self.configured = true;
                self.width = w;
                self.height = h;
                if (changed) self.layout() else self.root.commit();
            },
        }
    }

    fn toplevelEvent(_: *xdg.Toplevel, event: xdg.Toplevel.Event, self: *Window) void {
        switch (event) {
            .configure => |ev| {
                self.input.fullscreen = std.mem.indexOfScalar(u32, ev.states.slice(u32), @backingInt(xdg.Toplevel.State.fullscreen)) != null;
                self.pending_width = ev.width;
                self.pending_height = ev.height;
            },
            .close => self.closed = true,
            else => {},
        }
    }
};
