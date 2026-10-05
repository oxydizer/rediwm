const std = @import("std");

pub const Transform = enum {
    normal,
    @"90",
    @"180",
    @"270",
    flipped,
    flipped_90,
    flipped_180,
    flipped_270,
};

pub fn parseName(value: []const u8) !Transform {
    return std.meta.stringToEnum(Transform, value) orelse error.InvalidTransform;
}

pub fn parse(value: []const u8) !Transform {
    if (value.len < 2 or value[0] != '"' or value[value.len - 1] != '"') return error.ExpectedQuotedString;
    return parseName(value[1 .. value.len - 1]);
}

pub fn name(transform: Transform) []const u8 {
    return switch (transform) {
        .normal => "normal",
        .@"90" => "90",
        .@"180" => "180",
        .@"270" => "270",
        .flipped => "flipped",
        .flipped_90 => "flipped_90",
        .flipped_180 => "flipped_180",
        .flipped_270 => "flipped_270",
    };
}
