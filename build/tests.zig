//! Unit, integration and C test steps.

const std = @import("std");
const Context = @import("context.zig").Context;
const Session = @import("session.zig").Session;
const support = @import("support.zig");
const addBass = support.addBass;
const addGlass = support.addGlass;
const addThumbCodec = support.addThumbCodec;
const addFilesTerminal = support.addFilesTerminal;
const addVolumes = support.addVolumes;

pub const ZigTests = struct {
    test_step: *std.Build.Step,
    ui_tests_module: *std.Build.Module,
    ipc_tests_module: *std.Build.Module,
    files_tests: *std.Build.Step.Compile,
    images_tests: *std.Build.Step.Compile,
    editor_tests: *std.Build.Step.Compile,
    pdf_tests: *std.Build.Step.Compile,
    session_tests: *std.Build.Step.Compile,
    share_picker_tests: *std.Build.Step.Compile,
    dbus_tests: *std.Build.Step.Compile,
    dbus_service: *std.Build.Step.Compile,
    polkit_service: *std.Build.Step.Compile,
};

/// The unit test binaries and the `test` step, and the integration suites
/// (tests/*.py) with their `test-*` steps.
pub fn addZig(ctx: Context, session: Session) ZigTests {
    const b = ctx.b;
    const target = ctx.target;
    const optimize = ctx.optimize;
    const use_llvm = ctx.use_llvm;
    const i18n_tool = ctx.i18n_tool;
    const wayland = ctx.wayland;
    const xkbcommon = ctx.xkbcommon;
    const pixman = ctx.pixman;
    const wlroots = ctx.wlroots;
    const i18n_mod = ctx.i18n_mod;
    const ui_mod = ctx.ui_mod;
    const dbus_mod = ctx.dbus_mod;
    const config_mod = ctx.config_mod;
    const protocol_mod = ctx.protocol_mod;
    const session_supervisor = session.session_supervisor;
    const dm_ipc_mod = session.dm_ipc_mod;
    const ws_mod = session.ws_mod;
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
    ui_tests_module.linkSystemLibrary("cups", .{});
    ui_tests_module.addCSourceFile(.{ .file = b.path("src/printing/direct.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror", "-Wno-deprecated-declarations" } });
    ui_tests_module.linkSystemLibrary("xkbcommon", .{});
    ui_tests_module.linkSystemLibrary("pixman-1", .{});
    ui_tests_module.linkSystemLibrary("freetype2", .{});
    ui_tests_module.linkSystemLibrary("harfbuzz", .{});
    ui_tests_module.linkSystemLibrary("fontconfig", .{});
    ui_tests_module.linkSystemLibrary("librsvg-2.0", .{});
    ui_tests_module.linkSystemLibrary("libinput", .{});
    ui_tests_module.linkSystemLibrary("libudev", .{});
    ui_tests_module.linkSystemLibrary("png16", .{});
    ui_tests_module.linkSystemLibrary("libpulse", .{});
    inline for (.{ .{ "c_pulse", ctx.c.pulse }, .{ "c_libinput", ctx.c.libinput }, .{ "c_png", ctx.c.png } }) |entry| ui_tests_module.addImport(entry[0], entry[1]);
    ui_tests_module.linkSystemLibrary("xcb", .{});
    addBass(b, ui_tests_module);
    // Fake PAM is linked only into unit tests; the compositor always uses libpam.
    ui_tests_module.addCSourceFile(.{ .file = b.path("tests/auth_test.c"), .flags = &.{ "-std=c11", "-DREDIWM_AUTH_EMBEDDED_TEST" } });
    ui_tests_module.addCSourceFile(.{ .file = b.path("src/polkit/native.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    addGlass(b, ui_tests_module, false);
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
    ipc_tests_module.addImport("c_png", ctx.c.png);
    const ipc_tests = b.addTest(.{ .root_module = ipc_tests_module });
    const run_ipc_tests = b.addRunArtifact(ipc_tests);

    const test_step = b.step("test", "Run the project unit tests");
    const wlroots_tests = b.addTest(.{ .root_module = wlroots });
    const run_wlroots_tests = b.addRunArtifact(wlroots_tests);
    test_step.dependOn(&run_wlroots_tests.step);
    b.step("test-wlroots", "Check every exported wlroots binding against its C headers").dependOn(&run_wlroots_tests.step);
    const i18n_tests = b.addTest(.{ .root_module = i18n_mod });
    const run_i18n_tests = b.addRunArtifact(i18n_tests);
    test_step.dependOn(&run_i18n_tests.step);
    const run_platform_tests = b.addRunArtifact(b.addTest(.{ .root_module = ctx.platform_mod }));
    test_step.dependOn(&run_platform_tests.step);
    b.step("test-platform", "Test child handles, file watching and the program's own path").dependOn(&run_platform_tests.step);
    const theme_policy_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/theme_helper/syscall_policy.zig"), .target = target, .optimize = optimize, .link_libc = true }) });
    theme_policy_tests.root_module.addImport("platform", ctx.platform_mod);
    test_step.dependOn(&b.addRunArtifact(theme_policy_tests).step);
    const i18n_tool_tests = b.addTest(.{ .root_module = i18n_tool.root_module });
    test_step.dependOn(&b.addRunArtifact(i18n_tool_tests).step);
    b.step("test-i18n", "Test locale resolution, catalogs and formatting").dependOn(&run_i18n_tests.step);
    const monitor_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/system_monitor_tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }) });
    monitor_tests.root_module.addImport("c", ctx.c.libc);
    monitor_tests.root_module.addImport("platform", ctx.platform_mod);
    const run_monitor_tests = b.addRunArtifact(monitor_tests);
    const monitor_test_step = b.step("test-monitor", "Test System Monitor collection, process identity and model");
    monitor_test_step.dependOn(&run_monitor_tests.step);
    test_step.dependOn(&run_monitor_tests.step);
    const printing_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/printing/tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }) });
    printing_tests.root_module.addImport("c", ctx.c.libc);
    printing_tests.root_module.addImport("dbus", dbus_mod);
    printing_tests.root_module.addImport("i18n", i18n_mod);
    printing_tests.root_module.addImport("platform", ctx.platform_mod);
    printing_tests.root_module.addImport("wayland", wayland);
    printing_tests.root_module.linkSystemLibrary("wayland-server", .{});
    printing_tests.root_module.linkSystemLibrary("cups", .{});
    printing_tests.root_module.addCSourceFile(.{ .file = b.path("src/printing/direct.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror", "-Wno-deprecated-declarations" } });
    const run_printing_tests = b.addRunArtifact(printing_tests);
    test_step.dependOn(&run_printing_tests.step);
    const printers_integration = b.addSystemCommand(&.{"python3"});
    printers_integration.addFileArg(b.path("tests/printers.py"));
    printers_integration.step.dependOn(b.getInstallStep());
    const printers_step = b.step("test-printers", "Test printer diagnostics and private CUPS page lifecycle");
    printers_step.dependOn(&run_printing_tests.step);
    printers_step.dependOn(&printers_integration.step);
    const printers_direct = b.addSystemCommand(&.{"python3"});
    printers_direct.addFileArg(b.path("tests/printers_direct.py"));
    printers_direct.step.dependOn(&printers_integration.step);
    printers_step.dependOn(&printers_direct.step);
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
    polkit_service.root_module.addImport("i18n", i18n_mod);
    polkit_service.root_module.linkSystemLibrary("wayland-server", .{});
    polkit_service.root_module.addCSourceFile(.{ .file = b.path("src/polkit/native.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    polkit_service.root_module.linkSystemLibrary("pthread", .{});
    const polkit_manual = b.addRunArtifact(polkit_service);
    polkit_manual.addPassthruArgs();
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
    dm_tests.root_module.addImport("install_paths", ctx.layout.options);
    dm_tests.root_module.addImport("c", ctx.c.libc);
    dm_tests.root_module.addImport("platform", ctx.platform_mod);
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
    const auth_tests = b.addExecutable(.{ .name = "auth-tests", .root_module = b.createModule(.{ .target = target, .optimize = .debug, .link_libc = true }) });
    auth_tests.root_module.addCSourceFile(.{ .file = b.path("tests/auth_test.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    const run_auth_tests = b.addRunArtifact(auth_tests);
    lock_step.dependOn(&run_auth_tests.step);
    test_step.dependOn(&run_auth_tests.step);
    const editor_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/editor_tests.zig"), .target = target, .optimize = optimize, .link_libc = true }) });
    inline for (.{ "pangocairo", "xkbcommon" }) |lib| editor_tests.root_module.linkSystemLibrary(lib, .{});
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
    files_tests.root_module.addImport("c_archive", ctx.c.archive);
    addThumbCodec(b, files_tests.root_module);
    addVolumes(b, files_tests.root_module);
    addFilesTerminal(b, files_tests.root_module, true);
    const run_files_tests = b.addRunArtifact(files_tests);
    test_step.dependOn(&run_files_tests.step);
    b.step("test-files", "Test Files editing, navigation, transfers and layout").dependOn(&run_files_tests.step);
    const terminal_integration = b.addSystemCommand(&.{"env"});
    terminal_integration.addPrefixedDirectoryArg("REDIWM_TEST_BIN=", support.installed(.bin, ""));
    terminal_integration.addArg("python3");
    terminal_integration.addFileArg(b.path("tests/files_terminal.py"));
    terminal_integration.step.dependOn(b.getInstallStep());
    const terminal_tests = b.step("test-files-terminal", "Test the Files terminal against isolated PTYs and a headless compositor");
    terminal_tests.dependOn(&run_files_tests.step);
    terminal_tests.dependOn(&terminal_integration.step);
    const share_picker_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/share_picker_tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }) });
    test_step.dependOn(&b.addRunArtifact(share_picker_tests).step);
    test_step.dependOn(&run_ipc_tests.step);
    return .{ .test_step = test_step, .ui_tests_module = ui_tests_module, .ipc_tests_module = ipc_tests_module, .files_tests = files_tests, .images_tests = images_tests, .editor_tests = editor_tests, .pdf_tests = pdf_tests, .session_tests = session_tests, .share_picker_tests = share_picker_tests, .dbus_tests = dbus_tests, .dbus_service = dbus_service, .polkit_service = polkit_service };
}

/// The C fixtures for the scene graph, projection, glass and the owned GLES2 pass.
pub fn addC(ctx: Context, test_step: *std.Build.Step) void {
    const b = ctx.b;
    const target = ctx.target;
    const optimize = ctx.optimize;
    const gpu_timing_tests = b.addExecutable(.{
        .name = "gpu-timing-tests",
        .root_module = b.createModule(.{ .target = target, .optimize = .debug, .link_libc = true }),
    });
    gpu_timing_tests.root_module.addCSourceFile(.{ .file = b.path("src/gpu_timing_test.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    inline for (.{ "wlroots-0.20", "wayland-server", "pixman-1", "egl", "glesv2" }) |lib| {
        gpu_timing_tests.root_module.linkSystemLibrary(lib, .{});
    }
    const run_gpu_timing_tests = b.addRunArtifact(gpu_timing_tests);
    test_step.dependOn(&run_gpu_timing_tests.step);
    b.step("test-gpu-timing", "Test GPU timing query lifetime with a fake driver").dependOn(&run_gpu_timing_tests.step);

    const node_tests = b.addExecutable(.{
        .name = "node-tests",
        .root_module = b.createModule(.{ .target = target, .optimize = .debug, .link_libc = true }),
    });
    node_tests.root_module.addCSourceFile(.{ .file = b.path("src/node_test.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    node_tests.root_module.addCSourceFile(.{ .file = b.path("src/node.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    inline for (.{ "wlroots-0.20", "wayland-server", "pixman-1" }) |lib| {
        node_tests.root_module.linkSystemLibrary(lib, .{});
    }
    const run_node_tests = b.addRunArtifact(node_tests);
    test_step.dependOn(&run_node_tests.step);
    b.step("test-node", "Test the compositor's own scene nodes").dependOn(&run_node_tests.step);

    const projection_tests = b.addExecutable(.{
        .name = "projection-tests",
        .root_module = b.createModule(.{ .target = target, .optimize = .debug, .link_libc = true }),
    });
    projection_tests.root_module.addCSourceFile(.{ .file = b.path("src/projection_test.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    projection_tests.root_module.addCSourceFile(.{ .file = b.path("src/scene_damage.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    projection_tests.root_module.addCSourceFile(.{ .file = b.path("src/scene_outputs.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    projection_tests.root_module.addCSourceFile(.{ .file = b.path("src/node.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    inline for (.{ "wlroots-0.20", "wayland-server", "pixman-1" }) |lib| {
        projection_tests.root_module.linkSystemLibrary(lib, .{});
    }
    const run_projection_tests = b.addRunArtifact(projection_tests);
    test_step.dependOn(&run_projection_tests.step);
    b.step("test-projection", "Test projected damage with headless scene outputs").dependOn(&run_projection_tests.step);

    const glass_tests = b.addExecutable(.{
        .name = "glass-tests",
        .root_module = b.createModule(.{ .target = target, .optimize = .debug, .link_libc = true }),
    });
    glass_tests.root_module.addCSourceFile(.{ .file = b.path("src/glass_test.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    inline for (.{ "wlroots-0.20", "wayland-server", "pixman-1", "egl", "glesv2" }) |lib| {
        glass_tests.root_module.linkSystemLibrary(lib, .{});
    }
    glass_tests.root_module.addCSourceFiles(.{ .files = &support.projection_sources, .flags = &.{ "-std=c11", "-Wall", "-Wextra" } });
    glass_tests.root_module.addCSourceFile(.{ .file = b.path("src/scene_damage.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    glass_tests.root_module.addCSourceFile(.{ .file = b.path("src/scene_outputs.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    glass_tests.root_module.addCSourceFile(.{ .file = b.path("src/node.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    const run_glass_tests = b.addRunArtifact(glass_tests);
    run_glass_tests.setEnvironmentVariable("WLR_RENDERER", "gles2");
    b.step("test-glass", "Test the glass registry and its geometry in the graph (no GPU)").dependOn(&run_glass_tests.step);
    // Stage 1 spike of docs/plans/scene-graph.md: the owned pass's primitives, pixel-tested.
    const pass_spike_tests = b.addExecutable(.{
        .name = "pass-spike-tests",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
    });
    pass_spike_tests.root_module.addCSourceFile(.{ .file = b.path("src/pass_spike_test.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra" } });
    inline for (.{ "wlroots-0.20", "wayland-server", "pixman-1", "egl", "glesv2" }) |lib| {
        pass_spike_tests.root_module.linkSystemLibrary(lib, .{});
    }
    const run_pass_spike_tests = b.addRunArtifact(pass_spike_tests);
    run_pass_spike_tests.setEnvironmentVariable("WLR_RENDERER", "gles2");
    b.step("test-pass-spike", "Run the owned-pass spike's pixel gates on a headless GLES2 renderer").dependOn(&run_pass_spike_tests.step);
    const scene_pass_tests = b.addExecutable(.{
        .name = "scene-pass-tests",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
    });
    scene_pass_tests.root_module.addCSourceFile(.{ .file = b.path("src/scene_pass_test.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    inline for (.{ "wlroots-0.20", "wayland-server", "pixman-1", "egl", "glesv2", "gbm" }) |lib| {
        scene_pass_tests.root_module.linkSystemLibrary(lib, .{});
    }
    const run_scene_pass_tests = b.addRunArtifact(scene_pass_tests);
    run_scene_pass_tests.setEnvironmentVariable("WLR_RENDERER", "gles2");
    b.step("test-scene-pass", "Compare the owned GLES2 pass with wlroots on a headless renderer").dependOn(&run_scene_pass_tests.step);
    const run_glass_damage_tests = b.addRunArtifact(glass_tests);
    b.step("test-glass-damage", "Same as test-glass (kept for scripts)").dependOn(&run_glass_damage_tests.step);
    test_step.dependOn(&run_glass_damage_tests.step);
}
