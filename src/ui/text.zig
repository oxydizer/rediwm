// Small, process-wide FreeType + HarfBuzz text renderer. Bundled Manrope
// (titles, chrome) and JetBrains Mono (clock) are the default faces;
// Fontconfig supplies fallback files for missing glyphs — emoji, CJK, and
// whatever else the user has installed. `theme.font` / `theme.mono_font`
// become the primary face when those families exist; unknown names keep
// the bundled defaults.
const std = @import("std");
const gpa = @import("memory").gpa;
const font_fallback = @import("font_fallback.zig");
pub const c = @import("c_gfx");

const log = std.log.scoped(.text);

pub const Rect = struct { x: i32, y: i32, w: i32, h: i32 };
pub const Color = struct { r: f32, g: f32, b: f32, a: f32 };

pub const Font = enum {
    manrope,
    manrope_bold,
    mono,
    mono_bold,
    /// Bold (700), for headings above semibold labels and controls.
    manrope_heavy,

    pub fn bytes(font: Font) []const u8 {
        return switch (font) {
            .manrope, .manrope_bold, .manrope_heavy => @embedFile("manrope"),
            .mono => @embedFile("jetbrains_mono_regular"),
            .mono_bold => @embedFile("jetbrains_mono_bold"),
        };
    }
};

const FaceSource = union(enum) {
    bundled: Font,
    file: struct { path: [:0]u8, index: i32 },
};

pub const Face = struct {
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

pub const size_slots = 8;
const SizeSlot = struct { size: c.FT_F26Dot6, ft_size: c.FT_Size, hb_font: *c.hb_font_t, used: u64 };
pub var size_clock: u64 = 0;

// Full hinting: the chrome's 12-13.5px text is small enough that grid-fitting
// both axes measurably wins over FT_LOAD_TARGET_LIGHT's Y-only snapping. At
// 13.5px it cuts the share of ink pixels sitting at intermediate coverage from
// 40% to 27% and raises edge acutance from 110 to 117; the cost is the usual
// slight horizontal stem distortion. Shape and rasterize with the same
// metrics policy so HarfBuzz's advances match the bitmaps we place.
pub const load_flags: c_int = c.FT_LOAD_DEFAULT | c.FT_LOAD_NO_BITMAP;
pub const color_load_flags: c_int = c.FT_LOAD_DEFAULT | c.FT_LOAD_COLOR;

pub var ft_library: c.FT_Library = null;
pub var faces: std.ArrayListUnmanaged(Face) = .empty;
pub var chains: [font_count]std.ArrayListUnmanaged(u32) = @splat(.empty);
pub const font_count = @typeInfo(Font).@"enum".field_names.len;
pub var coverage: std.AutoHashMapUnmanaged(u64, u32) = .empty;
pub const no_face = std.math.maxInt(u32);

var sans_name_buf: [128]u8 = undefined;
var sans_name_len: usize = 0;
var mono_name_buf: [128]u8 = undefined;
var mono_name_len: usize = 0;

pub fn preferredSans() []const u8 {
    return sans_name_buf[0..sans_name_len];
}
pub fn preferredMono() []const u8 {
    return mono_name_buf[0..mono_name_len];
}

pub fn bundledWeight(font: Font) u32 {
    return switch (font) {
        .manrope_bold, .mono_bold => 600,
        .manrope_heavy => 700,
        else => 400,
    };
}

pub fn genericFamilyZ(font: Font) [*:0]const u8 {
    return switch (font) {
        .manrope, .manrope_bold, .manrope_heavy => "sans-serif",
        .mono, .mono_bold => "monospace",
    };
}

pub fn size26(size_px: f32, scale: f32) c.FT_F26Dot6 {
    return @intFromFloat(@max(64, @round(size_px * scale * 64)));
}

pub fn coverageKey(cp: u32, color: bool) u64 {
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

const text_faces = @import("text_faces.zig");
const ensureChain = text_faces.ensureChain;
pub const primaryId = text_faces.primaryId;
pub const ensureLoaded = text_faces.ensureLoaded;
pub const ensureFace = text_faces.ensureFace;
const resolveChar = text_faces.resolveChar;
pub const applySize = text_faces.applySize;
pub const setSize = text_faces.setSize;
const metricScale = text_faces.metricScale;
const scaledMetric = text_faces.scaledMetric;

const Shaped = struct {
    buffer: *c.hb_buffer_t,
    infos: [*]const c.hb_glyph_info_t,
    positions: [*]const c.hb_glyph_position_t,
    count: usize,
    width: i32,

    pub fn deinit(shaped: Shaped) void {
        c.hb_buffer_destroy(shaped.buffer);
    }
};

pub fn shape(face: *Face, utf8: []const u8) !Shaped {
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

const text_clusters = @import("text_clusters.zig");
pub const nextClusterEnd = text_clusters.nextClusterEnd;
const clusterBase = text_clusters.clusterBase;
const clusterWantsColor = text_clusters.clusterWantsColor;
pub const previousUtf8Boundary = text_clusters.previousUtf8Boundary;

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

pub const Run = struct {
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
pub var run_cache: std.HashMapUnmanaged(RunKey, Run, RunKeyContext, std.hash_map.default_max_load_percentage) = .empty;

/// Bounded because window and app titles are content, not a fixed set; past
/// this the whole cache is dropped rather than evicted one by one, which for
/// a redraw cache costs one re-shape per live string. The one caveat that
/// buys: a `Run`'s glyphs are owned by the cache, so a caller must not hold
/// one across a later `shapedRun` call (`draw` re-fetches after fitting, and
/// `fitWithEllipsis` is done with its run before it shapes candidates).
const max_cached_runs = 4096;

pub const GlyphKey = struct { face: u32, size: c.FT_F26Dot6, index: u32, italic: bool };

/// A rendered glyph, copied out of FreeType's own slot (which the next
/// FT_Load_Glyph would overwrite). `pixels` is 8-bit coverage, `cols` wide,
/// unless `color` in which case it is premul BGRA. An empty one records a
/// glyph with no ink so it isn't re-rendered.
pub const CachedGlyph = struct {
    pixels: []const u8,
    cols: i32,
    rows: i32,
    left: i32,
    top: i32,
    color: bool = false,
};

pub var glyph_cache: std.AutoHashMapUnmanaged(GlyphKey, CachedGlyph) = .empty;

fn clearRunCache() void {
    var it = run_cache.iterator();
    while (it.next()) |entry| {
        gpa.free(entry.key_ptr.text);
        gpa.free(entry.value_ptr.glyphs);
    }
    run_cache.clearRetainingCapacity();
}

pub fn shapedRun(font: Font, size: c.FT_F26Dot6, utf8: []const u8) !Run {
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
pub fn uncachedRun(font: Font, size: c.FT_F26Dot6, utf8: []const u8) !Run {
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

pub fn clearSensitiveRun(run: Run) void {
    std.crypto.secureZero(u8, std.mem.sliceAsBytes(@constCast(run.glyphs)));
    gpa.free(run.glyphs);
}

pub fn measureSensitiveWidth(utf8: []const u8, font: Font, size_px: f32, scale: f32) !f32 {
    _ = try setSize(font, size_px, scale);
    const run = try uncachedRun(font, size26(size_px, scale), utf8);
    defer clearSensitiveRun(run);
    return @as(f32, @floatFromInt(run.width)) / 64.0 / scale;
}

const text_raster = @import("text_raster.zig");
pub const glyphBitmap = text_raster.glyphBitmap;
pub const snap26_6 = text_raster.snap26_6;
pub const blendBitmap = text_raster.blendBitmap;
pub const blendColorBitmap = text_raster.blendColorBitmap;
pub const blendPixel = text_raster.blendPixel;
pub const devicePixels = text_raster.devicePixels;

const text_draw = @import("text_draw.zig");
pub const warmGlyphs = text_draw.warmGlyphs;
pub const measureWidth = text_draw.measureWidth;
pub const measureWidthF = text_draw.measureWidthF;
pub const offsetAtX = text_draw.offsetAtX;
pub const VMetrics = text_draw.VMetrics;
pub const verticalMetrics = text_draw.verticalMetrics;
pub const lineHeight = text_draw.lineHeight;
pub const draw = text_draw.draw;
pub const DrawOptions = text_draw.DrawOptions;
pub const Accelerator = text_draw.Accelerator;
pub const drawOpts = text_draw.drawOpts;
pub const inkBaseline = text_draw.inkBaseline;

test {
    _ = @import("text_tests.zig");
}

/// Test diagnostic exposes only the count, never cached text.
pub fn testingRunCacheCount() usize {
    if (!@import("builtin").is_test) @compileError("test-only cache diagnostic");
    return run_cache.count();
}
