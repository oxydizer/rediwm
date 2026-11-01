//! Small build helpers: translated C headers, C sources and assets shared by
//! several artifacts, localized data files and the catalog inputs.

const std = @import("std");

/// C headers as modules: Zig 0.17 has no @cImport. Each translates one header
/// root under src/c/ (src/wlr/c.h for wlroots). The module is created without
/// the translation's link objects, so importing one never links its libraries:
/// artifacts link what they call. pkg-config only supplies include paths.
pub const CHeaders = struct {
    /// libc and Linux (`c`).
    libc: *std.Build.Module,
    /// libc, cairo, fontconfig, freetype, harfbuzz, xkbcommon (`c_gfx`).
    gfx: *std.Build.Module,
    pulse: *std.Build.Module,
    libinput: *std.Build.Module,
    png: *std.Build.Module,
    archive: *std.Build.Module,
};

pub const gfx_libs = [_][]const u8{ "cairo", "fontconfig", "freetype2", "harfbuzz", "xkbcommon" };

pub fn cHeaders(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) CHeaders {
    return .{
        .libc = cHeader(b, target, optimize, b.path("src/c/libc.h"), &.{}),
        .gfx = cHeader(b, target, optimize, b.path("src/c/gfx.h"), &gfx_libs),
        .pulse = cHeader(b, target, optimize, b.path("src/c/pulse.h"), &.{"libpulse"}),
        .libinput = cHeader(b, target, optimize, b.path("src/c/libinput.h"), &.{ "libinput", "libudev" }),
        .png = cHeader(b, target, optimize, b.path("src/c/png.h"), &.{"libpng16"}),
        .archive = cHeader(b, target, optimize, b.path("src/c/archive.h"), &.{"libarchive"}),
    };
}

pub fn cHeader(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize, header: std.Build.LazyPath, libs: []const []const u8) *std.Build.Module {
    return b.createModule(.{ .root_source_file = cTranslation(b, target, optimize, header, libs).getOutput() });
}

pub fn cTranslation(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize, header: std.Build.LazyPath, libs: []const []const u8) *std.Build.Step.TranslateC {
    const translate = b.addTranslateC(.{ .root_source_file = header, .target = target, .optimize = optimize });
    for (libs) |lib| translate.linkSystemLibrary(lib, .{});
    return translate;
}

/// A directory under the install prefix as a Run argument. The prefix is known
/// only when the build runs, so it cannot be a string.
pub fn installed(base: enum { prefix, bin }, sub_path: []const u8) std.Build.LazyPath {
    return .{ .relative = .{ .base = switch (base) {
        .prefix => .install_prefix,
        .bin => .install_bin,
    }, .sub_path = sub_path } };
}

pub fn addBass(b: *std.Build, module: *std.Build.Module) void {
    module.linkSystemLibrary("libpipewire-0.3", .{});
    module.addCSourceFile(.{ .file = b.path("src/audio/bass.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra" } });
}

/// The bass boost DSP, a LADSPA plugin that bass.c loads into its
/// filter-chain from lib/rediwm/ladspa next to the binaries.
pub fn addBassDsp(b: *std.Build, target: std.Build.ResolvedTarget) void {
    const dsp = b.addLibrary(.{
        .name = "rediwm-bass",
        .linkage = .dynamic,
        // Realtime audio code: optimized in every build mode, and no UBSan
        // runtime for PipeWire's dlopen to resolve.
        .root_module = b.createModule(.{ .target = target, .optimize = .fast, .link_libc = true, .sanitize_c = .off }),
    });
    dsp.root_module.addCSourceFile(.{ .file = b.path("src/audio/bass_dsp.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra" } });
    dsp.root_module.linkSystemLibrary("m", .{});
    b.getInstallStep().dependOn(&b.addInstallArtifact(dsp, .{
        .dest_dir = .{ .override = .lib },
        .dest_sub_path = "rediwm/ladspa/rediwm-bass.so",
        .dylib_symlinks = false,
    }).step);
}

/// projection.c and its parts (projection_internal.h); projection_test.c
/// includes them all.
pub const projection_sources = [_][]const u8{ "src/projection.c", "src/projection_props.c", "src/projection_resolve.c", "src/projection_present.c", "src/projection_pass.c", "src/projection_pick.c" };

/// scene_output.c and its parts (scene_output_internal.h).
pub const scene_output_sources = [_][]const u8{ "src/scene_output.c", "src/scene_output_collect.c", "src/scene_output_effects.c", "src/scene_output_draw.c" };

pub fn addGlass(b: *std.Build, module: *std.Build.Module, damage_audit: bool) void {
    module.linkSystemLibrary("wlroots-0.20", .{});
    module.linkSystemLibrary("egl", .{});
    module.linkSystemLibrary("glesv2", .{});
    module.addCSourceFiles(.{ .files = &projection_sources, .flags = if (damage_audit) &.{ "-std=c11", "-Wall", "-Wextra", "-DREDIWM_DAMAGE_AUDIT" } else &.{ "-std=c11", "-Wall", "-Wextra" } });
    module.addCSourceFile(.{ .file = b.path("src/node.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    module.addCSourceFiles(.{ .files = &.{ "src/node_surface.c", "src/node_subsurface_tree.c", "src/node_xdg_shell.c" }, .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    module.addCSourceFile(.{ .file = b.path("src/scene_outputs.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    module.addCSourceFiles(.{ .files = &.{ "src/scene_pass.c", "src/scene_pass_draw.c", "src/scene_pass_backdrop.c" }, .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    module.addCSourceFiles(.{ .files = &scene_output_sources, .flags = if (damage_audit) &.{ "-std=c11", "-Wall", "-Wextra", "-Werror", "-DREDIWM_DAMAGE_AUDIT" } else &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    module.addCSourceFile(.{ .file = b.path("src/scene_damage.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    module.addCSourceFile(.{ .file = b.path("src/glass.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra" } });
    module.addCSourceFile(.{ .file = b.path("src/explicit_sync.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    module.addCSourceFile(.{ .file = b.path("src/switcher_preview.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    module.addCSourceFile(.{ .file = b.path("src/extra_protocols.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
}

// ui/ and text.zig for the Cairo clients (Files, Images, the share picker):
// bundled fonts and glyphs, and what text.zig and shell_icons.zig link.
// Files' thumbnails decode JPEG and PNG with libjpeg and libpng directly:
// GdkPixbuf routes them through sandboxed loader processes, ~10x slower.
pub fn addThumbCodec(b: *std.Build, module: *std.Build.Module) void {
    module.addIncludePath(b.path("src/files"));
    module.addCSourceFile(.{ .file = b.path("src/files/thumb_codec.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    module.addImport("c_thumb_codec", cHeader(b, module.resolved_target.?, module.optimize.?, b.path("src/files/thumb_codec.h"), &.{}));
    inline for (.{ "libjpeg", "libpng16" }) |lib| module.linkSystemLibrary(lib, .{});
}

// Pinned, Files-only emulator. No dependency on the compositor or distro ABI.
pub fn addFilesTerminal(b: *std.Build, module: *std.Build.Module, for_tests: bool) void {
    const vterm = b.dependency("vterm", .{});
    module.addIncludePath(vterm.path("include"));
    module.addIncludePath(vterm.path("src"));
    module.addCSourceFiles(.{ .root = vterm.path("src"), .files = &.{ "encoding.c", "keyboard.c", "mouse.c", "parser.c", "pen.c", "screen.c", "state.c", "unicode.c", "vterm.c" }, .flags = &.{ "-std=c99", "-DNDEBUG" } });
    module.addIncludePath(b.path("src/files/terminal"));
    const flags: []const []const u8 = if (for_tests) &.{ "-std=c11", "-Wall", "-Wextra", "-Werror", "-DFT_TEST" } else &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" };
    module.addCSourceFile(.{ .file = b.path("src/files/terminal/engine.c"), .flags = flags });
    const engine = cTranslation(b, module.resolved_target.?, module.optimize.?, b.path("src/files/terminal/engine.h"), &.{});
    if (for_tests) engine.defineCMacro("FT_TEST", "1");
    module.addImport("c_terminal", b.createModule(.{ .root_source_file = engine.getOutput() }));
    module.linkSystemLibrary("util", .{});
}

pub fn addVolumes(b: *std.Build, module: *std.Build.Module) void {
    module.addIncludePath(b.path("src/files"));
    module.addCSourceFile(.{ .file = b.path("src/files/volumes.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    module.addImport("c_volumes", cHeader(b, module.resolved_target.?, module.optimize.?, b.path("src/files/volumes.h"), &.{}));
    inline for (.{ "gio-2.0", "gobject-2.0", "glib-2.0" }) |lib| module.linkSystemLibrary(lib, .{});
}

pub fn addShellUi(b: *std.Build, module: *std.Build.Module) void {
    addShellIcons(b, module);
    module.addAnonymousImport("manrope", .{ .root_source_file = b.path("assets/fonts/Manrope-VariableFont_wght.ttf") });
    module.addAnonymousImport("jetbrains_mono_regular", .{ .root_source_file = b.path("assets/fonts/JetBrainsMono-Regular.ttf") });
    module.addAnonymousImport("jetbrains_mono_bold", .{ .root_source_file = b.path("assets/fonts/JetBrainsMono-Bold.ttf") });
    inline for (.{ "cairo", "librsvg-2.0", "freetype2", "harfbuzz", "fontconfig" }) |lib| module.linkSystemLibrary(lib, .{});
}

// Bundle shell glyphs so installed binaries never depend on the checkout.
pub fn addShellIcons(b: *std.Build, module: *std.Build.Module) void {
    module.addAnonymousImport("redi-logo", .{ .root_source_file = b.path("assets/redi-logo.svg") });
    module.addAnonymousImport("rediwm-settings-icon", .{ .root_source_file = b.path("assets/icons/rediwm-settings.png") });
    inline for (.{ "git-branch", "home", "folder", "terminal", "settings", "keyboard", "edit", "mouse", "touchpad", "trackball", "display", "music", "headphones", "wifi", "ethernet", "globe", "bluetooth", "battery", "notification-bell", "speaker", "speaker-xmark", "power-button", "clock", "lock", "logout", "restart", "eye", "eye-off", "refresh", "cut", "copy", "paste", "trash-outline", "trash", "view-grid", "view-list", "sort", "filter", "zoom-in", "zoom-out", "rotate", "crop", "undo", "save", "fit", "print", "open", "usb-stick", "drive", "eject", "users", "squares", "divide" }) |name| {
        module.addAnonymousImport("shell-icon-" ++ name, .{ .root_source_file = b.path("assets/icons/" ++ name ++ ".svg") });
    }
}

/// Localize installed metadata from the same reviewed catalog entries as UI.
pub fn localizedData(b: *std.Build, tool: *std.Build.Step.Compile, prefix: []const u8, path: []const u8) std.Build.LazyPath {
    const run = b.addRunArtifact(tool);
    run.setCwd(b.path("."));
    run.addArg("data");
    run.addFileArg(@import("install_paths.zig").configure(b, path, prefix));
    const result = run.addOutputFileArg(std.fs.path.basename(path));
    run.addDirectoryArg(b.path("po"));
    addCatalogInputs(b, run);
    return result;
}

/// Directory arguments alone do not hash their contents. Track every catalog
/// explicitly so edits, review flags and newly added languages invalidate both
/// compiled UI tables and installed desktop/polkit metadata.
pub fn addCatalogInputs(b: *std.Build, run: *std.Build.Step.Run) void {
    b.dependOnDirectoryContents(b.path("po"));
    var dir = b.root.openDir(b.graph.io, "po", .{ .iterate = true }) catch @panic("cannot open po/");
    defer dir.close(b.graph.io);
    var paths: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (it.next(b.graph.io) catch @panic("cannot read po/")) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.endsWith(u8, entry.name, ".po") or std.mem.eql(u8, entry.name, "rediwm.pot")) paths.append(b.allocator, b.fmt("po/{s}", .{entry.name})) catch @panic("OOM");
    }
    std.mem.sort([]const u8, paths.items, {}, struct {
        fn less(_: void, left: []const u8, right: []const u8) bool {
            return std.mem.lessThan(u8, left, right);
        }
    }.less);
    for (paths.items) |path| run.addFileInput(b.path(path));
}
