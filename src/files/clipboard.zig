const std = @import("std");
const Allocator = std.mem.Allocator;

/// A temporary directory whose real paths are advertised by a clipboard or
/// drag source, or opened in another program. The I/O service owns the
/// folder; the window holds it as a resource (stage S4) and gives it back
/// when its source's Wayland lifetime ends, and the service deletes it on a
/// worker. Nothing here touches the filesystem.
pub const StagingLease = struct {
    allocator: Allocator,
    path: []u8,
    /// The window-owned service resource.
    resource_id: u64,
    /// Gives the resource back (`app_service.disposeResource`).
    dispose: *const fn (context: *anyopaque, resource_id: u64) void,
    context: *anyopaque,

    pub fn deinit(self: *StagingLease) void {
        self.dispose(self.context, self.resource_id);
        self.allocator.free(self.path);
        self.* = undefined;
    }
};

/// Transfers a staging lease to a new owner, clearing the previous owner.
pub fn takeStagingLease(owner: *?StagingLease) ?StagingLease {
    const lease = owner.* orelse return null;
    owner.* = null;
    return lease;
}

test "taking a staging lease clears the previous owner, and its end gives the resource back" {
    const allocator = std.testing.allocator;
    const Disposed = struct {
        var id: u64 = 0;
        fn dispose(_: *anyopaque, resource_id: u64) void {
            id = resource_id;
        }
    };
    var context: u8 = 0;
    var app_lease: ?StagingLease = .{
        .allocator = allocator,
        .path = try allocator.dupe(u8, "/tmp/clipboard-staging-test"),
        .resource_id = 7,
        .dispose = Disposed.dispose,
        .context = &context,
    };
    var source_lease = takeStagingLease(&app_lease);

    try std.testing.expect(app_lease == null);
    try std.testing.expect(source_lease != null);
    try std.testing.expectEqualStrings("/tmp/clipboard-staging-test", source_lease.?.path);
    source_lease.?.deinit();
    try std.testing.expectEqual(@as(u64, 7), Disposed.id);
}

pub const ClipboardMode = enum {
    copy,
    cut,
};

pub const DecodedUris = struct {
    mode: ClipboardMode,
    paths: [][]const u8,

    pub fn deinit(self: DecodedUris, allocator: Allocator) void {
        for (self.paths) |p| allocator.free(p);
        allocator.free(self.paths);
    }
};

/// Decodes a percent-encoded local file URI (e.g. "file:///tmp/a%20b") into a local path.
pub fn decodeLocalPath(allocator: Allocator, uri: []const u8) ![]const u8 {
    var raw = uri;
    if (std.mem.startsWith(u8, raw, "file://localhost/")) {
        raw = raw[16..];
    } else if (std.mem.startsWith(u8, raw, "file:///")) {
        raw = raw[7..];
    } else {
        return error.NotLocalFile;
    }

    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        var ch = raw[i];
        if (ch == '%') {
            if (i + 2 >= raw.len) return error.InvalidEscape;
            ch = std.fmt.parseInt(u8, raw[i + 1 .. i + 3], 16) catch return error.InvalidEscape;
            i += 2;
        }
        if (ch == 0) return error.InvalidPath;
        try result.append(allocator, ch);
    }
    return result.toOwnedSlice(allocator);
}

/// Percent-encodes an absolute local path into a "file://..." URI.
pub fn encodeLocalUri(allocator: Allocator, path: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    const hex = "0123456789ABCDEF";
    try out.appendSlice(allocator, "file://");

    for (path) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '/' or ch == '-' or ch == '_' or ch == '.' or ch == '~') {
            try out.append(allocator, ch);
        } else {
            try out.appendSlice(allocator, &.{ '%', hex[ch >> 4], hex[ch & 15] });
        }
    }
    return out.toOwnedSlice(allocator);
}

/// Encodes paths into standard "text/uri-list" format (CRLF separated).
pub fn encodeUriList(allocator: Allocator, paths: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    for (paths) |path| {
        const uri = try encodeLocalUri(allocator, path);
        defer allocator.free(uri);
        try out.appendSlice(allocator, uri);
        try out.appendSlice(allocator, "\r\n");
    }
    return out.toOwnedSlice(allocator);
}

/// Encodes paths into GNOME copied files format ("copy\nfile://...\r\n" or "cut\nfile://...\r\n").
pub fn encodeGnomeCopiedFiles(allocator: Allocator, mode: ClipboardMode, paths: []const []const u8) ![]u8 {
    const uris = try encodeUriList(allocator, paths);
    defer allocator.free(uris);

    const prefix = if (mode == .cut) "cut\n" else "copy\n";
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, uris });
}

/// Decodes either "text/uri-list" or "x-special/gnome-copied-files" data into a list of local paths.
pub fn decodeUris(allocator: Allocator, data: []const u8) !DecodedUris {
    var mode: ClipboardMode = .copy;
    var content = data;

    if (std.mem.startsWith(u8, content, "cut\n")) {
        mode = .cut;
        content = content[4..];
    } else if (std.mem.startsWith(u8, content, "cut\r\n")) {
        mode = .cut;
        content = content[5..];
    } else if (std.mem.startsWith(u8, content, "copy\n")) {
        mode = .copy;
        content = content[5..];
    } else if (std.mem.startsWith(u8, content, "copy\r\n")) {
        mode = .copy;
        content = content[6..];
    }

    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |p| allocator.free(p);
        list.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        if (decodeLocalPath(allocator, line)) |path| {
            try list.append(allocator, path);
        } else |_| {
            // Ignore non-local or invalid URIs
            continue;
        }
    }

    return .{
        .mode = mode,
        .paths = try list.toOwnedSlice(allocator),
    };
}
