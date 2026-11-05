//! What build.zig's parts share: the build, its options and the modules every
//! artifact is assembled from.

const std = @import("std");
const CHeaders = @import("support.zig").CHeaders;

pub const Context = struct {
    b: *std.Build,
    layout: @import("install_paths.zig").Layout,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    use_llvm: bool,
    transfers: bool,
    login_session: bool,
    wlroots_prefix: ?[]const u8,
    i18n_tool: *std.Build.Step.Compile,
    wayland: *std.Build.Module,
    xkbcommon: *std.Build.Module,
    pixman: *std.Build.Module,
    wlroots: *std.Build.Module,
    i18n_mod: *std.Build.Module,
    ui_mod: *std.Build.Module,
    dbus_mod: *std.Build.Module,
    platform_mod: *std.Build.Module,
    config_mod: *std.Build.Module,
    protocol_mod: *std.Build.Module,
    c: CHeaders,
};
