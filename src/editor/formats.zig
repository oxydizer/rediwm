//! Filename MIME classification only; the editor validates file contents in its worker.
const std = @import("std");
extern fn g_content_type_guess([*:0]const u8, ?[*]const u8, usize, ?*c_int) ?[*:0]u8;
extern fn g_content_type_is_a([*:0]const u8, [*:0]const u8) c_int;
extern fn g_free(?*anyopaque) void;
pub fn candidate(path: []const u8) bool {
    // README, Makefile, dotfiles and other extensionless documents are common.
    const extension = std.fs.path.extension(path);
    if (extension.len == 0) return true;
    for ([_][]const u8{ ".zig", ".rs", ".go", ".py", ".js", ".ts", ".tsx", ".jsx", ".yaml", ".yml", ".toml", ".ini", ".conf", ".cfg", ".log", ".csv", ".sh" }) |ext| {
        if (std.ascii.eqlIgnoreCase(extension, ext)) return true;
    }
    var buf: [4096]u8 = undefined;
    const name = std.fmt.bufPrintZ(&buf, "{s}", .{path}) catch return false;
    const mime = g_content_type_guess(name, null, 0, null) orelse return false;
    defer g_free(mime);
    return g_content_type_is_a(mime, "text/plain") != 0 or
        g_content_type_is_a(mime, "application/json") != 0 or
        g_content_type_is_a(mime, "application/xml") != 0 or
        g_content_type_is_a(mime, "application/toml") != 0 or
        std.ascii.eqlIgnoreCase(std.fs.path.extension(path), ".toml");
}
test "text preview candidates include config, source and extensionless files" {
    for ([_][]const u8{ "hello.txt", "README", ".bashrc", "notes.md", "main.c", "main.zig", "config.toml", "data.json" }) |name| try std.testing.expect(candidate(name));
    for ([_][]const u8{ "image.png", "archive.zip", "movie.mp4", "document.pdf" }) |name| try std.testing.expect(!candidate(name));
}
