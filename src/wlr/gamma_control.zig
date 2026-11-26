//! Output gamma ramps and the manager's per-output change signal.
const wl = @import("wayland").server.wl;
const wlr = @import("wlr.zig");
const c = @import("c.zig").c;
const abi = @import("abi.zig");

pub const Control = opaque {
    pub const getTransform = abi.bind(fn (*Control) callconv(.c) ?*wlr.ColorTransform, c.wlr_gamma_control_v1_get_color_transform);
    pub const fail = abi.bind(fn (*Control) callconv(.c) void, c.wlr_gamma_control_v1_send_failed_and_destroy);
};

pub const Manager = extern struct {
    global: *wl.Global,
    controls: wl.list.Link,
    fallback_gamma_size: usize,
    events: extern struct {
        destroy: wl.Signal(*Manager),
        set_gamma: wl.Signal(*SetGamma),
    },

    pub const SetGamma = extern struct {
        output: *wlr.Output,
        control: ?*Control,
    };
    pub const create = abi.bind(fn (*wl.Server) callconv(.c) ?*Manager, c.wlr_gamma_control_manager_v1_create);
};

comptime {
    abi.assertFields(Manager, c.wlr_gamma_control_manager_v1);
    abi.assertLayout(Manager.SetGamma, c.wlr_gamma_control_manager_v1_set_gamma_event);
}
