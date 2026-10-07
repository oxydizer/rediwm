//! Byte-bounded page/tile cache (128 MiB) and thumbnail cache (16 MiB)
//! with LRU eviction and scale fallback.
const std = @import("std");
const layout = @import("layout.zig");
const document = @import("document.zig");

pub const PAGE_CACHE_LIMIT: usize = 128 * 1024 * 1024;
pub const THUMB_CACHE_LIMIT: usize = 16 * 1024 * 1024;

/// Tile bounds in pixels of the page's raster at the key's scale.
pub const TileKey = struct {
    x: u32,
    y: u32,
    w: u32,
    h: u32,

    pub fn eql(self: TileKey, other: TileKey) bool {
        return self.x == other.x and self.y == other.y and self.w == other.w and self.h == other.h;
    }
};

pub const PageKey = struct {
    generation: u64,
    page_index: usize,
    raster_scale_milli: u32, // scale * 1000 rounded
    rotation: layout.Rotation,
    tile: ?TileKey = null,

    pub fn init(generation: u64, page_index: usize, scale: f64, rotation: layout.Rotation, tile: ?TileKey) PageKey {
        const rounded: u32 = @intFromFloat(@round(std.math.clamp(scale, 0.01, 100.0) * 1000.0));
        return .{
            .generation = generation,
            .page_index = page_index,
            .raster_scale_milli = rounded,
            .rotation = rotation,
            .tile = tile,
        };
    }

    pub fn eql(self: PageKey, other: PageKey) bool {
        if (self.generation != other.generation) return false;
        if (self.page_index != other.page_index) return false;
        if (self.raster_scale_milli != other.raster_scale_milli) return false;
        if (self.rotation != other.rotation) return false;
        if (self.tile == null and other.tile == null) return true;
        if (self.tile != null and other.tile != null) return self.tile.?.eql(other.tile.?);
        return false;
    }
};

pub const CachedPage = struct {
    key: PageKey,
    pixels: []u32,
    width: i32,
    height: i32,
    stride: i32,
    bytes: usize,
    last_used: u64,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *CachedPage) void {
        self.allocator.free(self.pixels);
    }
};

pub const PageCache = struct {
    entries: std.ArrayList(CachedPage),
    byte_limit: usize = PAGE_CACHE_LIMIT,
    bytes: usize = 0,
    counter: u64 = 0,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, limit: usize) PageCache {
        return .{
            .entries = .empty,
            .byte_limit = limit,
            .bytes = 0,
            .counter = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *PageCache) void {
        for (self.entries.items) |*entry| {
            entry.deinit();
        }
        self.entries.deinit(self.allocator);
        self.bytes = 0;
    }

    pub fn get(self: *PageCache, key: PageKey) ?*CachedPage {
        for (self.entries.items) |*entry| {
            if (entry.key.eql(key)) {
                self.counter += 1;
                entry.last_used = self.counter;
                return entry;
            }
        }
        return null;
    }

    /// Finds any cached full-page render for this page in the current generation,
    /// so the UI can draw it scaled while the sharp new zoom level is being rendered.
    pub fn findBest(self: *PageCache, generation: u64, page_index: usize, rotation: layout.Rotation) ?*CachedPage {
        var best: ?*CachedPage = null;
        for (self.entries.items) |*entry| {
            if (entry.key.generation == generation and
                entry.key.page_index == page_index and
                entry.key.rotation == rotation and
                entry.key.tile == null)
            {
                if (best == null or entry.last_used > best.?.last_used) {
                    best = entry;
                }
            }
        }
        if (best) |b| {
            self.counter += 1;
            b.last_used = self.counter;
        }
        return best;
    }

    pub fn put(self: *PageCache, page: CachedPage) !void {
        // Checked dimensions & stride arithmetic
        if (page.width <= 0 or page.height <= 0 or page.stride < page.width * 4) {
            var mut_page = page;
            mut_page.deinit();
            return error.InvalidDimensions;
        }
        const needed = page.bytes;
        if (needed > self.byte_limit) {
            var mut_page = page;
            mut_page.deinit();
            return; // Drop single rasters exceeding cache limit
        }

        // If duplicate key exists, remove it first
        var i: usize = 0;
        while (i < self.entries.items.len) {
            if (self.entries.items[i].key.eql(page.key)) {
                var old = self.entries.swapRemove(i);
                self.bytes -= old.bytes;
                old.deinit();
            } else {
                i += 1;
            }
        }

        // Evict LRU entries until enough space
        while (self.bytes + needed > self.byte_limit and self.entries.items.len > 0) {
            self.evictOldest();
        }

        self.counter += 1;
        var new_entry = page;
        new_entry.last_used = self.counter;
        try self.entries.append(self.allocator, new_entry);
        self.bytes += needed;
    }

    fn evictOldest(self: *PageCache) void {
        if (self.entries.items.len == 0) return;
        var oldest_idx: usize = 0;
        var oldest_used = self.entries.items[0].last_used;

        for (self.entries.items[1..], 1..) |entry, idx| {
            if (entry.last_used < oldest_used) {
                oldest_used = entry.last_used;
                oldest_idx = idx;
            }
        }

        var old = self.entries.swapRemove(oldest_idx);
        self.bytes -= old.bytes;
        old.deinit();
    }

    pub fn clearGeneration(self: *PageCache, current_generation: u64) void {
        var i: usize = 0;
        while (i < self.entries.items.len) {
            if (self.entries.items[i].key.generation != current_generation) {
                var old = self.entries.swapRemove(i);
                self.bytes -= old.bytes;
                old.deinit();
            } else {
                i += 1;
            }
        }
    }
};

pub const ThumbKey = struct {
    generation: u64,
    page_index: usize,
    rotation: layout.Rotation,
    card_w: u16,
    card_h: u16,

    pub fn eql(self: ThumbKey, other: ThumbKey) bool {
        return self.generation == other.generation and
            self.page_index == other.page_index and
            self.rotation == other.rotation and
            self.card_w == other.card_w and
            self.card_h == other.card_h;
    }
};

pub const CachedThumb = struct {
    key: ThumbKey,
    pixels: []u32,
    width: i32,
    height: i32,
    stride: i32,
    bytes: usize,
    last_used: u64,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *CachedThumb) void {
        self.allocator.free(self.pixels);
    }
};

pub const ThumbCache = struct {
    entries: std.ArrayList(CachedThumb),
    byte_limit: usize = THUMB_CACHE_LIMIT,
    bytes: usize = 0,
    counter: u64 = 0,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, limit: usize) ThumbCache {
        return .{
            .entries = .empty,
            .byte_limit = limit,
            .bytes = 0,
            .counter = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ThumbCache) void {
        for (self.entries.items) |*entry| {
            entry.deinit();
        }
        self.entries.deinit(self.allocator);
        self.bytes = 0;
    }

    pub fn get(self: *ThumbCache, key: ThumbKey) ?*CachedThumb {
        for (self.entries.items) |*entry| {
            if (entry.key.eql(key)) {
                self.counter += 1;
                entry.last_used = self.counter;
                return entry;
            }
        }
        return null;
    }

    pub fn put(self: *ThumbCache, thumb: CachedThumb) !void {
        if (thumb.width <= 0 or thumb.height <= 0 or thumb.stride < thumb.width * 4) {
            var mut_thumb = thumb;
            mut_thumb.deinit();
            return error.InvalidDimensions;
        }
        const needed = thumb.bytes;
        if (needed > self.byte_limit) {
            var mut_thumb = thumb;
            mut_thumb.deinit();
            return;
        }

        var i: usize = 0;
        while (i < self.entries.items.len) {
            if (self.entries.items[i].key.eql(thumb.key)) {
                var old = self.entries.swapRemove(i);
                self.bytes -= old.bytes;
                old.deinit();
            } else {
                i += 1;
            }
        }

        while (self.bytes + needed > self.byte_limit and self.entries.items.len > 0) {
            self.evictOldest();
        }

        self.counter += 1;
        var new_entry = thumb;
        new_entry.last_used = self.counter;
        try self.entries.append(self.allocator, new_entry);
        self.bytes += needed;
    }

    fn evictOldest(self: *ThumbCache) void {
        if (self.entries.items.len == 0) return;
        var oldest_idx: usize = 0;
        var oldest_used = self.entries.items[0].last_used;

        for (self.entries.items[1..], 1..) |entry, idx| {
            if (entry.last_used < oldest_used) {
                oldest_used = entry.last_used;
                oldest_idx = idx;
            }
        }

        var old = self.entries.swapRemove(oldest_idx);
        self.bytes -= old.bytes;
        old.deinit();
    }

    pub fn clearGeneration(self: *ThumbCache, current_generation: u64) void {
        var i: usize = 0;
        while (i < self.entries.items.len) {
            if (self.entries.items[i].key.generation != current_generation) {
                var old = self.entries.swapRemove(i);
                self.bytes -= old.bytes;
                old.deinit();
            } else {
                i += 1;
            }
        }
    }
};
