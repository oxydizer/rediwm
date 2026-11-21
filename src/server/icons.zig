//! Server icon lookup, caching and prefetch.

const std = @import("std");
const Server = @import("../Server.zig");
const icon_service_mod = @import("../icon_service.zig");
const applications = @import("../start_menu/applications.zig");

/// Nonblocking icon lookup for titlebar/taskbar/start-menu rendering; see
/// `icon_service.zig`. `.missing` whenever the service failed to start,
/// matching how every other optional subsystem in this compositor degrades.
pub fn iconLookup(server: *Server, name: []const u8, size_px: i32) icon_service_mod.Lookup {
    const svc = server.icon_service orelse return .missing;
    // Resolve the canonical icon name: many apps advertise an app_id /
    // StartupWMClass that differs from their desktop Icon= name (e.g.
    // "brave-browser" → "brave-desktop", "dev.zed.Zed" → "zed").
    // Retain the snapshot for the duration of this call so any slice
    // borrowed from its arena stays valid until after svc.request().
    const snap = server.start_menu_catalog.retainSnapshot();
    defer snap.release();
    const icon_name = server.icon_names.resolve(snap, name);
    return svc.request(icon_name, size_px);
}

/// Returns the icon name that should be used for a given app_id / WM class.
/// Priority:
///   1. A catalog entry whose StartupWMClass= exactly matches `app_id` → use
///      that entry's Icon= name.
///   2. A catalog entry whose desktop-file ID (sans ".desktop") exactly
///      matches `app_id` → use its Icon= name.
///   3. A catalog entry resolved through the stable application identity
///      (e.g. Transmission's per-instance GTK ID) → use its Icon= name.
///   4. Reverse-DNS strip: "com.example.App" → last component, tried against
///      catalog icon names.
///   5. Fall back to `app_id` unchanged.
/// The returned slice is either borrowed from `snap` arena memory or is a
/// sub-slice of `app_id`; the caller must keep `snap` retained until done.
pub fn iconNameForAppId(snap: *applications.Snapshot, app_id: []const u8) []const u8 {
    if (app_id.len == 0) return app_id;
    // The built-in settings window has no desktop entry.
    if (std.mem.eql(u8, app_id, @import("../Toplevel.zig").welcome_app_id)) return "builtin:redi-logo";
    if (std.mem.eql(u8, app_id, @import("../Toplevel.zig").settings_app_id)) return @import("ui").shell_icons.settings_icon_name;

    // Pass 1: exact StartupWMClass match → use the desktop file's Icon= name.
    for (snap.entries) |e| {
        if (e.startup_wm_class) |wmc| {
            if (std.mem.eql(u8, wmc, app_id)) {
                return e.icon orelse app_id;
            }
        }
    }

    // Share the catalog mapping used to launch another window. In particular,
    // this matches desktop-file IDs with or without the .desktop suffix.
    // Transmission advertises com.transmissionbt.transmission_<n>_<n>, while
    // its installed desktop entry and icon can be named transmission-gtk.
    if (@import("../window_tabs.zig").entry(snap.entries, app_id)) |entry| {
        return entry.icon orelse app_id;
    }

    // Reverse-DNS heuristic — "dev.zed.Zed" → last component "Zed".
    // Only fire when there are at least two dots (genuine reverse-DNS prefix).
    if (std.mem.lastIndexOfScalar(u8, app_id, '.')) |dot| {
        const last = app_id[dot + 1 ..];
        if (std.mem.indexOfScalar(u8, app_id[0..dot], '.') != null and last.len > 0) {
            // Try matching the last component against catalog icon names.
            for (snap.entries) |e| {
                const icon = e.icon orelse continue;
                if (std.mem.eql(u8, icon, last)) return icon;
            }
            // Return the last component so the theme lookup at least tries it
            // (e.g. "Zed" — some icon themes use that exact casing).
            return last;
        }
    }

    return app_id;
}

test "app icons use catalog identities before reverse-DNS fallback" {
    const snap = try applications.Snapshot.create(std.testing.allocator);
    defer snap.release();
    snap.entries = &.{
        .{ .id = "transmission-gtk.desktop", .desktop_file_path = "", .name = "Transmission", .exec = "transmission-gtk %U", .icon = "transmission-artwork" },
        .{ .id = "browser.desktop", .desktop_file_path = "", .name = "Browser", .exec = "browser", .startup_wm_class = "browser-class", .icon = "browser-artwork" },
        .{ .id = "com.example.App.desktop", .desktop_file_path = "", .name = "App", .exec = "app", .icon = "app-artwork" },
    };
    for ([_][2][]const u8{
        .{ "com.transmissionbt.transmission_1000_12345", "transmission-artwork" },
        .{ "com.transmissionbt.transmission_1000_67890", "transmission-artwork" },
        .{ "com.transmissionbt.transmission", "transmission-artwork" },
        .{ "transmission-gtk", "transmission-artwork" },
        .{ "transmission-gtk.desktop", "transmission-artwork" },
        .{ "browser-class", "browser-artwork" },
        .{ "com.example.App", "app-artwork" },
        .{ "com.unknown.Other", "Other" },
        .{ "com.transmissionbt.transmission_bad_12345", "transmission_bad_12345" },
        .{ "unknown", "unknown" },
        .{ "", "" },
    }) |case| {
        try std.testing.expectEqualStrings(case[1], iconNameForAppId(snap, case[0]));
    }
}

pub fn iconAcquire(server: *Server, id: u64) void {
    if (server.icon_service) |svc| svc.acquire(id);
}

pub fn iconRelease(server: *Server, id: u64) void {
    if (server.icon_service) |svc| svc.release(id);
}

/// Speculative scroll-ahead/initial-results prefetch (step 5); see
/// `IconService.prefetch`. Fire-and-forget, budget-gated, safe to call
/// every frame for names that may already be resolved.
pub fn iconPrefetch(server: *Server, name: []const u8, size_px: i32) void {
    if (server.icon_service) |svc| svc.prefetch(name, size_px);
}

/// Drops speculative work nothing is interested in anymore (a query/scroll
/// change); see `IconService.cancelSpeculative`.
pub fn iconCancelSpeculative(server: *Server) void {
    if (server.icon_service) |svc| svc.cancelSpeculative();
}

/// Forces every titlebar/chip/logo icon to redecode on its next repaint;
/// see `IconService.invalidateAll`. Nothing calls this automatically today
/// (no runtime icon-theme reload path exists in this compositor) — it's
/// available for a future explicit-refresh trigger.
pub fn iconInvalidateAll(server: *Server) void {
    if (server.icon_service) |svc| svc.invalidateAll();
}

/// Applications changed at runtime and may have brought icons: forgets
/// cached misses; see `IconService.refreshInstalled`.
pub fn iconRefreshInstalled(server: *Server) void {
    if (server.icon_service) |svc| svc.refreshInstalled();
}
