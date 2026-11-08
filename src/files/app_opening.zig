//! Files opening: preview, editor, archives, extraction and activation.

const std = @import("std");
const i18n = @import("i18n");
const tr = i18n.tr;
const App = @import("app.zig").App;
const archive = @import("archive.zig");
const c = @import("c.zig").api;
const platform = @import("platform");
const image_formats = @import("../images/formats.zig");
const theme = @import("../icon_theme.zig");
const chooser_mod = @import("chooser.zig");
const Editor = @import("editor.zig").Editor;

pub fn addApplication(self: *App) void {
    const path = self.selectedAppImage() orelse return;
    self.worker.addApplication(path) catch |err| {
        self.setStatusNotice(if (err == error.Busy) tr("An application is already being added") else tr("Could not add the application"), true);
        return;
    };
    self.setStatusNotice(tr("Adding to applications…"), false);
}

pub fn previewSelected(self: *App) void {
    if (self.chooser != null) return;
    const formats = @import("../images/formats.zig");
    const selected = self.focused_index orelse return;
    if (selected >= self.items.items.len) return;
    const item = self.items.items[selected];
    if (!item.selected or item.missing or item.is_broken) return;
    if (self.history.archive_len > 0) {
        if (item.is_dir) self.navigate(item.path) else self.openArchiveMember(item.path, true);
        return;
    }
    if (!item.is_dir and archive.candidate(item.name)) {
        self.browseArchive(item.path);
        return;
    }
    if (item.is_dir) return;
    if (isPdf(item.path)) {
        self.openFile(item.path);
        return;
    }
    if (!formats.candidate(item.path)) {
        if (!@import("../editor/formats.zig").candidate(item.path)) return;
        if (self.editor_path == null) self.editor_path = self.allocator.dupeSentinel(u8, item.path, 0) catch null;
        return;
    }
    if (self.preview_return_fd != null) return;
    self.launchPreview(selected) catch |err| {
        std.log.warn("could not launch image preview: {}", .{err});
        self.setStatusNotice(tr("Could not open image viewer"), true);
    };
}

pub fn launchEditor(self: *App, token: []const u8) void {
    const path = self.editor_path orelse return;
    self.editor_path = null;
    defer self.allocator.free(path);
    var exe: [platform.exe.max_path]u8 = undefined;
    var child = std.process.spawn(self.io, .{
        .argv = &.{ platform.exe.siblingOrName(&exe, "rediwm-editor"), "--activation-token", token, "--", path },
    }) catch {
        self.setStatusNotice(tr("Could not open Text Editor"), true);
        return;
    };
    self.worker.recordOpened(path);
    self.children.add(self.allocator, child.id.?) catch child.kill(self.io);
}

pub fn launchPreview(self: *App, selected: usize) !void {
    // A seekable anonymous file avoids argv limits and blocking the UI on
    // a pipe. stdin carries NUL-separated absolute paths, including newlines.
    const fd = c.memfd_create("rediwm-image-list", c.MFD_CLOEXEC);
    if (fd < 0) return error.CreateListFailed;
    defer _ = c.close(fd);
    var index: usize = 0;
    var current: usize = 0;
    var size: usize = 0;
    for (self.items.items, 0..) |item, i| {
        if (item.is_dir or !@import("../images/formats.zig").candidate(item.path)) continue;
        if (i == selected) index = current;
        current += 1;
        size += item.path.len + 1;
        if (size > 16 * 1024 * 1024) return error.ListTooLarge;
        try writePreviewBytes(fd, item.path);
        try writePreviewBytes(fd, "\x00");
    }
    if (c.lseek(fd, 0, c.SEEK_SET) < 0) return error.SeekFailed;
    try self.launchImageList(fd, index);
    self.worker.recordOpened(self.items.items[selected].path);
}

pub fn launchImageList(self: *App, fd: c_int, index: usize) !void {
    var index_buf: [32]u8 = undefined;
    const index_arg = try std.fmt.bufPrint(&index_buf, "{d}", .{index});
    var sibling_buf: [platform.exe.max_path]u8 = undefined;
    const executable = platform.exe.siblingOrName(&sibling_buf, "rediwm-images");
    var child = try std.process.spawn(self.io, .{
        .argv = &.{ executable, "--list-stdin", index_arg },
        .stdin = .{ .file = .{ .handle = fd, .flags = .{ .nonblocking = false } } },
        .stdout = .pipe,
    });
    self.preview_return_fd = child.stdout.?.handle;
    child.stdout = null; // the client event loop now owns this fd
    self.children.add(self.allocator, child.id.?) catch |err| {
        _ = c.close(self.preview_return_fd.?);
        self.preview_return_fd = null;
        child.kill(self.io);
        return err;
    };
}

pub fn writePreviewBytes(fd: c_int, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = c.write(fd, bytes.ptr + offset, bytes.len - offset);
        if (n < 0 and std.posix.errno(n) == .INTR) continue;
        if (n <= 0) return error.WriteFailed;
        offset += @intCast(n);
    }
}

pub fn isPdf(path: []const u8) bool {
    return std.ascii.eqlIgnoreCase(std.fs.path.extension(path), ".pdf");
}

pub fn openFile(self: *App, path: []const u8) void {
    if (self.chooser != null) return;
    if (@import("app_torrents.zig").enabled and std.ascii.endsWithIgnoreCase(path, ".torrent")) {
        self.torrentSource(path);
        return;
    }
    if (std.ascii.endsWithIgnoreCase(path, ".rediwm-theme")) {
        self.worker.installTheme(path);
        self.setStatusNotice(tr("Installing theme…"), false);
        return;
    }
    if (self.playsBuiltin(path)) {
        if (self.playAudio(path)) {
            self.worker.recordOpened(path);
            return;
        }
        self.setStatusNotice(tr("Could not play the file"), true);
        return;
    }
    const pdf = isPdf(path) and !@import("associations.zig").hasAlternativeDefault(path, "rediwm-pdf.desktop");
    if (!pdf) {
        @import("associations.zig").launchDefault(path) catch |err| {
            std.log.warn("failed to open '{s}': {}", .{ path, err });
            self.setStatusNotice(tr("Could not open file"), true);
            return;
        };
        self.worker.recordOpened(path);
        return;
    }
    var sibling_buf: [platform.exe.max_path]u8 = undefined;
    const executable = platform.exe.siblingOrName(&sibling_buf, "rediwm-pdf");
    var child = std.process.spawn(self.io, .{
        .argv = &.{ executable, "--", path },
    }) catch |err| {
        std.log.warn("failed to open '{s}': {}", .{ path, err });
        self.setStatusNotice(tr("Could not open file"), true);
        return;
    };

    self.worker.recordOpened(path);
    self.children.add(self.allocator, child.id.?) catch child.kill(self.io);
}

pub fn browseArchive(self: *App, path: []const u8) void {
    self.rememberView();
    self.history.navigateLocation(path, path.len) catch return;
    self.worker.recordOpened(path);
    self.applyHistoryNav(self.history.current);
}

pub fn startExtraction(self: *App, path: []const u8, destination: []const u8) void {
    const runner = self.job_runner orelse return;
    runner.startArchive(path, destination, null) catch |err| {
        self.setStatusNotice(if (err == error.Busy) tr("A file operation is already running") else tr("Could not start extraction"), true);
        return;
    };
    self.job_was_running = true;
    self.job_cut_revision = null;
    self.invalidate();
}

pub fn openArchiveMember(self: *App, path: []const u8, preview: bool) void {
    const len = self.history.archive_len;
    if (len == 0 or path.len <= len) return;
    const runner = self.job_runner orelse return;
    runner.startArchive(self.history.current[0..len], "/tmp", path[len + 1 ..]) catch |err| {
        self.setStatusNotice(if (err == error.Busy) tr("A file operation is already running") else tr("Could not open archive member"), true);
        return;
    };
    self.archive_preview = preview;
    self.archive_open_navigation = self.navigation_count;
    self.job_was_running = true;
    self.job_cut_revision = null;
    self.invalidate();
}

pub fn openExtracted(self: *App, path: []const u8, preview: bool) void {
    if (preview and image_formats.candidate(path)) {
        self.previewExtracted(path) catch self.setStatusNotice(tr("Could not open image viewer"), true);
    } else if (preview and @import("../editor/formats.zig").candidate(path)) {
        if (self.editor_path == null) self.editor_path = self.allocator.dupeSentinel(u8, path, 0) catch null;
    } else if (!preview or isPdf(path)) self.openFile(path);
}

pub fn previewExtracted(self: *App, path: []const u8) !void {
    if (self.preview_return_fd != null) return;
    const fd = c.memfd_create("rediwm-archive-preview", c.MFD_CLOEXEC);
    if (fd < 0) return error.CreateListFailed;
    defer _ = c.close(fd);
    try writePreviewBytes(fd, path);
    try writePreviewBytes(fd, "\x00");
    if (c.lseek(fd, 0, c.SEEK_SET) < 0) return error.SeekFailed;
    try self.launchImageList(fd, 0);
}

pub fn closeExtractPicker(self: *App) void {
    if (self.extract_picker_fd) |fd| _ = c.close(fd);
    if (self.extract_picker_source) |path| self.allocator.free(path);
    self.extract_picker_fd = null;
    self.extract_picker_source = null;
    self.extract_picker_bytes.clearRetainingCapacity();
}

pub fn chooseExtractionFolder(self: *App) void {
    if (self.extract_picker_fd != null) return;
    const path = self.selectedArchive() orelse return;
    const source = self.allocator.dupe(u8, path) catch return;
    var exe: [platform.exe.max_path]u8 = undefined;
    const executable: []const u8 = platform.exe.path(&exe) orelse "rediwm-files";
    var child = std.process.spawn(self.io, .{
        .argv = &.{ executable, "--folder", std.fs.path.dirname(path) orelse "/" },
        .stdout = .pipe,
    }) catch {
        self.allocator.free(source);
        self.setStatusNotice(tr("Could not open folder picker"), true);
        return;
    };
    const fd = child.stdout.?.handle;
    child.stdout = null;
    const flags = c.fcntl(fd, c.F_GETFL);
    if (flags < 0 or c.fcntl(fd, c.F_SETFL, flags | c.O_NONBLOCK) < 0) {
        _ = c.close(fd);
        child.kill(self.io);
        self.allocator.free(source);
        self.setStatusNotice(tr("Could not open folder picker"), true);
        return;
    }
    self.children.add(self.allocator, child.id.?) catch {
        _ = c.close(fd);
        child.kill(self.io);
        self.allocator.free(source);
        return;
    };
    self.extract_picker_source = source;
    self.extract_picker_fd = fd;
}

pub fn extractionFolderReady(self: *App) void {
    const fd = self.extract_picker_fd orelse return;
    var buffer: [4096]u8 = undefined;
    while (true) {
        const n = c.read(fd, &buffer, buffer.len);
        if (n < 0) switch (std.posix.errno(n)) {
            .INTR => continue,
            .AGAIN => return,
            else => {
                self.closeExtractPicker();
                self.setStatusNotice(tr("Could not read folder picker result"), true);
                return;
            },
        };
        if (n == 0) break;
        if (self.extract_picker_bytes.items.len + @as(usize, @intCast(n)) > 65536) {
            self.closeExtractPicker();
            self.setStatusNotice(tr("Invalid folder picker result"), true);
            return;
        }
        self.extract_picker_bytes.appendSlice(self.allocator, buffer[0..@intCast(n)]) catch {
            self.closeExtractPicker();
            return;
        };
    }
    defer self.closeExtractPicker();
    if (self.extract_picker_bytes.items.len == 0) return;
    const parsed = std.json.parseFromSlice(chooser_mod.Result, self.allocator, self.extract_picker_bytes.items, .{}) catch {
        self.setStatusNotice(tr("Invalid folder picker result"), true);
        return;
    };
    defer parsed.deinit();
    if (parsed.value.paths.len == 1 and std.fs.path.isAbsolute(parsed.value.paths[0])) {
        self.startExtraction(self.extract_picker_source.?, parsed.value.paths[0]);
    }
}

pub fn activateItem(self: *App, idx: usize) void {
    if (idx >= self.items.items.len) return;
    const item = self.items.items[idx];
    if (item.transfer_stub or std.ascii.endsWithIgnoreCase(item.name, ".torrent")) {
        if (self.torrentForItem(idx)) |t| {
            self.openTorrentDetails(t.id);
            return;
        }
    }
    if (item.is_broken or item.missing) {
        return;
    }
    if (item.is_dir) {
        self.navigate(item.path);
    } else if (self.chooser != null) {
        self.setChooserName(item.name);
        for (self.items.items, 0..) |*it, i| it.selected = i == idx or (self.chooser.?.multiple and it.selected);
        self.acceptChooser();
    } else if (self.history.archive_len > 0) {
        self.openArchiveMember(item.path, false);
    } else if (archive.candidate(item.name)) {
        self.browseArchive(item.path);
    } else {
        self.openFile(item.path);
    }
}

pub fn activateSelected(self: *App) void {
    if (self.focused_index) |idx| {
        self.activateItem(idx);
        return;
    }
    for (self.items.items, 0..) |it, idx| {
        if (it.selected and !it.missing) {
            self.activateItem(idx);
            return;
        }
    }
}
