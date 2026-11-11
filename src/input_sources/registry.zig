//! The XKB layout catalogue (names, language codes, descriptions) from
//! libxkbregistry. Parsing evdev.xml takes about 11 ms, so it runs once on a
//! worker the first time something needs it (more than one layout, or the
//! Settings page) and wakes the event loop through an eventfd. The library is
//! opened with dlopen: some distributions package it separately, and without
//! it labels fall back to the layout code and Settings to a short built-in list.
const std = @import("std");
const builtin = @import("builtin");
const platform = @import("platform");
const sys = std.posix.system;

const a = std.heap.c_allocator;
const log = std.log.scoped(.input_sources);

pub const Entry = struct {
    layout: []const u8,
    variant: []const u8,
    /// Short language code from the registry ("en", "de", "ja"), or "".
    brief: []const u8,
    /// "German (no dead keys)".
    description: []const u8,
    /// ISO 639-3 codes, space separated, for searching ("deu", "jpn").
    languages: []const u8,
};

pub const Catalog = struct {
    arena: std.heap.ArenaAllocator,
    entries: []Entry,

    pub fn deinit(self: *Catalog) void {
        self.arena.deinit();
    }

    pub fn find(self: *const Catalog, layout: []const u8, variant: []const u8) ?*const Entry {
        for (self.entries) |*entry| {
            if (std.mem.eql(u8, entry.layout, layout) and std.mem.eql(u8, entry.variant, variant)) return entry;
        }
        return null;
    }
};

const Context = opaque {};
const Layout = opaque {};
const Code = opaque {};

const Api = struct {
    library: std.DynLib,
    context_new: *const fn (c_int) callconv(.c) ?*Context,
    parse_default: *const fn (*Context) callconv(.c) bool,
    context_unref: *const fn (*Context) callconv(.c) ?*Context,
    layout_first: *const fn (*Context) callconv(.c) ?*Layout,
    layout_next: *const fn (*Layout) callconv(.c) ?*Layout,
    layout_name: *const fn (*Layout) callconv(.c) ?[*:0]const u8,
    layout_variant: *const fn (*Layout) callconv(.c) ?[*:0]const u8,
    layout_brief: *const fn (*Layout) callconv(.c) ?[*:0]const u8,
    layout_description: *const fn (*Layout) callconv(.c) ?[*:0]const u8,
    iso639_first: *const fn (*Layout) callconv(.c) ?*Code,
    iso639_next: *const fn (*Code) callconv(.c) ?*Code,
    iso639_code: *const fn (*Code) callconv(.c) ?[*:0]const u8,

    fn open() ?Api {
        if (builtin.os.tag != .linux and builtin.os.tag != .freebsd) return null;
        var library = std.DynLib.open("libxkbregistry.so.0") catch return null;
        errdefer library.close();
        var api: Api = undefined;
        api.library = library;
        inline for (.{
            .{ "context_new", "rxkb_context_new" },
            .{ "parse_default", "rxkb_context_parse_default_ruleset" },
            .{ "context_unref", "rxkb_context_unref" },
            .{ "layout_first", "rxkb_layout_first" },
            .{ "layout_next", "rxkb_layout_next" },
            .{ "layout_name", "rxkb_layout_get_name" },
            .{ "layout_variant", "rxkb_layout_get_variant" },
            .{ "layout_brief", "rxkb_layout_get_brief" },
            .{ "layout_description", "rxkb_layout_get_description" },
            .{ "iso639_first", "rxkb_layout_get_iso639_first" },
            .{ "iso639_next", "rxkb_iso639_code_next" },
            .{ "iso639_code", "rxkb_iso639_code_get_code" },
        }) |pair| {
            @field(api, pair[0]) = library.lookup(@FieldType(Api, pair[0]), pair[1]) orelse {
                library.close();
                return null;
            };
        }
        return api;
    }
};

fn span(value: ?[*:0]const u8) []const u8 {
    return if (value) |v| std.mem.span(v) else "";
}

/// Blocking: reads the whole default ruleset. Null without the library or
/// rules.
pub fn load() ?Catalog {
    var api = Api.open() orelse return null;
    defer api.library.close();
    // RXKB_CONTEXT_NO_FLAGS: system include paths, no exotic layouts.
    const context = api.context_new(0) orelse return null;
    defer _ = api.context_unref(context);
    if (!api.parse_default(context)) return null;
    return build(&api, context) catch null;
}

fn build(api: *const Api, context: *Context) !Catalog {
    var catalog: Catalog = .{ .arena = .init(a), .entries = &.{} };
    errdefer catalog.deinit();
    const arena = catalog.arena.allocator();
    var list: std.ArrayList(Entry) = .empty;
    var it = api.layout_first(context);
    while (it) |layout| : (it = api.layout_next(layout)) {
        var languages: std.ArrayList(u8) = .empty;
        var code = api.iso639_first(layout);
        while (code) |c| : (code = api.iso639_next(c)) {
            if (languages.items.len > 0) try languages.append(arena, ' ');
            try languages.appendSlice(arena, span(api.iso639_code(c)));
        }
        try list.append(arena, .{
            .layout = try arena.dupe(u8, span(api.layout_name(layout))),
            .variant = try arena.dupe(u8, span(api.layout_variant(layout))),
            .brief = try arena.dupe(u8, span(api.layout_brief(layout))),
            .description = try arena.dupe(u8, span(api.layout_description(layout))),
            .languages = languages.items,
        });
    }
    catalog.entries = list.items;
    return catalog;
}

/// One background load. The owner polls `fd` on its event loop and calls
/// `finish` when it turns readable.
pub const Job = struct {
    fd: std.posix.fd_t,
    thread: ?std.Thread = null,
    result: ?Catalog = null,

    pub fn start() !*Job {
        const self = try a.create(Job);
        errdefer a.destroy(self);
        const fd = platform.wake.create() orelse return error.EventFdFailed;
        errdefer _ = sys.close(fd);
        self.* = .{ .fd = fd };
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }

    fn run(self: *Job) void {
        self.result = load();
        if (self.result == null) log.info("libxkbregistry unavailable; layout names fall back to their codes", .{});
        const one: u64 = 1;
        _ = sys.write(self.fd, std.mem.asBytes(&one), @sizeOf(u64));
    }

    /// Joins the worker and hands its catalogue over. Also safe while it still
    /// runs (shutdown): the join waits for it.
    pub fn finish(self: *Job) ?Catalog {
        if (self.thread) |thread| thread.join();
        self.thread = null;
        const result = self.result;
        _ = sys.close(self.fd);
        a.destroy(self);
        return result;
    }
};

test "the registry, when installed, names common layouts and their language codes" {
    var catalog = load() orelse return error.SkipZigTest;
    defer catalog.deinit();
    const de = catalog.find("de", "") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("de", de.brief);
    try std.testing.expect(std.mem.indexOf(u8, de.languages, "deu") != null);
    const jp = catalog.find("jp", "") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("ja", jp.brief);
    try std.testing.expect(catalog.find("us", "dvorak") != null);
}
