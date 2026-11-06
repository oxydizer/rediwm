//! Backend creation, output signals and multi-backend iteration, backed by
//! the installed wlroots headers. Resolve Output lazily through the facade:
//! Output contains a Backend pointer, so eagerly passing both through Types
//! would create a dependency loop.
const wl = @import("wayland").server.wl;
const wlr = @import("wlr.zig");
const c = @import("c.zig").c;
const assertSameLayout = @import("signal.zig").assertSameLayout;
const assertFieldOffset = @import("signal.zig").assertFieldOffset;

pub const Backend = extern struct {
    pub const OutputState = extern struct {
        output: *wlr.Output,
        base: wlr.Output.State,

        comptime {
            assertSameLayout(OutputState, c.wlr_backend_output_state);
            assertFieldOffset(OutputState, c.wlr_backend_output_state, "output");
            assertFieldOffset(OutputState, c.wlr_backend_output_state, "base");
        }
    };

    impl: *const c.wlr_backend_impl,
    buffer_caps: u32,
    features: extern struct {
        timeline: bool,
    },
    events: extern struct {
        destroy: wl.Signal(*Backend),
        new_input: wl.Signal(*wlr.InputDevice),
        new_output: wl.Signal(*wlr.Output),
    },

    pub fn autocreate(loop: *wl.EventLoop, session_ptr: ?*?*wlr.Session) !*Backend {
        const raw = c.wlr_backend_autocreate(@ptrCast(loop), @ptrCast(session_ptr));
        return @as(?*Backend, @ptrCast(raw)) orelse error.BackendCreateFailed;
    }

    pub fn start(backend: *Backend) !void {
        if (!c.wlr_backend_start(@ptrCast(backend))) return error.BackendStartFailed;
    }

    pub fn destroy(backend: *Backend) void {
        c.wlr_backend_destroy(@ptrCast(backend));
    }

    pub fn getDrmFd(backend: *Backend) c_int {
        return c.wlr_backend_get_drm_fd(@ptrCast(backend));
    }

    pub fn @"test"(backend: *Backend, states: []const OutputState) bool {
        return c.wlr_backend_test(@ptrCast(backend), @ptrCast(states.ptr), states.len);
    }

    pub fn commit(backend: *Backend, states: []const OutputState) bool {
        return c.wlr_backend_commit(@ptrCast(backend), @ptrCast(states.ptr), states.len);
    }

    pub fn createMulti(loop: *wl.EventLoop) !*Backend {
        const raw = c.wlr_multi_backend_create(@ptrCast(loop));
        return @as(?*Backend, @ptrCast(raw)) orelse error.BackendCreateFailed;
    }

    pub fn multiAdd(multi: *Backend, backend: *Backend) bool {
        return c.wlr_multi_backend_add(@ptrCast(multi), @ptrCast(backend));
    }

    pub fn multiForEachBackend(
        backend: *Backend,
        comptime T: type,
        comptime callback: fn (backend: *Backend, data: T) void,
        data: T,
    ) void {
        const Adapter = struct {
            fn call(raw: [*c]c.wlr_backend, context: ?*anyopaque) callconv(.c) void {
                callback(@ptrCast(raw), @ptrCast(@alignCast(context)));
            }
        };
        c.wlr_multi_for_each_backend(@ptrCast(backend), Adapter.call, data);
    }

    pub fn createHeadless(loop: *wl.EventLoop) !*Backend {
        const raw = c.wlr_headless_backend_create(@ptrCast(loop));
        return @as(?*Backend, @ptrCast(raw)) orelse error.BackendCreateFailed;
    }

    pub fn headlessAddOutput(backend: *Backend, width: c_uint, height: c_uint) !*wlr.Output {
        const raw = c.wlr_headless_add_output(@ptrCast(backend), width, height);
        return @as(?*wlr.Output, @ptrCast(raw)) orelse error.OutOfMemory;
    }

    pub fn isMulti(backend: *Backend) bool {
        return c.wlr_backend_is_multi(@ptrCast(backend));
    }

    pub fn isHeadless(backend: *Backend) bool {
        return c.wlr_backend_is_headless(@ptrCast(backend));
    }

    pub fn isDrm(backend: *Backend) bool {
        return c.wlr_backend_is_drm(@ptrCast(backend));
    }

    /// True for a DRM backend or a multi backend that wraps one. A real
    /// session's `server.backend` is the multi wrapper, for which `isDrm`
    /// is always false.
    pub fn hasDrm(backend: *Backend) bool {
        if (backend.isDrm()) return true;
        if (!backend.isMulti()) return false;
        const Found = struct {
            value: bool = false,
            fn visit(sub: *Backend, self: *@This()) void {
                if (sub.isDrm()) self.value = true;
            }
        };
        var found: Found = .{};
        backend.multiForEachBackend(*Found, Found.visit, &found);
        return found.value;
    }

    pub fn isWl(backend: *Backend) bool {
        return c.wlr_backend_is_wl(@ptrCast(backend));
    }

    pub fn isX11(backend: *Backend) bool {
        return c.wlr_backend_is_x11(@ptrCast(backend));
    }

    pub fn isLibinput(backend: *Backend) bool {
        return c.wlr_backend_is_libinput(@ptrCast(backend));
    }

    comptime {
        const Real = c.wlr_backend;
        assertSameLayout(Backend, Real);
        for (.{ "impl", "buffer_caps", "features", "events" }) |field| {
            assertFieldOffset(Backend, Real, field);
        }

        const Features = @FieldType(Backend, "features");
        const RealFeatures = @FieldType(Real, "features");
        assertSameLayout(Features, RealFeatures);
        assertFieldOffset(Features, RealFeatures, "timeline");

        const Events = @FieldType(Backend, "events");
        const RealEvents = @FieldType(Real, "events");
        assertSameLayout(Events, RealEvents);
        for (.{ "destroy", "new_input", "new_output" }) |field| {
            assertSameLayout(@FieldType(Events, field), c.wl_signal);
            assertFieldOffset(Events, RealEvents, field);
        }
    }
};
