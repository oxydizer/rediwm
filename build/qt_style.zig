//! The RediWM Qt style (src/qt_style/): Fusion with neutral title bars. One
//! plugin per Qt major, built with the system C++ compiler and moc so it
//! matches the distro's Qt ABI, wherever that Qt's development files exist.
//! Installed as lib/rediwm/qt<N>/styles/; the compositor finds it beside its
//! own executable (src/config_runtime/app_theme.zig `findQtStyles`).
const std = @import("std");
const Context = @import("context.zig").Context;

const Qt = struct { major: u8, widgets: []const u8, moc: []const u8 };
const versions = [_]Qt{
    .{ .major = 5, .widgets = "Qt5Widgets", .moc = "\"$(pkg-config --variable=host_bins Qt5Core)/moc\"" },
    .{ .major = 6, .widgets = "Qt6Widgets", .moc = "\"$(pkg-config --variable=libexecdir Qt6Core)/moc\"" },
};

pub fn add(ctx: Context) void {
    const b = ctx.b;
    const wanted = b.option(bool, "qt-style", "Build the RediWM Qt style for each Qt with development files (default: when found)");
    if (wanted == false) return;
    // The system compiler and Qt are the host's; cross builds skip the style.
    if (!ctx.target.query.isNative()) return;
    var built = false;
    for (versions) |qt| {
        if (!present(b, qt)) continue;
        built = true;
        const script = b.fmt(
            \\set -e
            \\tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
            \\{s} $(pkg-config --cflags-only-I {s}) -o "$tmp/rediwm_style.moc" "$1"
            \\exec c++ -std=c++17 -shared -fPIC -Wall -Wextra -Werror -fstack-protector-strong {s} -I"$tmp" \
            \\  $(pkg-config --cflags {s}) "$1" -o "$2" -Wl,--as-needed $(pkg-config --libs {s})
        , .{ qt.moc, qt.widgets, if (ctx.optimize == .debug) "-O0 -g" else "-O2 -g -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=3", qt.widgets, qt.widgets });
        const run = b.addSystemCommand(&.{ "sh", "-c", script, b.fmt("build-qt{d}-style", .{qt.major}) });
        run.addFileArg(b.path("src/qt_style/rediwm_style.cpp"));
        run.addFileInput(b.path("src/qt_style/rediwm_style.json"));
        const plugin = run.addOutputFileArg("librediwm-style.so");
        const install = b.addInstallFileWithDir(plugin, .lib, b.fmt("rediwm/qt{d}/styles/librediwm-style.so", .{qt.major}));
        b.getInstallStep().dependOn(&install.step);
    }
    if (wanted == true and !built) std.debug.panic("-Dqt-style needs Qt5Widgets or Qt6Widgets development files and moc", .{});
}

fn present(b: *std.Build, qt: Qt) bool {
    var code: u8 = 0;
    const probe = b.fmt("pkg-config --exists {s} && test -x {s}", .{ qt.widgets, qt.moc });
    _ = b.runAllowFail(&.{ "sh", "-c", probe }, &code, .ignore) catch return false;
    return true;
}
