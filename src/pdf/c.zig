//! C ABI bindings for Poppler, GLib and libc/Cairo.
//! GLib/GObject headers are intentionally hand-declared (no @cInclude per AGENTS.md).
pub const api = @cImport({
    // Translate libc declarations, not glibc's fortified inline wrappers: Zig
    // 0.16 rejects their attribute(error) calls in ReleaseSafe.
    @cUndef("_FORTIFY_SOURCE");
    @cDefine("_GNU_SOURCE", "1");
    @cInclude("cairo.h");
    @cInclude("cairo-pdf.h");
    @cInclude("sys/mman.h");
    @cInclude("sys/eventfd.h");
    @cInclude("sys/stat.h");
    @cInclude("sys/socket.h");
    @cInclude("sys/un.h");
    @cInclude("poll.h");
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
    @cInclude("pthread.h");
    @cInclude("time.h");
    @cInclude("stdlib.h");
    @cInclude("errno.h");
    @cInclude("stdio.h");
    @cInclude("signal.h");
    @cInclude("xkbcommon/xkbcommon.h");
    @cInclude("xkbcommon/xkbcommon-keysyms.h");
});

pub extern fn rediwm_pdf_open_document(path: [*:0]const u8) c_int;
/// `print_fd` is the print helper's socket or -1; it stays open in the sandbox.
pub extern fn rediwm_pdf_sandbox_enter(document_fd: c_int, display_fd: c_int, print_fd: c_int) c_int;
/// Forks the unsandboxed print helper (print.c); returns the viewer's end of
/// its socket, or -1.
pub extern fn rediwm_pdf_print_start(document_fd: c_int, path: [*:0]const u8) c_int;

// GLib & Poppler types declared by hand without @cInclude.
pub const PopplerDocument = opaque {};
pub const PopplerPage = opaque {};
pub const GBytes = opaque {};
pub const PopplerIndexIter = opaque {};
pub const PopplerAction = opaque {};

pub const GList = extern struct {
    data: ?*anyopaque,
    next: ?*GList,
    prev: ?*GList,
};

pub const GError = extern struct {
    domain: u32,
    code: c_int,
    message: [*:0]const u8,
};

pub const PopplerRectangle = extern struct {
    x1: f64,
    y1: f64,
    x2: f64,
    y2: f64,
};

pub const PopplerPoint = extern struct {
    x: f64,
    y: f64,
};

pub const PopplerColor = extern struct {
    red: u16,
    green: u16,
    blue: u16,
};

pub const PopplerDest = extern struct {
    type: c_int,
    page_num: c_int,
    left: f64,
    bottom: f64,
    right: f64,
    top: f64,
    zoom: f64,
    named_dest: ?[*:0]const u8,
    change_flags: u32,
};

pub const PopplerLinkMapping = extern struct {
    area: PopplerRectangle,
    action: ?*PopplerAction,
};

pub const PopplerActionAny = extern struct {
    type: c_int,
    title: ?[*:0]const u8,
};

pub const PopplerActionGotoDest = extern struct {
    type: c_int,
    title: ?[*:0]const u8,
    dest: ?*PopplerDest,
};

pub const PopplerActionUri = extern struct {
    type: c_int,
    title: ?[*:0]const u8,
    uri: ?[*:0]const u8,
};

// Poppler error codes
pub const POPPLER_ERROR_INVALID: c_int = 0;
pub const POPPLER_ERROR_ENCRYPTED: c_int = 1;
pub const POPPLER_ERROR_OPEN_FILE: c_int = 2;
pub const POPPLER_ERROR_BAD_CATALOG: c_int = 3;
pub const POPPLER_ERROR_DAMAGED: c_int = 4;
pub const POPPLER_ERROR_SIGNING: c_int = 5;

// Poppler action types
pub const POPPLER_ACTION_UNKNOWN: c_int = 0;
pub const POPPLER_ACTION_NONE: c_int = 1;
pub const POPPLER_ACTION_GOTO_DEST: c_int = 2;
pub const POPPLER_ACTION_GOTO_REMOTE: c_int = 3;
pub const POPPLER_ACTION_LAUNCH: c_int = 4;
pub const POPPLER_ACTION_URI: c_int = 5;
pub const POPPLER_ACTION_NAMED: c_int = 6;

// Poppler dest types
pub const POPPLER_DEST_UNKNOWN: c_int = 0;
pub const POPPLER_DEST_XYZ: c_int = 1;
pub const POPPLER_DEST_FIT: c_int = 2;
pub const POPPLER_DEST_FITH: c_int = 3;
pub const POPPLER_DEST_FITV: c_int = 4;
pub const POPPLER_DEST_FITR: c_int = 5;
pub const POPPLER_DEST_FITB: c_int = 6;
pub const POPPLER_DEST_FITBH: c_int = 7;
pub const POPPLER_DEST_FITBV: c_int = 8;
pub const POPPLER_DEST_NAMED: c_int = 9;

// GLib functions
pub extern fn g_object_unref(object: ?*anyopaque) void;
pub extern fn g_error_free(err: ?*GError) void;
pub extern fn g_free(mem: ?*anyopaque) void;
pub extern fn g_list_free(list: ?*GList) void;
pub extern fn g_list_free_full(list: ?*GList, free_func: ?*const fn (?*anyopaque) callconv(.c) void) void;
pub extern fn g_filename_to_uri(filename: [*:0]const u8, hostname: ?[*:0]const u8, err: ?*?*GError) ?[*:0]u8;
pub extern fn g_bytes_new_static(data: [*]const u8, size: usize) ?*GBytes;
pub extern fn g_bytes_unref(bytes: ?*GBytes) void;

// Poppler functions
pub extern fn poppler_error_quark() u32;
pub extern fn poppler_document_new_from_file(uri: [*:0]const u8, password: ?[*:0]const u8, err: ?*?*GError) ?*PopplerDocument;
pub extern fn poppler_document_new_from_bytes(bytes: *GBytes, password: ?[*:0]const u8, err: ?*?*GError) ?*PopplerDocument;
pub extern fn poppler_document_new_from_fd(fd: c_int, password: ?[*:0]const u8, err: ?*?*GError) ?*PopplerDocument;
pub extern fn poppler_document_get_n_pages(document: *PopplerDocument) c_int;
pub extern fn poppler_document_get_page(document: *PopplerDocument, index: c_int) ?*PopplerPage;
pub extern fn poppler_page_get_size(page: *PopplerPage, width: *f64, height: *f64) void;
pub extern fn poppler_page_render(page: *PopplerPage, cairo: ?*anyopaque) void;
pub extern fn poppler_page_get_text(page: *PopplerPage) ?[*:0]u8;
pub extern fn poppler_page_find_text(page: *PopplerPage, text: [*:0]const u8) ?*GList;
pub extern fn poppler_page_get_text_layout(page: *PopplerPage, rectangles: *?[*]PopplerRectangle, n_rectangles: *c_uint) c_int;
pub extern fn poppler_page_get_link_mapping(page: *PopplerPage) ?*GList;
pub extern fn poppler_page_free_link_mapping(list: ?*GList) void;
pub extern fn poppler_rectangle_free(rectangle: ?*anyopaque) void;
pub extern fn poppler_index_iter_new(document: *PopplerDocument) ?*PopplerIndexIter;
pub extern fn poppler_index_iter_free(iter: *PopplerIndexIter) void;
pub extern fn poppler_index_iter_next(iter: *PopplerIndexIter) c_int;
pub extern fn poppler_index_iter_get_child(parent: *PopplerIndexIter) ?*PopplerIndexIter;
pub extern fn poppler_index_iter_get_action(iter: *PopplerIndexIter) ?*PopplerAction;
pub extern fn poppler_action_free(action: *PopplerAction) void;
pub extern fn poppler_document_find_dest(document: *PopplerDocument, link_name: [*:0]const u8) ?*PopplerDest;
pub extern fn poppler_dest_free(dest: *PopplerDest) void;
