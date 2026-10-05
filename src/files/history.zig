const std = @import("std");
const Allocator = std.mem.Allocator;

pub const View = struct {
    scroll: i32 = 0,
    selected: std.ArrayList([]const u8) = .empty,
    focus: ?[]const u8 = null,
    anchor: ?[]const u8 = null,

    pub fn deinit(self: *View, a: Allocator) void {
        for (self.selected.items) |path| a.free(path);
        self.selected.deinit(a);
        if (self.focus) |path| a.free(path);
        if (self.anchor) |path| a.free(path);
        self.* = .{};
    }
};

pub const History = struct {
    const Entry = struct { path: []const u8, archive_len: usize, view: View };
    allocator: Allocator,
    current: []const u8,
    /// Prefix of current naming the archive; zero means a real directory.
    archive_len: usize = 0,
    view: View = .{},
    back_stack: std.ArrayList(Entry) = .empty,
    forward_stack: std.ArrayList(Entry) = .empty,

    pub fn init(allocator: Allocator, initial_path: []const u8) !History {
        return .{ .allocator = allocator, .current = try allocator.dupe(u8, initial_path) };
    }
    fn clear(self: *History, stack: *std.ArrayList(Entry)) void {
        for (stack.items) |*entry| {
            self.allocator.free(entry.path);
            entry.view.deinit(self.allocator);
        }
        stack.clearRetainingCapacity();
    }
    pub fn deinit(self: *History) void {
        self.allocator.free(self.current);
        self.view.deinit(self.allocator);
        self.clear(&self.back_stack);
        self.back_stack.deinit(self.allocator);
        self.clear(&self.forward_stack);
        self.forward_stack.deinit(self.allocator);
    }
    pub fn canBack(self: *const History) bool {
        return self.back_stack.items.len > 0;
    }
    pub fn canForward(self: *const History) bool {
        return self.forward_stack.items.len > 0;
    }
    pub fn canUp(self: *const History) bool {
        return !std.mem.eql(u8, self.current, "/");
    }
    pub fn navigate(self: *History, new_path: []const u8) !void {
        const archive_len = if (self.archive_len > 0 and new_path.len >= self.archive_len and
            std.mem.eql(u8, self.current[0..self.archive_len], new_path[0..self.archive_len]) and
            (new_path.len == self.archive_len or new_path[self.archive_len] == '/')) self.archive_len else 0;
        return self.navigateLocation(new_path, archive_len);
    }
    pub fn navigateLocation(self: *History, new_path: []const u8, archive_len: usize) !void {
        if (std.mem.eql(u8, self.current, new_path) and self.archive_len == archive_len) return;
        const owned = try self.allocator.dupe(u8, new_path);
        errdefer self.allocator.free(owned);
        try self.back_stack.append(self.allocator, .{ .path = self.current, .archive_len = self.archive_len, .view = self.view });
        self.clear(&self.forward_stack);
        self.current = owned;
        self.archive_len = archive_len;
        self.view = .{};
    }
    fn step(self: *History, from: *std.ArrayList(Entry), to: *std.ArrayList(Entry)) !?[]const u8 {
        if (from.items.len == 0) return null;
        try to.append(self.allocator, .{ .path = self.current, .archive_len = self.archive_len, .view = self.view });
        const entry = from.pop().?;
        self.current = entry.path;
        self.archive_len = entry.archive_len;
        self.view = entry.view;
        return self.current;
    }
    pub fn back(self: *History) !?[]const u8 {
        return self.step(&self.back_stack, &self.forward_stack);
    }
    pub fn forward(self: *History) !?[]const u8 {
        return self.step(&self.forward_stack, &self.back_stack);
    }
    pub fn up(self: *History) !?[]const u8 {
        if (!self.canUp()) return null;
        try self.navigate(std.fs.path.dirname(self.current) orelse "/");
        return self.current;
    }
    pub fn home(self: *History, home_dir: []const u8) !?[]const u8 {
        if (std.mem.eql(u8, self.current, home_dir)) return null;
        try self.navigate(home_dir);
        return self.current;
    }
};
