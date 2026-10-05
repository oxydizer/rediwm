// Fontconfig discovery for compositor-drawn text. Bundled faces stay in
// text.zig; this module answers "which installed file covers this character
// or family?" so fallback does not hardcode paths.
//
// fontconfig.h is a clean C API (no glib), so it @cInclude's unlike rsvg.
const std = @import("std");
const Allocator = std.mem.Allocator;

const c = @cImport({
    @cInclude("fontconfig/fontconfig.h");
});

const log = std.log.scoped(.fontconfig);

pub const Candidate = struct {
    path: [:0]u8,
    index: i32,
    color: bool,
    charset: *c.FcCharSet,

    pub fn deinit(self: Candidate, allocator: Allocator) void {
        allocator.free(self.path);
        c.FcCharSetDestroy(self.charset);
    }

    pub fn hasChar(self: Candidate, cp: u32) bool {
        return c.FcCharSetHasChar(self.charset, cp) != 0;
    }

    /// Drop the charset copy after the path has been interned by the caller.
    pub fn discardCharset(self: Candidate) void {
        c.FcCharSetDestroy(self.charset);
    }
};

var initialized = false;
var available = false;

pub fn ensureInit() bool {
    if (initialized) return available;
    initialized = true;
    available = c.FcInit() != 0;
    if (!available) log.warn("FcInit failed; compositor text has no system fallback", .{});
    return available;
}

pub fn isBundledFamily(name: []const u8) bool {
    const trimmed = std.mem.trim(u8, name, " \t");
    return std.ascii.eqlIgnoreCase(trimmed, "Manrope") or
        std.ascii.eqlIgnoreCase(trimmed, "JetBrains Mono") or
        std.ascii.eqlIgnoreCase(trimmed, "JetBrainsMono") or
        std.ascii.startsWithIgnoreCase(trimmed, "JetBrains Mono ") or
        std.ascii.startsWithIgnoreCase(trimmed, "JetBrainsMono ");
}

/// Discover scalable UI font families once per settings panel. The caller
/// owns the returned slice and each name (an arena is convenient).
pub fn listFamilies(allocator: Allocator) ![][]const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(allocator);
    const bundled = try allocator.dupe(u8, "Manrope");
    names.append(allocator, bundled) catch |err| {
        allocator.free(bundled);
        return err;
    };
    try seen.put(allocator, bundled, {});
    if (ensureInit()) {
        const pat = c.FcPatternCreate() orelse return error.OutOfMemory;
        defer c.FcPatternDestroy(pat);
        _ = c.FcPatternAddBool(pat, c.FC_SCALABLE, c.FcTrue);
        const objects = c.FcObjectSetCreate() orelse return error.OutOfMemory;
        defer c.FcObjectSetDestroy(objects);
        _ = c.FcObjectSetAdd(objects, c.FC_FAMILY);
        const fonts = c.FcFontList(null, pat, objects) orelse return error.OutOfMemory;
        defer c.FcFontSetDestroy(fonts);
        for (0..@intCast(fonts.*.nfont)) |i| {
            const font = fonts.*.fonts[i] orelse continue;
            var family: [*c]c.FcChar8 = null;
            if (c.FcPatternGetString(font, c.FC_FAMILY, 0, &family) != c.FcResultMatch or family == null) continue;
            const name = std.mem.span(@as([*:0]const u8, @ptrCast(family)));
            // Respect the renderer's family-name limit and the theme's
            // literal quoted-string format.
            if (name.len == 0 or name.len >= 128 or std.mem.indexOfAny(u8, name, "\"\\\r\n") != null or isBundledFamily(name) or seen.contains(name)) continue;
            const owned = try allocator.dupe(u8, name);
            names.append(allocator, owned) catch |err| {
                allocator.free(owned);
                return err;
            };
            try seen.put(allocator, owned, {});
        }
    }
    std.mem.sort([]const u8, names.items[1..], {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
    return names.toOwnedSlice(allocator);
}

/// Match `family` at OpenType weight. Null when fontconfig substitutes a
/// different family (the requested name is not installed).
pub fn matchFamily(allocator: Allocator, family: []const u8, ot_weight: u32) ?Candidate {
    if (!ensureInit()) return null;
    if (family.len == 0 or isBundledFamily(family)) return null;

    var name_buf: [128]u8 = undefined;
    if (family.len >= name_buf.len) return null;
    @memcpy(name_buf[0..family.len], family);
    name_buf[family.len] = 0;
    const name_z: [*:0]const u8 = @ptrCast(name_buf[0..family.len :0]);

    const pat = c.FcPatternCreate() orelse return null;
    defer c.FcPatternDestroy(pat);
    _ = c.FcPatternAddString(pat, c.FC_FAMILY, name_z);
    _ = c.FcPatternAddInteger(pat, c.FC_WEIGHT, c.FcWeightFromOpenType(@intCast(ot_weight)));
    _ = c.FcPatternAddInteger(pat, c.FC_SLANT, c.FC_SLANT_ROMAN);
    _ = c.FcConfigSubstitute(null, pat, c.FcMatchPattern);
    c.FcDefaultSubstitute(pat);

    var result: c.FcResult = undefined;
    const matched = c.FcFontMatch(null, pat, &result) orelse return null;
    defer c.FcPatternDestroy(matched);
    if (!patternHasFamily(matched, family)) return null;
    return candidateFromPattern(allocator, matched);
}

/// First installed font covering `codepoint` for `family`. `color` keeps
/// only color fonts, which is what emoji presentation needs so a B&W
/// symbol font cannot win over Noto Color Emoji.
pub fn findCovering(
    allocator: Allocator,
    family: [*:0]const u8,
    ot_weight: u32,
    codepoint: u32,
    color: bool,
) ?Candidate {
    if (!ensureInit()) return null;
    const cs = c.FcCharSetCreate() orelse return null;
    defer c.FcCharSetDestroy(cs);
    _ = c.FcCharSetAddChar(cs, codepoint);

    const pat = c.FcPatternCreate() orelse return null;
    defer c.FcPatternDestroy(pat);
    _ = c.FcPatternAddString(pat, c.FC_FAMILY, family);
    _ = c.FcPatternAddInteger(pat, c.FC_WEIGHT, c.FcWeightFromOpenType(@intCast(ot_weight)));
    _ = c.FcPatternAddInteger(pat, c.FC_SLANT, c.FC_SLANT_ROMAN);
    _ = c.FcPatternAddCharSet(pat, c.FC_CHARSET, cs);
    if (color) _ = c.FcPatternAddBool(pat, c.FC_COLOR, c.FcTrue);
    _ = c.FcConfigSubstitute(null, pat, c.FcMatchPattern);
    c.FcDefaultSubstitute(pat);

    var result: c.FcResult = undefined;
    const set = c.FcFontSort(null, pat, c.FcTrue, null, &result) orelse return null;
    defer c.FcFontSetDestroy(set);

    var i: c_int = 0;
    while (i < set.*.nfont) : (i += 1) {
        const font = set.*.fonts[@intCast(i)] orelse continue;
        var fcs: ?*c.FcCharSet = null;
        if (c.FcPatternGetCharSet(font, c.FC_CHARSET, 0, &fcs) != c.FcResultMatch) continue;
        const charset = fcs orelse continue;
        if (c.FcCharSetHasChar(charset, codepoint) == 0) continue;
        if (color) {
            var is_color: c.FcBool = 0;
            if (c.FcPatternGetBool(font, c.FC_COLOR, 0, &is_color) != c.FcResultMatch or is_color == 0)
                continue;
        }
        if (candidateFromPattern(allocator, font)) |cand| return cand;
    }
    return null;
}

fn patternHasFamily(pat: *c.FcPattern, name: []const u8) bool {
    const trimmed = std.mem.trim(u8, name, " \t");
    var n: c_int = 0;
    while (true) : (n += 1) {
        var fam: [*c]c.FcChar8 = undefined;
        if (c.FcPatternGetString(pat, c.FC_FAMILY, n, &fam) != c.FcResultMatch) break;
        if (fam == null) break;
        const s = std.mem.span(@as([*:0]const u8, @ptrCast(fam)));
        if (std.ascii.eqlIgnoreCase(s, trimmed)) return true;
    }
    return false;
}

fn shouldSkipPath(path: []const u8) bool {
    return std.ascii.endsWithIgnoreCase(path, ".woff") or
        std.ascii.endsWithIgnoreCase(path, ".woff2") or
        std.ascii.endsWithIgnoreCase(path, ".pcf") or
        std.ascii.endsWithIgnoreCase(path, ".pcf.gz") or
        std.ascii.endsWithIgnoreCase(path, ".bdf");
}

fn candidateFromPattern(allocator: Allocator, font: *c.FcPattern) ?Candidate {
    var file_c: [*c]c.FcChar8 = undefined;
    if (c.FcPatternGetString(font, c.FC_FILE, 0, &file_c) != c.FcResultMatch or file_c == null)
        return null;
    const file = std.mem.span(@as([*:0]const u8, @ptrCast(file_c)));
    if (shouldSkipPath(file)) return null;

    var index: c_int = 0;
    _ = c.FcPatternGetInteger(font, c.FC_INDEX, 0, &index);
    var color: c.FcBool = 0;
    _ = c.FcPatternGetBool(font, c.FC_COLOR, 0, &color);

    var cs: ?*c.FcCharSet = null;
    if (c.FcPatternGetCharSet(font, c.FC_CHARSET, 0, &cs) != c.FcResultMatch) return null;
    const copied = c.FcCharSetCopy(cs orelse return null) orelse return null;
    const path = allocator.dupeZ(u8, file) catch {
        c.FcCharSetDestroy(copied);
        return null;
    };
    return .{
        .path = path,
        .index = index,
        .color = color != 0,
        .charset = copied,
    };
}

test "bundled family names are not resolved through fontconfig" {
    try std.testing.expect(isBundledFamily("Manrope"));
    try std.testing.expect(isBundledFamily("manrope"));
    try std.testing.expect(isBundledFamily("JetBrains Mono"));
    try std.testing.expect(isBundledFamily("JetBrainsMono"));
    try std.testing.expect(!isBundledFamily("Noto Sans"));
    try std.testing.expect(!isBundledFamily(""));
}

test "matchFamily returns the named family when it is installed" {
    const cand = matchFamily(std.testing.allocator, "Noto Sans", 400) orelse return error.SkipZigTest;
    defer cand.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, cand.path, "NotoSans") != null or
        std.mem.indexOf(u8, cand.path, "Noto-Sans") != null);
    try std.testing.expect(cand.hasChar('A'));
}

test "matchFamily is null for a family fontconfig would substitute" {
    try std.testing.expect(matchFamily(std.testing.allocator, "DefinitelyNoSuchUiFont-xyz", 400) == null);
}

test "findCovering locates a color emoji font when one is installed" {
    const cand = findCovering(std.testing.allocator, "sans-serif", 400, 0x1F44B, true) orelse return error.SkipZigTest;
    defer cand.deinit(std.testing.allocator);
    try std.testing.expect(cand.color);
    try std.testing.expect(cand.hasChar(0x1F44B));
}

test "findCovering locates Arabic when a covering font is installed" {
    const cand = findCovering(std.testing.allocator, "sans-serif", 400, 0x0645, false) orelse return error.SkipZigTest;
    defer cand.deinit(std.testing.allocator);
    try std.testing.expect(cand.hasChar(0x0645));
}
