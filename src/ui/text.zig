// Small, process-wide FreeType + HarfBuzz text renderer. Bundled Manrope
// (titles, chrome) and JetBrains Mono (clock) are the default faces;
// Fontconfig supplies fallback files for missing glyphs — emoji, CJK, and
// whatever else the user has installed. `theme.font` / `theme.mono_font`
// become the primary face when those families exist; unknown names keep
// the bundled defaults.
const std = @import("std");
const gpa = @import("memory").gpa;
const font_fallback = @import("font_fallback.zig");
const c = @cImport({
    @cInclude("ft2build.h");
    @cInclude("freetype/freetype.h");
    @cInclude("freetype/ftmm.h");
    @cInclude("freetype/ftsizes.h");
    @cInclude("hb.h");
    @cInclude("hb-ft.h");
});

const log = std.log.scoped(.text);

pub const Rect = struct { x: i32, y: i32, w: i32, h: i32 };
pub const Color = struct { r: f32, g: f32, b: f32, a: f32 };

pub const Font = enum {
    manrope,
    manrope_bold,
    mono,
    mono_bold,

    fn bytes(font: Font) []const u8 {
        return switch (font) {
            .manrope, .manrope_bold => @embedFile("manrope"),
            .mono => @embedFile("jetbrains_mono_regular"),
            .mono_bold => @embedFile("jetbrains_mono_bold"),
        };
    }
};

const FaceSource = union(enum) {
    bundled: Font,
    file: struct { path: [:0]u8, index: i32 },
};

const Face = struct {
    source: FaceSource,
    color: bool = false,
    ft_face: c.FT_Face = null,
    /// The HarfBuzz font of the active size (`set_size`).
    hb_font: ?*c.hb_font_t = null,
    // Physical pixels in 26.6 units, including fractional sizes (13px at
    // 1.5x is 19.5px). Cache the full size, not just the rounded ppem.
    set_size: c.FT_F26Dot6 = 0,
    weight: u32 = 400,
    dead: bool = false,
    /// Prepared FreeType sizes, each with its own HarfBuzz font. Re-sizing
    /// one FT_Size in place reruns the TrueType `prep` program and the hinted
    /// glyph-0 warmup, and flushes hb-ft's advance cache; a window title
    /// change used to do that 14 times alternating titlebar and taskbar sizes.
    /// Activating a prepared size costs nothing.
    sizes: [size_slots]SizeSlot = undefined,
    size_count: usize = 0,
};

const size_slots = 8;
const SizeSlot = struct { size: c.FT_F26Dot6, ft_size: c.FT_Size, hb_font: *c.hb_font_t, used: u64 };
var size_clock: u64 = 0;

// Full hinting: the chrome's 12-13.5px text is small enough that grid-fitting
// both axes measurably wins over FT_LOAD_TARGET_LIGHT's Y-only snapping. At
// 13.5px it cuts the share of ink pixels sitting at intermediate coverage from
// 40% to 27% and raises edge acutance from 110 to 117; the cost is the usual
// slight horizontal stem distortion. Shape and rasterize with the same
// metrics policy so HarfBuzz's advances match the bitmaps we place.
const load_flags: c_int = c.FT_LOAD_DEFAULT | c.FT_LOAD_NO_BITMAP;
const color_load_flags: c_int = c.FT_LOAD_DEFAULT | c.FT_LOAD_COLOR;

var ft_library: c.FT_Library = null;
var faces: std.ArrayListUnmanaged(Face) = .empty;
var chains: [4]std.ArrayListUnmanaged(u32) = .{ .empty, .empty, .empty, .empty };
var coverage: std.AutoHashMapUnmanaged(u64, u32) = .empty;
const no_face = std.math.maxInt(u32);

var sans_name_buf: [128]u8 = undefined;
var sans_name_len: usize = 0;
var mono_name_buf: [128]u8 = undefined;
var mono_name_len: usize = 0;

fn preferredSans() []const u8 {
    return sans_name_buf[0..sans_name_len];
}
fn preferredMono() []const u8 {
    return mono_name_buf[0..mono_name_len];
}

fn bundledWeight(font: Font) u32 {
    return switch (font) {
        .manrope_bold, .mono_bold => 600,
        else => 400,
    };
}

fn genericFamilyZ(font: Font) [*:0]const u8 {
    return switch (font) {
        .manrope, .manrope_bold => "sans-serif",
        .mono, .mono_bold => "monospace",
    };
}

fn size26(size_px: f32, scale: f32) c.FT_F26Dot6 {
    return @intFromFloat(@max(64, @round(size_px * scale * 64)));
}

fn coverageKey(cp: u32, color: bool) u64 {
    return @as(u64, cp) | (@as(u64, @intFromBool(color)) << 32);
}

/// Bumped whenever the preferred families change, so callers caching a
/// measured width know it is stale.
pub var font_generation: u32 = 0;

/// Use `theme.font` / `theme.mono_font` as the primary face when Fontconfig
/// can resolve them. Bundled names, empty names, and unknown families keep
/// the embedded Manrope / JetBrains Mono as primary.
pub fn setPreferredFamilies(sans: []const u8, mono: []const u8) void {
    const new_sans = sans[0..@min(sans.len, sans_name_buf.len)];
    const new_mono = mono[0..@min(mono.len, mono_name_buf.len)];
    if (std.mem.eql(u8, preferredSans(), new_sans) and std.mem.eql(u8, preferredMono(), new_mono))
        return;
    @memcpy(sans_name_buf[0..new_sans.len], new_sans);
    sans_name_len = new_sans.len;
    @memcpy(mono_name_buf[0..new_mono.len], new_mono);
    mono_name_len = new_mono.len;
    for (&chains) |*ch| ch.clearRetainingCapacity();
    clearRunCache();
    font_generation +%= 1;
}

/// Releases every face and cache at compositor exit, so a Debug build's leak
/// report shows only real leaks. Text still works afterwards: it reloads lazily.
pub fn deinit() void {
    clearRunCache();
    run_cache.deinit(gpa);
    run_cache = .empty;
    var glyphs = glyph_cache.valueIterator();
    while (glyphs.next()) |glyph| if (glyph.pixels.len > 0) gpa.free(glyph.pixels);
    glyph_cache.deinit(gpa);
    glyph_cache = .empty;
    coverage.deinit(gpa);
    coverage = .empty;
    for (&chains) |*ch| {
        ch.deinit(gpa);
        ch.* = .empty;
    }
    for (faces.items) |*face| {
        for (face.sizes[0..face.size_count]) |slot| c.hb_font_destroy(slot.hb_font);
        if (face.ft_face != null) _ = c.FT_Done_Face(face.ft_face);
        switch (face.source) {
            .file => |file| gpa.free(file.path),
            .bundled => {},
        }
    }
    faces.deinit(gpa);
    faces = .empty;
    if (ft_library != null) _ = c.FT_Done_FreeType(ft_library);
    ft_library = null;
    font_generation +%= 1;
}

fn ensureLibrary() !void {
    if (ft_library == null and c.FT_Init_FreeType(&ft_library) != 0) return error.FreeTypeInitFailed;
}

fn ensureFaceTable() void {
    if (faces.items.len >= 4) return;
    const fonts = [_]Font{ .manrope, .manrope_bold, .mono, .mono_bold };
    for (fonts) |font| {
        faces.append(gpa, .{
            .source = .{ .bundled = font },
            .weight = bundledWeight(font),
        }) catch return;
    }
}

fn chainAppend(font: Font, id: u32) void {
    const ch = &chains[@intFromEnum(font)];
    for (ch.items) |existing| if (existing == id) return;
    ch.append(gpa, id) catch {};
}

fn ensureChain(font: Font) void {
    ensureFaceTable();
    const idx = @intFromEnum(font);
    if (chains[idx].items.len != 0) return;

    const preferred = switch (font) {
        .manrope, .manrope_bold => preferredSans(),
        .mono, .mono_bold => preferredMono(),
    };
    const weight = bundledWeight(font);
    if (preferred.len > 0 and !font_fallback.isBundledFamily(preferred)) {
        if (font_fallback.matchFamily(gpa, preferred, weight)) |cand| {
            chainAppend(font, internFileFace(cand, weight));
        }
    }
    chainAppend(font, idx);
}

fn primaryId(font: Font) u32 {
    ensureChain(font);
    const items = chains[@intFromEnum(font)].items;
    return if (items.len == 0) @intFromEnum(font) else items[0];
}

fn internFileFace(cand: font_fallback.Candidate, weight: u32) u32 {
    for (faces.items, 0..) |f, i| {
        switch (f.source) {
            .file => |file| {
                if (file.index == cand.index and f.weight == weight and std.mem.eql(u8, file.path, cand.path)) {
                    cand.deinit(gpa);
                    return @intCast(i);
                }
            },
            .bundled => {},
        }
    }
    const path = cand.path;
    const index = cand.index;
    const color = cand.color;
    cand.discardCharset();
    faces.append(gpa, .{
        .source = .{ .file = .{ .path = path, .index = index } },
        .color = color,
        .weight = weight,
    }) catch {
        gpa.free(path);
        return 0;
    };
    log.debug("fallback face {s}#{d}", .{ path, index });
    return @intCast(faces.items.len - 1);
}

fn ensureLoaded(id: u32) !*Face {
    ensureFaceTable();
    if (id >= faces.items.len) return error.FontLoadFailed;
    const face = &faces.items[id];
    if (face.dead) return error.FontLoadFailed;
    if (face.hb_font != null) return face;
    try ensureLibrary();

    switch (face.source) {
        .bundled => |font| {
            const font_bytes = font.bytes();
            if (c.FT_New_Memory_Face(ft_library, @ptrCast(font_bytes.ptr), @intCast(font_bytes.len), 0, &face.ft_face) != 0) {
                face.dead = true;
                return error.FontLoadFailed;
            }
        },
        .file => |file| {
            if (c.FT_New_Face(ft_library, file.path.ptr, file.index, &face.ft_face) != 0) {
                face.dead = true;
                return error.FontLoadFailed;
            }
        },
    }
    errdefer {
        _ = c.FT_Done_Face(face.ft_face);
        face.ft_face = null;
        face.set_size = 0;
    }
    selectWeight(face.ft_face, face.weight);
    // hb-ft requires an initialized face size at construction.
    if (c.FT_Set_Char_Size(face.ft_face, 0, 64, 72, 72) != 0) {
        if (face.ft_face.*.num_fixed_sizes > 0) {
            _ = c.FT_Select_Size(face.ft_face, 0);
        } else return error.FontSizeFailed;
    }
    face.set_size = 64;
    const flags: c_int = if (face.color) color_load_flags else load_flags;
    // Initialize the variable font's lazy metrics before hb-ft caches its
    // first advance. Otherwise Manrope's first shaped glyph can get a
    // rounded fallback advance while later calls get fractional metrics.
    _ = c.FT_Load_Glyph(face.ft_face, 0, flags);
    const hb_font = c.hb_ft_font_create_referenced(face.ft_face) orelse return error.HarfBuzzFontFailed;
    c.hb_ft_font_set_load_flags(hb_font, flags);
    face.sizes[0] = .{ .size = 64, .ft_size = face.ft_face.*.size, .hb_font = hb_font, .used = 0 };
    face.size_count = 1;
    face.hb_font = hb_font;
    return face;
}

fn ensureFace(font: Font) !*Face {
    ensureFaceTable();
    return ensureLoaded(@intFromEnum(font));
}

fn faceHasChar(id: u32, cp: u32) bool {
    ensureFaceTable();
    if (id >= faces.items.len) return false;
    const face = &faces.items[id];
    if (face.dead) return false;
    const loaded = ensureLoaded(id) catch return false;
    return c.FT_Get_Char_Index(loaded.ft_face, cp) != 0;
}

fn findAndIntern(font: Font, cp: u32, color: bool) ?u32 {
    const cand = font_fallback.findCovering(gpa, genericFamilyZ(font), bundledWeight(font), cp, color) orelse return null;
    return internFileFace(cand, bundledWeight(font));
}

fn resolveChar(font: Font, cp: u32, want_color: bool) u32 {
    const primary = primaryId(font);
    if (want_color) {
        if (coverage.get(coverageKey(cp, true))) |id| {
            if (id != no_face) return id;
        } else if (findAndIntern(font, cp, true)) |id| {
            coverage.put(gpa, coverageKey(cp, true), id) catch {};
            return id;
        } else {
            coverage.put(gpa, coverageKey(cp, true), no_face) catch {};
        }
    }
    if (faceHasChar(primary, cp)) return primary;
    if (coverage.get(coverageKey(cp, false))) |id| {
        return if (id == no_face) primary else id;
    }
    if (findAndIntern(font, cp, false)) |id| {
        coverage.put(gpa, coverageKey(cp, false), id) catch {};
        return id;
    }
    coverage.put(gpa, coverageKey(cp, false), no_face) catch {};
    return primary;
}

const wght_tag: c.FT_ULong = (@as(c.FT_ULong, 'w') << 24) | (@as(c.FT_ULong, 'g') << 16) | (@as(c.FT_ULong, 'h') << 8) | @as(c.FT_ULong, 't');

// Manrope ships as a variable font whose fvar default (and OS/2 usWeightClass)
// is 200 (ExtraLight), not 400 (Regular). Left alone, FreeType instantiates
// that hairline-thin default, which is what made the compositor-drawn chrome
// (titlebars, control center, taskbar chip titles) look faint and blurry
// next to the statically-hinted JetBrains Mono clock. Pin variable axes to
// the requested design weight (400 for regular, 600 for bold/semibold);
// harmless no-op for the static mono faces.
fn selectWeight(face: c.FT_Face, target_weight: u32) void {
    var mm_var: [*c]c.FT_MM_Var = null;
    if (c.FT_Get_MM_Var(face, &mm_var) != 0) return;
    defer _ = c.FT_Done_MM_Var(ft_library, mm_var);

    var coords: [16]c.FT_Fixed = undefined;
    const num_axis = @min(@as(usize, mm_var.*.num_axis), coords.len);
    for (0..num_axis) |i| {
        const axis = mm_var.*.axis[i];
        coords[i] = if (axis.tag == wght_tag) @as(c.FT_Fixed, @as(i32, @intCast(target_weight)) << 16) else axis.def;
    }
    _ = c.FT_Set_Var_Design_Coordinates(face, @intCast(num_axis), &coords);
}

fn applySize(face: *Face, size: c.FT_F26Dot6) !void {
    if (face.set_size == size and face.hb_font != null) return;
    size_clock +%= 1;
    for (face.sizes[0..face.size_count]) |*slot| if (slot.size == size) {
        if (c.FT_Activate_Size(slot.ft_size) != 0) return error.FontSizeFailed;
        slot.used = size_clock;
        face.hb_font = slot.hb_font;
        face.set_size = size;
        return;
    };

    const previous = face.ft_face.*.size;
    var ft_size: c.FT_Size = null;
    if (c.FT_New_Size(face.ft_face, &ft_size) != 0) return error.FontSizeFailed;
    errdefer {
        _ = c.FT_Done_Size(ft_size);
        _ = c.FT_Activate_Size(previous);
    }
    if (c.FT_Activate_Size(ft_size) != 0) return error.FontSizeFailed;
    try setCharSize(face, size);
    const flags: c_int = if (face.color) color_load_flags else load_flags;
    // Same lazy-metrics warmup as ensureLoaded, at the size we will shape.
    _ = c.FT_Load_Glyph(face.ft_face, 0, flags);
    const hb_font = c.hb_ft_font_create_referenced(face.ft_face) orelse return error.HarfBuzzFontFailed;
    c.hb_ft_font_set_load_flags(hb_font, flags);

    const slot_index = if (face.size_count < size_slots) blk: {
        face.size_count += 1;
        break :blk face.size_count - 1;
    } else blk: {
        // The new size is active, so every stored one is safe to discard.
        var oldest: usize = 0;
        for (face.sizes[1..], 1..) |slot, i| {
            if (slot.used < face.sizes[oldest].used) oldest = i;
        }
        c.hb_font_destroy(face.sizes[oldest].hb_font);
        _ = c.FT_Done_Size(face.sizes[oldest].ft_size);
        break :blk oldest;
    };
    face.sizes[slot_index] = .{ .size = size, .ft_size = ft_size, .hb_font = hb_font, .used = size_clock };
    face.hb_font = hb_font;
    face.set_size = size;
}

fn setCharSize(face: *Face, size: c.FT_F26Dot6) !void {
    if (c.FT_Set_Char_Size(face.ft_face, 0, size, 72, 72) != 0) {
        if (face.ft_face.*.num_fixed_sizes > 0) {
            var best: i32 = 0;
            var best_diff: i32 = std.math.maxInt(i32);
            const want: i32 = @intCast(@divTrunc(size, 64));
            const n: usize = @intCast(face.ft_face.*.num_fixed_sizes);
            for (0..n) |i| {
                const h: i32 = face.ft_face.*.available_sizes[i].height;
                const diff: i32 = @intCast(@abs(h - want));
                if (diff < best_diff) {
                    best_diff = diff;
                    best = @intCast(i);
                }
            }
            if (c.FT_Select_Size(face.ft_face, best) != 0) return error.FontSizeFailed;
        } else return error.FontSizeFailed;
    }
}

fn setSize(font: Font, size_px: f32, scale: f32) !*Face {
    const face = try ensureLoaded(primaryId(font));
    try applySize(face, size26(size_px, scale));
    return face;
}

fn metricScale(face: *Face, requested: c.FT_F26Dot6) f32 {
    // Outline faces are sized in 26.6 already. Color bitmap strikes (Noto
    // Color Emoji is typically one 109px CBDT strike) report that strike's
    // ppem; scale advances down to the requested size so the emoji sits in
    // the title rather than overflowing it.
    if (!face.color) return 1;
    const ppem = face.ft_face.*.size.*.metrics.y_ppem;
    if (ppem == 0) return 1;
    const want = @as(f32, @floatFromInt(requested)) / 64.0;
    const have = @as(f32, @floatFromInt(ppem));
    if (@abs(want - have) < 0.5) return 1;
    return want / have;
}

fn scaledMetric(value: i32, scale: f32) i32 {
    if (scale == 1) return value;
    return @intFromFloat(@round(@as(f32, @floatFromInt(value)) * scale));
}

const Shaped = struct {
    buffer: *c.hb_buffer_t,
    infos: [*]const c.hb_glyph_info_t,
    positions: [*]const c.hb_glyph_position_t,
    count: usize,
    width: i32,

    fn deinit(shaped: Shaped) void {
        c.hb_buffer_destroy(shaped.buffer);
    }
};

fn shape(face: *Face, utf8: []const u8) !Shaped {
    const buffer = c.hb_buffer_create() orelse return error.HarfBuzzBufferFailed;
    errdefer c.hb_buffer_destroy(buffer);
    c.hb_buffer_add_utf8(buffer, utf8.ptr, @intCast(utf8.len), 0, @intCast(utf8.len));
    c.hb_buffer_guess_segment_properties(buffer);
    const dir = c.hb_buffer_get_direction(buffer);
    const hb_font = face.hb_font orelse return error.HarfBuzzFontFailed;
    c.hb_shape(hb_font, buffer, null, 0);
    // A single RTL run (an Arabic title) is reversed into visual order so
    // the LTR pen in `draw` places letters correctly. Mixed-direction bidi
    // reordering of adjacent runs is still out of scope.
    if (dir == c.HB_DIRECTION_RTL) c.hb_buffer_reverse(buffer);

    var info_count: c_uint = 0;
    var position_count: c_uint = 0;
    const infos = c.hb_buffer_get_glyph_infos(buffer, &info_count) orelse return error.ShapeFailed;
    const positions = c.hb_buffer_get_glyph_positions(buffer, &position_count) orelse return error.ShapeFailed;
    const count: usize = @intCast(@min(info_count, position_count));
    var width: i32 = 0;
    for (positions[0..count]) |position| width += position.x_advance;
    return .{ .buffer = buffer, .infos = infos, .positions = positions, .count = count, .width = width };
}

fn nextCodepoint(bytes: []const u8, i: *usize) ?u21 {
    if (i.* >= bytes.len) return null;
    const n = std.unicode.utf8ByteSequenceLength(bytes[i.*]) catch {
        i.* += 1;
        return null;
    };
    if (i.* + n > bytes.len) {
        i.* = bytes.len;
        return null;
    }
    const cp = std.unicode.utf8Decode(bytes[i.*..][0..n]) catch {
        i.* += 1;
        return null;
    };
    i.* += n;
    return cp;
}

fn isRegionalIndicator(cp: u21) bool {
    return cp >= 0x1F1E6 and cp <= 0x1F1FF;
}

fn isSkinTone(cp: u21) bool {
    return cp >= 0x1F3FB and cp <= 0x1F3FF;
}

fn isVariationSelector(cp: u21) bool {
    return (cp >= 0xFE00 and cp <= 0xFE0F) or (cp >= 0xE0100 and cp <= 0xE01EF);
}

fn isMark(cp: u21) bool {
    const cat = c.hb_unicode_general_category(c.hb_unicode_funcs_get_default(), cp);
    return cat == c.HB_UNICODE_GENERAL_CATEGORY_NON_SPACING_MARK or
        cat == c.HB_UNICODE_GENERAL_CATEGORY_SPACING_MARK or
        cat == c.HB_UNICODE_GENERAL_CATEGORY_ENCLOSING_MARK;
}

fn consumeExtenders(bytes: []const u8, start: usize) usize {
    var i = start;
    while (i < bytes.len) {
        var j = i;
        const cp = nextCodepoint(bytes, &j) orelse break;
        if (isMark(cp) or isVariationSelector(cp) or isSkinTone(cp) or cp == 0x20E3) {
            i = j;
            continue;
        }
        break;
    }
    return i;
}

/// End of the grapheme cluster starting at `start`. ZWJ emoji sequences and
/// flag pairs stay together so HarfBuzz can ligate them on one face.
fn nextClusterEnd(bytes: []const u8, start: usize) usize {
    if (start >= bytes.len) return bytes.len;
    var i = start;
    const first = nextCodepoint(bytes, &i) orelse return @min(start + 1, bytes.len);

    if (isRegionalIndicator(first)) {
        const saved = i;
        if (nextCodepoint(bytes, &i)) |second| {
            if (!isRegionalIndicator(second)) i = saved;
        } else i = saved;
        return consumeExtenders(bytes, i);
    }

    i = consumeExtenders(bytes, i);
    while (i < bytes.len) {
        var j = i;
        const cp = nextCodepoint(bytes, &j) orelse break;
        if (cp != 0x200D) break;
        i = j;
        if (i >= bytes.len) break;
        _ = nextCodepoint(bytes, &i);
        i = consumeExtenders(bytes, i);
    }
    return i;
}

fn clusterBase(bytes: []const u8) ?u32 {
    var i: usize = 0;
    while (i < bytes.len) {
        const cp = nextCodepoint(bytes, &i) orelse break;
        if (cp == 0x200D or isMark(cp) or isVariationSelector(cp) or isSkinTone(cp)) continue;
        return cp;
    }
    return null;
}

fn clusterWantsColor(bytes: []const u8) bool {
    var i: usize = 0;
    var vs16 = false;
    var pictographic = false;
    while (i < bytes.len) {
        const cp = nextCodepoint(bytes, &i) orelse break;
        if (cp == 0xFE0F) vs16 = true;
        if (cp >= 0x1F000 and cp <= 0x1FFFF) pictographic = true;
    }
    return pictographic or vs16;
}

fn previousUtf8Boundary(bytes: []const u8, end: usize) usize {
    if (end == 0) return 0;
    var start = end - 1;
    while (start > 0 and (bytes[start] & 0xc0) == 0x80) : (start -= 1) {}
    return start;
}

/// One shaped glyph, kept independently of the HarfBuzz buffer it came from.
/// `cluster` is the byte offset in the source string, which is what lets a
/// run be truncated without re-shaping prefixes to find the cut.
const RunGlyph = struct {
    face: u32,
    index: u32,
    cluster: u32,
    x_advance: i32,
    y_advance: i32,
    x_offset: i32,
    y_offset: i32,
};

const Run = struct {
    glyphs: []const RunGlyph,
    width: i32,
};

const RunKey = struct { font: Font, size: c.FT_F26Dot6, text: []const u8 };

const RunKeyContext = struct {
    pub fn hash(_: RunKeyContext, key: RunKey) u64 {
        var hasher = std.hash.Wyhash.init(@intFromEnum(key.font));
        hasher.update(std.mem.asBytes(&key.size));
        hasher.update(key.text);
        return hasher.final();
    }
    pub fn eql(_: RunKeyContext, a: RunKey, b: RunKey) bool {
        return a.font == b.font and a.size == b.size and std.mem.eql(u8, a.text, b.text);
    }
};

/// Shaping is pure: the same string at the same size always produces the same
/// glyphs. The shell redraws whole panels every frame from the same handful of
/// strings, so without this every frame paid HarfBuzz (and a buffer malloc)
/// for text that had not changed.
var run_cache: std.HashMapUnmanaged(RunKey, Run, RunKeyContext, std.hash_map.default_max_load_percentage) = .empty;

/// Bounded because window and app titles are content, not a fixed set; past
/// this the whole cache is dropped rather than evicted one by one, which for
/// a redraw cache costs one re-shape per live string. The one caveat that
/// buys: a `Run`'s glyphs are owned by the cache, so a caller must not hold
/// one across a later `shapedRun` call (`draw` re-fetches after fitting, and
/// `fitWithEllipsis` is done with its run before it shapes candidates).
const max_cached_runs = 4096;

const GlyphKey = struct { face: u32, size: c.FT_F26Dot6, index: u32 };

/// A rendered glyph, copied out of FreeType's own slot (which the next
/// FT_Load_Glyph would overwrite). `pixels` is 8-bit coverage, `cols` wide,
/// unless `color` in which case it is premul BGRA. An empty one records a
/// glyph with no ink so it isn't re-rendered.
const CachedGlyph = struct {
    pixels: []const u8,
    cols: i32,
    rows: i32,
    left: i32,
    top: i32,
    color: bool = false,
};

var glyph_cache: std.AutoHashMapUnmanaged(GlyphKey, CachedGlyph) = .empty;

fn clearRunCache() void {
    var it = run_cache.iterator();
    while (it.next()) |entry| {
        gpa.free(entry.key_ptr.text);
        gpa.free(entry.value_ptr.glyphs);
    }
    run_cache.clearRetainingCapacity();
}

fn shapedRun(font: Font, size: c.FT_F26Dot6, utf8: []const u8) !Run {
    const key = RunKey{ .font = font, .size = size, .text = utf8 };
    if (run_cache.getContext(key, .{})) |cached| return cached;

    const run = try uncachedRun(font, size, utf8);

    if (run_cache.count() >= max_cached_runs) clearRunCache();
    const owned = gpa.dupe(u8, utf8) catch return run; // usable now, just not cached
    run_cache.putContext(gpa, .{ .font = font, .size = size, .text = owned }, run, .{}) catch {
        gpa.free(owned);
    };
    return run;
}

fn appendShaped(
    glyphs: *std.ArrayListUnmanaged(RunGlyph),
    face_id: u32,
    face: *Face,
    utf8: []const u8,
    byte_start: u32,
    size: c.FT_F26Dot6,
) !i32 {
    try applySize(face, size);
    const shaped = try shape(face, utf8);
    defer shaped.deinit();
    const scale = metricScale(face, size);
    try glyphs.ensureUnusedCapacity(gpa, shaped.count);
    var width: i32 = 0;
    for (shaped.infos[0..shaped.count], shaped.positions[0..shaped.count]) |info, position| {
        const glyph = RunGlyph{
            .face = face_id,
            .index = info.codepoint,
            .cluster = info.cluster + byte_start,
            .x_advance = scaledMetric(position.x_advance, scale),
            .y_advance = scaledMetric(position.y_advance, scale),
            .x_offset = scaledMetric(position.x_offset, scale),
            .y_offset = scaledMetric(position.y_offset, scale),
        };
        glyphs.appendAssumeCapacity(glyph);
        width += glyph.x_advance;
    }
    return width;
}

// Password reveal must never retain a whole password in the shaping cache.
fn uncachedRun(font: Font, size: c.FT_F26Dot6, utf8: []const u8) !Run {
    ensureChain(font);
    var glyphs: std.ArrayListUnmanaged(RunGlyph) = .empty;
    errdefer glyphs.deinit(gpa);

    var width: i32 = 0;
    var i: usize = 0;
    var run_start: usize = 0;
    var run_face: ?u32 = null;
    while (i < utf8.len) {
        const end = nextClusterEnd(utf8, i);
        const cluster = utf8[i..end];
        const base = clusterBase(cluster) orelse ' ';
        const face_id = resolveChar(font, base, clusterWantsColor(cluster));
        if (run_face) |current| {
            if (face_id != current) {
                const loaded = try ensureLoaded(current);
                width += try appendShaped(&glyphs, current, loaded, utf8[run_start..i], @intCast(run_start), size);
                run_start = i;
            }
        }
        run_face = face_id;
        i = end;
    }
    if (run_face) |current| {
        const loaded = try ensureLoaded(current);
        width += try appendShaped(&glyphs, current, loaded, utf8[run_start..utf8.len], @intCast(run_start), size);
    }
    return Run{ .glyphs = try glyphs.toOwnedSlice(gpa), .width = width };
}

fn clearSensitiveRun(run: Run) void {
    std.crypto.secureZero(u8, std.mem.sliceAsBytes(@constCast(run.glyphs)));
    gpa.free(run.glyphs);
}

pub fn measureSensitiveWidth(utf8: []const u8, font: Font, size_px: f32, scale: f32) !f32 {
    _ = try setSize(font, size_px, scale);
    const run = try uncachedRun(font, size26(size_px, scale), utf8);
    defer clearSensitiveRun(run);
    return @as(f32, @floatFromInt(run.width)) / 64.0 / scale;
}

fn copyBitmapRows(bitmap: c.FT_Bitmap, cols: i32, rows: i32, bpp: i32) ?[]u8 {
    if (cols <= 0 or rows <= 0) return null;
    const count: usize = @intCast(cols * rows * bpp);
    const copy = gpa.alloc(u8, count) catch return null;
    const pitch: i32 = bitmap.pitch;
    var row: i32 = 0;
    while (row < rows) : (row += 1) {
        // A negative pitch means FreeType handed back a bottom-up bitmap;
        // either way row 0 of the copy is the top row.
        const source_offset = @as(isize, row) * @as(isize, pitch);
        const source: [*]const u8 = @ptrCast(bitmap.buffer + @as(usize, @intCast(if (pitch < 0) source_offset + @as(isize, rows - 1) * -@as(isize, pitch) else source_offset)));
        const dest_off: usize = @intCast(row * cols * bpp);
        @memcpy(copy[dest_off..][0..@intCast(cols * bpp)], source[0..@intCast(cols * bpp)]);
    }
    return copy;
}

fn scaleBgra(src: []const u8, src_w: i32, src_h: i32, dst_w: i32, dst_h: i32) ?[]u8 {
    const sw: usize = @intCast(src_w);
    const sh: usize = @intCast(src_h);
    const dw: usize = @intCast(dst_w);
    const dh: usize = @intCast(dst_h);
    const dst = gpa.alloc(u8, dw * dh * 4) catch return null;
    if (src_w == dst_w and src_h == dst_h) {
        @memcpy(dst, src[0 .. dw * dh * 4]);
        return dst;
    }
    var y: usize = 0;
    while (y < dh) : (y += 1) {
        const sy = @as(f32, @floatFromInt(y)) * @as(f32, @floatFromInt(src_h)) / @as(f32, @floatFromInt(dst_h));
        const y0: usize = @min(@as(usize, @intFromFloat(@floor(sy))), sh - 1);
        const y1: usize = @min(y0 + 1, sh - 1);
        const fy = sy - @as(f32, @floatFromInt(y0));
        var x: usize = 0;
        while (x < dw) : (x += 1) {
            const sx = @as(f32, @floatFromInt(x)) * @as(f32, @floatFromInt(src_w)) / @as(f32, @floatFromInt(dst_w));
            const x0: usize = @min(@as(usize, @intFromFloat(@floor(sx))), sw - 1);
            const x1: usize = @min(x0 + 1, sw - 1);
            const fx = sx - @as(f32, @floatFromInt(x0));
            const dst_i = (y * dw + x) * 4;
            var ch: usize = 0;
            while (ch < 4) : (ch += 1) {
                const s00 = @as(f32, @floatFromInt(src[(y0 * sw + x0) * 4 + ch]));
                const s10 = @as(f32, @floatFromInt(src[(y0 * sw + x1) * 4 + ch]));
                const s01 = @as(f32, @floatFromInt(src[(y1 * sw + x0) * 4 + ch]));
                const s11 = @as(f32, @floatFromInt(src[(y1 * sw + x1) * 4 + ch]));
                const v = s00 * (1 - fx) * (1 - fy) + s10 * fx * (1 - fy) + s01 * (1 - fx) * fy + s11 * fx * fy;
                dst[dst_i + ch] = @intFromFloat(@max(0, @min(v + 0.5, 255)));
            }
        }
    }
    return dst;
}

fn glyphBitmap(face: *Face, face_id: u32, index: u32) ?CachedGlyph {
    const key = GlyphKey{ .face = face_id, .size = face.set_size, .index = index };
    if (glyph_cache.get(key)) |cached| return cached;

    const flags: c_int = if (face.color) color_load_flags else load_flags;
    if (c.FT_Load_Glyph(face.ft_face, index, flags) != 0) return null;
    if (c.FT_Render_Glyph(face.ft_face.*.glyph, c.FT_RENDER_MODE_NORMAL) != 0) return null;

    const glyph_slot = face.ft_face.*.glyph;
    const bitmap = glyph_slot.*.bitmap;
    const cols: i32 = @intCast(bitmap.width);
    const rows: i32 = @intCast(bitmap.rows);

    var pixels: []u8 = &.{};
    var out_cols = cols;
    var out_rows = rows;
    var out_left = glyph_slot.*.bitmap_left;
    var out_top = glyph_slot.*.bitmap_top;
    var is_color = false;

    if (bitmap.pixel_mode == c.FT_PIXEL_MODE_BGRA and cols > 0 and rows > 0) {
        const src = copyBitmapRows(bitmap, cols, rows, 4) orelse return null;
        is_color = true;
        const want_px: i32 = @max(1, @as(i32, @intCast(@divTrunc(face.set_size + 32, 64))));
        if (rows != want_px) {
            const dst_h = want_px;
            const dst_w: i32 = @max(1, @divTrunc(cols * want_px, rows));
            if (scaleBgra(src, cols, rows, dst_w, dst_h)) |scaled| {
                gpa.free(src);
                pixels = scaled;
                out_cols = dst_w;
                out_rows = dst_h;
                out_left = @divTrunc(glyph_slot.*.bitmap_left * dst_w, cols);
                out_top = @divTrunc(glyph_slot.*.bitmap_top * dst_h, rows);
            } else {
                pixels = src;
            }
        } else {
            pixels = src;
        }
    } else if (bitmap.pixel_mode == c.FT_PIXEL_MODE_GRAY and cols > 0 and rows > 0) {
        pixels = copyBitmapRows(bitmap, cols, rows, 1) orelse &.{};
    }

    const cached = CachedGlyph{
        .pixels = pixels,
        .cols = if (pixels.len == 0) 0 else out_cols,
        .rows = if (pixels.len == 0) 0 else out_rows,
        .left = out_left,
        .top = out_top,
        .color = is_color,
    };
    glyph_cache.put(gpa, key, cached) catch {
        if (pixels.len > 0) gpa.free(pixels);
        return .{ .pixels = &.{}, .cols = 0, .rows = 0, .left = cached.left, .top = cached.top };
    };
    return cached;
}

/// Prepare common UI glyphs without drawing. Call on the compositor thread:
/// FreeType slots and these caches are shared with normal rendering.
pub fn warmGlyphs(font: Font, size_px: f32, scale: f32, chars: []const u8) !void {
    const size = size26(size_px, scale);
    _ = try setSize(font, size_px, scale);
    const run = try shapedRun(font, size, chars);
    for (run.glyphs) |glyph| {
        const face = ensureLoaded(glyph.face) catch continue;
        applySize(face, size) catch continue;
        _ = glyphBitmap(face, glyph.face, glyph.index);
    }
}

/// Longest prefix of `utf8` that fits in `available_26_6` with an ellipsis
/// appended, written into `storage`. The cut point comes from walking the
/// already-shaped run's advances rather than re-shaping every prefix, so a
/// long client-supplied title costs one extra shaping, not one per character.
fn fitWithEllipsis(font: Font, size: c.FT_F26Dot6, utf8: []const u8, available_26_6: i32, storage: []u8) ![]const u8 {
    const ellipsis = "\u{2026}";
    const dots = try shapedRun(font, size, ellipsis);
    if (dots.width > available_26_6) return "";

    const limit = @min(utf8.len, storage.len - ellipsis.len);
    const full = try shapedRun(font, size, utf8[0..limit]);

    var budget = available_26_6 - dots.width;
    var cut: usize = limit;
    for (full.glyphs) |glyph| {
        if (budget < glyph.x_advance) {
            cut = @min(@as(usize, glyph.cluster), limit);
            break;
        }
        budget -= glyph.x_advance;
    }

    // Shaping the prefix can differ slightly from the advances measured in
    // the middle of a run (kerning at the new boundary), so confirm the cut
    // and step back a character at a time if it still overflows.
    var attempts: usize = 0;
    while (attempts < 8) : (attempts += 1) {
        const candidate_len = cut + ellipsis.len;
        @memcpy(storage[0..cut], utf8[0..cut]);
        @memcpy(storage[cut..candidate_len], ellipsis);
        const candidate = try shapedRun(font, size, storage[0..candidate_len]);
        if (candidate.width <= available_26_6 or cut == 0) return storage[0..candidate_len];
        cut = previousUtf8Boundary(utf8, cut);
    }
    @memcpy(storage[0..ellipsis.len], ellipsis);
    return storage[0..ellipsis.len];
}

// Logical-pixel width the text would take if drawn with draw(), for callers
// that need to right-align or center a run (the taskbar clock).
pub fn measureWidth(utf8: []const u8, font: Font, size_px: f32, scale: f32) !i32 {
    return @intFromFloat(@ceil(try measureWidthF(utf8, font, size_px, scale)));
}

// Unrounded logical-pixel advance of a run. `measureWidth` ceils this to a
// whole pixel, which is right for laying a box out around text but wrong for
// positioning something *inside* the run: a text caret placed at the ceiled
// prefix width drifts up to a pixel right of the glyph it sits before, and
// the drift changes with every keystroke. Callers that need the pen position
// rather than a box size want this one.
pub fn measureWidthF(utf8: []const u8, font: Font, size_px: f32, scale: f32) !f32 {
    if (utf8.len == 0) return 0;
    _ = try setSize(font, size_px, scale);
    const run = try shapedRun(font, size26(size_px, scale), utf8);
    return @as(f32, @floatFromInt(run.width)) / 64.0 / scale;
}

/// Byte offset in `utf8` nearest to `target_px` logical pixels from the start
/// of the run — the inverse of `measureWidthF`, for turning a click into a
/// caret position. The run is shaped once and walked, so clusters and
/// ligatures land on real boundaries rather than on a byte count; the point is
/// compared against each glyph's midpoint, which is what makes clicking the
/// right half of a character put the caret after it.
///
/// Assumes a left-to-right run, like everything else here: `draw` advances one
/// pen in one direction and `text.zig` has no bidi.
pub fn offsetAtX(utf8: []const u8, font: Font, size_px: f32, scale: f32, target_px: f32) !usize {
    if (utf8.len == 0 or target_px <= 0) return 0;
    _ = try setSize(font, size_px, scale);
    const run = try shapedRun(font, size26(size_px, scale), utf8);
    const target = target_px * 64.0 * scale;
    var pen: f32 = 0;
    for (run.glyphs) |glyph| {
        const advance: f32 = @floatFromInt(glyph.x_advance);
        if (target < pen + advance / 2) return @min(glyph.cluster, utf8.len);
        pen += advance;
    }
    return utf8.len;
}

/// Logical-pixel vertical extent of a face at a size, both positive and
/// measured from the baseline. `draw` centers `ascent + descent` in its box,
/// so anything that has to line up with drawn text vertically — a caret, a
/// selection highlight, an underline — must be derived from these rather
/// than from a multiple of the font size, which is a different number for
/// every face.
pub const VMetrics = struct { ascent: f32, descent: f32 };

pub fn verticalMetrics(font: Font, size_px: f32, scale: f32) !VMetrics {
    const slot = try setSize(font, size_px, scale);
    const metrics = slot.ft_face.*.size.*.metrics;
    return .{
        .ascent = @as(f32, @floatFromInt(metrics.ascender)) / 64.0 / scale,
        .descent = @as(f32, @floatFromInt(-metrics.descender)) / 64.0 / scale,
    };
}

// Logical-pixel line height (ascender - descender) for callers that need to
// size a box around text without drawing it yet (ui/measure.zig).
pub fn lineHeight(font: Font, size_px: f32, scale: f32) !f32 {
    const slot = try setSize(font, size_px, scale);
    const metrics = slot.ft_face.*.size.*.metrics;
    const height_26_6 = metrics.ascender - metrics.descender;
    return @as(f32, @floatFromInt(height_26_6)) / 64.0 / scale;
}

pub fn draw(
    pixels: []u32,
    width: i32,
    height: i32,
    rect: Rect,
    utf8: []const u8,
    color: Color,
    scale: f32,
    font: Font,
    size_px: f32,
) !void {
    return drawOpts(pixels, width, height, utf8, color, scale, font, size_px, .{ .rect = rect });
}

/// `rect` places the pen and baseline; `clip` (defaulting to `rect`) bounds
/// which pixels may be touched. Keeping the two separate is what lets a text
/// field scroll horizontally: the run is laid out from an origin left of the
/// field — a negative `rect.x` — while only the field's own pixels are
/// written. Passing `rect` as the clip, which `draw` does, would instead slide
/// the text back to the clip's left edge and show its beginning again.
pub const DrawOptions = struct {
    rect: Rect,
    clip: ?Rect = null,
    /// Additional buffer-pixel scissor, independent of pen layout and logical
    /// clipping. Damage edges use floor/ceil, not text placement's rounding.
    device_clip: ?Rect = null,
    /// Replace an overlong run with one ellipsized to fit `rect`. A scrolling
    /// field wants this off — it shows the overflow by moving, not by cutting.
    ellipsize: bool = true,
    /// Do not cache text or glyph sequences; disables ellipsizing.
    sensitive: bool = false,
    /// Center the visible glyph bounds rather than the font line metrics.
    /// For standalone labels; editable fields retain their stable baseline.
    center_ink: bool = false,
    /// Buffer-pixel row of the baseline, instead of centring the line in
    /// `rect`: for callers that place text by baseline (the Cairo clients,
    /// through ui/cairo.zig).
    baseline: ?i32 = null,
};

pub fn drawOpts(
    pixels: []u32,
    width: i32,
    height: i32,
    utf8: []const u8,
    color: Color,
    scale: f32,
    font: Font,
    size_px: f32,
    options: DrawOptions,
) !void {
    const rect = options.rect;
    if (utf8.len == 0 or rect.w <= 0 or rect.h <= 0) return;
    const size = size26(size_px, scale);
    _ = try setSize(font, size_px, scale);

    const x0 = devicePixels(rect.x, scale);
    const y0 = devicePixels(rect.y, scale);
    // Clamped to the buffer, as it always was: the baseline is centred in
    // `y0..y1`, and changing that would move every existing caller's text.
    const y1 = @min(height, devicePixels(rect.y + rect.h, scale));

    const clip = options.clip orelse rect;
    if (clip.w <= 0 or clip.h <= 0) return;
    var clip_x0 = devicePixels(clip.x, scale);
    var clip_y0 = devicePixels(clip.y, scale);
    var clip_x1 = @min(width, devicePixels(clip.x + clip.w, scale));
    var clip_y1 = @min(height, devicePixels(clip.y + clip.h, scale));
    if (options.device_clip) |damage| {
        clip_x0 = @max(clip_x0, damage.x);
        clip_y0 = @max(clip_y0, damage.y);
        clip_x1 = @min(clip_x1, damage.x + damage.w);
        clip_y1 = @min(clip_y1, damage.y + damage.h);
    }
    if (clip_x0 >= clip_x1 or clip_y0 >= clip_y1) return;

    var fitted_storage: [4096]u8 = undefined;
    var run = if (options.sensitive) try uncachedRun(font, size, utf8) else try shapedRun(font, size, utf8);
    defer if (options.sensitive) clearSensitiveRun(run);
    if (options.ellipsize and !options.sensitive) {
        const available = (@min(width, devicePixels(rect.x + rect.w, scale)) - x0) * 64;
        const tolerance: i32 = @as(i32, @intFromFloat(@ceil(scale * 2.0))) * 64;
        if (run.width > available + tolerance) {
            const fitted = try fitWithEllipsis(font, size, utf8, available, &fitted_storage);
            if (fitted.len == 0) return;
            run = try shapedRun(font, size, fitted);
        }
    }

    // Re-fetch after shaping: fallback intern can grow `faces` and move the
    // primary Face that `setSize` returned.
    const slot = try ensureLoaded(primaryId(font));
    try applySize(slot, size);
    const metrics = slot.ft_face.*.size.*.metrics;
    const ink_height = metrics.ascender - metrics.descender;
    var baseline = snap26_6(y0 * 64 + @divTrunc((y1 - y0) * 64 - ink_height, 2) + metrics.ascender) * 64;
    if (options.center_ink) {
        if (inkCenteredBaseline(run, size, y0, y1)) |row| baseline = row * 64;
    }
    if (options.baseline) |row| baseline = row * 64;
    var pen_x = x0 * 64;
    var pen_y = baseline;
    for (run.glyphs) |glyph| {
        const face = ensureLoaded(glyph.face) catch {
            pen_x += glyph.x_advance;
            pen_y += glyph.y_advance;
            continue;
        };
        applySize(face, size) catch {
            pen_x += glyph.x_advance;
            pen_y += glyph.y_advance;
            continue;
        };
        if (glyphBitmap(face, glyph.face, glyph.index)) |bitmap| {
            // Keep the accumulated pen fractional to avoid spacing drift;
            // snap only the final bitmap placement to the nearest pixel.
            const origin_x = snap26_6(pen_x + glyph.x_offset) + bitmap.left;
            const origin_y = snap26_6(pen_y - glyph.y_offset) - bitmap.top;
            if (bitmap.cols > 0) {
                if (bitmap.color) {
                    blendColorBitmap(pixels, width, height, clip_x0, clip_y0, clip_x1, clip_y1, origin_x, origin_y, bitmap, color.a);
                } else {
                    blendBitmap(pixels, width, height, clip_x0, clip_y0, clip_x1, clip_y1, origin_x, origin_y, bitmap, color);
                }
            }
        }
        pen_x += glyph.x_advance;
        pen_y += glyph.y_advance;
    }
}

/// Buffer-pixel baseline row that centres the visible glyph bounds of `run`
/// between rows `y0` and `y1`; null when nothing in it has ink.
fn inkCenteredBaseline(run: Run, size: c.FT_F26Dot6, y0: i32, y1: i32) ?i32 {
    var top: i32 = std.math.maxInt(i32);
    var bottom: i32 = std.math.minInt(i32);
    var offset_y: c.FT_Pos = 0;
    for (run.glyphs) |glyph| {
        defer offset_y += glyph.y_advance;
        const face = ensureLoaded(glyph.face) catch continue;
        applySize(face, size) catch continue;
        if (glyphBitmap(face, glyph.face, glyph.index)) |bitmap| {
            if (bitmap.cols == 0 or bitmap.rows == 0) continue;
            const origin_y = snap26_6(offset_y - glyph.y_offset) - bitmap.top;
            top = @min(top, origin_y);
            bottom = @max(bottom, origin_y + bitmap.rows);
        }
    }
    if (top >= bottom) return null;
    return @divFloor(y0 + y1 - top - bottom + 1, 2);
}

/// The `DrawOptions.baseline` that `center_ink` would pick for `sample` in
/// `rect` (which must lie inside the buffer). A line drawn in pieces, such as
/// tabular digits, gives every piece this row: centring each piece on its own
/// ink would lift a colon to mid-height and let a flat "1" sit a row off a
/// round "0".
pub fn inkBaseline(sample: []const u8, font: Font, size_px: f32, scale: f32, rect: Rect) !i32 {
    const size = size26(size_px, scale);
    _ = try setSize(font, size_px, scale);
    const run = try shapedRun(font, size, sample);
    return inkCenteredBaseline(run, size, devicePixels(rect.y, scale), devicePixels(rect.y + rect.h, scale)) orelse error.NoInk;
}

fn snap26_6(value: c.FT_Pos) i32 {
    return @intCast(@divFloor(value + 32, 64));
}

fn blendBitmap(
    pixels: []u32,
    width: i32,
    height: i32,
    clip_x0: i32,
    clip_y0: i32,
    clip_x1: i32,
    clip_y1: i32,
    origin_x: i32,
    origin_y: i32,
    glyph: CachedGlyph,
    color: Color,
) void {
    const x_start = @max(clip_x0, @max(0, origin_x));
    const y_start = @max(clip_y0, @max(0, origin_y));
    const x_end = @min(@min(clip_x1, width), origin_x + glyph.cols);
    const y_end = @min(@min(clip_y1, height), origin_y + glyph.rows);

    var py = y_start;
    while (py < y_end) : (py += 1) {
        const source_row: usize = @intCast((py - origin_y) * glyph.cols);
        var px = x_start;
        while (px < x_end) : (px += 1) {
            const value = glyph.pixels[source_row + @as(usize, @intCast(px - origin_x))];
            if (value == 0) continue;
            blendPixel(&pixels[@intCast(py * width + px)], color, @as(f32, @floatFromInt(value)) / 255.0);
        }
    }
}

fn blendColorBitmap(
    pixels: []u32,
    width: i32,
    height: i32,
    clip_x0: i32,
    clip_y0: i32,
    clip_x1: i32,
    clip_y1: i32,
    origin_x: i32,
    origin_y: i32,
    glyph: CachedGlyph,
    color_a: f32,
) void {
    if (color_a <= 0) return;
    const x_start = @max(clip_x0, @max(0, origin_x));
    const y_start = @max(clip_y0, @max(0, origin_y));
    const x_end = @min(@min(clip_x1, width), origin_x + glyph.cols);
    const y_end = @min(@min(clip_y1, height), origin_y + glyph.rows);

    var py = y_start;
    while (py < y_end) : (py += 1) {
        const source_row: usize = @intCast((py - origin_y) * glyph.cols * 4);
        var px = x_start;
        while (px < x_end) : (px += 1) {
            const off = source_row + @as(usize, @intCast(px - origin_x)) * 4;
            const src_b = glyph.pixels[off];
            const src_g = glyph.pixels[off + 1];
            const src_r = glyph.pixels[off + 2];
            const src_a = glyph.pixels[off + 3];
            if (src_a == 0) continue;
            blendColorPixel(&pixels[@intCast(py * width + px)], src_r, src_g, src_b, src_a, color_a);
        }
    }
}

fn blendColorPixel(destination: *u32, src_r: u8, src_g: u8, src_b: u8, src_a: u8, color_a: f32) void {
    const sa = @as(f32, @floatFromInt(src_a)) / 255.0 * color_a;
    const sr = @as(f32, @floatFromInt(src_r)) / 255.0 * color_a;
    const sg = @as(f32, @floatFromInt(src_g)) / 255.0 * color_a;
    const sb = @as(f32, @floatFromInt(src_b)) / 255.0 * color_a;
    const inverse = 1.0 - sa;
    const value = destination.*;
    const da = @as(f32, @floatFromInt((value >> 24) & 0xff)) / 255.0;
    const dr = @as(f32, @floatFromInt((value >> 16) & 0xff)) / 255.0;
    const dg = @as(f32, @floatFromInt((value >> 8) & 0xff)) / 255.0;
    const db = @as(f32, @floatFromInt(value & 0xff)) / 255.0;
    const a = sa + da * inverse;
    const r = sr + dr * inverse;
    const g = sg + dg * inverse;
    const b = sb + db * inverse;
    destination.* = (byte(a) << 24) | (byte(r) << 16) | (byte(g) << 8) | byte(b);
}

pub inline fn blendPixel(destination: *u32, color: Color, coverage_a: f32) void {
    const value = destination.*;
    const sa = color.a * coverage_a;
    const inverse = 1.0 - sa;
    const da = @as(f32, @floatFromInt((value >> 24) & 0xff)) / 255.0;
    const dr = @as(f32, @floatFromInt((value >> 16) & 0xff)) / 255.0;
    const dg = @as(f32, @floatFromInt((value >> 8) & 0xff)) / 255.0;
    const db = @as(f32, @floatFromInt(value & 0xff)) / 255.0;
    const a = sa + da * inverse;
    const r = color.r * sa + dr * inverse;
    const g = color.g * sa + dg * inverse;
    const b = color.b * sa + db * inverse;
    destination.* = (byte(a) << 24) | (byte(r) << 16) | (byte(g) << 8) | byte(b);
}

// Rounds like @round for the [0,1] inputs this takes, without the call into
// compiler_rt's roundf that @round compiles to on a baseline x86_64 target
// (no SSE4.1 roundss). It runs four times per blended pixel, so that call
// showed up as ~15% of a start menu frame.
inline fn byte(value: f32) u32 {
    return @intFromFloat(@max(0, @min(value, 1)) * 255 + 0.5);
}

fn devicePixels(logical: i32, scale: f32) i32 {
    return @intFromFloat(@round(@as(f32, @floatFromInt(logical)) * scale));
}

test "manrope face selects Regular (400) weight, not the fvar default (200/ExtraLight)" {
    const slot = try ensureFace(.manrope);
    var coords: [1]c.FT_Fixed = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.FT_Get_Var_Design_Coordinates(slot.ft_face, 1, &coords));
    try std.testing.expectEqual(@as(c.FT_Fixed, 400 << 16), coords[0]);
}

test "fractional physical font sizes survive size caching and shaping" {
    setPreferredFamilies("", "");
    const slot = try setSize(.manrope, 13, 1.5);
    const fractional_scale = slot.ft_face.*.size.*.metrics.y_scale;
    const fractional = try shape(slot, "Rendering Settings");
    defer fractional.deinit();
    _ = try setSize(.manrope, 20, 1);
    try std.testing.expect(fractional_scale < slot.ft_face.*.size.*.metrics.y_scale);
    const rounded = try shape(slot, "Rendering Settings");
    defer rounded.deinit();
    try std.testing.expect(fractional.width < rounded.width);

    _ = try setSize(.manrope, 13, 1.5);
    try std.testing.expectEqual(fractional_scale, slot.ft_face.*.size.*.metrics.y_scale);
    const again = try shape(slot, "Rendering Settings");
    defer again.deinit();
    try std.testing.expectEqual(fractional.width, again.width);
    const integral = try setSize(.manrope, 12, 1.5);
    try std.testing.expectEqual(@as(c_ushort, 18), integral.ft_face.*.size.*.metrics.y_ppem);
}

test "text retains grayscale coverage and premultiplied opacity at output scales" {
    setPreferredFamilies("", "");
    for ([_]Font{ .manrope, .mono, .mono_bold }) |font| {
        for ([_]f32{ 1, 1.5, 2 }) |scale| {
            const width = devicePixels(180, scale);
            const height = devicePixels(32, scale);
            const pixels = try std.testing.allocator.alloc(u32, @intCast(width * height));
            defer std.testing.allocator.free(pixels);
            @memset(pixels, 0);
            try draw(pixels, width, height, .{ .x = 1, .y = 1, .w = 178, .h = 30 }, "Aaeg 0123456789", .{ .r = 1, .g = 0.5, .b = 0.25, .a = 0.5 }, scale, font, 13);
            var levels: [129]bool = @splat(false);
            for (pixels) |pixel| {
                const alpha = pixel >> 24;
                const red = (pixel >> 16) & 255;
                const green = (pixel >> 8) & 255;
                const blue = pixel & 255;
                try std.testing.expect(alpha <= 128);
                try std.testing.expectEqual(alpha, red);
                try std.testing.expect(green <= red and blue <= green);
                try std.testing.expect(@abs(@as(i32, @intCast(green * 2)) - @as(i32, @intCast(red))) <= 1);
                levels[alpha] = true;
            }
            var intermediate: usize = 0;
            for (levels[1..128]) |present| intermediate += @intFromBool(present);
            try std.testing.expect(intermediate > 32);
        }
    }
}

test "offsetAtX inverts measureWidthF and rounds to the nearer character edge" {
    setPreferredFamilies("", "");
    const value = "hello world";
    // Every boundary maps back to itself when probed at its own pen position.
    var index: usize = 0;
    while (index <= value.len) : (index += 1) {
        const pen = try measureWidthF(value[0..index], .manrope, 13, 1);
        try std.testing.expectEqual(index, try offsetAtX(value, .manrope, 13, 1, pen));
    }

    // Left of the run and past its end clamp rather than going out of bounds.
    try std.testing.expectEqual(@as(usize, 0), try offsetAtX(value, .manrope, 13, 1, -100));
    try std.testing.expectEqual(value.len, try offsetAtX(value, .manrope, 13, 1, 100_000));

    // Past a character's midpoint the caret belongs after it, not before:
    // this is what makes clicking the right half of a glyph feel right.
    const first = try measureWidthF(value[0..1], .manrope, 13, 1);
    try std.testing.expectEqual(@as(usize, 0), try offsetAtX(value, .manrope, 13, 1, first * 0.4));
    try std.testing.expectEqual(@as(usize, 1), try offsetAtX(value, .manrope, 13, 1, first * 0.6));
}

test "offsetAtX lands on codepoint boundaries in multi-byte text" {
    setPreferredFamilies("", "");
    const value = "aé漢";
    var seen: usize = 0;
    var x: f32 = 0;
    while (x < 60) : (x += 0.5) {
        const offset = try offsetAtX(value, .manrope, 13, 1, x);
        // 1, 3 and 6 are the only interior boundaries; anything else would be
        // a caret inside a codepoint.
        try std.testing.expect(offset == 0 or offset == 1 or offset == 3 or offset == 6);
        seen = @max(seen, offset);
    }
    try std.testing.expectEqual(value.len, seen);
}

test "lock revealed password never enters the text run cache" {
    const password = "private-lock-test-7é";
    const before = run_cache.count();
    _ = try measureSensitiveWidth(password, .manrope, 20, 1);
    var pixels: [400 * 50]u32 = @splat(0);
    try drawOpts(&pixels, 400, 50, password, .{ .r = 1, .g = 1, .b = 1, .a = 1 }, 1, .manrope, 20, .{ .rect = .{ .x = 0, .y = 0, .w = 400, .h = 50 }, .sensitive = true });
    try std.testing.expectEqual(before, run_cache.count());
}

test "ZWJ emoji sequence and flags stay one cluster" {
    const family = "👨‍👩‍👧";
    try std.testing.expectEqual(family.len, nextClusterEnd(family, 0));
    try std.testing.expectEqual(@as(usize, 1), nextClusterEnd("ab", 0));
    try std.testing.expectEqual(@as(usize, 2), nextClusterEnd("ab", 1));
    const flag = "🇺🇸";
    try std.testing.expectEqual(flag.len, nextClusterEnd(flag, 0));
    const acute = "e\u{0301}";
    try std.testing.expectEqual(acute.len, nextClusterEnd(acute, 0));
}

test "repeated draws of the same glyph match" {
    setPreferredFamilies("", "");
    var first: [56 * 26]u32 = @splat(0);
    var second: [56 * 26]u32 = @splat(0);
    const color = Color{ .r = 1, .g = 1, .b = 1, .a = 1 };
    const rect = Rect{ .x = 0, .y = 0, .w = 56, .h = 26 };
    try draw(&first, 56, 26, rect, "S", color, 1, .manrope_bold, 11.5);
    try draw(&second, 56, 26, rect, "S", color, 1, .manrope_bold, 11.5);
    try std.testing.expectEqualSlices(u32, &first, &second);
}

test "ASCII stays on the bundled face" {
    setPreferredFamilies("", "");
    const before = faces.items.len;
    const text_s = "Selected icon";
    const w = try measureWidth(text_s, .manrope_bold, 11.5, 1);
    try std.testing.expectEqual(before, faces.items.len);
    try std.testing.expectEqual(@intFromEnum(Font.manrope), primaryId(.manrope));
    try std.testing.expectEqual(@intFromEnum(Font.manrope_bold), primaryId(.manrope_bold));
    const slot = try ensureFace(.manrope_bold);
    try applySize(slot, size26(11.5, 1));
    const shaped = try shape(slot, text_s);
    defer shaped.deinit();
    const run = try uncachedRun(.manrope_bold, size26(11.5, 1), text_s);
    defer gpa.free(run.glyphs);
    try std.testing.expectEqual(shaped.width, run.width);
    try std.testing.expect(w > 0);
}

test "preferred family becomes primary when installed" {
    const cand = font_fallback.matchFamily(std.testing.allocator, "Noto Sans", 400) orelse return error.SkipZigTest;
    cand.deinit(std.testing.allocator);
    setPreferredFamilies("", "");
    defer setPreferredFamilies("", "");
    try std.testing.expectEqual(@intFromEnum(Font.manrope), primaryId(.manrope));
    setPreferredFamilies("Noto Sans", "");
    const id = primaryId(.manrope);
    try std.testing.expect(id != @intFromEnum(Font.manrope));
    const face = try ensureLoaded(id);
    const name = std.mem.span(face.ft_face.*.family_name);
    try std.testing.expect(std.mem.indexOf(u8, name, "Noto") != null);
}

test "color emoji fallback paints its own colours" {
    setPreferredFamilies("", "");
    const cand = font_fallback.findCovering(std.testing.allocator, "sans-serif", 400, 0x1F44B, true) orelse return error.SkipZigTest;
    cand.deinit(std.testing.allocator);

    var pixels: [200 * 40]u32 = @splat(0);
    try draw(&pixels, 200, 40, .{ .x = 2, .y = 2, .w = 196, .h = 36 }, "Hi 👋", .{ .r = 1, .g = 1, .b = 1, .a = 1 }, 1, .manrope, 18);
    var colorful: usize = 0;
    var ink: usize = 0;
    for (pixels) |pixel| {
        const a = pixel >> 24;
        if (a == 0) continue;
        ink += 1;
        const r = (pixel >> 16) & 255;
        const g = (pixel >> 8) & 255;
        const b = pixel & 255;
        // Coverage glyphs tinted white are grayscale (r==g==b). Color emoji
        // is not: at least some pixels have unequal channels.
        if (!(r == g and g == b)) colorful += 1;
    }
    try std.testing.expect(ink > 20);
    try std.testing.expect(colorful > 8);
}

test "Arabic fallback produces ink when a covering font is installed" {
    setPreferredFamilies("", "");
    const cand = font_fallback.findCovering(std.testing.allocator, "sans-serif", 400, 0x0645, false) orelse return error.SkipZigTest;
    cand.deinit(std.testing.allocator);

    const latin = try measureWidth("Hi", .manrope, 16, 1);
    const mixed = try measureWidth("Hi مرحبا", .manrope, 16, 1);
    try std.testing.expect(mixed > latin);

    var pixels: [240 * 36]u32 = @splat(0);
    try draw(&pixels, 240, 36, .{ .x = 2, .y = 2, .w = 236, .h = 32 }, "مرحبا", .{ .r = 1, .g = 1, .b = 1, .a = 1 }, 1, .manrope, 16);
    var ink: usize = 0;
    for (pixels) |pixel| ink += @intFromBool(pixel >> 24 > 0);
    try std.testing.expect(ink > 20);
}

test "visible label ink stays vertically centered at taskbar sizes and scales" {
    setPreferredFamilies("", "");
    var pixels: [240 * 168]u32 = undefined;
    for ([_]f32{ 1, 1.5, 2 }) |scale| {
        for ([_]i32{ 20, 34, 54, 84 }) |logical_height| {
            const width = devicePixels(120, scale);
            const height = devicePixels(logical_height, scale);
            for ([_][]const u8{ "100%", "9%", "Files", "gyp", "12:34" }) |label| {
                @memset(&pixels, 0);
                try drawOpts(&pixels, width, height, label, .{ .r = 1, .g = 1, .b = 1, .a = 1 }, scale, .manrope, 14, .{
                    .rect = .{ .x = 0, .y = 0, .w = 120, .h = logical_height },
                    .center_ink = true,
                });
                var top = height;
                var bottom: i32 = -1;
                for (0..@intCast(height)) |y| {
                    for (0..@intCast(width)) |x| {
                        if (pixels[y * @as(usize, @intCast(width)) + x] >> 24 == 0) continue;
                        top = @min(top, @as(i32, @intCast(y)));
                        bottom = @max(bottom, @as(i32, @intCast(y)));
                    }
                }
                try std.testing.expect(bottom >= top);
                try std.testing.expect(@abs(top + bottom + 1 - height) <= 1);
            }
        }
    }
}

/// Test diagnostic exposes only the count, never cached text.
pub fn testingRunCacheCount() usize {
    if (!@import("builtin").is_test) @compileError("test-only cache diagnostic");
    return run_cache.count();
}
