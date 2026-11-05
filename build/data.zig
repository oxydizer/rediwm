//! Installed data: portals, sessions, polkit policy, wallpapers and cursors.

const std = @import("std");
const Context = @import("context.zig").Context;
const support = @import("support.zig");
const localizedData = support.localizedData;

/// Portal and session files, policies, wallpapers and the generated cursor themes.
pub fn add(ctx: Context) void {
    const b = ctx.b;
    const use_llvm = ctx.use_llvm;
    const i18n_tool = ctx.i18n_tool;
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(
        b.path("data/rediwm-portals.conf"),
        .prefix,
        "share/xdg-desktop-portal/rediwm-portals.conf",
    ).step);
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(
        b.path("data/rediwm.portal"),
        .prefix,
        "share/xdg-desktop-portal/portals/rediwm.portal",
    ).step);
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(
        b.path("data/xdg-desktop-portal-wlr.ini"),
        .prefix,
        "share/xdg-desktop-portal-wlr/config",
    ).step);
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(
        localizedData(b, i18n_tool, ctx.layout.prefix, "data/rediwm.desktop"),
        .prefix,
        "share/wayland-sessions/rediwm.desktop",
    ).step);

    b.getInstallStep().dependOn(&b.addInstallFileWithDir(localizedData(b, i18n_tool, ctx.layout.prefix, "data/org.rediwm.accounts.policy"), .prefix, "share/polkit-1/actions/org.rediwm.accounts.policy").step);
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(localizedData(b, i18n_tool, ctx.layout.prefix, "data/rediwm-release-safe.desktop"), .prefix, "share/wayland-sessions/rediwm-release-safe.desktop").step);

    inline for (.{ "rediwm-dm.conf", "rediwm-dm.service" }) |name| {
        const configured = @import("install_paths.zig").configure(b, "data/" ++ name, ctx.layout.prefix);
        b.getInstallStep().dependOn(&b.addInstallFileWithDir(configured, .prefix, "share/rediwm/" ++ name).step);
    }

    // Wallpapers, found at runtime through share/rediwm/wallpapers next to
    // the binaries (wallpapers.zig); `[compositor] wallpaper` picks one.
    b.installDirectory(.{
        .source_dir = b.path("assets/wallpapers"),
        .install_dir = .prefix,
        .install_subdir = "share/rediwm/wallpapers",
    });

    // Xcursor themes rendered from the vendored phinger-cursors SVGs. They
    // land in share/icons next to the binaries; the compositor adds that
    // directory to XCURSOR_PATH for itself and its children.
    const cursorgen = b.addExecutable(.{
        .name = "rediwm-cursorgen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cursor_theme_gen.zig"),
            .target = b.graph.host,
            .optimize = .safe,
            .link_libc = true,
        }),
        .use_llvm = use_llvm,
        .use_lld = use_llvm,
    });
    cursorgen.root_module.linkSystemLibrary("librsvg-2.0", .{});
    cursorgen.root_module.linkSystemLibrary("cairo", .{});
    cursorgen.root_module.addImport("c_gfx", support.cHeader(b, b.graph.host, .safe, b.path("src/c/gfx.h"), &support.gfx_libs));
    const cursorgen_run = b.addRunArtifact(cursorgen);
    cursorgen_run.addDirectoryArg(b.path("assets/cursors"));
    const cursor_themes = cursorgen_run.addOutputDirectoryArg("icons");
    // Cursor aliases are symlinks, which InstallDir drops; cp -a keeps them.
    // "$1/." copies the contents into the existing "$2" with GNU and BSD cp (-T is GNU only).
    const install_cursors = b.addSystemCommand(&.{ "sh", "-c", "mkdir -p \"$2\" && cp -a \"$1/.\" \"$2\"", "sh" });
    install_cursors.addDirectoryArg(cursor_themes);
    install_cursors.addDirectoryArg(support.installed(.prefix, "share/icons"));
    b.getInstallStep().dependOn(&install_cursors.step);
}
