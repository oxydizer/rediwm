// The scene API has no backdrop-filter primitive. Keep the GLES/EGL bridge
// in C, using wlroots' installed headers for its renderer and scene ABI.
const wlr = @import("wlroots");

pub const Kind = enum(c_int) { titlebar, taskbar, panel };
pub const Effect = opaque {
    extern fn rediwm_glass_configure(effect: ?*Effect, radius: f32, opacity: f32) void;
    pub const configure = rediwm_glass_configure;
};
pub const Engine = opaque {
    extern fn rediwm_glass_create(renderer: *wlr.Renderer, allocator: *wlr.Allocator, scene: *wlr.Scene, read_fence: ?*@import("explicit_sync.zig").ReadFence) ?*Engine;
    pub const create = rediwm_glass_create;
    extern fn rediwm_glass_destroy(engine: ?*Engine) void;
    pub const destroy = rediwm_glass_destroy;
    extern fn rediwm_glass_attach(engine: ?*Engine, target: *wlr.SceneBuffer, before: *wlr.SceneNode, kind: Kind) ?*Effect;
    pub const attach = rediwm_glass_attach;
    extern fn rediwm_glass_hold(engine: ?*Engine, effect: ?*Effect) void;
    pub const hold = rediwm_glass_hold;
    extern fn rediwm_glass_hold_all(engine: ?*Engine, hold: bool) void;
    pub const holdAll = rediwm_glass_hold_all;
    extern fn rediwm_glass_update(engine: ?*Engine, output: *wlr.SceneOutput, scale: f32) void;
    pub const update = rediwm_glass_update;
    extern fn rediwm_glass_project(engine: ?*Engine, projection: ?*anyopaque, zoom: f32) void;
    pub const project = rediwm_glass_project;
};
