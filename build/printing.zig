//! rediwm-cups: the only program linked against libcups. The compositor reads
//! printers over native IPP and, for administration without cups-pk-helper,
//! starts this helper, so libcups and the TLS and crypto libraries behind it
//! stay out of every session's address space (src/printing/AGENTS.md).
const std = @import("std");
const Context = @import("context.zig").Context;
pub fn add(ctx: Context) void {
    const b = ctx.b;
    const helper = b.addExecutable(.{ .name = "rediwm-cups", .root_module = b.createModule(.{ .root_source_file = b.path("src/cups_main.zig"), .target = ctx.target, .optimize = ctx.optimize, .link_libc = true }), .use_llvm = ctx.use_llvm, .use_lld = ctx.use_llvm });
    helper.root_module.addImport("platform", ctx.platform_mod);
    helper.root_module.addImport("c", ctx.c.libc);
    helper.root_module.linkSystemLibrary("cups", .{});
    helper.root_module.addCSourceFile(.{ .file = b.path("src/printing/direct.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror", "-Wno-deprecated-declarations" } });
    b.installArtifact(helper);
    b.step("cups-helper", "Build the CUPS administration helper").dependOn(&helper.step);
}
