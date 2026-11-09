//! Portable supervisor primitives and the independent ConsoleKit2 bus fixture.
const std = @import("std");
const Context = @import("context.zig").Context;

pub fn add(ctx: Context, test_step: *std.Build.Step) void {
    const b = ctx.b;
    const target = ctx.target;
    const optimize = ctx.optimize;
    const use_llvm = ctx.use_llvm;
    const wayland = ctx.wayland;
    const run_platform_tests = b.addRunArtifact(b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/platform/mod.zig"), .target = target, .optimize = optimize, .link_libc = true }) }));
    test_step.dependOn(&run_platform_tests.step);
    b.step("test-platform", "Test child handles, file watching and the program's own path").dependOn(&run_platform_tests.step);
    const login_service = b.addExecutable(.{
        .name = "login-manager-test-service",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/login_manager_test_service.zig"), .target = target, .optimize = optimize, .link_libc = true }),
        .use_llvm = use_llvm,
        .use_lld = use_llvm,
    });
    login_service.root_module.addImport("wayland", wayland);
    login_service.root_module.addImport("dbus", ctx.dbus_mod);
    login_service.root_module.addImport("platform", ctx.platform_mod);
    login_service.root_module.linkSystemLibrary("wayland-server", .{});
    const login_integration = b.addSystemCommand(&.{"python3"});
    login_integration.addFileArg(b.path("tests/consolekit.py"));
    login_integration.addArtifactArg(login_service);
    b.step("test-login-manager", "Test ConsoleKit2 login ownership on a private bus").dependOn(&login_integration.step);
}
