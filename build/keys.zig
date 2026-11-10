//! The unprivileged key helper and its standalone parser tests.
const std = @import("std");
const Context = @import("context.zig").Context;
pub fn add(ctx: Context, test_step: *std.Build.Step, hosts: []const *std.Build.Module) void {
    const b = ctx.b;
    const module = b.createModule(.{ .root_source_file = b.path("src/keys/mod.zig"), .target = ctx.target, .optimize = ctx.optimize, .link_libc = true });
    module.addImport("c", ctx.c.libc);
    module.addImport("platform", ctx.platform_mod);
    for (hosts) |host| host.addImport("keys", module);
    const helper = b.addExecutable(.{ .name = "rediwm-keys", .root_module = b.createModule(.{ .root_source_file = b.path("src/keys_main.zig"), .target = ctx.target, .optimize = ctx.optimize, .link_libc = true }), .use_llvm = ctx.use_llvm, .use_lld = ctx.use_llvm });
    helper.root_module.addImport("keys", module);
    helper.root_module.addImport("platform", ctx.platform_mod);
    helper.root_module.addImport("c", ctx.c.libc);
    helper.root_module.addCSourceFile(.{ .file = b.path("src/platform/key_scan.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    b.installArtifact(helper);
    const tests = b.addTest(.{ .root_module = module });
    const run = b.addRunArtifact(tests);
    b.step("test-keys", "Test key metadata parsers and operation plans").dependOn(&run.step);
    test_step.dependOn(&run.step);
}
