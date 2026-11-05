//! The login session supervisor, the display manager and the accounts helper.

const std = @import("std");
const Context = @import("context.zig").Context;

pub const Session = struct {
    session_supervisor: *std.Build.Step.Compile,
    dm_ipc_mod: *std.Build.Module,
    ws_mod: *std.Build.Module,
};

/// rediwm-session, rediwm-dm and the accounts helper. The first two are always
/// described (tests and other steps name them) but installed only with `login_session`.
pub fn add(ctx: Context) Session {
    const b = ctx.b;
    const target = ctx.target;
    const optimize = ctx.optimize;
    const use_llvm = ctx.use_llvm;
    const wlroots_prefix = ctx.wlroots_prefix;
    const wayland = ctx.wayland;
    const session_supervisor = b.addExecutable(.{
        .name = "rediwm-session",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/session_main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
        .use_llvm = use_llvm,
        .use_lld = use_llvm,
    });
    session_supervisor.root_module.addImport("wayland", wayland);
    session_supervisor.root_module.linkSystemLibrary("wayland-server", .{});
    if (wlroots_prefix != null) session_supervisor.root_module.addRPathSpecial("$ORIGIN/../lib/rediwm");
    if (ctx.login_session) b.installArtifact(session_supervisor);

    const restart = b.addExecutable(.{
        .name = "rediwm-restart",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/session_restart.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
        .use_llvm = use_llvm,
        .use_lld = use_llvm,
    });
    restart.root_module.addImport("install_paths", ctx.layout.options);
    restart.root_module.addImport("platform", ctx.platform_mod);
    b.installArtifact(restart);

    const dm_ipc_mod = b.createModule(.{
        .root_source_file = b.path("src/session/dm_ipc.zig"),
        .target = target,
        .optimize = optimize,
    });
    const ws_mod = b.createModule(.{
        .root_source_file = b.path("src/session/wayland_sessions.zig"),
        .target = target,
        .optimize = optimize,
    });

    dm_ipc_mod.addImport("c", ctx.c.libc);
    ws_mod.addImport("c", ctx.c.libc);
    ws_mod.addImport("install_paths", ctx.layout.options);

    const dm = b.addExecutable(.{
        .name = "rediwm-dm",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/dm/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
        .use_llvm = use_llvm,
        .use_lld = use_llvm,
    });
    dm.root_module.addImport("install_paths", ctx.layout.options);
    dm.root_module.addImport("c", ctx.c.libc);
    dm.root_module.addImport("platform", ctx.platform_mod);
    dm.root_module.addImport("dm_ipc", dm_ipc_mod);
    dm.root_module.addImport("wayland_sessions", ws_mod);
    dm.root_module.linkSystemLibrary("pam", .{});
    dm.root_module.addCSourceFile(.{ .file = b.path("src/dm/pam.c"), .flags = &.{"-std=c11"} });
    if (ctx.login_session) b.installArtifact(dm);
    b.step("rediwm-dm", "Build the display manager").dependOn(&dm.step);

    const accounts_helper = b.addExecutable(.{
        .name = "rediwm-accounts-helper",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/accounts_helper/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
        .use_llvm = use_llvm,
        .use_lld = use_llvm,
    });
    accounts_helper.root_module.addImport("c", ctx.c.libc);
    accounts_helper.root_module.addImport("wayland_sessions", ws_mod);
    accounts_helper.root_module.addImport("accounts_validation", b.createModule(.{
        .root_source_file = b.path("src/accounts/validation.zig"),
        .target = target,
        .optimize = optimize,
    }));
    const dm_config = b.createModule(.{
        .root_source_file = b.path("src/dm/config.zig"),
        .target = target,
        .optimize = optimize,
    });
    dm_config.addImport("install_paths", ctx.layout.options);
    accounts_helper.root_module.addImport("dm_config", dm_config);
    b.installArtifact(accounts_helper);
    b.step("accounts-helper", "Build the privileged account-management helper").dependOn(&accounts_helper.step);
    return .{ .session_supervisor = session_supervisor, .dm_ipc_mod = dm_ipc_mod, .ws_mod = ws_mod };
}
