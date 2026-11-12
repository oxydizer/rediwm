//! Enumerate base keyboard layouts from the host's XKB registry.
//! The registry owns its records; returned strings are copied into the
//! caller's allocator so they can safely back retained UI widgets.

const std = @import("std");

const Context = opaque {};
const RegistryLayout = opaque {};

pub const Layout = struct {
    name: []const u8,
    label: []const u8,
};

pub const Variant = struct {
    name: []const u8,
    label: []const u8,
};

extern "c" fn rxkb_context_new(flags: c_int) ?*Context;
extern "c" fn rxkb_context_unref(context: *Context) ?*Context;
extern "c" fn rxkb_context_parse_default_ruleset(context: *Context) bool;

extern "c" fn rxkb_layout_first(context: *Context) ?*RegistryLayout;
extern "c" fn rxkb_layout_next(layout: *RegistryLayout) ?*RegistryLayout;
extern "c" fn rxkb_layout_get_name(layout: *RegistryLayout) ?[*:0]const u8;
extern "c" fn rxkb_layout_get_variant(layout: *RegistryLayout) ?[*:0]const u8;
extern "c" fn rxkb_layout_get_description(layout: *RegistryLayout) ?[*:0]const u8;

fn lessThan(_: void, a: Layout, b: Layout) bool {
    return std.mem.lessThan(u8, a.label, b.label);
}

fn lessThanVariant(_: void, a: Variant, b: Variant) bool {
    return std.mem.lessThan(u8, a.label, b.label);
}

/// Returns one entry per base layout (variants are intentionally omitted).
/// Labels come from the host's xkeyboard-config data, not a local translation
/// table. The caller owns the returned slice and strings.
pub fn enumerate(allocator: std.mem.Allocator) ![]Layout {
    const context = rxkb_context_new(0) orelse return error.RegistryUnavailable;
    defer _ = rxkb_context_unref(context);

    if (!rxkb_context_parse_default_ruleset(context)) {
        return error.RegistryUnavailable;
    }

    var count: usize = 0;
    var entry = rxkb_layout_first(context);
    while (entry) |layout| : (entry = rxkb_layout_next(layout)) {
        if (rxkb_layout_get_variant(layout) == null) count += 1;
    }

    const layouts = try allocator.alloc(Layout, count);
    var len: usize = 0;
    entry = rxkb_layout_first(context);
    while (entry) |layout| : (entry = rxkb_layout_next(layout)) {
        // The language dropdown lists base layouts only. Variant selection
        // will be populated separately from the same registry in the next step.
        if (rxkb_layout_get_variant(layout) != null) continue;

        const raw_name = rxkb_layout_get_name(layout) orelse continue;
        const name = std.mem.span(raw_name);

        // User-provided include paths may add duplicate definitions.
        var duplicate = false;
        for (layouts[0..len]) |existing| {
            if (std.mem.eql(u8, existing.name, name)) {
                duplicate = true;
                break;
            }
        }
        if (duplicate) continue;

        const raw_label = rxkb_layout_get_description(layout) orelse raw_name;
        layouts[len] = .{
            .name = try allocator.dupe(u8, name),
            .label = try allocator.dupe(u8, std.mem.span(raw_label)),
        };
        len += 1;
    }

    std.mem.sort(Layout, layouts[0..len], {}, lessThan);
    return layouts[0..len];
}

/// Returns the variants belonging to one base layout. The empty/default
/// variant is represented by the caller, not by this list.
pub fn enumerateVariants(allocator: std.mem.Allocator, layout_name: []const u8) ![]Variant {
    const context = rxkb_context_new(0) orelse return error.RegistryUnavailable;
    defer _ = rxkb_context_unref(context);

    if (!rxkb_context_parse_default_ruleset(context)) {
        return error.RegistryUnavailable;
    }

    var count: usize = 0;
    var entry = rxkb_layout_first(context);
    while (entry) |layout| : (entry = rxkb_layout_next(layout)) {
        const name = rxkb_layout_get_name(layout) orelse continue;
        if (!std.mem.eql(u8, std.mem.span(name), layout_name)) continue;
        if (rxkb_layout_get_variant(layout) != null) count += 1;
    }

    const variants = try allocator.alloc(Variant, count);
    var len: usize = 0;
    entry = rxkb_layout_first(context);
    while (entry) |layout| : (entry = rxkb_layout_next(layout)) {
        const raw_name = rxkb_layout_get_name(layout) orelse continue;
        if (!std.mem.eql(u8, std.mem.span(raw_name), layout_name)) continue;

        const raw_variant = rxkb_layout_get_variant(layout) orelse continue;
        const name = std.mem.span(raw_variant);
        var duplicate = false;
        for (variants[0..len]) |existing| {
            if (std.mem.eql(u8, existing.name, name)) {
                duplicate = true;
                break;
            }
        }
        if (duplicate) continue;

        const raw_label = rxkb_layout_get_description(layout) orelse raw_variant;
        variants[len] = .{
            .name = try allocator.dupe(u8, name),
            .label = try allocator.dupe(u8, std.mem.span(raw_label)),
        };
        len += 1;
    }

    std.mem.sort(Variant, variants[0..len], {}, lessThanVariant);
    return variants[0..len];
}
