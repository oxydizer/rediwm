// Opt-in startup timing. Recording a monotonic timestamp is cheap and always
// on so IPC/tests can observe it; logging is gated by REDIWM_STARTUP_TIMING.
// Offsets are nanoseconds from process entry. Zero means the mark has not
// happened yet. A listening socket is not a responsive event loop, and a
// queued frame is not a presentation — first_presented is the first successful
// scene commit, first_ipc the first successfully handled IPC request.
const std = @import("std");
const builtin = @import("builtin");
const stats = @import("ipc/stats.zig");

const log = std.log.scoped(.startup);

pub const CatalogState = enum {
    pending,
    loading,
    cache,
    published,
};

pub const WallpaperState = enum {
    solid,
    decoding,
    presented,
    failed,
};

pub const Marks = struct {
    origin_ns: u64 = 0,
    renderer_ready_ns: u64 = 0,
    config_ready_ns: u64 = 0,
    catalog_cache_read_ns: u64 = 0,
    catalog_scan_ns: u64 = 0,
    wallpaper_decode_ns: u64 = 0,
    socket_ready_ns: u64 = 0,
    ipc_ready_ns: u64 = 0,
    session_ready_ns: u64 = 0,
    session_clients_started_ns: u64 = 0,
    xwayland_ready_ns: u64 = 0,
    first_presented_ns: u64 = 0,
    first_ipc_ns: u64 = 0,
    first_input_ns: u64 = 0,
    catalog_published_ns: u64 = 0,
    wallpaper_presented_ns: u64 = 0,
    desktop_client_ready_ns: u64 = 0,

    catalog_cache_read_duration_ns: u64 = 0,
    catalog_scan_duration_ns: u64 = 0,
    wallpaper_decode_duration_ns: u64 = 0,

    catalog_state: CatalogState = .pending,
    wallpaper_state: WallpaperState = .solid,
    catalog_provisional: bool = false,
    catalog_loading: bool = true,
    catalog_generation: u64 = 0,
    catalog_entries: u32 = 0,
    autostart_count: u32 = 0,
    output_count: u32 = 0,
    scale: f32 = 1,
    renderer: []const u8 = "",
    build_mode: []const u8 = @tagName(builtin.mode),

    wallpaper_awaiting_present: bool = false,
    log_enabled: bool = false,
};

pub var marks: Marks = .{};

pub fn initOrigin(environ: std.process.Environ) void {
    marks.origin_ns = stats.nowNs();
    marks.log_enabled = envEnabled(environ, "REDIWM_STARTUP_TIMING");
    if (marks.log_enabled) {
        log.info("process entry (build_mode={s})", .{marks.build_mode});
    }
}

pub fn envEnabled(environ: std.process.Environ, key: []const u8) bool {
    const text = environ.getPosix(key) orelse return false;
    return text.len > 0 and !std.mem.eql(u8, text, "0") and !std.mem.eql(u8, text, "false");
}

pub fn envDelayNs(environ: std.process.Environ, key: []const u8) u64 {
    const text = environ.getPosix(key) orelse return 0;
    const ms = std.fmt.parseInt(u64, text, 10) catch return 0;
    return ms *% 1_000_000;
}

pub fn offset(abs_ns: u64) u64 {
    if (abs_ns == 0 or marks.origin_ns == 0) return 0;
    return abs_ns -% marks.origin_ns;
}

fn stampFirst(slot: *u64, name: []const u8) void {
    if (slot.* != 0) return;
    slot.* = stats.nowNs();
    if (marks.log_enabled) {
        log.info("{s} +{d}ms", .{ name, offset(slot.*) / 1_000_000 });
    }
}

pub fn markRendererReady(renderer: []const u8, scale: f32) void {
    marks.renderer = renderer;
    marks.scale = scale;
    stampFirst(&marks.renderer_ready_ns, "renderer_ready");
}

pub fn markConfigReady(autostart_count: u32) void {
    marks.autostart_count = autostart_count;
    stampFirst(&marks.config_ready_ns, "config_ready");
}

pub fn markSocketReady() void {
    stampFirst(&marks.socket_ready_ns, "socket_ready");
}

pub fn markIpcReady() void {
    stampFirst(&marks.ipc_ready_ns, "ipc_ready");
}

pub fn markFirstIpc() void {
    stampFirst(&marks.first_ipc_ns, "first_ipc");
}

pub fn markSessionReady() void {
    stampFirst(&marks.session_ready_ns, "session_ready");
}

pub fn markSessionClientsStarted() void {
    stampFirst(&marks.session_clients_started_ns, "session_clients_started");
}

pub fn markXwaylandReady() void {
    stampFirst(&marks.xwayland_ready_ns, "xwayland_ready");
}

pub fn markFirstInput() void {
    stampFirst(&marks.first_input_ns, "first_input");
}

pub fn markCatalogCacheRead(duration_ns: u64, entries: u32) void {
    marks.catalog_cache_read_duration_ns = duration_ns;
    marks.catalog_entries = entries;
    marks.catalog_state = .cache;
    marks.catalog_provisional = true;
    marks.catalog_loading = false;
    stampFirst(&marks.catalog_cache_read_ns, "catalog_cache_read");
}

pub fn markCatalogLoading() void {
    if (marks.catalog_state == .pending) {
        marks.catalog_state = .loading;
        marks.catalog_loading = true;
    }
}

pub fn markCatalogPublished(duration_ns: u64, entries: u32, provisional: bool, generation: u64) void {
    marks.catalog_scan_duration_ns = duration_ns;
    marks.catalog_entries = entries;
    marks.catalog_provisional = provisional;
    marks.catalog_loading = false;
    marks.catalog_generation = generation;
    marks.catalog_state = if (provisional) .cache else .published;
    stampFirst(&marks.catalog_scan_ns, "catalog_scan");
    if (!provisional) {
        stampFirst(&marks.catalog_published_ns, "catalog_published");
    }
}

pub fn markWallpaperDecoding() void {
    if (marks.wallpaper_state == .solid) marks.wallpaper_state = .decoding;
}

pub fn markWallpaperDecoded(duration_ns: u64) void {
    marks.wallpaper_decode_duration_ns = duration_ns;
    stampFirst(&marks.wallpaper_decode_ns, "wallpaper_decode");
    marks.wallpaper_awaiting_present = true;
}

pub fn markWallpaperFailed() void {
    marks.wallpaper_state = .failed;
    marks.wallpaper_awaiting_present = false;
    if (marks.log_enabled) log.info("wallpaper_failed", .{});
}

pub fn notePresented(output_count: u32, scale: f32) void {
    marks.output_count = output_count;
    // Preserve the legacy scalar metric as the highest active output density.
    marks.scale = scale;
    stampFirst(&marks.first_presented_ns, "first_presented");
    if (marks.wallpaper_awaiting_present) {
        marks.wallpaper_awaiting_present = false;
        marks.wallpaper_state = .presented;
        stampFirst(&marks.wallpaper_presented_ns, "wallpaper_presented");
    }
}

pub fn markDesktopClientReady() void {
    stampFirst(&marks.desktop_client_ready_ns, "desktop_client_ready");
}

pub fn interruptibleSleep(running: *const std.atomic.Value(bool), delay_ns: u64) void {
    if (delay_ns == 0) return;
    const slice: u64 = 50_000_000;
    var left = delay_ns;
    while (left > 0) {
        if (!running.load(.seq_cst)) return;
        const step = @min(left, slice);
        const ms: i32 = @intCast(@max(step / 1_000_000, 1));
        _ = std.posix.poll(&.{}, ms) catch {};
        left -= step;
    }
}

test "offset is zero until origin and mark are set" {
    const saved = marks;
    defer marks = saved;
    marks = .{};
    try std.testing.expectEqual(@as(u64, 0), offset(1));
    marks.origin_ns = 1000;
    try std.testing.expectEqual(@as(u64, 0), offset(0));
    try std.testing.expectEqual(@as(u64, 250), offset(1250));
}

test "catalog published is distinct from a provisional cache" {
    const saved = marks;
    defer marks = saved;
    marks = .{ .origin_ns = stats.nowNs() };
    markCatalogCacheRead(10, 3);
    try std.testing.expectEqual(CatalogState.cache, marks.catalog_state);
    try std.testing.expect(marks.catalog_published_ns == 0);
    markCatalogPublished(20, 3, false, 1);
    try std.testing.expectEqual(CatalogState.published, marks.catalog_state);
    try std.testing.expect(marks.catalog_published_ns != 0);
}
