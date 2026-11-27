//! Files folder sizes: the size column, backed by the process's folder-size
//! service (`sizetree.zig`), and the Properties totals (`dirsize.zig`).

const std = @import("std");
const App = app_mod.App;
const dirsize = @import("dirsize.zig");
const sizetree = @import("sizetree.zig");
const app_mod = @import("app.zig");
const ItemSizeDisplay = App.ItemSizeDisplay;
const ViewItem = @import("app_model.zig").ViewItem;
const formatSize = @import("app_draw.zig").formatSize;

pub fn getOrInitDirsizePool(self: *App) !*dirsize.Pool {
    if (self.dirsize_pool) |p| return p;
    const p = try dirsize.Pool.init(self.allocator);
    self.dirsize_pool = p;
    return p;
}

/// A folder's Properties adds up its Size and On disk while it is open; the
/// dialog cancels the walk when it closes (`properties.State.deinit`).
pub fn startPropertiesSizes(self: *App) void {
    const dlg = if (self.dialog) |*d| d else return;
    const props = if (dlg.properties) |*p| p else return;
    if (!props.isDirectory() or props.sizes != null) return;
    const pool = self.getOrInitDirsizePool() catch return;
    props.sizes = pool.startJobWith(props.path, .{ .allocated = true }) catch null;
}

/// The process's folder-size service, shared by every window; a test may
/// give an App its own (`App.size_service`).
var shared_service: ?*sizetree.Service = null;

/// The shared service if it was started; never starts it.
pub fn sharedService() ?*sizetree.Service {
    return shared_service;
}

/// Retire the process-wide cache after every window has released its owner.
pub fn retireSharedService(reaper: *@import("reaper.zig").Reaper) void {
    const svc = shared_service orelse return;
    shared_service = null;
    @import("reaper.zig").retire(reaper, svc, sizetree.Service.destroy);
}

pub fn sizeService(self: *App) ?*sizetree.Service {
    if (self.size_service) |svc| return svc;
    // Tests give an App its own; none runs behind their backs.
    if (@import("builtin").is_test) return null;
    if (shared_service) |svc| return svc;
    shared_service = sizetree.Service.create(std.heap.c_allocator, sizetree.Service.defaultThreads(), sizetree.defaultAutoPolicy) catch return null;
    return shared_service;
}

fn sizeOwner(self: *App) ?*sizetree.Owner {
    if (self.size_owner == null) {
        const svc = self.sizeService() orelse return null;
        self.size_owner = svc.registerOwner();
    }
    return &self.size_owner.?;
}

pub const Viewport = struct {
    revision: u64,
    first: usize,
    last: usize,
};

/// Update demand from the actual viewport, independently of paint damage.
pub fn syncVisibleFolderSizes(self: *App) void {
    const height = self.contentBottom() - self.viewTop();
    const row_h = @max(1, self.rowHeight());
    const cols: usize = @intCast(@max(1, self.columns()));
    const top = self.scroll_y - self.itemInset();
    const row0: usize = @intCast(@max(0, @divFloor(top - self.cardHeight(), row_h) + 1));
    const row1: usize = @intCast(@max(0, -@divFloor(-(top + height), row_h)));
    const len = self.items.items.len;
    const first = @min(len, row0 * cols);
    const view: Viewport = .{
        .revision = self.view_revision,
        .first = first,
        .last = if (height <= 0) first else @max(first, @min(len, row1 * cols)),
    };
    if (self.size_viewport) |previous| if (std.meta.eql(previous, view)) return;

    const items = self.items.items[view.first..view.last];
    if (self.size_owner == null) {
        for (items) |item| {
            if (sizable(self, item)) break;
        } else {
            self.size_viewport = view;
            return;
        }
    }
    const owner = sizeOwner(self) orelse return;
    owner.beginViewport();
    var registered = true;
    for (items) |item| {
        if (sizable(self, item) and !owner.service.requestOwned(owner, item.path, .visible, .{
            .revalidate = true,
            .directory_key = item.directory_key,
        }))
            registered = false;
    }
    owner.endViewport();
    if (registered) self.size_viewport = view;
}

/// Folders whose size this window may show: real folders on disk, not an
/// archive's or a transfer's.
fn sizable(self: *App, item: ViewItem) bool {
    if (self.history.archive_len > 0 or self.history.torrent) return false;
    return item.is_dir and !item.is_symlink and !item.transfer_stub and !item.transfer_ghost and !item.missing;
}

pub fn startFolderSize(self: *App, idx: usize) void {
    if (idx >= self.items.items.len) return;
    const it = self.items.items[idx];
    if (!sizable(self, it)) return;
    const owner = sizeOwner(self) orelse return;
    owner.service.request(owner, it.path, .background, .{
        .force = true,
        .directory_key = it.directory_key,
    });
    self.size_viewport = null;
    self.damagePathSize(it.path);
}

pub fn cancelFolderSize(self: *App, idx: usize) void {
    if (idx >= self.items.items.len) return;
    const it = self.items.items[idx];
    if (!sizable(self, it)) return;
    const owner = if (self.size_owner) |*owner| owner else return;
    owner.service.stopPath(owner, it.path);
    self.damagePathSize(it.path);
}

/// A click on a folder's size: measure it, or stop it while it runs.
pub fn toggleFolderSize(self: *App, idx: usize) void {
    if (idx >= self.items.items.len) return;
    const it = self.items.items[idx];
    if (!sizable(self, it)) return;
    switch (self.folderSizeInfo(it).status) {
        .measuring, .revalidating => self.cancelFolderSize(idx),
        .partial, .exact => {},
        .unknown, .idle, .stale => self.startFolderSize(idx),
    }
}

/// Whether a click on this folder's size does something.
pub fn folderSizeClickable(self: *App, item: ViewItem) bool {
    if (!sizable(self, item)) return false;
    return switch (self.folderSizeInfo(item).status) {
        .partial, .exact => false,
        else => true,
    };
}

pub fn folderSizeInfo(self: *App, item: ViewItem) sizetree.Info {
    if (!sizable(self, item)) return .{};
    const svc = self.sizeService() orelse return .{};
    return svc.lookupIdentity(if (self.size_owner) |*owner| owner else null, item.path, item.directory_key);
}

/// Leaving a folder: the service drops the queued work for its subfolders
/// (what was added up stays).
pub fn cancelRunningFolderSizes(self: *App) void {
    if (self.size_owner) |*owner| owner.clear();
    self.size_viewport = null;
}

pub fn clearFolderSizes(self: *App) void {
    self.cancelRunningFolderSizes();
    self.invalidate();
}

/// Entering or refreshing a folder makes the next viewport check freshness.
/// The service applies its own age threshold to each requested directory.
pub fn revalidateFolderSizes(self: *App) void {
    self.size_viewport = null;
    self.invalidate();
}

pub fn hasRunningFolderSize(self: *App) bool {
    if (self.dialog) |*dlg| if (dlg.properties) |*props| if (props.sizesRunning()) return true;
    const svc = self.size_service orelse shared_service orelse return false;
    // A change not painted yet still needs one more turn.
    return svc.busy() or svc.generation.load(.acquire) != self.size_generation;
}

pub fn damagePathSize(self: *App, path: []const u8) void {
    for (self.items.items, 0..) |it, idx| {
        if (std.mem.eql(u8, it.path, path)) {
            if (self.sizeButtonRect(idx)) |r| {
                var rect = r;
                rect.x -= 2;
                rect.y -= 2;
                rect.w += 4;
                rect.h += 4;
                self.addDamage(rect);
            }
            break;
        }
    }
}

pub fn syncFolderSizes(self: *App) void {
    if (self.dialog) |*dlg| if (dlg.properties) |*props| if (props.pollSizes()) self.invalidate();
    const svc = self.size_service orelse shared_service orelse return;
    const generation = svc.generation.load(.acquire);
    if (generation == self.size_generation) return;
    self.size_generation = generation;
    damageVisibleSizes(self);
}

/// Damages the size of every folder on screen.
fn damageVisibleSizes(self: *App) void {
    const rh = @max(1, self.rowHeight());
    const cols: usize = @intCast(@max(1, self.columns()));
    const first_row: usize = @intCast(@max(0, @divTrunc(self.scroll_y - self.itemInset(), rh)));
    const rows: usize = @intCast(@divTrunc(@max(0, self.h), rh) + 2);
    const first = @min(self.items.items.len, first_row * cols);
    const last = @min(self.items.items.len, first + rows * cols);
    for (first..last) |idx| {
        if (self.sizeButtonRect(idx)) |r| {
            var rect = r;
            rect.x -= 2;
            rect.y -= 2;
            rect.w += 4;
            rect.h += 4;
            self.addDamage(rect);
        }
    }
}

/// The size column of a folder: measured automatically on fast local disks,
/// on a click elsewhere. "≈" is the last total while it is measured again;
/// "≥" means part of it could not be read.
pub fn itemSizeDisplay(self: *App, item: ViewItem, buf: *[64]u8) ItemSizeDisplay {
    if (!item.is_dir) {
        return .{ .text = formatSize(item.bytes, buf), .is_running = false };
    }
    if (item.is_symlink) {
        return .{ .text = "—", .is_running = false };
    }
    // A torrent's folder knows its size.
    if (self.history.torrent) return .{ .text = formatSize(item.bytes, buf), .is_running = false };
    if (!sizable(self, item)) return .{ .text = "—", .is_running = false };
    const info = self.folderSizeInfo(item);
    var sbuf: [64]u8 = undefined;
    const formatted = formatSize(info.bytes, &sbuf);
    return switch (info.status) {
        .unknown, .idle => .{ .text = "—", .is_running = false },
        .measuring => .{ .text = std.fmt.bufPrint(buf, "{s}", .{formatted}) catch "—", .is_running = true },
        .revalidating, .stale => .{ .text = std.fmt.bufPrint(buf, "≈ {s}", .{formatted}) catch "—", .is_running = false },
        .partial => .{ .text = std.fmt.bufPrint(buf, "≥ {s}", .{formatted}) catch "—", .is_running = false },
        .exact => .{ .text = formatSize(info.bytes, buf), .is_running = false },
    };
}
