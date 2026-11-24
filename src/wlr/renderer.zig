//! Renderer lifecycle and capabilities from the installed wlroots headers.
//! wlroots owns the renderer allocation, so its private tail is omitted.
const wl = @import("wayland").server.wl;
const wlr = @import("wlr.zig");
const c = @import("c.zig").c;
const assertSameLayout = @import("signal.zig").assertSameLayout;
const assertFieldOffset = @import("signal.zig").assertFieldOffset;

pub const Renderer = extern struct {
    pub const BufferPassOptions = extern struct {
        timer: ?*c.wlr_render_timer = null,
        color_transform: ?*wlr.ColorTransform = null,
        signal_timeline: ?*wlr.DrmSyncobjTimeline = null,
        signal_point: u64 = 0,

        comptime {
            const Real = c.wlr_buffer_pass_options;
            assertSameLayout(BufferPassOptions, Real);
            for (@typeInfo(BufferPassOptions).@"struct".field_names) |field_name| {
                assertFieldOffset(BufferPassOptions, Real, field_name);
                assertSameLayout(@FieldType(BufferPassOptions, field_name), @FieldType(Real, field_name));
            }
        }
    };

    render_buffer_caps: u32,
    color_encodings: u32,
    events: extern struct {
        destroy: wl.Signal(*Renderer),
        lost: wl.Signal(void),
    },
    features: extern struct {
        input_color_transform: bool,
        output_color_transform: bool,
        timeline: bool,
    },

    pub fn autocreate(backend: *wlr.Backend) !*Renderer {
        const raw = c.wlr_renderer_autocreate(@ptrCast(backend));
        return @as(?*Renderer, @ptrCast(raw)) orelse error.RendererCreateFailed;
    }

    pub fn destroy(renderer: *Renderer) void {
        c.wlr_renderer_destroy(@ptrCast(renderer));
    }

    pub fn initServer(renderer: *Renderer, server: *wl.Server) !void {
        if (!c.wlr_renderer_init_wl_display(@ptrCast(renderer), @ptrCast(server)))
            return error.RenderInitFailed;
    }

    pub fn initShm(renderer: *Renderer, server: *wl.Server) !void {
        if (!c.wlr_renderer_init_wl_shm(@ptrCast(renderer), @ptrCast(server)))
            return error.RenderInitFailed;
    }

    pub fn getDrmFd(renderer: *Renderer) c_int {
        return c.wlr_renderer_get_drm_fd(@ptrCast(renderer));
    }

    // Format sets and their elements share the header-backed facade.
    pub fn getTextureFormats(renderer: *Renderer, buffer_caps: u32) ?*const wlr.DrmFormatSet {
        return @ptrCast(c.wlr_renderer_get_texture_formats(@ptrCast(renderer), buffer_caps));
    }

    pub fn isGles2(renderer: *Renderer) bool {
        return c.wlr_renderer_is_gles2(@ptrCast(renderer));
    }

    pub fn isPixman(renderer: *Renderer) bool {
        return c.wlr_renderer_is_pixman(@ptrCast(renderer));
    }

    comptime {
        const Real = c.wlr_renderer;
        for (@typeInfo(Renderer).@"struct".field_names) |field_name| {
            assertFieldOffset(Renderer, Real, field_name);
            assertSameLayout(@FieldType(Renderer, field_name), @FieldType(Real, field_name));
        }

        const Events = @FieldType(Renderer, "events");
        const RealEvents = @FieldType(Real, "events");
        for (@typeInfo(Events).@"struct".field_names) |field_name| {
            assertFieldOffset(Events, RealEvents, field_name);
            assertSameLayout(@FieldType(Events, field_name), c.wl_signal);
        }

        const Features = @FieldType(Renderer, "features");
        const RealFeatures = @FieldType(Real, "features");
        for (@typeInfo(Features).@"struct".field_names) |field_name| {
            assertFieldOffset(Features, RealFeatures, field_name);
            assertSameLayout(@FieldType(Features, field_name), @FieldType(RealFeatures, field_name));
        }
    }
};
