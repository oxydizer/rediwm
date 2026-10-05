const std = @import("std");
const wire = @import("dbus").wire;
const model = @import("../files/chooser.zig");
const uri = @import("../files/clipboard.zig");
const Allocator = std.mem.Allocator;

fn filter(a: Allocator, r: *wire.Reader) !model.Filter {
    try r.alignTo(8);
    const name = try a.dupe(u8, try r.string());
    var rules: std.ArrayList(model.Rule) = .empty;
    var array = try r.array(8);
    while (array.offset < array.bytes.len) {
        if (rules.items.len >= 128) return error.TooLarge;
        try array.alignTo(8);
        const kind = try array.uint32();
        if (kind > 1) return error.InvalidFilter;
        try rules.append(a, .{ .kind = kind, .value = try a.dupe(u8, try array.string()) });
    }
    return .{ .name = name, .rules = try rules.toOwnedSlice(a) };
}
fn bytestring(a: Allocator, r: *wire.Reader) ![]const u8 {
    const array = try r.array(1);
    const bytes = array.bytes[array.offset..];
    if (bytes.len == 0 or bytes[bytes.len - 1] != 0 or std.mem.indexOfScalar(u8, bytes[0 .. bytes.len - 1], 0) != null) return error.InvalidPath;
    return a.dupe(u8, bytes[0 .. bytes.len - 1]);
}

/// Allocations belong to the request arena; never retain borrowed bus bytes.
pub fn options(a: Allocator, reader: *wire.Reader, save: bool, save_files: bool) !model.Options {
    var opts: model.Options = .{ .mode = if (save_files) .folder else if (save) .save else .open };
    var current_filter: ?model.Filter = null;
    var current_file: ?[]const u8 = null;
    var dict = try reader.array(8);
    while (dict.offset < dict.bytes.len) {
        try dict.alignTo(8);
        const key = try dict.string();
        const sig = try dict.variant();
        if (std.mem.eql(u8, key, "multiple") and std.mem.eql(u8, sig, "b")) {
            opts.multiple = (try dict.boolean()) and !save and !save_files;
        } else if (std.mem.eql(u8, key, "directory") and std.mem.eql(u8, sig, "b")) {
            if (try dict.boolean()) {
                if (!save) opts.mode = .folder;
            }
        } else if (std.mem.eql(u8, key, "accept_label") and std.mem.eql(u8, sig, "s")) {
            const label = try dict.string();
            var plain: std.ArrayList(u8) = .empty;
            for (label) |ch| if (ch != '_') {
                try plain.append(a, ch);
            };
            opts.accept_label = try plain.toOwnedSlice(a);
        } else if (std.mem.eql(u8, key, "current_name") and std.mem.eql(u8, sig, "s")) {
            opts.current_name = try a.dupe(u8, try dict.string());
        } else if (std.mem.eql(u8, key, "current_folder") and std.mem.eql(u8, sig, "ay")) {
            opts.current_folder = try bytestring(a, &dict);
        } else if (std.mem.eql(u8, key, "current_file") and std.mem.eql(u8, sig, "ay")) {
            current_file = try bytestring(a, &dict);
        } else if (std.mem.eql(u8, key, "filters") and std.mem.eql(u8, sig, "a(sa(us))")) {
            var list = try dict.array(8);
            var filters: std.ArrayList(model.Filter) = .empty;
            while (list.offset < list.bytes.len) {
                if (filters.items.len >= 64) return error.TooLarge;
                try filters.append(a, try filter(a, &list));
            }
            opts.filters = try filters.toOwnedSlice(a);
        } else if (std.mem.eql(u8, key, "current_filter") and std.mem.eql(u8, sig, "(sa(us))")) {
            current_filter = try filter(a, &dict);
        } else if (std.mem.eql(u8, key, "files") and std.mem.eql(u8, sig, "aay")) {
            var list = try dict.array(4);
            var files: std.ArrayList([]const u8) = .empty;
            while (list.offset < list.bytes.len) {
                if (files.items.len >= 256) return error.TooLarge;
                const name = try bytestring(a, &list);
                if (!model.validName(name)) return error.InvalidFilename;
                try files.append(a, name);
            }
            opts.files = try files.toOwnedSlice(a);
        } else if (std.mem.eql(u8, key, "choices") and std.mem.eql(u8, sig, "a(ssa(ss)s)")) {
            var list = try dict.array(8);
            var choices: std.ArrayList(model.Choice) = .empty;
            while (list.offset < list.bytes.len) {
                if (choices.items.len >= 8) return error.TooLarge;
                try list.alignTo(8);
                const id = try a.dupe(u8, try list.string());
                const label = try a.dupe(u8, try list.string());
                var values = try list.array(8);
                var vals: std.ArrayList(model.ChoiceValue) = .empty;
                while (values.offset < values.bytes.len) {
                    if (vals.items.len >= 128) return error.TooLarge;
                    try values.alignTo(8);
                    try vals.append(a, .{ .id = try a.dupe(u8, try values.string()), .label = try a.dupe(u8, try values.string()) });
                }
                const selected = try a.dupe(u8, try list.string());
                try choices.append(a, .{ .id = id, .label = label, .values = try vals.toOwnedSlice(a), .selected = selected });
            }
            opts.choices = try choices.toOwnedSlice(a);
        } else try dict.skip(sig);
    }
    if (current_file) |path| {
        opts.current_folder = std.fs.path.dirname(path) orelse "";
        opts.current_name = std.fs.path.basename(path);
    }
    if (opts.current_folder.len > 0 and !std.fs.path.isAbsolute(opts.current_folder)) return error.InvalidPath;
    if (current_filter) |selected| {
        if (opts.filters.len == 0) {
            const filters = try a.alloc(model.Filter, 1);
            filters[0] = selected;
            opts.filters = filters;
        } else for (opts.filters, 0..) |f, i| {
            if (!std.mem.eql(u8, f.name, selected.name) or f.rules.len != selected.rules.len) continue;
            var same = true;
            for (f.rules, selected.rules) |x, y| if (x.kind != y.kind or !std.mem.eql(u8, x.value, y.value)) {
                same = false;
            };
            if (same) {
                opts.filter_index = i;
                break;
            }
        }
    }
    return opts;
}

pub fn response(body: *wire.Writer, opts: model.Options, result: ?model.Result, code: u32) !void {
    try body.uint32(code);
    const dict = try body.beginArray(8);
    if (result) |selected| {
        try body.alignTo(8);
        try body.string("uris");
        try body.variant("as");
        const uris = try body.beginArray(4);
        for (selected.paths) |path| {
            if (!std.fs.path.isAbsolute(path) or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;
            const encoded = try uri.encodeLocalUri(body.allocator, path);
            defer body.allocator.free(encoded);
            try body.string(encoded);
        }
        try body.endArray(uris);
        if (opts.filters.len > 0) {
            if (selected.filter_index >= opts.filters.len) return error.InvalidFilter;
            const f = opts.filters[selected.filter_index];
            try body.alignTo(8);
            try body.string("current_filter");
            try body.variant("(sa(us))");
            try body.alignTo(8);
            try body.string(f.name);
            const rules = try body.beginArray(8);
            for (f.rules) |rule| {
                try body.alignTo(8);
                try body.uint32(rule.kind);
                try body.string(rule.value);
            }
            try body.endArray(rules);
        }
        if (opts.choices.len > 0) {
            if (opts.choices.len != selected.choices.len) return error.InvalidChoices;
            try body.alignTo(8);
            try body.string("choices");
            try body.variant("a(ss)");
            const choices = try body.beginArray(8);
            for (opts.choices, selected.choices) |choice, value| {
                try body.alignTo(8);
                try body.string(choice.id);
                try body.string(value);
            }
            try body.endArray(choices);
        }
    }
    try body.endArray(dict);
}

test "cancel response never includes paths" {
    var body: wire.Writer = .{ .allocator = std.testing.allocator };
    defer body.deinit();
    try response(&body, .{}, null, 1);
    var reader: wire.Reader = .{ .bytes = body.bytes.items };
    try std.testing.expectEqual(@as(u32, 1), try reader.uint32());
    const dict = try reader.array(8);
    try dict.done();
    try reader.done();
}
