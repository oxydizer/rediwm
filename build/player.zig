//! rediwm-player: the background audio player (src/player/, plain C with GIO).
//! miniaudio lives in its own library so the player's code keeps -Werror and
//! UBSan while the vendored implementation is built as shipped.

const std = @import("std");
const Context = @import("context.zig").Context;
const localizedData = @import("support.zig").localizedData;

/// The player's executable. `test_null_device` builds the noninstalled test
/// fixture, whose output is miniaudio's paced null device.
pub fn executable(ctx: Context, name: []const u8, test_null_device: bool) *std.Build.Step.Compile {
    const b = ctx.b;
    const miniaudio = b.addLibrary(.{
        .name = "miniaudio",
        .linkage = .static,
        .root_module = b.createModule(.{ .target = ctx.target, .optimize = ctx.optimize, .link_libc = true, .sanitize_c = .off }),
    });
    miniaudio.root_module.addCSourceFile(.{ .file = b.path("src/player/miniaudio_impl.c"), .flags = &.{ "-std=c11", "-w" } });

    const player = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{ .target = ctx.target, .optimize = ctx.optimize, .link_libc = true }),
    });
    inline for (.{ "main.c", "engine.c", "mpris.c", "tray.c" }) |part| {
        player.root_module.addCSourceFile(.{
            .file = b.path("src/player/" ++ part),
            .flags = if (test_null_device) &.{ "-std=c11", "-Wall", "-Wextra", "-Werror", "-DRP_TEST_NULL_DEVICE" } else &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" },
        });
    }
    player.root_module.linkLibrary(miniaudio);
    player.root_module.linkSystemLibrary("gio-2.0", .{});
    player.root_module.linkSystemLibrary("gobject-2.0", .{});
    player.root_module.linkSystemLibrary("glib-2.0", .{});
    player.root_module.linkSystemLibrary("m", .{});
    return player;
}

pub fn add(ctx: Context) void {
    const b = ctx.b;
    const player = executable(ctx, "rediwm-player", false);
    const install = b.addInstallArtifact(player, .{});
    // Registers the player for audio types, so Open With lists it and an
    // explicit default can replace it (Files falls back to it otherwise).
    const entry = b.addInstallFileWithDir(localizedData(b, ctx.i18n_tool, ctx.layout.prefix, "data/rediwm-player.desktop"), .prefix, "share/applications/rediwm-player.desktop");
    const license = b.addInstallFileWithDir(b.path("third_party/miniaudio/LICENSE"), .prefix, "share/licenses/rediwm/miniaudio-LICENSE");
    b.getInstallStep().dependOn(&install.step);
    b.getInstallStep().dependOn(&entry.step);
    b.getInstallStep().dependOn(&license.step);
    const step = b.step("player", "Build the background audio player");
    step.dependOn(&install.step);
    step.dependOn(&entry.step);
    step.dependOn(&license.step);
}
