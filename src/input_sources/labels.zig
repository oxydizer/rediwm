//! Indicator texts: the language code a layout carries in the XKB registry,
//! uppercased (`us` → EN, `de` → DE, `jp` → JA). Two sources that would read
//! the same get subscripts (EN₁, EN₂); a configured label always wins.
const std = @import("std");

pub const max_bytes = 24;

pub const Text = struct {
    bytes: [max_bytes]u8 = undefined,
    len: u8 = 0,

    pub fn slice(self: *const Text) []const u8 {
        return self.bytes[0..self.len];
    }

    pub fn set(self: *Text, value: []const u8) void {
        // Never cut a UTF-8 sequence in half.
        var n = @min(value.len, max_bytes);
        while (n > 0 and n < value.len and value[n] & 0xc0 == 0x80) n -= 1;
        @memcpy(self.bytes[0..n], value[0..n]);
        self.len = @intCast(n);
    }

    fn append(self: *Text, value: []const u8) void {
        if (self.len + value.len > max_bytes) return;
        @memcpy(self.bytes[self.len..][0..value.len], value);
        self.len += @intCast(value.len);
    }
};

/// A layout's base text: its registry code when known, else the layout name
/// itself, both uppercased and kept to three letters.
pub fn base(brief: []const u8, layout: []const u8) Text {
    const full = if (brief.len > 0) brief else layout;
    // A language tag's region is not part of its code: zh_CN reads ZH.
    const source = full[0 .. std.mem.indexOfAny(u8, full, "_-@.") orelse full.len];
    var out: Text = .{};
    var ascii: [3]u8 = undefined;
    var n: usize = 0;
    for (source) |ch| {
        if (n == ascii.len) break;
        if (ch >= 0x80) {
            // A non-Latin brief is shown as written.
            out.set(source);
            return out;
        }
        if (!std.ascii.isAlphanumeric(ch)) continue;
        ascii[n] = std.ascii.toUpper(ch);
        n += 1;
    }
    out.set(ascii[0..n]);
    return out;
}

const subscripts = [_][]const u8{ "₀", "₁", "₂", "₃", "₄", "₅", "₆", "₇", "₈", "₉" };

/// Numbers repeated texts in place. `explicit[i]` marks a configured label,
/// which is never changed and never numbered.
pub fn disambiguate(texts: []Text, explicit: []const bool) void {
    var numbered: [16]?usize = @splat(null);
    for (texts, 0..) |text, i| {
        if (explicit[i] or i >= numbered.len) continue;
        var position: usize = 1;
        var total: usize = 0;
        for (texts, 0..) |other, j| {
            if (explicit[j] or !std.mem.eql(u8, other.slice(), text.slice())) continue;
            total += 1;
            if (j < i) position += 1;
        }
        if (total > 1) numbered[i] = position;
    }
    for (texts, 0..) |*text, i| {
        if (i >= numbered.len) break;
        const n = numbered[i] orelse continue;
        text.append(subscripts[@min(n, 9)]);
    }
}

test "layout codes become uppercase language codes and repeats are numbered" {
    var texts = [_]Text{ base("en", "us"), base("en", "us"), base("de", "de"), base("ja", "jp"), base("", "custom"), base("zh_CN", "pinyin") };
    const explicit = [_]bool{ false, false, false, false, false, false };
    disambiguate(&texts, &explicit);
    try std.testing.expectEqualStrings("EN₁", texts[0].slice());
    try std.testing.expectEqualStrings("EN₂", texts[1].slice());
    try std.testing.expectEqualStrings("DE", texts[2].slice());
    try std.testing.expectEqualStrings("JA", texts[3].slice());
    try std.testing.expectEqualStrings("CUS", texts[4].slice());
    try std.testing.expectEqualStrings("ZH", texts[5].slice());
}

test "configured labels are kept as written and never numbered" {
    var jp: Text = .{};
    jp.set("JP");
    var texts = [_]Text{ base("ja", "jp"), jp, base("ja", "jp") };
    const explicit = [_]bool{ false, true, false };
    disambiguate(&texts, &explicit);
    try std.testing.expectEqualStrings("JA₁", texts[0].slice());
    try std.testing.expectEqualStrings("JP", texts[1].slice());
    try std.testing.expectEqualStrings("JA₂", texts[2].slice());
    var long: Text = .{};
    long.set("あいうえおかきくけ");
    try std.testing.expect(std.unicode.utf8ValidateSlice(long.slice()));
}
