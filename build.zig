//! RediWM's build: options, the shared modules, the compositor and rediwm-msg.
//! The other programs, installed data, the session binaries and every test step
//! are in build/ (apps, data, session, tests.zig); generated Wayland bindings in
//! build/protocols.zig, helpers in build/support.zig.

const std = @import("std");

const Context = @import("build/context.zig").Context;
const protocols = @import("build/protocols.zig");
const apps = @import("build/apps.zig");
const data = @import("build/data.zig");
const session_build = @import("build/session.zig");
const tests = @import("build/tests.zig");
const support = @import("build/support.zig");
const addBass = support.addBass;
const addBassDsp = support.addBassDsp;
const addGlass = support.addGlass;
const addThumbCodec = support.addThumbCodec;
const addShellUi = support.addShellUi;
const localizedData = support.localizedData;
const addCatalogInputs = support.addCatalogInputs;

pub fn build(b: *std.Build) void {
    const layout = @import("build/install_paths.zig").Layout.init(b);
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const use_llvm = b.option(bool, "llvm", "Use LLVM and LLD (default for optimized builds)") orelse (optimize != .debug);
    // Debug aid (TESTING.md): redraw every frame whole and log what the damage missed.
    const damage_audit = b.option(bool, "damage-audit", "Compare every frame with a full repaint and log the difference (slow)") orelse false;
    // Debug aid: log the timing of every frame (event, render, commit, presentation).
    const frame_trace = b.option(bool, "frame-trace", "Log per-frame timing for frame scheduling measurements (src/output/frame_trace.zig)") orelse false;
    const trace_options = b.addOptions();
    trace_options.addOption(bool, "frame_trace", frame_trace);
    const trace_mod = trace_options.createModule();
    // Set by scripts/build-wlroots.sh builds on distros without wlroots 0.20
    // (Debian/Ubuntu). pkg-config runs in zig build's own environment, so
    // start it through scripts/with-wlroots.sh to find the prefix.
    const wlroots_prefix = b.option([]const u8, "wlroots-prefix", "Use wlroots and its bundled dependencies from this private prefix (run through scripts/with-wlroots.sh)");

    const c_headers = support.cHeaders(b, target, optimize);
    const wayland = protocols.module(b);
    const xkbcommon = b.dependency("xkbcommon", .{}).module("xkbcommon");
    const pixman = b.dependency("pixman", .{}).module("pixman");
    // One header-backed module supplies every compositor wlroots binding.
    const wlr_facade = b.createModule(.{
        .root_source_file = b.path("src/wlr/wlr.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    wlr_facade.addImport("wayland", wayland);
    wlr_facade.addImport("pixman", pixman);
    wlr_facade.addImport("xkbcommon", xkbcommon);
    wlr_facade.linkSystemLibrary("wlroots-0.20", .{});
    const wlr_c = support.cTranslation(b, target, optimize, b.path("src/wlr/c.h"), &.{"wlroots-0.20"});

    // These public wlroots headers include protocol headers which wlroots
    // does not install. Generate them from the same XML as our Zig bindings.
    inline for (.{ "wlr-output-power-management-unstable-v1", "wlr-layer-shell-unstable-v1" }) |name| {
        const run = b.addSystemCommand(&.{ "wayland-scanner", "server-header" });
        run.addFileArg(b.path("protocol/" ++ name ++ ".xml"));
        const header = run.addOutputFileArg(name ++ "-protocol.h");
        wlr_c.addIncludePath(header.dirname());
    }
    wlr_facade.addImport("wlr_c", b.createModule(.{ .root_source_file = wlr_c.getOutput() }));

    const wlroots = wlr_facade;

    // Module roots enforce one-way dependencies: shared code cannot import Server.
    const memory_mod = b.createModule(.{ .root_source_file = b.path("src/memory/allocator.zig"), .target = target, .optimize = optimize });
    // The OS-specific parts (children, file watching, own path): std only.
    const platform_mod = b.createModule(.{ .root_source_file = b.path("src/platform/mod.zig"), .target = target, .optimize = optimize });
    const i18n_tool = b.addExecutable(.{ .name = "i18n-tool", .root_module = b.createModule(.{ .root_source_file = b.path("tools/i18n.zig"), .target = b.graph.host, .optimize = .safe }) });
    const catalog_compile = b.addRunArtifact(i18n_tool);
    catalog_compile.setCwd(b.path("."));
    catalog_compile.addArg("compile");
    const catalog_source = catalog_compile.addOutputFileArg("catalogs.zig");
    catalog_compile.addDirectoryArg(b.path("po"));
    addCatalogInputs(b, catalog_compile);
    const i18n_mod = b.createModule(.{ .root_source_file = b.path("src/i18n/mod.zig"), .target = target, .optimize = optimize });
    i18n_mod.addAnonymousImport("catalogs", .{ .root_source_file = catalog_source });
    inline for (.{ .{ "extract", "Regenerate the UI message template" }, .{ "check", "Check UI catalogs, placeholders and plural forms" }, .{ "lint", "Check converted UI files for untranslated literals" } }) |entry| {
        const run = b.addRunArtifact(i18n_tool);
        run.setCwd(b.path("."));
        run.addArg(entry[0]);
        b.step("i18n-" ++ entry[0], entry[1]).dependOn(&run.step);
    }
    const ui_mod = b.createModule(.{ .root_source_file = b.path("src/ui/mod.zig"), .target = target, .optimize = optimize, .link_libc = true });
    ui_mod.addImport("i18n", i18n_mod);
    ui_mod.addImport("memory", memory_mod);
    ui_mod.addImport("wayland", wayland);
    ui_mod.addImport("c_gfx", c_headers.gfx);
    ui_mod.linkSystemLibrary("xkbcommon", .{});
    addShellUi(b, ui_mod);
    ui_mod.addAnonymousImport("theme-rediwm-dark", .{ .root_source_file = b.path("assets/themes/rediwm-dark.toml") });
    ui_mod.addAnonymousImport("theme-rediwm-light", .{ .root_source_file = b.path("assets/themes/rediwm-light.toml") });
    ui_mod.addAnonymousImport("theme-redi-blue", .{ .root_source_file = b.path("assets/themes/redi-blue.toml") });
    ui_mod.addAnonymousImport("theme-redi-mocha", .{ .root_source_file = b.path("assets/themes/redi-mocha.toml") });
    ui_mod.addAnonymousImport("theme-chamfer-blue", .{ .root_source_file = b.path("assets/themes/chamfer-blue.toml") });
    ui_mod.addAnonymousImport("theme-gold", .{ .root_source_file = b.path("assets/themes/gold.toml") });
    b.getInstallStep().dependOn(&b.addInstallDirectory(.{
        .source_dir = b.path("assets/themes/gold"),
        .install_dir = .prefix,
        .install_subdir = "share/rediwm/themes/gold",
    }).step);
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(b.path("assets/themes/gold.toml"), .prefix, "share/rediwm/themes/gold/theme.toml").step);
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(b.path("assets/wallpapers/wallpaper-gold.png"), .prefix, "share/rediwm/themes/gold/wallpapers/wallpaper-gold.png").step);
    const dbus_mod = b.createModule(.{ .root_source_file = b.path("src/dbus/mod.zig"), .target = target, .optimize = optimize, .link_libc = true });
    dbus_mod.addImport("wayland", wayland);
    dbus_mod.linkSystemLibrary("wayland-server", .{});
    const config_mod = b.createModule(.{ .root_source_file = b.path("src/config/mod.zig"), .target = target, .optimize = optimize, .link_libc = true });
    config_mod.addImport("ui", ui_mod);
    config_mod.addImport("i18n", i18n_mod);
    config_mod.addImport("xkbcommon", xkbcommon);
    config_mod.linkSystemLibrary("xkbcommon", .{});

    const theme_helper = b.addExecutable(.{
        .name = "rediwm-theme",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/theme_main.zig"), .target = target, .optimize = optimize, .link_libc = true }),
        .use_llvm = use_llvm,
        .use_lld = use_llvm,
    });
    theme_helper.root_module.addImport("config", config_mod);
    theme_helper.root_module.addImport("ui", ui_mod);
    theme_helper.root_module.addImport("i18n", i18n_mod);
    theme_helper.root_module.addImport("platform", platform_mod);
    theme_helper.root_module.addCSourceFile(.{ .file = b.path("src/theme_helper/native.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    inline for (.{ "libarchive", "librsvg-2.0", "gdk-pixbuf-2.0" }) |lib| theme_helper.root_module.linkSystemLibrary(lib, .{});
    addThumbCodec(b, theme_helper.root_module);
    theme_helper.root_module.linkSystemLibrary("libwebp", .{});
    b.installArtifact(theme_helper);
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(localizedData(b, i18n_tool, layout.prefix, "data/rediwm-theme.desktop"), .prefix, "share/applications/rediwm-theme.desktop").step);
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(b.path("data/rediwm-theme.xml"), .prefix, "share/mime/packages/rediwm-theme.xml").step);

    const protocol_mod = b.createModule(.{
        .root_source_file = b.path("src/ipc/protocol.zig"),
        .target = target,
        .optimize = optimize,
    });

    const compositor = b.addExecutable(.{
        .name = "rediwm",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
        .use_llvm = use_llvm,
        .use_lld = use_llvm,
    });
    compositor.root_module.addImport("protocol", protocol_mod);
    compositor.root_module.addImport("wayland", wayland);
    compositor.root_module.addImport("xkbcommon", xkbcommon);
    compositor.root_module.addImport("wlroots", wlroots);
    compositor.root_module.addImport("pixman", pixman);
    compositor.root_module.addImport("c_pulse", c_headers.pulse);
    compositor.root_module.addImport("c_libinput", c_headers.libinput);
    compositor.root_module.addImport("c_png", c_headers.png);
    compositor.root_module.linkSystemLibrary("wayland-server", .{});
    compositor.root_module.linkSystemLibrary("cups", .{});
    compositor.root_module.addCSourceFile(.{ .file = b.path("src/printing/direct.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror", "-Wno-deprecated-declarations" } });
    compositor.root_module.linkSystemLibrary("xkbcommon", .{});
    compositor.root_module.linkSystemLibrary("pixman-1", .{});
    compositor.root_module.linkSystemLibrary("freetype2", .{});
    compositor.root_module.linkSystemLibrary("harfbuzz", .{});
    compositor.root_module.linkSystemLibrary("fontconfig", .{});
    // Pulls in cairo/gdk-pixbuf/glib/gobject/gio transitively via its own
    // pkg-config Requires: chain — no separate linkSystemLibrary calls needed
    // for those. Used by icon_cache.zig to rasterize XDG-theme SVG icons.
    compositor.root_module.linkSystemLibrary("librsvg-2.0", .{});
    // Pointer/keyboard device config for the control center's Input section
    // (accel speed, natural scroll, tap-to-click). Header is a clean, glib-free
    // C API so it's @cInclude'd directly, unlike librsvg (see AGENTS.md, "Build and platform gotchas").
    compositor.root_module.linkSystemLibrary("libinput", .{});
    compositor.root_module.linkSystemLibrary("libudev", .{});
    compositor.root_module.linkSystemLibrary("png16", .{});
    // PipeWire's PulseAudio-compat client library — see src/audio/pipewire.zig.
    compositor.root_module.linkSystemLibrary("libpulse", .{});
    addBass(b, compositor.root_module);
    addBassDsp(b, target);
    compositor.root_module.linkSystemLibrary("pam", .{});
    compositor.root_module.linkSystemLibrary("xcb", .{});
    compositor.root_module.addCSourceFile(.{ .file = b.path("src/session/auth.c"), .flags = &.{"-std=c11"} });
    compositor.root_module.addCSourceFile(.{ .file = b.path("src/polkit/native.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    addGlass(b, compositor.root_module, damage_audit);
    if (frame_trace) compositor.root_module.addCMacro("REDIWM_FRAME_TRACE", "1");
    compositor.root_module.addCSourceFile(.{ .file = b.path("src/gpu_timing.c"), .flags = &.{"-std=c11"} });
    b.step("rediwm", "Build the compositor").dependOn(&compositor.step);

    b.installArtifact(compositor);

    const msg_cli = b.addExecutable(.{
        .name = "rediwm-msg",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/msg/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
        .use_llvm = use_llvm,
        .use_lld = use_llvm,
    });
    msg_cli.root_module.addImport("protocol", protocol_mod);
    b.installArtifact(msg_cli);

    const ctx: Context = .{
        .b = b,
        .layout = layout,
        .target = target,
        .optimize = optimize,
        .use_llvm = use_llvm,
        .wlroots_prefix = wlroots_prefix,
        .i18n_tool = i18n_tool,
        .wayland = wayland,
        .xkbcommon = xkbcommon,
        .pixman = pixman,
        .wlroots = wlroots,
        .i18n_mod = i18n_mod,
        .ui_mod = ui_mod,
        .dbus_mod = dbus_mod,
        .platform_mod = platform_mod,
        .config_mod = config_mod,
        .protocol_mod = protocol_mod,
        .c = c_headers,
    };
    const app = apps.add(ctx);
    const files = app.files;
    const images = app.images;
    const monitor = app.monitor;
    const calculator = app.calculator;
    const editor = app.editor;
    const pdf = app.pdf;
    const share_picker = app.share_picker;
    if (wlroots_prefix) |prefix| {
        // Installed next to the binaries so both zig-out/ and /usr/local work.
        b.installDirectory(.{
            .source_dir = .{ .cwd_relative = b.pathJoin(&.{ prefix, "runtime" }) },
            .install_dir = .lib,
            .install_subdir = "rediwm",
        });
        for ([_]*std.Build.Step.Compile{ compositor, files, images, share_picker, pdf, editor }) |exe|
            exe.root_module.addRPathSpecial("$ORIGIN/../lib/rediwm");
    }
    data.add(ctx);

    const session = session_build.add(ctx);
    const session_supervisor = session.session_supervisor;

    const zig_tests = tests.addZig(ctx, session);
    const ui_tests_module = zig_tests.ui_tests_module;
    const ipc_tests_module = zig_tests.ipc_tests_module;
    const files_tests = zig_tests.files_tests;
    const images_tests = zig_tests.images_tests;
    const editor_tests = zig_tests.editor_tests;
    const pdf_tests = zig_tests.pdf_tests;
    const session_tests = zig_tests.session_tests;
    const share_picker_tests = zig_tests.share_picker_tests;
    const dbus_tests = zig_tests.dbus_tests;
    const dbus_service = zig_tests.dbus_service;
    const polkit_service = zig_tests.polkit_service;

    // Hosts also rasterize app-specific content through their own C imports.
    inline for (.{ files.root_module, images.root_module, editor.root_module, pdf.root_module, share_picker.root_module, monitor.root_module, calculator.root_module, files_tests.root_module, images_tests.root_module, editor_tests.root_module, pdf_tests.root_module }) |module| {
        inline for (.{ "cairo", "librsvg-2.0", "freetype2", "harfbuzz", "fontconfig" }) |lib| module.linkSystemLibrary(lib, .{});
    }
    inline for (.{ compositor.root_module, ui_tests_module, files.root_module, images.root_module, editor.root_module, pdf.root_module, share_picker.root_module, monitor.root_module, calculator.root_module, editor_tests.root_module, images_tests.root_module, pdf_tests.root_module, files_tests.root_module, ipc_tests_module, protocol_mod, session_supervisor.root_module, session_tests.root_module, share_picker_tests.root_module, dbus_tests.root_module }) |module| {
        module.addImport("install_paths", layout.options);
        module.addImport("trace", trace_mod);
        module.addImport("ui", ui_mod);
        module.addImport("i18n", i18n_mod);
        module.addImport("config", config_mod);
        module.addImport("memory", memory_mod);
        module.addImport("platform", platform_mod);
        module.addImport("c", c_headers.libc);
        module.addImport("c_gfx", c_headers.gfx);
    }
    inline for (.{ compositor.root_module, ui_tests_module, dbus_tests.root_module, dbus_service.root_module, polkit_service.root_module, session_supervisor.root_module, session_tests.root_module, share_picker_tests.root_module, files_tests.root_module }) |module| {
        module.addImport("dbus", dbus_mod);
    }

    tests.addC(ctx, zig_tests.test_step);

    // Autostart looks up `rediwm-desktop` / `rediwm-files` on PATH. Run the
    // cached artifact with the installed bin directory first on PATH.
    const run_cmd = b.addSystemCommand(&.{ "sh", "-c", "PATH=\"$0:$PATH\" exec \"$@\"" });
    run_cmd.addDirectoryArg(support.installed(.bin, ""));
    run_cmd.addArtifactArg(compositor);
    // The development run target is always nested in the current Wayland session.
    run_cmd.setEnvironmentVariable("WLR_BACKENDS", "wayland");
    run_cmd.setEnvironmentVariable("WLR_WL_OUTPUTS", "1");
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Run the nested compositor (pass a client command after --)");
    run_step.dependOn(&run_cmd.step);
}
