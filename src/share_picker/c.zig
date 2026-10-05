pub const api = @cImport({
    @cUndef("_FORTIFY_SOURCE");
    @cDefine("_GNU_SOURCE", "1");
    @cInclude("cairo.h");
    @cInclude("sys/mman.h");
    @cInclude("poll.h");
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
    @cInclude("time.h");
    @cInclude("signal.h");
    @cInclude("xkbcommon/xkbcommon.h");
    @cInclude("xkbcommon/xkbcommon-keysyms.h");
});
