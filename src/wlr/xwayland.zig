//! Typed wlroots header adapter. API shapes adapted from zig-wlroots;
//! see LICENSE.zig-wlroots for its MIT license.
const c = @import("c.zig").c;
const abi = @import("abi.zig");
const wlr = @import("wlr.zig");

const std = @import("std");
const posix = std.posix;

const wayland = @import("wayland");
const wl = wayland.server.wl;

// Only bind enough to make binding wlr/xwayland.h possible
// Consider full xcb bindings in the future if needed
const xcb = struct {
    const Pixmap = u32;
    const Window = u32;
    const Atom = u32;

    const StackMode = enum(c_int) {
        above = c.XCB_STACK_MODE_ABOVE,
        below = c.XCB_STACK_MODE_BELOW,
        top_if = c.XCB_STACK_MODE_TOP_IF,
        bottom_if = c.XCB_STACK_MODE_BOTTOM_IF,
        opposite = c.XCB_STACK_MODE_OPPOSITE,
    };

    pub const IcccmWmHints = c.xcb_icccm_wm_hints_t;

    pub const SizeHints = c.xcb_size_hints_t;

    pub const EwmhWmStrutPartial = c.xcb_ewmh_wm_strut_partial_t;
};

pub const Xwm = opaque {};

// Only the ownership fields are read by the global filter. wlroots owns both
// objects, so their unrelated public fields and private tails are omitted.
const XwaylandServer = extern struct {
    pid: posix.pid_t,
    client: ?*wl.Client,
};
const XwaylandShellV1 = extern struct {
    global: *wl.Global,
};

pub const Xwayland = extern struct {
    // XWM connection and event types from the same headers as wlroots.
    pub const Xcb = struct {
        pub const Event = c.xcb_generic_event_t;
        pub const ClientMessage = c.xcb_client_message_event_t;
        pub const client_message = c.XCB_CLIENT_MESSAGE;
        pub const cardinal = c.XCB_ATOM_CARDINAL;
        pub const substructure_redirect = c.XCB_EVENT_MASK_SUBSTRUCTURE_REDIRECT;
        pub const getSetup = c.xcb_get_setup;
        pub const rootsIterator = c.xcb_setup_roots_iterator;
        pub const sendEvent = c.xcb_send_event;
        pub const fd = c.xcb_get_file_descriptor;
        pub const flush = c.xcb_flush;
        pub const hasError = c.xcb_connection_has_error;
        pub const RawButton = c.xcb_input_raw_button_press_event_t;
        pub const VersionCookie = c.xcb_input_xi_query_version_cookie_t;
        pub const EventMask = c.xcb_input_event_mask_t;
        pub const generic_event = c.XCB_GE_GENERIC;
        pub const press = c.XCB_INPUT_RAW_BUTTON_PRESS;
        pub const release = c.XCB_INPUT_RAW_BUTTON_RELEASE;
        pub const all_master = c.XCB_INPUT_DEVICE_ALL_MASTER;
        pub const raw_buttons = c.XCB_INPUT_XI_EVENT_MASK_RAW_BUTTON_PRESS | c.XCB_INPUT_XI_EVENT_MASK_RAW_BUTTON_RELEASE;
        pub const input_id = &c.xcb_input_id;
        pub const prefetchExtension = c.xcb_prefetch_extension_data;
        pub const getExtension = c.xcb_get_extension_data;
        pub const queryVersion = c.xcb_input_xi_query_version;
        pub const versionReply = c.xcb_input_xi_query_version_reply;
        pub const selectEvents = c.xcb_input_xi_select_events;
    };
    pub const event = struct {
        pub const RemoveStartupInfo = extern struct {
            id: [*:0]const u8,
            window: xcb.Window,
        };
    };

    /// This can be null during destruction
    server: ?*XwaylandServer,
    own_server: bool,
    xwm: ?*Xwm,
    shell_v1: *XwaylandShellV1,

    display_name: [*:0]const u8,

    wl_display: *wl.Server,
    compositor: *wlr.Compositor,
    seat: ?*wlr.Seat,

    events: extern struct {
        destroy: wl.Signal(void),
        ready: wl.Signal(void),
        new_surface: wl.Signal(*XwaylandSurface),
        remove_startup_info: wl.Signal(*event.RemoveStartupInfo),
    },

    user_event_handler: ?*const fn (*Xwayland, *Xcb.Event) callconv(.c) bool,

    data: ?*anyopaque,

    const wlr_xwayland_create = abi.bind(fn (server: *wl.Server, compositor: *wlr.Compositor, lazy: bool) callconv(.c) ?*Xwayland, c.wlr_xwayland_create);
    pub fn create(server: *wl.Server, compositor: *wlr.Compositor, lazy: bool) !*Xwayland {
        return wlr_xwayland_create(server, compositor, lazy) orelse error.XwaylandCreateFailed;
    }

    const wlr_xwayland_create_with_server = abi.bind(fn (server: *wl.Server, compositor: *wlr.Compositor, xwayland_server: *XwaylandServer) callconv(.c) ?*Xwayland, c.wlr_xwayland_create_with_server);
    pub fn createWithServer(server: *wl.Server, compositor: *wlr.Compositor, xwayland_server: *XwaylandServer) !*Xwayland {
        return wlr_xwayland_create_with_server(server, compositor, xwayland_server) orelse error.XwaylandCreateWithServerFailed;
    }

    const wlr_xwayland_destroy = abi.bind(fn (wlr_xwayland: *Xwayland) callconv(.c) void, c.wlr_xwayland_destroy);
    pub const destroy = wlr_xwayland_destroy;

    const wlr_xwayland_set_cursor = abi.bind(fn (wlr_xwayland: *Xwayland, buffer: *wlr.Buffer, hotspot_x: i32, hotspot_y: i32) callconv(.c) void, c.wlr_xwayland_set_cursor);
    pub const setCursor = wlr_xwayland_set_cursor;

    const wlr_xwayland_set_seat = abi.bind(fn (xwayland: *Xwayland, seat: *wlr.Seat) callconv(.c) void, c.wlr_xwayland_set_seat);
    pub const setSeat = wlr_xwayland_set_seat;

    const wlr_xwayland_get_xwm_connection = abi.bind(fn (xwayland: *Xwayland) callconv(.c) ?*c.xcb_connection_t, c.wlr_xwayland_get_xwm_connection);
    pub const getXwmConnection = wlr_xwayland_get_xwm_connection;
};

pub const XwaylandSurface = extern struct {
    pub const IcccmInputModel = enum(c_int) {
        none = c.WLR_ICCCM_INPUT_MODEL_NONE,
        passive = c.WLR_ICCCM_INPUT_MODEL_PASSIVE,
        local = c.WLR_ICCCM_INPUT_MODEL_LOCAL,
        global = c.WLR_ICCCM_INPUT_MODEL_GLOBAL,
    };

    /// Bitfield with the size/alignment of a u32
    pub const Decorations = packed struct(u32) {
        no_border: bool = false,
        no_title: bool = false,
        _: u30 = 0,
    };

    pub const event = struct {
        pub const Configure = extern struct {
            surface: *XwaylandSurface,
            x: i16,
            y: i16,
            width: u16,
            height: u16,
            mask: u16,
        };

        pub const Resize = extern struct {
            surface: *XwaylandSurface,
            edges: u32,
        };

        pub const Minimize = extern struct {
            surface: *XwaylandSurface,
            minimize: bool,
        };
    };

    window_id: xcb.Window,
    xwm: *Xwm,
    surface_id: u32,
    serial: u64,

    link: wl.list.Link,
    stack_link: wl.list.Link,
    unpaired_link: wl.list.Link,

    surface: ?*wlr.Surface,
    surface_addon: c.wlr_addon,

    x: i16,
    y: i16,
    width: u16,
    height: u16,
    override_redirect: bool,
    opacity: f32,

    title: ?[*:0]u8,
    class: ?[*:0]u8,
    instance: ?[*:0]u8,
    role: ?[*:0]u8,
    startup_id: ?[*:0]u8,
    pid: posix.pid_t,

    children: wl.list.Head(XwaylandSurface, .parent_link),
    parent: ?*XwaylandSurface,
    /// XwaylandSurface.children
    parent_link: wl.list.Link,

    window_type: ?[*]xcb.Atom,
    window_type_len: usize,

    protocols: ?[*]xcb.Atom,
    protocols_len: usize,

    decorations: Decorations,
    hints: ?*xcb.IcccmWmHints,
    size_hints: ?*xcb.SizeHints,
    strut_partial: ?*xcb.EwmhWmStrutPartial,

    pinging: bool,
    ping_timer: *wl.EventSource,

    modal: bool,
    fullscreen: bool,
    maximized_vert: bool,
    maximized_horz: bool,
    minimized: bool,
    withdrawn: bool,
    sticky: bool,
    shaded: bool,
    skip_taskbar: bool,
    skip_pager: bool,
    above: bool,
    below: bool,
    demands_attention: bool,

    has_alpha: bool,

    events: extern struct {
        destroy: wl.Signal(void),
        request_configure: wl.Signal(*event.Configure),
        request_move: wl.Signal(void),
        request_resize: wl.Signal(*event.Resize),
        request_minimize: wl.Signal(*event.Minimize),
        request_maximize: wl.Signal(void),
        request_fullscreen: wl.Signal(void),
        request_activate: wl.Signal(void),
        request_close: wl.Signal(void),
        request_sticky: wl.Signal(void),
        request_shaded: wl.Signal(void),
        request_skip_taskbar: wl.Signal(void),
        request_skip_pager: wl.Signal(void),
        request_above: wl.Signal(void),
        request_below: wl.Signal(void),
        request_demands_attention: wl.Signal(void),

        associate: wl.Signal(void),
        dissociate: wl.Signal(void),

        set_title: wl.Signal(void),
        set_class: wl.Signal(void),
        set_role: wl.Signal(void),
        set_parent: wl.Signal(void),
        set_startup_id: wl.Signal(void),
        set_window_type: wl.Signal(void),
        set_hints: wl.Signal(void),
        set_size_hints: wl.Signal(void),
        set_decorations: wl.Signal(void),
        set_strut_partial: wl.Signal(void),
        set_override_redirect: wl.Signal(void),
        set_geometry: wl.Signal(void),
        set_opacity: wl.Signal(void),
        set_icon: wl.Signal(void),
        focus_in: wl.Signal(void),
        grab_focus: wl.Signal(void),

        map_request: wl.Signal(void),

        ping_timeout: wl.Signal(void),
    },

    data: ?*anyopaque,

    const wlr_xwayland_surface_activate = abi.bind(fn (surface: *XwaylandSurface, activated: bool) callconv(.c) void, c.wlr_xwayland_surface_activate);
    pub const activate = wlr_xwayland_surface_activate;

    const wlr_xwayland_surface_restack = abi.bind(fn (surface: *XwaylandSurface, sibling: ?*XwaylandSurface, mode: xcb.StackMode) callconv(.c) void, c.wlr_xwayland_surface_restack);
    pub const restack = wlr_xwayland_surface_restack;

    const wlr_xwayland_surface_configure = abi.bind(fn (surface: *XwaylandSurface, x: i16, y: i16, width: u16, height: u16) callconv(.c) void, c.wlr_xwayland_surface_configure);
    pub const configure = wlr_xwayland_surface_configure;

    const wlr_xwayland_surface_close = abi.bind(fn (surface: *XwaylandSurface) callconv(.c) void, c.wlr_xwayland_surface_close);
    pub const close = wlr_xwayland_surface_close;

    const wlr_xwayland_surface_set_withdrawn = abi.bind(fn (surface: *XwaylandSurface, withdrawn: bool) callconv(.c) void, c.wlr_xwayland_surface_set_withdrawn);
    pub const setWithdrawn = wlr_xwayland_surface_set_withdrawn;

    const wlr_xwayland_surface_set_minimized = abi.bind(fn (surface: *XwaylandSurface, minimized: bool) callconv(.c) void, c.wlr_xwayland_surface_set_minimized);
    pub const setMinimized = wlr_xwayland_surface_set_minimized;

    const wlr_xwayland_surface_set_maximized = abi.bind(fn (surface: *XwaylandSurface, maximized_horz: bool, maximized_vert: bool) callconv(.c) void, c.wlr_xwayland_surface_set_maximized);
    pub const setMaximized = wlr_xwayland_surface_set_maximized;

    const wlr_xwayland_surface_set_fullscreen = abi.bind(fn (surface: *XwaylandSurface, fullscreen: bool) callconv(.c) void, c.wlr_xwayland_surface_set_fullscreen);
    pub const setFullscreen = wlr_xwayland_surface_set_fullscreen;

    const wlr_xwayland_surface_try_from_wlr_surface = abi.bind(fn (surface: *wlr.Surface) callconv(.c) ?*XwaylandSurface, c.wlr_xwayland_surface_try_from_wlr_surface);
    pub const tryFromWlrSurface = wlr_xwayland_surface_try_from_wlr_surface;

    const wlr_xwayland_surface_ping = abi.bind(fn (surface: *XwaylandSurface) callconv(.c) void, c.wlr_xwayland_surface_ping);
    pub const ping = wlr_xwayland_surface_ping;

    pub const offerFocus = abi.bind(fn (surface: *XwaylandSurface) callconv(.c) void, c.wlr_xwayland_surface_offer_focus);
    pub const setDemandsAttention = abi.bind(fn (surface: *XwaylandSurface, urgent: bool) callconv(.c) void, c.wlr_xwayland_surface_set_demands_attention);

    const wlr_xwayland_surface_override_redirect_wants_focus = abi.bind(fn (surface: *const XwaylandSurface) callconv(.c) bool, c.wlr_xwayland_surface_override_redirect_wants_focus);
    pub const overrideRedirectWantsFocus = wlr_xwayland_surface_override_redirect_wants_focus;

    const wlr_xwayland_surface_icccm_input_model = abi.bind(fn (surface: *const XwaylandSurface) callconv(.c) IcccmInputModel, c.wlr_xwayland_surface_icccm_input_model);
    pub const icccmInputModel = wlr_xwayland_surface_icccm_input_model;
};

comptime {
    @setEvalBranchQuota(10000);
    abi.assertFields(XwaylandServer, c.wlr_xwayland_server);
    abi.assertFields(XwaylandShellV1, c.wlr_xwayland_shell_v1);
    abi.assertFields(Xwayland, c.wlr_xwayland);
    abi.assertFields(XwaylandSurface, c.wlr_xwayland_surface);
    abi.assertLayout(Xwayland.event.RemoveStartupInfo, c.wlr_xwayland_remove_startup_info_event);
    abi.assertLayout(XwaylandSurface.event.Configure, c.wlr_xwayland_surface_configure_event);
    abi.assertLayout(XwaylandSurface.event.Resize, c.wlr_xwayland_resize_event);
    abi.assertLayout(XwaylandSurface.event.Minimize, c.wlr_xwayland_minimize_event);
}
