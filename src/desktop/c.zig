pub const api = @cImport({
    // Translate libc declarations, not glibc's fortified inline wrappers: Zig
    // 0.16 rejects their attribute(error) calls in ReleaseSafe. This affects
    // this import only; Zig runtime safety and separately compiled C stay on.
    @cUndef("_FORTIFY_SOURCE");
    @cDefine("_GNU_SOURCE", "1");
    @cInclude("cairo.h");
    @cInclude("sys/inotify.h");
    @cInclude("sys/eventfd.h");
    @cInclude("sys/stat.h");
    @cInclude("poll.h");
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
    @cInclude("pthread.h");
    @cInclude("time.h");
    @cInclude("stdlib.h");
    @cInclude("xkbcommon/xkbcommon.h");
});
