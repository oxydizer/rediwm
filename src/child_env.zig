// Environment map for compositor-spawned children. DISPLAY is the owned
// Xwayland display when that server exists; otherwise inherited host X11
// settings are stripped so X clients cannot attach to a nested host session.
const std = @import("std");

pub const Map = std.process.Environ.Map;

/// Desktop identity spawned children and portal routing use. Matches
/// `data/rediwm-portals.conf` / `data/rediwm.desktop` (`DesktopNames`).
pub const desktop_name = "rediwm";
pub const session_type = "wayland";

pub const InputMethod = @import("config").types.InputMethod;

pub const Spec = struct {
    region: @import("config").loader.RegionConfig = .{},
    input_method: InputMethod = .none,
    wayland_display: ?[]const u8 = null,
    ipc_socket: ?[]const u8 = null,
    /// Owned Xwayland `DISPLAY` value (`:N`). Null means Xwayland is disabled
    /// or failed to start: strip host X11 connection settings instead.
    x11_display: ?[]const u8 = null,
    activation_token: ?[]const u8 = null,
    /// Configured Xcursor theme, so clients drawing their own cursors match
    /// the compositor's. Null leaves inherited XCURSOR_THEME/SIZE alone.
    cursor_theme: ?[]const u8 = null,
    cursor_size: u32 = 0,
    /// XCURSOR_PATH including RediWM's installed themes.
    cursor_path: ?[]const u8 = null,
};

pub fn apply(map: *Map, spec: Spec) !void {
    try applyRegion(map, spec.region);
    // Private supervisor authority must never escape to descendant launches.
    inline for (.{ "REDIWM_SESSION_FD", "REDIWM_LOGIN_SESSION", "REDIWM_SESSION_PRIMARY" }) |key| _ = map.swapRemove(key);
    switch (spec.input_method) {
        .none => {},
        inline .fcitx, .ibus => |im| {
            const module = @tagName(im);
            try map.put("XMODIFIERS", "@im=" ++ module);
            try map.put("QT_IM_MODULE", module);
            try map.put("QT_IM_MODULES", "wayland;" ++ module);
            try map.put("SDL_IM_MODULE", module);
            _ = map.swapRemove("GTK_IM_MODULE");
        },
    }
    if (spec.wayland_display) |value| try map.put("WAYLAND_DISPLAY", value);
    if (spec.ipc_socket) |value| try map.put("REDIWM_SOCKET", value);
    if (spec.cursor_path) |value| try map.put("XCURSOR_PATH", value);
    if (spec.cursor_theme) |theme| {
        try map.put("XCURSOR_THEME", theme);
        var buf: [16]u8 = undefined;
        try map.put("XCURSOR_SIZE", try std.fmt.bufPrint(&buf, "{d}", .{spec.cursor_size}));
    }
    if (spec.activation_token) |tok| {
        try map.put("XDG_ACTIVATION_TOKEN", tok);
        try map.put("DESKTOP_STARTUP_ID", tok);
    } else {
        _ = map.swapRemove("XDG_ACTIVATION_TOKEN");
        _ = map.swapRemove("DESKTOP_STARTUP_ID");
    }
    // Always overwrite: a nested compositor inherits the host's desktop
    // (sway/niri/GNOME) and would otherwise send portal requests to the host
    // backend. Spawned apps and xdpw must see RediWM.
    try map.put("XDG_CURRENT_DESKTOP", desktop_name);
    try map.put("XDG_SESSION_TYPE", session_type);
    if (spec.x11_display) |value| {
        if (value.len > 0) {
            try map.put("DISPLAY", value);
        } else {
            stripHostX11(map);
        }
    } else {
        stripHostX11(map);
    }
}

pub const format_categories = [_][]const u8{ "LC_TIME", "LC_NUMERIC", "LC_MONETARY", "LC_MEASUREMENT", "LC_PAPER", "LC_ADDRESS", "LC_TELEPHONE", "LC_NAME" };

pub fn applyRegion(map: *Map, prefs: @import("config").loader.RegionConfig) !void {
    if (prefs.timezone.len != 0) try map.put("TZ", prefs.timezone);
    if (prefs.language.len == 0 and prefs.formats.len == 0) return;
    // Preserve LC_ALL's inherited categories before removing its precedence.
    if (map.get("LC_ALL")) |all| {
        const copy = try map.allocator.dupe(u8, all);
        defer map.allocator.free(copy);
        if (copy.len != 0) {
            inline for (.{ "LC_MESSAGES", "LC_CTYPE", "LC_COLLATE", "LC_TIME", "LC_NUMERIC", "LC_MONETARY", "LC_MEASUREMENT", "LC_PAPER", "LC_ADDRESS", "LC_TELEPHONE", "LC_NAME", "LC_IDENTIFICATION" }) |key| try map.put(key, copy);
        }
        _ = map.swapRemove("LC_ALL");
    }
    if (prefs.language.len != 0) {
        try map.put("LANG", prefs.language);
        try map.put("LC_MESSAGES", prefs.language);
        try map.put("LC_CTYPE", prefs.language);
        // gettext's LANGUAGE would otherwise override LC_MESSAGES.
        _ = map.swapRemove("LANGUAGE");
    }
    for (format_categories) |key| if (prefs.formats.len != 0) try map.put(key, prefs.formats);
}

fn stripHostX11(map: *Map) void {
    // Host DISPLAY/XAUTHORITY would send X clients to the nested backend's
    // parent session. Clearing both is what "Xwayland disabled" means.
    _ = map.swapRemove("DISPLAY");
    _ = map.swapRemove("XAUTHORITY");
}

test "enabled Xwayland publishes DISPLAY and keeps Wayland sockets" {
    var map = Map.init(std.testing.allocator);
    defer map.deinit();
    try map.put("DISPLAY", ":0");
    try map.put("XAUTHORITY", "/tmp/host-xauth");
    try map.put("WAYLAND_DISPLAY", "wayland-host");
    try map.put("HOME", "/tmp");

    try apply(&map, .{
        .wayland_display = "wayland-1",
        .ipc_socket = "/run/user/1000/rediwm-1.sock",
        .x11_display = ":12",
    });

    try std.testing.expectEqualStrings("wayland-1", map.get("WAYLAND_DISPLAY").?);
    try std.testing.expectEqualStrings("/run/user/1000/rediwm-1.sock", map.get("REDIWM_SOCKET").?);
    try std.testing.expectEqualStrings(":12", map.get("DISPLAY").?);
    try std.testing.expectEqualStrings(desktop_name, map.get("XDG_CURRENT_DESKTOP").?);
    try std.testing.expectEqualStrings(session_type, map.get("XDG_SESSION_TYPE").?);
    // Host XAUTHORITY is left alone; Xwayland writes its cookie there.
    try std.testing.expectEqualStrings("/tmp/host-xauth", map.get("XAUTHORITY").?);
}

test "disabled Xwayland strips host DISPLAY and XAUTHORITY" {
    var map = Map.init(std.testing.allocator);
    defer map.deinit();
    try map.put("DISPLAY", ":0");
    try map.put("XAUTHORITY", "/tmp/host-xauth");
    try map.put("HOME", "/tmp");

    try apply(&map, .{
        .wayland_display = "wayland-1",
        .ipc_socket = "/tmp/rediwm.sock",
        .x11_display = null,
    });

    try std.testing.expectEqualStrings("wayland-1", map.get("WAYLAND_DISPLAY").?);
    try std.testing.expect(map.get("DISPLAY") == null);
    try std.testing.expect(map.get("XAUTHORITY") == null);
}

test "empty x11_display is treated as disabled" {
    var map = Map.init(std.testing.allocator);
    defer map.deinit();
    try map.put("DISPLAY", ":0");

    try apply(&map, .{ .x11_display = "" });
    try std.testing.expect(map.get("DISPLAY") == null);
}

test "child env overwrites a host XDG_CURRENT_DESKTOP" {
    var map = Map.init(std.testing.allocator);
    defer map.deinit();
    try map.put("XDG_CURRENT_DESKTOP", "sway");
    try map.put("XDG_SESSION_TYPE", "tty");

    try apply(&map, .{ .wayland_display = "wayland-1" });
    try std.testing.expectEqualStrings(desktop_name, map.get("XDG_CURRENT_DESKTOP").?);
    try std.testing.expectEqualStrings(session_type, map.get("XDG_SESSION_TYPE").?);
    try map.put("LC_ALL", "en_US.utf8");
    try map.put("LANGUAGE", "de:fr");
    try apply(&map, .{ .region = .{ .timezone = "Pacific/Auckland", .language = "C.utf8", .formats = "en_NZ.utf8" } });
    try std.testing.expect(map.get("LC_ALL") == null);
    try std.testing.expect(map.get("LANGUAGE") == null);
    try std.testing.expectEqualStrings("C.utf8", map.get("LANG").?);
    try std.testing.expectEqualStrings("C.utf8", map.get("LC_MESSAGES").?);
    try std.testing.expectEqualStrings("C.utf8", map.get("LC_CTYPE").?);
    try std.testing.expectEqualStrings("en_US.utf8", map.get("LC_COLLATE").?);
    for (format_categories) |key| try std.testing.expectEqualStrings("en_NZ.utf8", map.get(key).?);
    try std.testing.expectEqualStrings("Pacific/Auckland", map.get("TZ").?);
}

test "activation_token sets XDG_ACTIVATION_TOKEN and DESKTOP_STARTUP_ID" {
    var map = Map.init(std.testing.allocator);
    defer map.deinit();

    try apply(&map, .{
        .wayland_display = "wayland-1",
        .activation_token = "test-token-1234",
    });
    try std.testing.expectEqualStrings("test-token-1234", map.get("XDG_ACTIVATION_TOKEN").?);
    try std.testing.expectEqualStrings("test-token-1234", map.get("DESKTOP_STARTUP_ID").?);
}

test "input methods configure new children and preserve inherited settings for none" {
    inline for (.{ InputMethod.none, InputMethod.fcitx, InputMethod.ibus }) |method| {
        var map = Map.init(std.testing.allocator);
        defer map.deinit();
        try map.put("GTK_IM_MODULE", "inherited");
        try map.put("QT_IM_MODULE", "inherited");
        try apply(&map, .{ .input_method = method });
        if (method == .none) {
            try std.testing.expectEqualStrings("inherited", map.get("GTK_IM_MODULE").?);
            try std.testing.expectEqualStrings("inherited", map.get("QT_IM_MODULE").?);
            try std.testing.expect(map.get("XMODIFIERS") == null);
        } else {
            try std.testing.expect(map.get("GTK_IM_MODULE") == null);
            try std.testing.expectEqualStrings(@tagName(method), map.get("QT_IM_MODULE").?);
            try std.testing.expectEqualStrings("wayland;" ++ @tagName(method), map.get("QT_IM_MODULES").?);
            try std.testing.expectEqualStrings("@im=" ++ @tagName(method), map.get("XMODIFIERS").?);
            try std.testing.expectEqualStrings(@tagName(method), map.get("SDL_IM_MODULE").?);
        }
    }
}

test "private session authority and stale activation tokens never reach children" {
    var map = Map.init(std.testing.allocator);
    defer map.deinit();
    inline for (.{ "REDIWM_SESSION_FD", "REDIWM_LOGIN_SESSION", "REDIWM_SESSION_PRIMARY", "XDG_ACTIVATION_TOKEN", "DESKTOP_STARTUP_ID" }) |key| try map.put(key, "inherited");
    try apply(&map, .{});
    inline for (.{ "REDIWM_SESSION_FD", "REDIWM_LOGIN_SESSION", "REDIWM_SESSION_PRIMARY", "XDG_ACTIVATION_TOKEN", "DESKTOP_STARTUP_ID" }) |key| try std.testing.expect(map.get(key) == null);
}
