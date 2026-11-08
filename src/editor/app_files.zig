//! Messages and failures, opening and loading, syncing background operations, saving and closing tabs.

const std = @import("std");
const i18n = @import("i18n");
const tr = i18n.tr;
const op = @import("operation.zig");
const a = std.heap.c_allocator;
const app_mod = @import("app.zig");
const App = app_mod.App;
const Action = app_mod.Action;
const Tab = app_mod.Tab;

pub fn message(self: *App, value: []const u8) void {
    self.notice_len = @min(value.len, self.notice.len);
    @memcpy(self.notice[0..self.notice_len], value[0..self.notice_len]);
    self.dirty = true;
}

pub fn failure(self: *App, err: anyerror) void {
    self.message(switch (err) {
        error.FileChanged => tr("File changed on disk. Use Save As to keep your edits in another file."),
        error.BinaryFile => tr("This file contains binary data and cannot be edited as text."),
        error.UnsupportedEncoding => tr("This file is not valid UTF-8 text."),
        error.FileTooLarge => tr("Text files are limited to 4 GiB."),
        error.OutOfMemory => tr("Not enough free memory to hold this file."),
        error.Busy => tr("Saving a large file. Editing resumes when it is written."),
        error.PermissionDenied => tr("Permission denied. Try Save As in a writable folder."),
        error.HardLinkedFile => tr("This file has multiple hard links. Use Save As to create a separate copy."),
        else => @errorName(err),
    });
}

pub fn open(self: *App, path: []const u8) void {
    if (self.close_tab == null) for (self.tabs.items, 0..) |t, i| {
        if (t.path != null and std.mem.eql(u8, t.path.?, path)) {
            self.selected = i;
            self.changed();
            return;
        }
    };
    const owned = a.dupeSentinel(u8, path, 0) catch return;
    self.queue.append(a, owned) catch {
        a.free(owned);
        return;
    };
}

pub fn sync(self: *App) void {
    if (self.operation) |job| {
        if (!job.done.load(.acquire)) return;
        self.operation = null;
        defer job.deinit();
        self.dirty = true;
        if (job.kind == .save) if (self.findTab(job.tab_id)) |i| {
            self.tabs.items[i].doc.locked = false;
        };
        if (job.err) |err| {
            self.close_all = false;
            self.failure(err);
            return;
        }
        if (job.cancelled) {
            self.close_all = false;
            return;
        }
        switch (job.kind) {
            .load => {
                for (self.tabs.items, 0..) |t, i| if (t.path != null and std.mem.eql(u8, t.path.?, job.path)) {
                    self.selected = i;
                    self.changed();
                    return;
                };
                if (self.current().path != null or self.current().doc.text.items.len > 0 or self.current().doc.modified()) self.newTab() catch return;
                const t = self.current();
                const path = a.dupeSentinel(u8, job.path, 0) catch return;
                t.doc.deinit();
                t.doc = job.document.?;
                job.document = null;
                t.path = path;
                t.stamp = job.stamp;
                t.dy = 0;
                t.scroll_x = 0;
                t.measure = .{};
                self.notice_len = 0;
                self.recordRecent(job.path);
                self.changed();
            },
            .save => if (self.findTab(job.tab_id)) |i| {
                const t = self.tabs.items[i];
                const path = a.dupeSentinel(u8, job.path, 0) catch return;
                if (t.path) |old| a.free(old);
                t.path = path;
                t.stamp = job.stamp;
                if (t.doc.revision == job.revision) t.doc.saved = t.doc.position;
                self.message(tr("Saved"));
                self.recordRecent(job.path);
                self.changed();
                if (self.close_tab == t.id and !t.doc.modified()) self.finishClose();
            },
            .open_dialog => self.open(job.path),
            .save_dialog => if (self.findTab(job.tab_id)) |i| {
                for (self.tabs.items) |other| if (other.id != job.tab_id and other.path != null and std.mem.eql(u8, other.path.?, job.path)) {
                    self.message(tr("That file is open in another tab. Choose a different name."));
                    return;
                };
                self.startSave(self.tabs.items[i], job.path, job.stamp);
            },
        }
    }
    if (self.operation == null and self.queue.items.len > 0 and self.close_tab == null) {
        const path = self.queue.orderedRemove(0);
        defer a.free(path);
        self.operation = op.Operation.start(.load, self.io, 0, path, "", null) catch |err| {
            self.failure(err);
            return;
        };
        self.message(tr("Opening…"));
    }
}

pub fn choose(self: *App, saving: bool) void {
    if (self.operation != null) return;
    const t = self.current();
    self.operation = op.Operation.start(if (saving) .save_dialog else .open_dialog, self.io, t.id, t.path orelse "", "", null) catch |err| {
        self.failure(err);
        return;
    };
}

pub fn startSave(self: *App, t: *Tab, path: []const u8, stamp: ?op.Stamp) void {
    // A small document is copied so typing can continue while it is
    // written. A large one is written where it is, which needs the text to
    // stay put until the save finishes (see `Document.locked`).
    const borrow = t.doc.text.items.len > op.copy_limit;
    self.operation = op.Operation.startSave(self.io, t.id, path, t.doc.bom, t.doc.text.items, borrow, stamp) catch |err| {
        self.failure(err);
        return;
    };
    self.operation.?.revision = t.doc.revision;
    t.doc.locked = borrow;
    self.message(tr("Saving…"));
}

pub fn save(self: *App, as: bool) void {
    if (self.operation != null) return;
    const t = self.current();
    if (as or t.path == null) self.choose(true) else self.startSave(t, t.path.?, t.stamp);
}

pub fn requestClose(self: *App) void {
    if (self.operation != null) {
        self.message(tr("Finish the file dialog or operation before closing."));
        return;
    }
    self.close_all = true;
    self.closeSelected();
}

pub fn closeSelected(self: *App) void {
    if (self.operation != null) return;
    self.close_tab = self.current().id;
    self.close_choice = 2;
    if (!self.current().doc.modified()) self.finishClose() else self.dirty = true;
}

pub fn finishClose(self: *App) void {
    const id = self.close_tab orelse return;
    self.close_tab = null;
    const idx = self.findTab(id) orelse return;
    self.tabs.orderedRemove(idx).deinit();
    if (self.tabs.items.len == 0) {
        self.closed = true;
        return;
    }
    self.selected = @min(idx, self.tabs.items.len - 1);
    self.changed();
    if (self.close_all) self.closeSelected();
}

pub fn act(self: *App, action: Action) void {
    switch (action) {
        .new => self.newTab() catch |err| self.failure(err),
        .open => self.choose(false),
        .open_recent => {}, // the menu opens its submenu; nothing to run
        .save => self.save(false),
        .save_as => self.save(true),
        .find => {
            if (self.find_open) self.find_open = false else self.openSearch(false);
        },
        .replace => self.openSearch(true),
        .wrap => {
            self.wrap = !self.wrap;
            self.current().scroll_x = 0;
            self.port().clamp();
        },
    }
    self.dirty = true;
}
