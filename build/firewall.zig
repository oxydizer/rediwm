//! The firewall model shared by Settings and the root helper, the helper
//! itself, its polkit policy and the standalone tests.
const std = @import("std");
const Context = @import("context.zig").Context;
const support = @import("support.zig");

pub fn add(ctx: Context, test_step: *std.Build.Step, hosts: []const *std.Build.Module) void {
    const b = ctx.b;
    const module = b.createModule(.{ .root_source_file = b.path("src/firewall/mod.zig"), .target = ctx.target, .optimize = ctx.optimize });
    for (hosts) |host| host.addImport("firewall", module);
    const helper = b.addExecutable(.{ .name = "rediwm-firewall-helper", .root_module = b.createModule(.{ .root_source_file = b.path("src/firewall_main.zig"), .target = ctx.target, .optimize = ctx.optimize, .link_libc = true }), .use_llvm = ctx.use_llvm, .use_lld = ctx.use_llvm });
    helper.root_module.addImport("firewall", module);
    helper.root_module.addImport("platform", ctx.platform_mod);
    helper.root_module.addImport("c", ctx.c.libc);
    helper.root_module.addImport("install_paths", ctx.layout.options);
    b.installArtifact(helper);
    b.step("firewall-helper", "Build the privileged firewall helper").dependOn(&helper.step);
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(support.localizedData(b, ctx.i18n_tool, ctx.layout.prefix, "data/org.rediwm.firewall.policy"), .prefix, "share/polkit-1/actions/org.rediwm.firewall.policy").step);
    const tests = b.addTest(.{ .root_module = module });
    const run = b.addRunArtifact(tests);
    b.step("test-firewall", "Test firewall parsers, validation and rule rendering").dependOn(&run.step);
    test_step.dependOn(&run.step);
    // Integration suites (namespaces, never the host firewall); run on demand.
    inline for (.{ .{ "test-firewall-helper", "tests/firewall_helper.py", "Test the firewall helper against nftables in a private namespace" }, .{ "test-firewall-settings", "tests/firewall_settings.py", "Test Settings' Firewall section against a fake helper" } }) |suite| {
        const integration = b.addSystemCommand(&.{"python3"});
        integration.addFileArg(b.path(suite[1]));
        integration.step.dependOn(b.getInstallStep());
        b.step(suite[0], suite[2]).dependOn(&integration.step);
    }
}
