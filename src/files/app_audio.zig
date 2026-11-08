//! Files and the built-in audio player: the play button on audio rows, opening
//! audio in rediwm-player, and following what it plays.
//!
//! The player is a separate process (src/player/), so playback outlives this
//! window. The link thread (player_link.c) only reports changes; while a
//! track plays in the folder on screen, a deadline repaints its progress ring.

const std = @import("std");
const i18n = @import("i18n");
const tr = i18n.tr;
const platform = @import("platform");
const App = @import("app.zig").App;
const ui = @import("ui").cairo;
const theme = @import("ui").theme;
const button = @import("ui").widgets.button;
const header = @import("header.zig");
const draw = @import("app_draw.zig");
const associations = @import("associations.zig");
const formats = @import("../player/formats.zig");
const player_link = @import("player_link.zig");
const volumes_mod = @import("volumes.zig");

/// The desktop entry that stands for the built-in player in the MIME defaults.
const bundled_id = "rediwm-player.desktop";
/// The progress ring repaints this often while it moves.
const tick_ms = 250;

/// Starts following the player. Once, after the window exists.
pub fn startAudio(self: *App) void {
    if (self.audio_link != null or self.chooser != null or volumes_mod.disabled(self.environ)) return;
    // Without a session bus GIO would try to autolaunch one.
    if (self.environ.getPosix("DBUS_SESSION_BUS_ADDRESS") == null) {
        const runtime = self.environ.getPosix("XDG_RUNTIME_DIR") orelse return;
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const socket = std.fmt.bufPrintSentinel(&buf, "{s}/bus", .{runtime}, 0) catch return;
        if (std.c.access(socket, std.c.F_OK) != 0) return;
    }
    self.audio_link = player_link.Link.start();
}

/// Readable when `drainAudio` has news; -1 before `startAudio`.
pub fn audioWakeFd(self: *const App) c_int {
    return if (self.audio_link) |link| link.wakeFd() else -1;
}

pub fn drainAudio(self: *App) void {
    const link = self.audio_link orelse return;
    link.clearWake();
    var state = self.audio_state;
    if (link.take(&state)) {
        if (!state.isTrack(self.audio_state.file())) self.audio_bar.drag.end();
        const list = link.playlist();
        if (self.audio_bar.playlist) |old| {
            if (list == null or old.handle != list.?.handle) {
                self.audio_bar.playlist_selected = 0;
                self.audio_bar.playlist_first = 0;
            }
            old.deinit();
        }
        self.audio_bar.playlist = list;
        if (state.status == .none) self.audio_bar.playlist_open = false;
        self.audio_state = state;
        self.invalidate();
    }
    self.audio_tick_at = 0;
}

pub fn stopAudio(self: *App) void {
    if (self.audio_bar.playlist) |list| list.deinit();
    self.audio_bar.playlist = null;
    if (self.audio_link) |link| link.stop();
    self.audio_link = null;
}

/// Whether activating this file plays it here: the built-in player is on, can
/// decode it, and the user has not chosen another default application.
pub fn playsBuiltin(self: *App, path: []const u8) bool {
    if (!self.audio_player or self.chooser != null or self.history.archive_len > 0 or !formats.candidate(path)) return false;
    return !associations.hasExplicitDefault(path, bundled_id);
}

/// Hands `path` to the player, starting it if needed. False when it cannot be
/// reached at all.
pub fn playAudio(self: *App, path: []const u8) bool {
    const link = self.audio_link orelse return false;
    var sibling: [platform.exe.max_path]u8 = undefined;
    const executable = platform.exe.siblingOrName(&sibling, "rediwm-player");
    const executable_z = std.heap.c_allocator.dupeSentinel(u8, executable, 0) catch return false;
    defer std.heap.c_allocator.free(executable_z);
    const path_z = std.heap.c_allocator.dupeSentinel(u8, path, 0) catch return false;
    defer std.heap.c_allocator.free(path_z);
    link.play(path_z, executable_z, self.terminalScopes());
    return true;
}

fn audioItem(self: *App, index: usize) bool {
    if (!self.audio_player or self.audio_link == null or self.chooser != null or self.transfer_view.active or index >= self.items.items.len) return false;
    const item = self.items.items[index];
    return !item.is_dir and !item.is_broken and !item.missing and formats.candidate(item.name) and playsBuiltin(self, item.path);
}

fn isCurrent(self: *App, index: usize) bool {
    return index < self.items.items.len and self.audio_state.isTrack(self.items.items[index].path);
}

const button_size: f64 = 28;

/// The button's box in window coordinates: right-aligned in the name column in
/// list view, over the icon in the grid, where it only shows on the item under
/// the pointer or the one playing.
fn buttonRect(self: *App, index: usize) ?header.Rect {
    if (!audioItem(self, index)) return null;
    const row: i32 = @intCast(index / @as(usize, @intCast(self.columns())));
    const y: f64 = @floatFromInt(self.viewTop() + self.itemInset() + row * self.rowHeight() - self.scroll_y);
    if (self.list_view) {
        const name = self.listColumn(0);
        if (name.w < 120) return null;
        return .{ .x = name.x + name.w - 4 - button_size, .y = y + (@as(f64, @floatFromInt(self.cardHeight())) - button_size) / 2, .w = button_size, .h = button_size };
    }
    if (!isCurrent(self, index) and self.itemAt(self.mouse_x, self.mouse_y) != index) return null;
    const icon = self.itemIconRect(@intCast(index));
    return .{ .x = icon.x + (icon.w - button_size) / 2, .y = icon.y + (icon.h - button_size) / 2, .w = button_size, .h = button_size };
}

/// Room the button takes from the file name in list view.
pub fn audioButtonWidth(self: *App, index: usize) f64 {
    if (!self.list_view) return 0;
    return if (buttonRect(self, index) != null) button_size + 6 else 0;
}

pub fn renderAudioButton(self: *App, cr: *@import("c.zig").api.cairo_t, index: usize) void {
    const rect = buttonRect(self, index) orelse return;
    const current = isCurrent(self, index);
    const playing = current and self.audio_state.status == .playing;
    const hover = self.dialog == null and self.menu == null and rect.contains(self.mouse_x, self.mouse_y);
    const c = @import("c.zig").api;
    c.cairo_save(cr);
    defer c.cairo_restore(cr);
    c.cairo_rectangle(cr, @floatFromInt(self.sidebarWidth()), @floatFromInt(self.viewTop()), @floatFromInt(self.w - self.sidebarWidth() - self.scrollbarGutter()), @floatFromInt(@max(0, self.contentBottom() - self.viewTop())));
    c.cairo_clip(cr);
    if (!self.list_view) {
        // Over a picture or a type icon, the control needs its own backing.
        var backing = theme.global.app_bg;
        backing[3] = 0.88;
        draw.setSource(cr, backing);
        c.cairo_arc(cr, rect.x + rect.w / 2, rect.y + rect.h / 2, rect.w / 2 - 1, 0, 2 * std.math.pi);
        c.cairo_fill(cr);
    }
    ui.drawProgressRing(cr, .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h }, if (current) self.audio_state.fraction(draw.nowMs()) else 0, theme.shellPalette().accent);
    var layer = ui.Layer.begin(cr, .{ .x = @floatCast(rect.x), .y = @floatCast(rect.y), .w = button_size, .h = button_size }) orelse return;
    defer layer.finish();
    button.paint(&layer.renderer, layer.local(), .{
        .variant = .ghost,
        .size = .sm,
        .icon = if (playing) .pause else .play,
        .label = if (playing) tr("Pause") else tr("Play"),
    }, .{ .pointer = if (hover) .hover else .idle });
}

/// The row whose button is under the pointer.
pub fn audioButtonHit(self: *App, x: f64, y: f64) ?usize {
    if (self.dialog != null or self.menu != null or self.selection_band != null or self.drag_origin != null) return null;
    const index = self.itemAt(x, y) orelse return null;
    const rect = buttonRect(self, index) orelse return null;
    return if (rect.contains(x, y)) index else null;
}

/// A click on a button: pause or resume this row's track, or play it.
pub fn audioButtonClick(self: *App, x: f64, y: f64) bool {
    const index = audioButtonHit(self, x, y) orelse return false;
    self.last_click_index = null;
    self.last_click_time = 0;
    const path = self.items.items[index].path;
    if (self.audio_state.isTrack(path)) {
        if (self.audio_link) |link| link.playPause();
    } else if (!playAudio(self, path)) {
        self.setStatusNotice(tr("Could not play the file"), true);
    } else self.worker.recordOpened(path);
    return true;
}

/// When the progress ring next needs repainting; null when nothing moves.
pub fn audioDeadline(self: *App) ?i64 {
    const feedback = @import("app_audio_bar.zig").deadline(self);
    const progress = progressDeadline(self);
    return if (feedback) |at| @min(at, progress orelse at) else progress;
}

fn progressDeadline(self: *App) ?i64 {
    if (self.audio_state.status != .playing or self.audio_state.length_us <= 0 or self.audio_link == null) return null;
    if (@import("app_audio_bar.zig").visible(self)) return self.audio_tick_at;
    // Only a track in the folder on screen shows a ring.
    const dir = std.fs.path.dirname(self.audio_state.file()) orelse return null;
    if (!std.mem.eql(u8, dir, self.history.current)) return null;
    return self.audio_tick_at;
}

pub fn stepAudio(self: *App, now: i64) void {
    @import("app_audio_bar.zig").step(self, now);
    if (self.audio_state.status != .playing) return;
    if (self.audio_tick_at == 0) self.audio_tick_at = now + tick_ms;
    const at = progressDeadline(self) orelse return;
    if (now < at) return;
    self.audio_tick_at = now + tick_ms;
    if (@import("app_audio_bar.zig").rect(self)) |r| self.addDamage(r);
    for (self.items.items, 0..) |item, i| {
        if (!self.audio_state.isTrack(item.path)) continue;
        if (buttonRect(self, i)) |rect| self.addDamage(.{ .x = rect.x - 2, .y = rect.y - 2, .w = rect.w + 4, .h = rect.h + 4 });
        return;
    }
}

/// The key `hoverKey` reports over a row's button (in the range the hover
/// bookkeeping treats as "repaint everything").
pub fn audioHoverKey(index: usize) usize {
    return std.math.maxInt(usize) - (20 + @as(usize, @min(index, 1900)));
}
