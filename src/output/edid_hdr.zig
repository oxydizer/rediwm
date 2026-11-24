//! The HDR static metadata data block of an EDID's CTA-861 extensions (CTA-861-H
//! 7.5.13): which transfer functions the display takes and the luminance range
//! it suggests for content. HDR caps the SDR white
//! level at that peak and sends the range as mastering metadata. A display that
//! describes itself only in DisplayID blocks reports nothing here.

const std = @import("std");

pub const Static = struct {
    /// SMPTE ST 2084 (PQ) is among the display's transfer functions.
    pq: bool = false,
    /// Desired content maximum luminance, cd/m².
    max_nits: ?f64 = null,
    /// Desired content maximum frame-average luminance, cd/m².
    max_fall_nits: ?f64 = null,
    /// Desired content minimum luminance, cd/m².
    min_nits: ?f64 = null,
};

const block_size = 128;
const cta_tag = 0x02;
const extended_tag = 7;
const hdr_static_tag = 6;

/// The first HDR static metadata block in `edid`, or null when there is none
/// (or the EDID is too short to hold its extensions).
pub fn parse(edid: []const u8) ?Static {
    if (edid.len < block_size) return null;
    const extensions: usize = edid[126];
    var i: usize = 1;
    while (i <= extensions) : (i += 1) {
        if (edid.len < (i + 1) * block_size) return null;
        const block = edid[i * block_size ..][0..block_size];
        if (block[0] != cta_tag) continue;
        // Byte 2: where the detailed timings start; data blocks lie before it.
        const end: usize = @min(block[2], block_size - 1);
        var at: usize = 4;
        while (at < end) {
            const tag = block[at] >> 5;
            const len: usize = block[at] & 0x1f;
            if (at + 1 + len > end) break;
            const payload = block[at + 1 ..][0..len];
            if (tag == extended_tag and len >= 3 and payload[0] == hdr_static_tag) return decode(payload[1..]);
            at += 1 + len;
        }
    }
    return null;
}

// EOTFs, descriptors, then the optional luminance code values.
fn decode(data: []const u8) Static {
    var out: Static = .{ .pq = data[0] & 0x04 != 0 };
    if (data.len > 2 and data[2] != 0) out.max_nits = codeNits(data[2]);
    if (data.len > 3 and data[3] != 0) out.max_fall_nits = codeNits(data[3]);
    if (data.len > 4 and out.max_nits != null) {
        const cv: f64 = @floatFromInt(data[4]);
        out.min_nits = out.max_nits.? * (cv / 255) * (cv / 255) / 100;
    }
    return out;
}

fn codeNits(cv: u8) f64 {
    return 50 * std.math.pow(f64, 2, @as(f64, @floatFromInt(cv)) / 32);
}

fn edidWith(blocks: []const u8) [2 * block_size]u8 {
    var edid = std.mem.zeroes([2 * block_size]u8);
    edid[126] = 1;
    edid[block_size] = cta_tag;
    edid[block_size + 1] = 3;
    @memcpy(edid[block_size + 4 ..][0..blocks.len], blocks);
    edid[block_size + 2] = @intCast(4 + blocks.len);
    return edid;
}

test "the HDR static metadata block after other data blocks" {
    // A video data block, then the HDR block: SDR and PQ, type 1, about 476 /
    // 400 / 0.07 cd/m².
    const max_cv: u8 = 104; // 50 * 2^(104/32) = 475.7
    const edid = edidWith(&.{ 0x42, 0x10, 0x04, 0xe6, 0x06, 0x05, 0x01, max_cv, 96, 32 });
    const got = parse(&edid).?;
    try std.testing.expect(got.pq);
    try std.testing.expectApproxEqAbs(@as(f64, 475.68), got.max_nits.?, 0.01);
    try std.testing.expectApproxEqAbs(@as(f64, 400), got.max_fall_nits.?, 0.01);
    try std.testing.expectApproxEqAbs(@as(f64, 475.68 * (32.0 / 255.0) * (32.0 / 255.0) / 100.0), got.min_nits.?, 0.001);
}

test "a block without luminances, a display without PQ, and none at all" {
    const bare = edidWith(&.{ 0xe3, 0x06, 0x05, 0x01 });
    const got = parse(&bare).?;
    try std.testing.expect(got.pq);
    try std.testing.expectEqual(@as(?f64, null), got.max_nits);
    try std.testing.expectEqual(@as(?f64, null), got.min_nits);
    const hlg_only = edidWith(&.{ 0xe3, 0x06, 0x09, 0x01 });
    try std.testing.expect(!parse(&hlg_only).?.pq);
    const none = edidWith(&.{ 0x42, 0x10, 0x04 });
    try std.testing.expectEqual(@as(?Static, null), parse(&none));
    // Truncated: the header promises an extension that is not there.
    try std.testing.expectEqual(@as(?Static, null), parse(none[0..block_size]));
    try std.testing.expectEqual(@as(?Static, null), parse(&.{}));
}

test "a block that runs past the data block collection is ignored" {
    var edid = edidWith(&.{ 0xe6, 0x06, 0x05, 0x01, 104, 96, 32 });
    edid[block_size + 2] = 8; // the collection ends inside the block
    try std.testing.expectEqual(@as(?Static, null), parse(&edid));
}
