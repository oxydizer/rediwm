const std = @import("std");
/// Candidates for preview; installed decoders determine actual support.
pub fn candidate(path: []const u8) bool {
    const ext = std.fs.path.extension(path);
    inline for (.{ ".png", ".jpg", ".jpeg", ".webp", ".gif", ".bmp", ".tif", ".tiff", ".svg", ".ico", ".avif", ".heic", ".heif", ".pnm", ".ppm", ".pgm" }) |suffix| {
        if (std.ascii.eqlIgnoreCase(ext, suffix)) return true;
    }
    return false;
}
