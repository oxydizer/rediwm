//! Files folder sizes: background calculation and the size column's state.

const std = @import("std");
const App = @import("app.zig").App;
const dirsize = @import("dirsize.zig");
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

pub fn startFolderSize(self: *App, idx: usize) void {
    if (self.history.archive_len > 0) return;
    if (idx >= self.items.items.len) return;
    const it = self.items.items[idx];
    if (!it.is_dir or it.is_symlink or it.transfer_stub or it.transfer_ghost) return;
    if (self.folder_sizes.get(it.path)) |sz| {
        switch (sz) {
            .running => return,
            .done => {},
        }
    }
    const pool = self.getOrInitDirsizePool() catch return;
    const job = pool.startJob(it.path) catch return;
    if (self.folder_sizes.getPtr(it.path)) |entry| {
        entry.* = .{ .running = job };
    } else {
        const key = self.allocator.dupe(u8, it.path) catch {
            job.cancel();
            job.unref();
            return;
        };
        self.folder_sizes.put(key, .{ .running = job }) catch {
            self.allocator.free(key);
            job.cancel();
            job.unref();
            return;
        };
    }
    self.damagePathSize(it.path);
}

pub fn cancelFolderSize(self: *App, idx: usize) void {
    if (idx >= self.items.items.len) return;
    const it = self.items.items[idx];
    if (self.folder_sizes.fetchRemove(it.path)) |kv| {
        self.allocator.free(kv.key);
        switch (kv.value) {
            .running => |job| {
                job.cancel();
                job.unref();
            },
            .done => {},
        }
        self.damagePathSize(it.path);
    }
}

pub fn toggleFolderSize(self: *App, idx: usize) void {
    if (idx >= self.items.items.len) return;
    const it = self.items.items[idx];
    if (!it.is_dir or it.is_symlink or it.transfer_stub or it.transfer_ghost) return;
    if (self.folder_sizes.get(it.path)) |sz| {
        switch (sz) {
            .running => self.cancelFolderSize(idx),
            .done => {},
        }
    } else {
        self.startFolderSize(idx);
    }
}

pub fn cancelRunningFolderSizes(self: *App) void {
    var to_remove = std.ArrayList([]const u8).empty;
    defer to_remove.deinit(self.allocator);
    var it = self.folder_sizes.iterator();
    while (it.next()) |entry| {
        switch (entry.value_ptr.*) {
            .running => |job| {
                job.cancel();
                job.unref();
                to_remove.append(self.allocator, entry.key_ptr.*) catch {};
            },
            .done => {},
        }
    }
    for (to_remove.items) |key| {
        if (self.folder_sizes.fetchRemove(key)) |kv| {
            self.allocator.free(kv.key);
        }
    }
}

pub fn clearFolderSizes(self: *App) void {
    var it = self.folder_sizes.iterator();
    while (it.next()) |entry| {
        self.allocator.free(entry.key_ptr.*);
        switch (entry.value_ptr.*) {
            .running => |job| {
                job.cancel();
                job.unref();
            },
            .done => {},
        }
    }
    self.folder_sizes.clearRetainingCapacity();
    self.invalidate();
}

pub fn hasRunningFolderSize(self: *App) bool {
    if (self.dialog) |*dlg| if (dlg.properties) |*props| if (props.sizesRunning()) return true;
    var it = self.folder_sizes.valueIterator();
    while (it.next()) |sz| {
        switch (sz.*) {
            .running => return true,
            .done => {},
        }
    }
    return false;
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
    var it = self.folder_sizes.iterator();
    while (it.next()) |entry| {
        switch (entry.value_ptr.*) {
            .running => |job| {
                if (job.isDone()) {
                    const bytes = job.bytes.load(.acquire);
                    const partial = job.partial.load(.acquire);
                    entry.value_ptr.* = .{ .done = .{ .bytes = bytes, .partial = partial } };
                    job.unref();
                    self.damagePathSize(entry.key_ptr.*);
                } else {
                    self.damagePathSize(entry.key_ptr.*);
                }
            },
            .done => {},
        }
    }
}

pub fn itemSizeDisplay(self: *App, item: ViewItem, buf: *[64]u8) ItemSizeDisplay {
    if (!item.is_dir) {
        return .{ .text = formatSize(item.bytes, buf), .is_running = false };
    }
    if (item.is_symlink) {
        return .{ .text = "—", .is_running = false };
    }
    // A torrent's folder knows its size.
    if (self.history.torrent) return .{ .text = formatSize(item.bytes, buf), .is_running = false };
    if (self.folder_sizes.get(item.path)) |sz| {
        switch (sz) {
            .running => |job| {
                const bytes = job.bytes.load(.acquire);
                var sbuf: [64]u8 = undefined;
                const formatted = formatSize(bytes, &sbuf);
                const str = std.fmt.bufPrint(buf, "{s}", .{formatted}) catch "—";
                return .{ .text = str, .is_running = true };
            },
            .done => |d| {
                if (d.partial) {
                    var sbuf: [64]u8 = undefined;
                    const formatted = formatSize(d.bytes, &sbuf);
                    const str = std.fmt.bufPrint(buf, "≥ {s}", .{formatted}) catch "—";
                    return .{ .text = str, .is_running = false };
                } else {
                    return .{ .text = formatSize(d.bytes, buf), .is_running = false };
                }
            },
        }
    }
    return .{ .text = "—", .is_running = false };
}
