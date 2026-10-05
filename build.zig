const std = @import("std");

const Scanner = @import("wayland").Scanner;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const use_llvm = b.option(bool, "llvm", "Use LLVM and LLD (default for optimized builds)") orelse (optimize != .Debug);
    // Set by scripts/build-wlroots.sh builds on distros without wlroots 0.20
    // (Debian/Ubuntu). Must be applied before anything runs pkg-config.
    const wlroots_prefix = b.option([]const u8, "wlroots-prefix", "Use wlroots and its bundled dependencies from this private prefix (see scripts/build-wlroots.sh)");
    if (wlroots_prefix) |prefix| usePrivateWlroots(b, prefix);

    const scanner = Scanner.create(b, .{});
    scanner.addSystemProtocol("stable/xdg-shell/xdg-shell.xml");
    scanner.addSystemProtocol("unstable/text-input/text-input-unstable-v3.xml");
    scanner.generate("zwp_text_input_manager_v3", 1);
    scanner.addSystemProtocol("staging/xdg-activation/xdg-activation-v1.xml");
    scanner.addSystemProtocol("staging/security-context/security-context-v1.xml");
    scanner.generate("wp_security_context_manager_v1", 1);
    scanner.generate("xdg_activation_v1", 1);
    scanner.addCustomProtocol(b.path("protocol/wlr-layer-shell-unstable-v1.xml"));
    scanner.generate("zwlr_layer_shell_v1", 4);
    scanner.addSystemProtocol("stable/tablet/tablet-v2.xml");
    scanner.addSystemProtocol("staging/cursor-shape/cursor-shape-v1.xml");
    scanner.addSystemProtocol("staging/ext-idle-notify/ext-idle-notify-v1.xml");
    scanner.addSystemProtocol("staging/color-management/color-management-v1.xml");
    scanner.addSystemProtocol("unstable/idle-inhibit/idle-inhibit-unstable-v1.xml");
    scanner.addSystemProtocol("unstable/xdg-decoration/xdg-decoration-unstable-v1.xml");
    scanner.addCustomProtocol(b.path("protocol/server-decoration.xml"));
    scanner.addCustomProtocol(b.path("protocol/virtual-keyboard-unstable-v1.xml"));
    scanner.addSystemProtocol("unstable/pointer-gestures/pointer-gestures-unstable-v1.xml");
    scanner.addSystemProtocol("unstable/xdg-output/xdg-output-unstable-v1.xml");
    scanner.addSystemProtocol("unstable/pointer-constraints/pointer-constraints-unstable-v1.xml");
    scanner.addSystemProtocol("unstable/relative-pointer/relative-pointer-unstable-v1.xml");
    scanner.addSystemProtocol("staging/ext-session-lock/ext-session-lock-v1.xml");
    scanner.addCustomProtocol(b.path("protocol/wlr-output-power-management-unstable-v1.xml"));

    // These versions control generated Zig bindings only. They do not change
    // the wlroots ABI used by the compositor.
    scanner.generate("wl_compositor", 5);
    scanner.generate("wl_subcompositor", 1);
    scanner.generate("wl_shm", 1);
    scanner.generate("wl_output", 4);
    scanner.generate("wl_seat", 8);
    scanner.generate("wl_data_device_manager", 3);
    scanner.generate("xdg_wm_base", 2);
    scanner.generate("zwp_tablet_manager_v2", 1);
    scanner.generate("wp_cursor_shape_manager_v1", 2);
    scanner.generate("ext_idle_notifier_v1", 1);
    scanner.generate("zwp_idle_inhibit_manager_v1", 1);
    scanner.generate("wp_color_manager_v1", 2);
    scanner.generate("zxdg_decoration_manager_v1", 1);
    scanner.generate("org_kde_kwin_server_decoration_manager", 1);
    scanner.generate("zwp_virtual_keyboard_manager_v1", 1);
    scanner.generate("zwp_pointer_gestures_v1", 3);
    scanner.generate("zxdg_output_manager_v1", 3);
    scanner.generate("zwp_pointer_constraints_v1", 1);
    scanner.generate("zwp_relative_pointer_manager_v1", 1);
    scanner.generate("ext_session_lock_manager_v1", 1);
    scanner.generate("zwlr_output_power_manager_v1", 1);

    const wayland = b.createModule(.{ .root_source_file = scanner.result });
    const xkbcommon = b.dependency("xkbcommon", .{}).module("xkbcommon");
    const pixman = b.dependency("pixman", .{}).module("pixman");
    const wlroots = b.dependency("wlroots", .{}).module("wlroots");

    wlroots.addImport("wayland", wayland);
    wlroots.addImport("xkbcommon", xkbcommon);
    wlroots.addImport("pixman", pixman);

    // Expose the wlroots include path from pkg-config to its @cImport calls.
    wlroots.resolved_target = target;
    wlroots.linkSystemLibrary("wlroots-0.20", .{});

    // Module roots enforce one-way dependencies: shared code cannot import Server.
    const memory_mod = b.createModule(.{ .root_source_file = b.path("src/memory/allocator.zig"), .target = target, .optimize = optimize });
    const ui_mod = b.createModule(.{ .root_source_file = b.path("src/ui/mod.zig"), .target = target, .optimize = optimize, .link_libc = true });
    ui_mod.addImport("memory", memory_mod);
    ui_mod.addImport("wayland", wayland);
    addShellUi(b, ui_mod);
    ui_mod.addAnonymousImport("theme-rediwm-dark", .{ .root_source_file = b.path("src/assets/themes/rediwm-dark.toml") });
    ui_mod.addAnonymousImport("theme-rediwm-light", .{ .root_source_file = b.path("src/assets/themes/rediwm-light.toml") });
    ui_mod.addAnonymousImport("theme-redi-blue", .{ .root_source_file = b.path("src/assets/themes/redi-blue.toml") });
    const dbus_mod = b.createModule(.{ .root_source_file = b.path("src/dbus/mod.zig"), .target = target, .optimize = optimize, .link_libc = true });
    dbus_mod.addImport("wayland", wayland);
    dbus_mod.linkSystemLibrary("wayland-server", .{});
    const config_mod = b.createModule(.{ .root_source_file = b.path("src/config/mod.zig"), .target = target, .optimize = optimize, .link_libc = true });
    config_mod.addImport("ui", ui_mod);
    config_mod.addImport("xkbcommon", xkbcommon);
    config_mod.linkSystemLibrary("xkbcommon", .{});

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
    compositor.root_module.linkSystemLibrary("wayland-server", .{});
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
    compositor.root_module.linkSystemLibrary("png16", .{});
    // PipeWire's PulseAudio-compat client library — see src/audio/pipewire.zig.
    compositor.root_module.linkSystemLibrary("libpulse", .{});
    addBass(b, compositor.root_module);
    addBassDsp(b, target);
    compositor.root_module.linkSystemLibrary("pam", .{});
    compositor.root_module.linkSystemLibrary("xcb", .{});
    compositor.root_module.addCSourceFile(.{ .file = b.path("src/session/auth.c"), .flags = &.{"-std=c11"} });
    compositor.root_module.addCSourceFile(.{ .file = b.path("src/polkit/native.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    addGlass(b, compositor.root_module);
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

    const files = b.addExecutable(.{
        .name = "rediwm-files",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/files_main.zig"), .target = target, .optimize = optimize, .link_libc = true }),
        .use_llvm = use_llvm,
        .use_lld = use_llvm,
    });
    files.root_module.addImport("wayland", wayland);
    inline for (.{ "wayland-client", "wayland-cursor", "xkbcommon", "gio-2.0", "gdk-pixbuf-2.0", "gobject-2.0", "glib-2.0" }) |lib| files.root_module.linkSystemLibrary(lib, .{});
    files.root_module.linkSystemLibrary("libarchive", .{});
    addThumbCodec(b, files.root_module);
    addVolumes(b, files.root_module);
    const install_files = b.addInstallArtifact(files, .{});
    // Advertises rediwm-files to the start menu's applications scanner
    // (src/start_menu/applications.zig) and to any other XDG-aware
    // launcher. Its icon is installed in the hicolor fallback theme so the
    // start menu and taskbar can resolve the desktop entry's Icon name.
    const install_files_desktop_entry = b.addInstallFileWithDir(
        b.path("data/rediwm-files.desktop"),
        .prefix,
        "share/applications/rediwm-files.desktop",
    );
    b.getInstallStep().dependOn(&install_files.step);
    b.getInstallStep().dependOn(&install_files_desktop_entry.step);
    const install_files_icon = b.addSystemCommand(&.{ "install", "-Dm644" });
    install_files_icon.addFileArg(b.path("icons/redi-fm-icon.png"));
    install_files_icon.addArg(b.getInstallPath(.prefix, "share/icons/hicolor/256x256/apps/redi-fm-icon.png"));
    b.getInstallStep().dependOn(&install_files_icon.step);
    // rediwm-files links neither wlroots-server nor libinput/libpulse, so it
    // can be built (and its dependencies checked) without the rest of this
    // repository's toolchain. `zig build` (the default `install` step) still
    // builds everything, this only adds a narrower entry point.
    const files_step = b.step("files", "Build the standalone Files and image viewer clients");
    files_step.dependOn(&install_files.step);
    files_step.dependOn(&install_files_desktop_entry.step);

    const images = b.addExecutable(.{
        .name = "rediwm-images",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/images_main.zig"), .target = target, .optimize = optimize, .link_libc = true }),
        .use_llvm = use_llvm,
        .use_lld = use_llvm,
    });
    images.root_module.addImport("wayland", wayland);
    inline for (.{ "wayland-client", "wayland-cursor", "gdk-pixbuf-2.0", "gobject-2.0", "glib-2.0", "xkbcommon" }) |lib| images.root_module.linkSystemLibrary(lib, .{});
    const install_images = b.addInstallArtifact(images, .{});
    const images_entry = b.addInstallFileWithDir(b.path("data/rediwm-images.desktop"), .prefix, "share/applications/rediwm-images.desktop");
    b.getInstallStep().dependOn(&install_images.step);
    b.getInstallStep().dependOn(&images_entry.step);
    const images_step = b.step("images", "Build the standalone image viewer");
    images_step.dependOn(&install_images.step);
    images_step.dependOn(&images_entry.step);
    files_step.dependOn(&install_images.step);
    files_step.dependOn(&images_entry.step);

    const editor = b.addExecutable(.{
        .name = "rediwm-editor",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/editor_main.zig"), .target = target, .optimize = optimize, .link_libc = true }),
        .use_llvm = use_llvm,
        .use_lld = use_llvm,
    });
    editor.root_module.addImport("wayland", wayland);
    inline for (.{ "wayland-client", "wayland-cursor", "xkbcommon", "pangocairo", "gio-2.0" }) |lib| editor.root_module.linkSystemLibrary(lib, .{});
    const install_editor = b.addInstallArtifact(editor, .{});
    const editor_entry = b.addInstallFileWithDir(b.path("data/rediwm-editor.desktop"), .prefix, "share/applications/rediwm-editor.desktop");
    b.getInstallStep().dependOn(&install_editor.step);
    b.getInstallStep().dependOn(&editor_entry.step);
    const editor_step = b.step("editor", "Build the standalone text editor");
    editor_step.dependOn(&install_editor.step);
    editor_step.dependOn(&editor_entry.step);
    files_step.dependOn(&install_editor.step);
    files_step.dependOn(&editor_entry.step);

    const pdf = b.addExecutable(.{
        .name = "rediwm-pdf",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/pdf_main.zig"), .target = target, .optimize = optimize, .link_libc = true }),
        .use_llvm = use_llvm,
        .use_lld = use_llvm,
    });
    pdf.root_module.addImport("wayland", wayland);
    pdf.root_module.addCSourceFile(.{ .file = b.path("src/pdf/sandbox.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    pdf.root_module.linkSystemLibrary("seccomp", .{});
    inline for (.{ "wayland-client", "wayland-cursor", "poppler-glib", "cairo", "gobject-2.0", "glib-2.0", "xkbcommon" }) |lib| pdf.root_module.linkSystemLibrary(lib, .{});
    const install_pdf = b.addInstallArtifact(pdf, .{});
    const pdf_entry = b.addInstallFileWithDir(b.path("data/rediwm-pdf.desktop"), .prefix, "share/applications/rediwm-pdf.desktop");
    b.getInstallStep().dependOn(&install_pdf.step);
    b.getInstallStep().dependOn(&pdf_entry.step);
    const pdf_step = b.step("pdf", "Build the standalone PDF viewer");
    pdf_step.dependOn(&install_pdf.step);
    pdf_step.dependOn(&pdf_entry.step);

    const share_picker = b.addExecutable(.{
        .name = "rediwm-share-picker",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/share_picker_main.zig"), .target = target, .optimize = optimize, .link_libc = true }),
        .use_llvm = use_llvm,
        .use_lld = use_llvm,
    });
    share_picker.root_module.addImport("wayland", wayland);
    inline for (.{ "wayland-client", "xkbcommon" }) |lib| share_picker.root_module.linkSystemLibrary(lib, .{});
    b.installArtifact(share_picker);
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
        b.path("data/rediwm.desktop"),
        .prefix,
        "share/wayland-sessions/rediwm.desktop",
    ).step);

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
            .optimize = .ReleaseSafe,
            .link_libc = true,
        }),
        .use_llvm = use_llvm,
        .use_lld = use_llvm,
    });
    cursorgen.root_module.linkSystemLibrary("librsvg-2.0", .{});
    cursorgen.root_module.linkSystemLibrary("cairo", .{});
    const cursorgen_run = b.addRunArtifact(cursorgen);
    cursorgen_run.addDirectoryArg(b.path("assets/cursors"));
    const cursor_themes = cursorgen_run.addOutputDirectoryArg("icons");
    // Cursor aliases are symlinks, which InstallDir drops; cp -a keeps them.
    const install_cursors = b.addSystemCommand(&.{ "sh", "-c", "mkdir -p \"$2\" && cp -a -T \"$1\" \"$2\"", "sh" });
    install_cursors.addDirectoryArg(cursor_themes);
    install_cursors.addArg(b.getInstallPath(.prefix, "share/icons"));
    b.getInstallStep().dependOn(&install_cursors.step);

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
    b.installArtifact(session_supervisor);

    const child_set_mod = b.createModule(.{ .root_source_file = b.path("src/child_set.zig"), .target = target, .optimize = optimize });
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
    dm.root_module.addImport("child_set", child_set_mod);
    dm.root_module.addImport("dm_ipc", dm_ipc_mod);
    dm.root_module.addImport("wayland_sessions", ws_mod);
    dm.root_module.linkSystemLibrary("pam", .{});
    dm.root_module.addCSourceFile(.{ .file = b.path("src/dm/pam.c"), .flags = &.{"-std=c11"} });
    b.installArtifact(dm);

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
    accounts_helper.root_module.addImport("wayland_sessions", ws_mod);
    accounts_helper.root_module.addImport("accounts_validation", b.createModule(.{
        .root_source_file = b.path("src/accounts/validation.zig"),
        .target = target,
        .optimize = optimize,
    }));
    accounts_helper.root_module.addImport("dm_config", b.createModule(.{
        .root_source_file = b.path("src/dm/config.zig"),
        .target = target,
        .optimize = optimize,
    }));
    b.installArtifact(accounts_helper);
    b.step("accounts-helper", "Build the privileged account-management helper").dependOn(&accounts_helper.step);

    // The UI layout engine (src/ui/) isn't wired into the compositor's
    // render loop yet, but its files reach into the rest of src/ (chrome.zig
    // for its SDF primitives, text.zig for glyph metrics, ...), so its test
    // build needs the same system libraries and embedded fonts as the
    // compositor itself.
    const ui_tests_module = b.createModule(.{
        .root_source_file = b.path("src/ui_tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    ui_tests_module.addImport("wayland", wayland);
    ui_tests_module.addImport("xkbcommon", xkbcommon);
    ui_tests_module.addImport("wlroots", wlroots);
    ui_tests_module.addImport("pixman", pixman);
    ui_tests_module.linkSystemLibrary("wayland-server", .{});
    ui_tests_module.linkSystemLibrary("xkbcommon", .{});
    ui_tests_module.linkSystemLibrary("pixman-1", .{});
    ui_tests_module.linkSystemLibrary("freetype2", .{});
    ui_tests_module.linkSystemLibrary("harfbuzz", .{});
    ui_tests_module.linkSystemLibrary("fontconfig", .{});
    ui_tests_module.linkSystemLibrary("librsvg-2.0", .{});
    ui_tests_module.linkSystemLibrary("libinput", .{});
    ui_tests_module.linkSystemLibrary("png16", .{});
    ui_tests_module.linkSystemLibrary("libpulse", .{});
    ui_tests_module.linkSystemLibrary("xcb", .{});
    addBass(b, ui_tests_module);
    // Fake PAM is linked only into unit tests; the compositor always uses libpam.
    ui_tests_module.addCSourceFile(.{ .file = b.path("tests/auth_test.c"), .flags = &.{ "-std=c11", "-DREDIWM_AUTH_EMBEDDED_TEST" } });
    ui_tests_module.addCSourceFile(.{ .file = b.path("src/polkit/native.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    addGlass(b, ui_tests_module);
    ui_tests_module.addCSourceFile(.{ .file = b.path("src/gpu_timing.c"), .flags = &.{"-std=c11"} });
    const ui_tests = b.addTest(.{ .root_module = ui_tests_module });
    const run_ui_tests = b.addRunArtifact(ui_tests);

    const ipc_tests_module = b.createModule(.{
        .root_source_file = b.path("src/ipc_tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    ipc_tests_module.addImport("protocol", protocol_mod);
    ipc_tests_module.linkSystemLibrary("png16", .{});
    const ipc_tests = b.addTest(.{ .root_module = ipc_tests_module });
    const run_ipc_tests = b.addRunArtifact(ipc_tests);

    const test_step = b.step("test", "Run the project unit tests");
    // Dependency-module tests are not collected by the executable's test root.
    const shared_ui_tests = b.addTest(.{ .root_module = ui_mod });
    const shared_config_tests = b.addTest(.{ .root_module = config_mod });
    const shared_dbus_tests = b.addTest(.{ .root_module = dbus_mod });
    const run_shared_ui_tests = b.addRunArtifact(shared_ui_tests);
    const run_shared_config_tests = b.addRunArtifact(shared_config_tests);
    const run_shared_dbus_tests = b.addRunArtifact(shared_dbus_tests);
    test_step.dependOn(&run_shared_ui_tests.step);
    test_step.dependOn(&run_shared_config_tests.step);
    test_step.dependOn(&run_shared_dbus_tests.step);
    const dbus_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/dbus_tests.zig"),
        .link_libc = true,
        .target = target,
        .optimize = optimize,
    }) });
    dbus_tests.root_module.addImport("wayland", wayland);
    dbus_tests.root_module.linkSystemLibrary("wayland-server", .{});
    dbus_tests.root_module.addCSourceFile(.{ .file = b.path("src/polkit/native.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    dbus_tests.root_module.linkSystemLibrary("pthread", .{});
    const run_dbus_tests = b.addRunArtifact(dbus_tests);
    test_step.dependOn(&run_dbus_tests.step);
    const dbus_service = b.addExecutable(.{
        .name = "dbus-test-service",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/dbus_test_service.zig"), .target = target, .optimize = optimize, .link_libc = true }),
        .use_llvm = use_llvm,
        .use_lld = use_llvm,
    });
    dbus_service.root_module.addImport("wayland", wayland);
    dbus_service.root_module.linkSystemLibrary("wayland-server", .{});
    const dbus_integration = b.addSystemCommand(&.{"python3"});
    dbus_integration.addFileArg(b.path("tests/dbus.py"));
    dbus_integration.addArtifactArg(dbus_service);
    const dbus_step = b.step("test-dbus", "Test D-Bus codec and real private-bus client/service");
    dbus_step.dependOn(&run_shared_dbus_tests.step);
    dbus_step.dependOn(&run_dbus_tests.step);
    dbus_step.dependOn(&dbus_integration.step);

    const polkit_service = b.addExecutable(.{
        .name = "polkit-test-service",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/polkit_test_service.zig"), .target = target, .optimize = optimize, .link_libc = true }),
        .use_llvm = use_llvm,
        .use_lld = use_llvm,
    });
    polkit_service.root_module.addImport("wayland", wayland);
    polkit_service.root_module.linkSystemLibrary("wayland-server", .{});
    polkit_service.root_module.addCSourceFile(.{ .file = b.path("src/polkit/native.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    polkit_service.root_module.linkSystemLibrary("pthread", .{});
    const polkit_manual = b.addRunArtifact(polkit_service);
    if (b.args) |args| polkit_manual.addArgs(args);
    b.step("run-polkit-test-agent", "Run the noninstalled polkit test agent (-- --terminal for manual authentication)").dependOn(&polkit_manual.step);
    const polkit_integration = b.addSystemCommand(&.{"python3"});
    polkit_integration.addFileArg(b.path("tests/polkit.py"));
    polkit_integration.addArtifactArg(polkit_service);
    const polkit_step = b.step("test-polkit", "Test polkit registration on a private bus without credentials");
    polkit_step.dependOn(&run_dbus_tests.step);
    polkit_step.dependOn(&polkit_integration.step);
    const polkit_ui = b.addSystemCommand(&.{"python3"});
    polkit_ui.addFileArg(b.path("tests/polkit_dialog.py"));
    polkit_ui.step.dependOn(b.getInstallStep());
    b.step("test-polkit-ui", "Test native authentication UI on a private bus and headless output").dependOn(&polkit_ui.step);

    const tray_integration = b.addSystemCommand(&.{"python3"});
    tray_integration.addFileArg(b.path("tests/tray.py"));
    tray_integration.step.dependOn(b.getInstallStep());
    b.step("test-tray", "Test application tray icons and D-Bus context menus on a private bus").dependOn(&tray_integration.step);

    const notif_integration = b.addSystemCommand(&.{"python3"});
    notif_integration.addFileArg(b.path("tests/notifications.py"));
    const notif_step = b.step("test-notifications", "Test notifications daemon, D-Bus service, and IPC");
    notif_step.dependOn(&notif_integration.step);

    const chooser_integration = b.addSystemCommand(&.{"python3"});
    chooser_integration.addFileArg(b.path("tests/file_chooser.py"));
    chooser_integration.step.dependOn(b.getInstallStep());
    b.step("test-file-chooser", "Test Open/Save dialogs and portal preferences on a private bus").dependOn(&chooser_integration.step);

    const settings_portal_integration = b.addSystemCommand(&.{"python3"});
    settings_portal_integration.addFileArg(b.path("tests/settings_portal.py"));
    const settings_portal_step = b.step("test-settings-portal", "Test the dark_mode Settings portal backend on a private bus");
    settings_portal_step.dependOn(&settings_portal_integration.step);

    const power_integration = b.addSystemCommand(&.{"python3"});
    power_integration.addFileArg(b.path("tests/power.py"));
    power_integration.step.dependOn(b.getInstallStep());
    const power_step = b.step("test-power", "Test poweroff/reboot/suspend against a private mock logind");
    power_step.dependOn(&power_integration.step);

    const power_profiles_integration = b.addSystemCommand(&.{"python3"});
    power_profiles_integration.addFileArg(b.path("tests/power_profiles.py"));
    power_profiles_integration.step.dependOn(b.getInstallStep());
    const power_profiles_step = b.step("test-power-profiles", "Test the power profile OSD against a private fake PowerProfiles daemon");
    power_profiles_step.dependOn(&power_profiles_integration.step);

    const layout_autosave_integration = b.addSystemCommand(&.{"python3"});
    layout_autosave_integration.addFileArg(b.path("tests/layout_autosave.py"));
    const layout_autosave_step = b.step("test-layout-autosave", "Test periodic layout autosave and startup restore");
    layout_autosave_step.dependOn(&layout_autosave_integration.step);

    const dm_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/dm/tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }) });
    dm_tests.root_module.addImport("child_set", child_set_mod);
    dm_tests.root_module.addImport("dm_ipc", dm_ipc_mod);
    dm_tests.root_module.addImport("wayland_sessions", ws_mod);
    dm_tests.root_module.linkSystemLibrary("pam", .{});
    dm_tests.root_module.addCSourceFile(.{ .file = b.path("src/dm/pam.c"), .flags = &.{"-std=c11"} });
    const run_dm_tests = b.addRunArtifact(dm_tests);
    test_step.dependOn(&run_dm_tests.step);
    const dm_step = b.step("test-dm", "Run unit tests for rediwm-dm");
    dm_step.dependOn(&run_dm_tests.step);

    const session_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/session_main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }) });
    session_tests.root_module.addImport("wayland", wayland);
    session_tests.root_module.linkSystemLibrary("wayland-server", .{});
    const run_session_tests = b.addRunArtifact(session_tests);
    test_step.dependOn(&run_session_tests.step);
    const rediwm_session_step = b.step("test-rediwm-session", "Test the login supervisor's publication, crash-restart loop and bus calls");
    rediwm_session_step.dependOn(&run_session_tests.step);
    const rediwm_session_integration = b.addSystemCommand(&.{"python3"});
    rediwm_session_integration.addFileArg(b.path("tests/rediwm_session.py"));
    rediwm_session_integration.addArtifactArg(session_supervisor);
    rediwm_session_step.dependOn(&rediwm_session_integration.step);
    const session_services = b.addSystemCommand(&.{"python3"});
    session_services.addFileArg(b.path("tests/session_services.py"));
    session_services.addArtifactArg(session_supervisor);
    rediwm_session_step.dependOn(&session_services.step);
    const session_bus = b.addSystemCommand(&.{"python3"});
    session_bus.addFileArg(b.path("tests/session_bus.py"));
    session_bus.addArtifactArg(session_supervisor);
    rediwm_session_step.dependOn(&session_bus.step);
    const session_readiness = b.addSystemCommand(&.{"python3"});
    session_readiness.addFileArg(b.path("tests/session_readiness.py"));
    session_readiness.step.dependOn(b.getInstallStep());
    rediwm_session_step.dependOn(&session_readiness.step);
    const notification_services = b.addSystemCommand(&.{"python3"});
    notification_services.addFileArg(b.path("tests/notification_services.py"));
    notification_services.step.dependOn(b.getInstallStep());
    rediwm_session_step.dependOn(&notification_services.step);
    const app_activation = b.addSystemCommand(&.{"python3"});
    app_activation.addFileArg(b.path("tests/app_activation.py"));
    app_activation.step.dependOn(b.getInstallStep());
    b.step("test-app-activation", "Test application Activate/Open and Exec fallback on a private bus").dependOn(&app_activation.step);
    const lifecycle_tests = b.addTest(.{ .root_module = ui_tests_module, .filters = &.{"lifecycle"} });
    const run_lifecycle_tests = b.addRunArtifact(lifecycle_tests);
    b.step("test-lifecycle", "Check callback ownership under allocation failure").dependOn(&run_lifecycle_tests.step);
    test_step.dependOn(&run_ui_tests.step);
    const lock_tests = b.addTest(.{ .root_module = ui_tests_module, .filters = &.{ "lock ", "greeter " } });
    const run_lock_tests = b.addRunArtifact(lock_tests);
    const lock_step = b.step("test-lock", "Test lock isolation, password editing, rendering, PAM outcomes and the rediwm-dm greeter");
    lock_step.dependOn(&run_lock_tests.step);
    const auth_tests = b.addExecutable(.{ .name = "auth-tests", .root_module = b.createModule(.{ .target = target, .optimize = .Debug, .link_libc = true }) });
    auth_tests.root_module.addCSourceFile(.{ .file = b.path("tests/auth_test.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    const run_auth_tests = b.addRunArtifact(auth_tests);
    lock_step.dependOn(&run_auth_tests.step);
    test_step.dependOn(&run_auth_tests.step);
    const editor_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/editor_tests.zig"), .target = target, .optimize = optimize, .link_libc = true }) });
    inline for (.{ "pangocairo", "gio-2.0", "xkbcommon" }) |lib| editor_tests.root_module.linkSystemLibrary(lib, .{});
    const run_editor_tests = b.addRunArtifact(editor_tests);
    test_step.dependOn(&run_editor_tests.step);
    b.step("test-editor", "Test text document editing and saving").dependOn(&run_editor_tests.step);

    const images_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/images_tests.zig"), .target = target, .optimize = optimize, .link_libc = true }) });
    inline for (.{ "gdk-pixbuf-2.0", "gobject-2.0", "glib-2.0", "xkbcommon" }) |lib| images_tests.root_module.linkSystemLibrary(lib, .{});
    const run_images_tests = b.addRunArtifact(images_tests);
    test_step.dependOn(&run_images_tests.step);
    const test_images_step = b.step("test-images", "Test image viewer geometry and loading");
    test_images_step.dependOn(&run_images_tests.step);

    const pdf_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/pdf_tests.zig"), .target = target, .optimize = optimize, .link_libc = true }) });
    inline for (.{ "poppler-glib", "cairo", "gobject-2.0", "glib-2.0", "xkbcommon" }) |lib| pdf_tests.root_module.linkSystemLibrary(lib, .{});
    const run_pdf_tests = b.addRunArtifact(pdf_tests);
    test_step.dependOn(&run_pdf_tests.step);
    const test_pdf_step = b.step("test-pdf", "Test PDF document loading, geometry and rendering");
    test_pdf_step.dependOn(&run_pdf_tests.step);

    const files_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/files_tests.zig"), .target = target, .optimize = optimize, .link_libc = true }) });
    files_tests.root_module.linkSystemLibrary("xkbcommon", .{});
    files_tests.root_module.linkSystemLibrary("gio-2.0", .{});
    inline for (.{ "gdk-pixbuf-2.0", "gobject-2.0", "glib-2.0" }) |lib| files_tests.root_module.linkSystemLibrary(lib, .{});
    files_tests.root_module.linkSystemLibrary("libarchive", .{});
    addThumbCodec(b, files_tests.root_module);
    addVolumes(b, files_tests.root_module);
    const run_files_tests = b.addRunArtifact(files_tests);
    test_step.dependOn(&run_files_tests.step);
    b.step("test-files", "Test Files editing, navigation, transfers and layout").dependOn(&run_files_tests.step);
    const share_picker_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/share_picker_tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }) });
    test_step.dependOn(&b.addRunArtifact(share_picker_tests).step);
    test_step.dependOn(&run_ipc_tests.step);

    // Hosts also rasterize app-specific content through their own C imports.
    inline for (.{ files.root_module, images.root_module, editor.root_module, pdf.root_module, share_picker.root_module, files_tests.root_module, images_tests.root_module, editor_tests.root_module, pdf_tests.root_module }) |module| {
        inline for (.{ "cairo", "librsvg-2.0", "freetype2", "harfbuzz", "fontconfig" }) |lib| module.linkSystemLibrary(lib, .{});
    }
    inline for (.{ compositor.root_module, ui_tests_module, files.root_module, images.root_module, editor.root_module, pdf.root_module, share_picker.root_module, editor_tests.root_module, images_tests.root_module, pdf_tests.root_module, files_tests.root_module, ipc_tests_module, protocol_mod, session_supervisor.root_module, session_tests.root_module, share_picker_tests.root_module, dbus_tests.root_module }) |module| {
        module.addImport("ui", ui_mod);
        module.addImport("config", config_mod);
        module.addImport("memory", memory_mod);
    }
    inline for (.{ compositor.root_module, ui_tests_module, dbus_tests.root_module, dbus_service.root_module, polkit_service.root_module, session_supervisor.root_module, session_tests.root_module, share_picker_tests.root_module, files_tests.root_module }) |module| {
        module.addImport("dbus", dbus_mod);
    }

    const gpu_timing_tests = b.addExecutable(.{
        .name = "gpu-timing-tests",
        .root_module = b.createModule(.{ .target = target, .optimize = .Debug, .link_libc = true }),
    });
    gpu_timing_tests.root_module.addCSourceFile(.{ .file = b.path("src/gpu_timing_test.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    inline for (.{ "wlroots-0.20", "wayland-server", "pixman-1", "egl", "glesv2" }) |lib| {
        gpu_timing_tests.root_module.linkSystemLibrary(lib, .{});
    }
    const run_gpu_timing_tests = b.addRunArtifact(gpu_timing_tests);
    test_step.dependOn(&run_gpu_timing_tests.step);
    b.step("test-gpu-timing", "Test GPU timing query lifetime with a fake driver").dependOn(&run_gpu_timing_tests.step);

    const projection_tests = b.addExecutable(.{
        .name = "projection-tests",
        .root_module = b.createModule(.{ .target = target, .optimize = .Debug, .link_libc = true }),
    });
    projection_tests.root_module.addCSourceFile(.{ .file = b.path("src/projection_test.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    inline for (.{ "wlroots-0.20", "wayland-server", "pixman-1" }) |lib| {
        projection_tests.root_module.linkSystemLibrary(lib, .{});
    }
    const run_projection_tests = b.addRunArtifact(projection_tests);
    test_step.dependOn(&run_projection_tests.step);
    b.step("test-projection", "Test projected damage with headless scene outputs").dependOn(&run_projection_tests.step);

    const glass_tests = b.addExecutable(.{
        .name = "glass-tests",
        .root_module = b.createModule(.{ .target = target, .optimize = .Debug, .link_libc = true }),
    });
    glass_tests.root_module.addCSourceFile(.{ .file = b.path("src/glass_test.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra" } });
    inline for (.{ "wlroots-0.20", "wayland-server", "pixman-1", "egl", "glesv2" }) |lib| {
        glass_tests.root_module.linkSystemLibrary(lib, .{});
    }
    glass_tests.root_module.addCSourceFile(.{ .file = b.path("src/projection.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra" } });
    glass_tests.root_module.addCSourceFile(.{ .file = b.path("src/explicit_sync.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    const run_glass_tests = b.addRunArtifact(glass_tests);
    run_glass_tests.setEnvironmentVariable("WLR_RENDERER", "gles2");
    b.step("test-glass", "Run backdrop pixel checks with a headless GLES2 renderer").dependOn(&run_glass_tests.step);
    const run_glass_damage_tests = b.addRunArtifact(glass_tests);
    run_glass_damage_tests.addArg("--damage-only");
    b.step("test-glass-damage", "Test backdrop invalidation without a GPU").dependOn(&run_glass_damage_tests.step);
    test_step.dependOn(&run_glass_damage_tests.step);

    const run_cmd = b.addRunArtifact(compositor);
    // The development run target is always nested in the current Wayland session.
    run_cmd.setEnvironmentVariable("WLR_BACKENDS", "wayland");
    run_cmd.setEnvironmentVariable("WLR_WL_OUTPUTS", "1");
    // Autostart looks up `rediwm-desktop` / `rediwm-files` on PATH. The run
    // artifact lives in the cache, so install the helpers and expose zig-out/bin.
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPathDir(b.exe_dir);
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the nested compositor (pass a client command after --)");
    run_step.dependOn(&run_cmd.step);
}

fn usePrivateWlroots(b: *std.Build, prefix: []const u8) void {
    prependEnvPath(b, "PKG_CONFIG_PATH", b.fmt("{s}/lib/pkgconfig:{s}/share/pkgconfig", .{ prefix, prefix }));
    // Tests and `zig build run` execute from the cache, where the installed
    // RUNPATH doesn't reach lib/rediwm.
    prependEnvPath(b, "LD_LIBRARY_PATH", b.pathJoin(&.{ prefix, "runtime" }));
}

fn prependEnvPath(b: *std.Build, key: []const u8, dirs: []const u8) void {
    const env = &b.graph.environ_map;
    const value = if (env.get(key)) |prev| b.fmt("{s}:{s}", .{ dirs, prev }) else dirs;
    env.put(key, value) catch @panic("OOM");
}

fn addBass(b: *std.Build, module: *std.Build.Module) void {
    module.linkSystemLibrary("libpipewire-0.3", .{});
    module.addCSourceFile(.{ .file = b.path("src/audio/bass.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra" } });
}

/// The bass boost DSP, a LADSPA plugin that bass.c loads into its
/// filter-chain from lib/rediwm/ladspa next to the binaries.
fn addBassDsp(b: *std.Build, target: std.Build.ResolvedTarget) void {
    const dsp = b.addLibrary(.{
        .name = "rediwm-bass",
        .linkage = .dynamic,
        // Realtime audio code: optimized in every build mode, and no UBSan
        // runtime for PipeWire's dlopen to resolve.
        .root_module = b.createModule(.{ .target = target, .optimize = .ReleaseFast, .link_libc = true, .sanitize_c = .off }),
    });
    dsp.root_module.addCSourceFile(.{ .file = b.path("src/audio/bass_dsp.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra" } });
    dsp.root_module.linkSystemLibrary("m", .{});
    b.getInstallStep().dependOn(&b.addInstallArtifact(dsp, .{
        .dest_dir = .{ .override = .lib },
        .dest_sub_path = "rediwm/ladspa/rediwm-bass.so",
        .dylib_symlinks = false,
    }).step);
}

fn addGlass(b: *std.Build, module: *std.Build.Module) void {
    module.linkSystemLibrary("wlroots-0.20", .{});
    module.linkSystemLibrary("egl", .{});
    module.linkSystemLibrary("glesv2", .{});
    module.addCSourceFile(.{ .file = b.path("src/projection.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra" } });
    module.addCSourceFile(.{ .file = b.path("src/glass.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra" } });
    module.addCSourceFile(.{ .file = b.path("src/explicit_sync.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    module.addCSourceFile(.{ .file = b.path("src/extra_protocols.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
}

// ui/ and text.zig for the Cairo clients (Files, Images, the share picker):
// bundled fonts and glyphs, and what text.zig and shell_icons.zig link.
// Files' thumbnails decode JPEG and PNG with libjpeg and libpng directly:
// GdkPixbuf routes them through sandboxed loader processes, ~10x slower.
fn addThumbCodec(b: *std.Build, module: *std.Build.Module) void {
    module.addIncludePath(b.path("src/files"));
    module.addCSourceFile(.{ .file = b.path("src/files/thumb_codec.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    inline for (.{ "libjpeg", "libpng16" }) |lib| module.linkSystemLibrary(lib, .{});
}

// Files' device list: a GLib thread speaking to UDisks2 (src/files/volumes.c).
fn addVolumes(b: *std.Build, module: *std.Build.Module) void {
    module.addIncludePath(b.path("src/files"));
    module.addCSourceFile(.{ .file = b.path("src/files/volumes.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    inline for (.{ "gio-2.0", "gobject-2.0", "glib-2.0" }) |lib| module.linkSystemLibrary(lib, .{});
}

fn addShellUi(b: *std.Build, module: *std.Build.Module) void {
    addShellIcons(b, module);
    module.addAnonymousImport("manrope", .{ .root_source_file = b.path("assets/fonts/Manrope-VariableFont_wght.ttf") });
    module.addAnonymousImport("jetbrains_mono_regular", .{ .root_source_file = b.path("assets/fonts/JetBrainsMono-Regular.ttf") });
    module.addAnonymousImport("jetbrains_mono_bold", .{ .root_source_file = b.path("assets/fonts/JetBrainsMono-Bold.ttf") });
    inline for (.{ "cairo", "librsvg-2.0", "freetype2", "harfbuzz", "fontconfig" }) |lib| module.linkSystemLibrary(lib, .{});
}

// Bundle shell glyphs so installed binaries never depend on the checkout.
fn addShellIcons(b: *std.Build, module: *std.Build.Module) void {
    inline for (.{ "git-branch", "home", "folder", "settings", "keyboard", "edit", "mouse", "display", "music", "headphones", "wifi", "ethernet", "globe", "bluetooth", "battery", "notification-bell", "speaker", "speaker-xmark", "power-button", "clock", "lock", "logout", "restart", "eye", "eye-off", "refresh", "cut", "copy", "paste", "trash-outline", "trash", "view-grid", "view-list", "sort", "filter", "zoom-in", "zoom-out", "rotate", "crop", "undo", "save", "fit", "open", "usb-stick", "drive", "eject", "users", "squares" }) |name| {
        module.addAnonymousImport("shell-icon-" ++ name, .{ .root_source_file = b.path("icons/" ++ name ++ ".svg") });
    }
}
