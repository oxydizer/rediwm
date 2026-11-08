//! What rediwm-player can decode. miniaudio's built-in decoders: WAV, FLAC and
//! MP3 (Vorbis, Opus and AAC need extra backends, so they go to the default
//! application until the player gains them).

const std = @import("std");

const extensions = [_][]const u8{ ".mp3", ".flac", ".wav", ".wave" };

pub fn candidate(path: []const u8) bool {
    const extension = std.fs.path.extension(path);
    for (extensions) |known| if (std.ascii.eqlIgnoreCase(extension, known)) return true;
    return false;
}

test "candidates are recognised by extension, ignoring case" {
    try std.testing.expect(candidate("/music/Track.MP3"));
    try std.testing.expect(candidate("a.flac"));
    try std.testing.expect(candidate("a.b.wav"));
    try std.testing.expect(!candidate("a.ogg"));
    try std.testing.expect(!candidate("mp3"));
    try std.testing.expect(!candidate("dir.mp3/file"));
}
