// Glass effects are registered here and drawn by the owned output pass
// (scene_output.c); see glass.c.
const wlr = @import("wlroots");
const sn = @import("node.zig");

extern fn rediwm_background_effect_create(display: *@import("wayland").server.wl.Server, engine: ?*Engine) bool;
pub const createBackgroundEffect = rediwm_background_effect_create;

pub const Kind = enum(c_int) { titlebar, taskbar, panel, sidebar };
pub const Effect = opaque {
    extern fn rediwm_glass_detach(effect: ?*Effect) void;
    pub const detach = rediwm_glass_detach;
    extern fn rediwm_glass_configure(effect: ?*Effect, radius: f32, opacity: f32) void;
    pub const configure = rediwm_glass_configure;
};
pub const Engine = opaque {
    extern fn rediwm_glass_create() ?*Engine;
    pub const create = rediwm_glass_create;
    extern fn rediwm_glass_destroy(engine: ?*Engine) void;
    pub const destroy = rediwm_glass_destroy;
    extern fn rediwm_glass_attach(engine: ?*Engine, target: *sn.Buffer, before: *sn.Node, kind: Kind) ?*Effect;
    pub const attach = rediwm_glass_attach;
    extern fn rediwm_glass_hold(engine: ?*Engine, effect: ?*Effect) void;
    pub const hold = rediwm_glass_hold;
    extern fn rediwm_glass_hold_all(engine: ?*Engine, hold: bool) void;
    pub const holdAll = rediwm_glass_hold_all;
};
