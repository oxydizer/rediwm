//! rediwm-video: the video player (src/video/, docs/plans/video-player.md).
//! Links the system's shared FFmpeg; never a vendored or static copy.

const std = @import("std");
const Context = @import("context.zig").Context;
const support = @import("support.zig");

fn executable(ctx: Context, fixture: bool) *std.Build.Step.Compile {
    const b = ctx.b;
    const video = b.addExecutable(.{
        .name = if (fixture) "rediwm-video-test" else "rediwm-video",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/video_main.zig"), .target = ctx.target, .optimize = ctx.optimize, .link_libc = true }),
        .use_llvm = ctx.use_llvm,
        .use_lld = ctx.use_llvm,
    });
    video.root_module.addImport("wayland", ctx.wayland);
    video.root_module.addImport("platform", ctx.platform_mod);
    video.root_module.addImport("c_av", ctx.c.av);
    video.root_module.linkSystemLibrary("wayland-client", .{});
    for (support.av_libs) |lib| video.root_module.linkSystemLibrary(lib, .{});
    video.root_module.addImport("c", ctx.c.libc);
    video.root_module.addImport("c_gfx", ctx.c.gfx);
    video.root_module.addImport("ui", ctx.ui_mod);
    video.root_module.addImport("app_kit", ctx.app_kit_mod);
    for ([_][]const u8{ "xkbcommon", "wayland-cursor", "cairo", "librsvg-2.0", "freetype2", "harfbuzz", "fontconfig" }) |lib| video.root_module.linkSystemLibrary(lib, .{});
    video.root_module.linkSystemLibrary("m", .{});
    video.root_module.linkLibrary(@import("player.zig").miniaudio(ctx));
    video.root_module.addCSourceFile(.{
        .file = b.path("src/video/audio_out.c"),
        .flags = if (fixture) &.{ "-std=c11", "-Wall", "-Wextra", "-Werror", "-DRV_TEST_NULL_DEVICE" } else &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" },
    });
    return video;
}

pub fn add(ctx: Context) *std.Build.Step.Compile {
    const b = ctx.b;
    const video = executable(ctx, false);
    const install = b.addInstallArtifact(video, .{});
    const entry = b.addInstallFileWithDir(support.localizedData(b, ctx.i18n_tool, ctx.layout.prefix, "data/rediwm-video.desktop"), .prefix, "share/applications/rediwm-video.desktop");
    // Desktop-specific defaults (`rediwm-mimeapps.list`) rank below the user's
    // own mimeapps.list but above the distribution's, so a fresh account opens
    // videos here without overriding anyone's choice.
    const defaults = b.addInstallFileWithDir(b.path("data/rediwm-mimeapps.list"), .prefix, "share/applications/rediwm-mimeapps.list");
    const icon_256 = b.addInstallFileWithDir(b.path("assets/icons/redi-video-icon-256.png"), .prefix, "share/icons/hicolor/256x256/apps/redi-video-icon.png");
    const icon_512 = b.addInstallFileWithDir(b.path("assets/icons/redi-video-icon-512.png"), .prefix, "share/icons/hicolor/512x512/apps/redi-video-icon.png");
    const step = b.step("video", "Build the video player");
    inline for (.{ &install.step, &entry.step, &defaults.step, &icon_256.step, &icon_512.step }) |s| {
        b.getInstallStep().dependOn(s);
        step.dependOn(s);
    }
    return video;
}

/// `src/video_tests.zig`, run by `zig build test`.
pub fn addTests(ctx: Context, test_step: *std.Build.Step) void {
    const b = ctx.b;
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/video_tests.zig"),
        .target = ctx.target,
        .optimize = ctx.optimize,
        .link_libc = true,
    }) });
    tests.root_module.addImport("wayland", ctx.wayland);
    tests.root_module.addImport("c_av", ctx.c.av);
    tests.root_module.linkSystemLibrary("wayland-client", .{});
    for (support.av_libs) |lib| tests.root_module.linkSystemLibrary(lib, .{});
    const integration = b.addSystemCommand(&.{"env"});
    integration.addPrefixedDirectoryArg("REDIWM_TEST_BIN=", support.installed(.bin, ""));
    integration.addArg("python3");
    integration.addFileArg(b.path("tests/video.py"));
    integration.addArtifactArg(executable(ctx, true));
    integration.step.dependOn(b.getInstallStep());
    b.step("test-video-integration", "Play and seek video on a private headless compositor").dependOn(&integration.step);
    const run_tests = b.addRunArtifact(tests);
    test_step.dependOn(&run_tests.step);
    b.step("test-video", "Run the video player's unit tests").dependOn(&run_tests.step);
}
