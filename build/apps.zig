//! The standalone applications built alongside the compositor.

const std = @import("std");
const Context = @import("context.zig").Context;
const support = @import("support.zig");
const addThumbCodec = support.addThumbCodec;
const addFilesTerminal = support.addFilesTerminal;
const addVolumes = support.addVolumes;
const localizedData = support.localizedData;

pub const Apps = struct {
    files: *std.Build.Step.Compile,
    images: *std.Build.Step.Compile,
    monitor: *std.Build.Step.Compile,
    calculator: *std.Build.Step.Compile,
    editor: *std.Build.Step.Compile,
    pdf: *std.Build.Step.Compile,
    share_picker: *std.Build.Step.Compile,
};

/// Files (with its terminal and transfers helpers), Images, System Monitor,
/// Calculator, the text editor, the PDF viewer and the share picker, with
/// their desktop entries and build steps.
pub fn add(ctx: Context) Apps {
    const b = ctx.b;
    const target = ctx.target;
    const optimize = ctx.optimize;
    const use_llvm = ctx.use_llvm;
    const i18n_tool = ctx.i18n_tool;
    const wayland = ctx.wayland;
    const files = b.addExecutable(.{
        .name = "rediwm-files",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/files_main.zig"), .target = target, .optimize = optimize, .link_libc = true }),
        .use_llvm = use_llvm,
        .use_lld = use_llvm,
    });
    files.root_module.addImport("wayland", wayland);
    inline for (.{ "wayland-client", "wayland-cursor", "xkbcommon", "gio-2.0", "gdk-pixbuf-2.0", "gobject-2.0", "glib-2.0" }) |lib| files.root_module.linkSystemLibrary(lib, .{});
    files.root_module.linkSystemLibrary("libarchive", .{});
    files.root_module.addImport("c_archive", ctx.c.archive);
    addThumbCodec(b, files.root_module);
    addVolumes(b, files.root_module);
    addFilesTerminal(b, files.root_module, false);
    const terminal_license = b.addInstallFileWithDir(b.dependency("vterm", .{}).path("LICENSE"), .prefix, "share/licenses/rediwm/libvterm-LICENSE");
    b.getInstallStep().dependOn(&terminal_license.step);
    // Use the system C++ ABI, matching the distro's libtorrent-rasterbar.
    const torrents = b.addSystemCommand(&.{ "sh", "-c", "exec c++ -std=c++17 -Wall -Wextra -Werror -Wno-deprecated-declarations -Wno-missing-field-initializers $(pkg-config --cflags libtorrent-rasterbar gio-unix-2.0 json-glib-1.0) \"$@\" $(pkg-config --libs libtorrent-rasterbar gio-unix-2.0 json-glib-1.0)", "build-transfers" });
    torrents.addArg(if (optimize == .debug) "-O0" else "-O2");
    torrents.addArg("-g");
    torrents.addArg("-D_GLIBCXX_ASSERTIONS");
    torrents.addArg("-fstack-protector-strong");
    if (optimize != .debug) {
        // Distro compilers may predefine fortification; replace it explicitly.
        torrents.addArg("-U_FORTIFY_SOURCE");
        torrents.addArg("-D_FORTIFY_SOURCE=3");
    }
    inline for (.{ "helper.cpp", "helper_transfers.cpp", "helper_peers.cpp", "helper_tray.cpp" }) |part| torrents.addFileArg(b.path("src/files/torrent/" ++ part));
    torrents.addFileInput(b.path("src/files/torrent/helper.hpp"));
    torrents.addFileInput(b.path("src/platform/self_exe.h"));
    torrents.addArg("-o");
    const torrent_binary = torrents.addOutputFileArg("rediwm-transfers");
    const install_torrents = b.addInstallFileWithDir(torrent_binary, .bin, "rediwm-transfers");
    b.getInstallStep().dependOn(&install_torrents.step);
    const torrent_license = b.addInstallFileWithDir(b.path("src/files/torrent/LICENSE.libtorrent"), .prefix, "share/licenses/rediwm/libtorrent-LICENSE");
    b.getInstallStep().dependOn(&torrent_license.step);
    const install_files = b.addInstallArtifact(files, .{});
    // Advertises rediwm-files to the start menu's applications scanner
    // (src/start_menu/applications.zig) and to any other XDG-aware
    // launcher. Its icon is installed in the hicolor fallback theme so the
    // start menu and taskbar can resolve the desktop entry's Icon name.
    const install_files_desktop_entry = b.addInstallFileWithDir(
        localizedData(b, i18n_tool, ctx.layout.prefix, "data/rediwm-files.desktop"),
        .prefix,
        "share/applications/rediwm-files.desktop",
    );
    b.getInstallStep().dependOn(&install_files.step);
    b.getInstallStep().dependOn(&install_files_desktop_entry.step);
    const install_files_icon = b.addSystemCommand(&.{ "install", "-Dm644", "-t" });
    install_files_icon.addDirectoryArg(support.installed(.prefix, "share/icons/hicolor/256x256/apps"));
    install_files_icon.addFileArg(b.path("assets/icons/redi-fm-icon.png"));
    b.getInstallStep().dependOn(&install_files_icon.step);
    // rediwm-files links neither wlroots-server nor libinput/libpulse, so it
    // can be built (and its dependencies checked) without the rest of this
    // repository's toolchain. `zig build` (the default `install` step) still
    // builds everything, this only adds a narrower entry point.
    const files_step = b.step("files", "Build the standalone Files and image viewer clients");
    files_step.dependOn(&install_files.step);
    files_step.dependOn(&install_torrents.step);
    files_step.dependOn(&torrent_license.step);
    const transfers_entry = b.addInstallFileWithDir(localizedData(b, i18n_tool, ctx.layout.prefix, "data/rediwm-transfers.desktop"), .prefix, "share/applications/rediwm-transfers.desktop");
    b.getInstallStep().dependOn(&transfers_entry.step);
    files_step.dependOn(&transfers_entry.step);
    const test_torrents = b.step("test-files-torrents", "Test real loopback transfers and the Files/tray interface");
    const torrent_engine_test = b.addSystemCommand(&.{ "python3", "tests/files_torrents.py" });
    torrent_engine_test.step.dependOn(b.getInstallStep());
    const torrent_ui_test = b.addSystemCommand(&.{ "python3", "tests/files_transfers_ui.py" });
    torrent_ui_test.step.dependOn(&torrent_engine_test.step);
    test_torrents.dependOn(&torrent_ui_test.step);
    files_step.dependOn(&install_files_desktop_entry.step);
    files_step.dependOn(&terminal_license.step);
    const terminal_child = b.addExecutable(.{
        .name = "rediwm-files-terminal",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
    });
    terminal_child.root_module.addCSourceFile(.{ .file = b.path("src/files/terminal/child.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    terminal_child.root_module.linkSystemLibrary("gio-2.0", .{});
    const install_terminal = b.addInstallArtifact(terminal_child, .{});
    b.getInstallStep().dependOn(&install_terminal.step);
    files_step.dependOn(&install_terminal.step);
    const bash_hook = b.addLibrary(.{
        .name = "rediwm-files-bash",
        .linkage = .dynamic,
        .root_module = b.createModule(.{ .target = target, .optimize = .fast, .link_libc = true, .sanitize_c = .off }),
    });
    bash_hook.root_module.addCSourceFile(.{ .file = b.path("src/files/terminal/bash.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    bash_hook.root_module.linkSystemLibrary("readline", .{});
    const install_bash = b.addInstallArtifact(bash_hook, .{ .dest_dir = .{ .override = .lib }, .dest_sub_path = "rediwm/files-bash.so", .dylib_symlinks = false });
    b.getInstallStep().dependOn(&install_bash.step);
    files_step.dependOn(&install_bash.step);

    const images = b.addExecutable(.{
        .name = "rediwm-images",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/images_main.zig"), .target = target, .optimize = optimize, .link_libc = true }),
        .use_llvm = use_llvm,
        .use_lld = use_llvm,
    });
    images.root_module.addImport("wayland", wayland);
    inline for (.{ "wayland-client", "wayland-cursor", "gdk-pixbuf-2.0", "gobject-2.0", "glib-2.0", "xkbcommon" }) |lib| images.root_module.linkSystemLibrary(lib, .{});
    const install_images = b.addInstallArtifact(images, .{});
    const images_entry = b.addInstallFileWithDir(localizedData(b, i18n_tool, ctx.layout.prefix, "data/rediwm-images.desktop"), .prefix, "share/applications/rediwm-images.desktop");
    b.getInstallStep().dependOn(&install_images.step);
    b.getInstallStep().dependOn(&images_entry.step);
    const images_step = b.step("images", "Build the standalone image viewer");
    images_step.dependOn(&install_images.step);
    images_step.dependOn(&images_entry.step);
    files_step.dependOn(&install_images.step);
    files_step.dependOn(&images_entry.step);

    const monitor = b.addExecutable(.{
        .name = "rediwm-monitor",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/system_monitor_main.zig"), .target = target, .optimize = optimize, .link_libc = true }),
        .use_llvm = use_llvm,
        .use_lld = use_llvm,
    });
    monitor.root_module.addImport("wayland", wayland);
    inline for (.{ "wayland-client", "wayland-cursor", "xkbcommon" }) |lib| monitor.root_module.linkSystemLibrary(lib, .{});
    const install_monitor = b.addInstallArtifact(monitor, .{});
    const monitor_entry = b.addInstallFileWithDir(localizedData(b, i18n_tool, ctx.layout.prefix, "data/rediwm-monitor.desktop"), .prefix, "share/applications/rediwm-monitor.desktop");
    const monitor_icon = b.addInstallFileWithDir(b.path("data/rediwm-monitor.svg"), .prefix, "share/icons/hicolor/scalable/apps/rediwm-monitor.svg");
    const monitor_step = b.step("monitor", "Build the standalone System Monitor");
    inline for (.{ &install_monitor.step, &monitor_entry.step, &monitor_icon.step }) |step| {
        b.getInstallStep().dependOn(step);
        monitor_step.dependOn(step);
    }

    const calculator = b.addExecutable(.{
        .name = "rediwm-calculator",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/calculator_main.zig"), .target = target, .optimize = optimize, .link_libc = true }),
        .use_llvm = use_llvm,
        .use_lld = use_llvm,
    });
    calculator.root_module.addImport("wayland", wayland);
    inline for (.{ "wayland-client", "wayland-cursor", "xkbcommon" }) |lib| calculator.root_module.linkSystemLibrary(lib, .{});
    const install_calculator = b.addInstallArtifact(calculator, .{});
    const calculator_entry = b.addInstallFileWithDir(localizedData(b, i18n_tool, ctx.layout.prefix, "data/rediwm-calculator.desktop"), .prefix, "share/applications/rediwm-calculator.desktop");
    const calculator_icon = b.addInstallFileWithDir(b.path("data/rediwm-calculator.svg"), .prefix, "share/icons/hicolor/scalable/apps/rediwm-calculator.svg");
    const calculator_step = b.step("calculator", "Build the standalone Calculator");
    inline for (.{ &install_calculator.step, &calculator_entry.step, &calculator_icon.step }) |step| {
        b.getInstallStep().dependOn(step);
        calculator_step.dependOn(step);
    }

    const editor = b.addExecutable(.{
        .name = "rediwm-editor",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/editor_main.zig"), .target = target, .optimize = optimize, .link_libc = true }),
        .use_llvm = use_llvm,
        .use_lld = use_llvm,
    });
    editor.root_module.addImport("wayland", wayland);
    inline for (.{ "wayland-client", "wayland-cursor", "xkbcommon", "pangocairo" }) |lib| editor.root_module.linkSystemLibrary(lib, .{});
    const install_editor = b.addInstallArtifact(editor, .{});
    const editor_entry = b.addInstallFileWithDir(localizedData(b, i18n_tool, ctx.layout.prefix, "data/rediwm-editor.desktop"), .prefix, "share/applications/rediwm-editor.desktop");
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
    pdf.root_module.addCSourceFile(.{ .file = b.path("src/pdf/print.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    inline for (.{ "wayland-client", "wayland-cursor", "poppler-glib", "cairo", "gio-2.0", "gobject-2.0", "glib-2.0", "xkbcommon" }) |lib| pdf.root_module.linkSystemLibrary(lib, .{});
    const install_pdf = b.addInstallArtifact(pdf, .{});
    const pdf_entry = b.addInstallFileWithDir(localizedData(b, i18n_tool, ctx.layout.prefix, "data/rediwm-pdf.desktop"), .prefix, "share/applications/rediwm-pdf.desktop");
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
    return .{ .files = files, .images = images, .monitor = monitor, .calculator = calculator, .editor = editor, .pdf = pdf, .share_picker = share_picker };
}
