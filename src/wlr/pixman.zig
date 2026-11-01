//! Minimal facade over pixman's 32-bit region API, the only pixman surface
//! this compositor uses (wlroots damage/opaque/clip regions). Adapted from
//! zig-pixman; see LICENSE.zig-pixman. `Region32`'s layout must keep
//! matching pixman's `pixman_region32_t` (checked structurally wherever it
//! crosses the wlroots boundary, see abi.zig).

pub const Box32 = extern struct {
    x1: i32,
    y1: i32,
    x2: i32,
    y2: i32,
};

const Region32Data = extern struct {
    size: c_long,
    num_rects: c_long,
};

pub const Region32 = extern struct {
    extents: Box32,
    data: ?*Region32Data,

    extern fn pixman_region32_init(region: *Region32) void;
    pub const init = pixman_region32_init;

    extern fn pixman_region32_init_rect(region: *Region32, x: c_int, y: c_int, width: c_uint, height: c_uint) void;
    pub const initRect = pixman_region32_init_rect;

    extern fn pixman_region32_fini(region: *Region32) void;
    pub const deinit = pixman_region32_fini;

    extern fn pixman_region32_union_rect(dest: *Region32, source: *Region32, x: c_int, y: c_int, width: c_uint, height: c_uint) c_int;
    pub fn unionRect(dest: *Region32, source: *Region32, x: c_int, y: c_int, width: c_uint, height: c_uint) bool {
        return pixman_region32_union_rect(dest, source, x, y, width, height) != 0;
    }

    extern fn pixman_region32_not_empty(region: *Region32) c_int;
    pub fn notEmpty(region: *Region32) bool {
        return pixman_region32_not_empty(region) != 0;
    }

    extern fn pixman_region32_contains_point(region: *Region32, x: c_int, y: c_int, box: ?*Box32) c_int;
    pub fn containsPoint(region: *Region32, x: c_int, y: c_int, box: ?*Box32) bool {
        return pixman_region32_contains_point(region, x, y, box) != 0;
    }
};
