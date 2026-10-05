// State model for the start menu: query, category, search results, selection, and launch state.
const std = @import("std");
const Allocator = std.mem.Allocator;

const applications = @import("applications.zig");
const AppEntry = applications.AppEntry;
const search_mod = @import("search.zig");
pub const Category = search_mod.Category;
pub const SearchResult = search_mod.SearchResult;

pub const Model = struct {
    allocator: Allocator,
    query: std.ArrayList(u8) = .empty,
    category: Category = .all,
    results: []SearchResult = &.{},
    selected_index: usize = 0,
    launching: bool = false,
    error_msg: ?[]const u8 = null,
    results_arena: ?*std.heap.ArenaAllocator = null,
    snapshot: ?*applications.Snapshot = null,

    pub fn init(allocator: Allocator) Model {
        return .{
            .allocator = allocator,
            .query = .empty,
            .category = .all,
            .results = &.{},
            .selected_index = 0,
            .launching = false,
            .error_msg = null,
            .results_arena = null,
        };
    }

    pub fn deinit(self: *Model) void {
        self.query.deinit(self.allocator);
        self.freeResults();
        if (self.snapshot) |snap| {
            snap.release();
            self.snapshot = null;
        }
    }

    fn freeResults(self: *Model) void {
        if (self.results_arena) |arena| {
            arena.deinit();
            self.allocator.destroy(arena);
            self.results_arena = null;
        }
        self.results = &.{};
    }

    /// Re-evaluates search against the catalog, preserving the previously selected ID if possible.
    pub fn update(self: *Model, catalog: []const AppEntry, preserve_selection: bool) !void {
        try self.updateInner(catalog, preserve_selection, false);
    }

    pub fn bindSnapshot(self: *Model, snap: *applications.Snapshot, preserve_selection: bool) !void {
        try self.updateInner(snap.entries, preserve_selection, snap.loading);
        if (self.snapshot) |old| old.release();
        self.snapshot = snap.retain();
    }

    fn updateInner(self: *Model, catalog: []const AppEntry, preserve_selection: bool, loading: bool) !void {
        const prev_selected_id = if (preserve_selection and self.selected_index < self.results.len)
            self.results[self.selected_index].id
        else
            null;

        const new_arena = try self.allocator.create(std.heap.ArenaAllocator);
        new_arena.* = std.heap.ArenaAllocator.init(self.allocator);
        errdefer {
            new_arena.deinit();
            self.allocator.destroy(new_arena);
        }

        const new_results = try search_mod.search(new_arena.allocator(), catalog, self.query.items, self.category, loading);

        self.freeResults();
        self.results_arena = new_arena;
        self.results = new_results;

        if (prev_selected_id) |prev_id| {
            var found = false;
            for (new_results, 0..) |res, idx| {
                if (std.mem.eql(u8, res.id, prev_id) and !res.is_loading) {
                    self.selected_index = idx;
                    found = true;
                    break;
                }
            }
            if (!found) self.selected_index = defaultIndex(new_results);
        } else {
            self.selected_index = defaultIndex(new_results);
        }
    }

    fn defaultIndex(results: []const SearchResult) usize {
        for (results, 0..) |res, idx| {
            if (!res.is_loading) return idx;
        }
        return 0;
    }

    pub fn isLoading(self: *const Model) bool {
        return if (self.snapshot) |snap| snap.loading else false;
    }

    pub fn setQuery(self: *Model, text: []const u8, catalog: []const AppEntry) !void {
        self.query.clearRetainingCapacity();
        try self.query.appendSlice(self.allocator, text);
        try self.update(catalog, false);
    }

    pub fn setQuerySnapshot(self: *Model, text: []const u8, snap: *applications.Snapshot) !void {
        self.query.clearRetainingCapacity();
        try self.query.appendSlice(self.allocator, text);
        try self.bindSnapshot(snap, false);
    }

    pub fn setCategory(self: *Model, cat: Category, catalog: []const AppEntry) !void {
        if (self.category == cat) return;
        self.category = cat;
        try self.update(catalog, false);
    }

    pub fn setCategorySnapshot(self: *Model, cat: Category, snap: *applications.Snapshot) !void {
        if (self.category == cat) return;
        self.category = cat;
        try self.bindSnapshot(snap, false);
    }

    pub fn moveSelection(self: *Model, delta: isize) bool {
        if (self.results.len == 0) return false;
        const cur: isize = @intCast(self.selected_index);
        const max: isize = @intCast(self.results.len - 1);
        const next = std.math.clamp(cur + delta, 0, max);
        const changed = (next != cur);
        self.selected_index = @intCast(next);
        return changed;
    }

    pub fn selectFirst(self: *Model) bool {
        if (self.results.len == 0 or self.selected_index == 0) return false;
        self.selected_index = 0;
        return true;
    }

    pub fn selectLast(self: *Model) bool {
        if (self.results.len == 0) return false;
        const last = self.results.len - 1;
        if (self.selected_index == last) return false;
        self.selected_index = last;
        return true;
    }

    pub fn selectedResult(self: *const Model) ?*const SearchResult {
        if (self.selected_index < self.results.len) {
            return &self.results[self.selected_index];
        }
        return null;
    }

    pub fn countApplications(self: *const Model) usize {
        var count: usize = 0;
        for (self.results) |res| {
            if (!res.is_settings and !res.is_loading) count += 1;
        }
        return count;
    }
};

test "model updates and preserves selection" {
    var model = Model.init(std.testing.allocator);
    defer model.deinit();

    const apps = [_]AppEntry{
        .{ .id = "a.desktop", .desktop_file_path = "", .name = "App A", .exec = "a" },
        .{ .id = "b.desktop", .desktop_file_path = "", .name = "App B", .exec = "b" },
    };

    try model.update(&apps, false);
    try std.testing.expectEqual(@as(usize, 0), model.selected_index);

    _ = model.moveSelection(1);
    try std.testing.expectEqual(@as(usize, 1), model.selected_index);

    // Refresh preserves "b.desktop" selection
    try model.update(&apps, true);
    try std.testing.expectEqual(@as(usize, 1), model.selected_index);
    try std.testing.expectEqualStrings("App B", model.selectedResult().?.name);
}

test "loading snapshot selects Settings not the placeholder" {
    var model = Model.init(std.testing.allocator);
    defer model.deinit();
    const snap = try applications.Snapshot.create(std.testing.allocator);
    defer snap.release();
    snap.loading = true;
    try model.bindSnapshot(snap, false);
    try std.testing.expect(model.isLoading());
    try std.testing.expectEqual(@as(usize, 0), model.countApplications());
    try std.testing.expect(model.selectedResult().?.is_settings);
}
