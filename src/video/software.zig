//! Source-size RGB shm buffers. A free slot may be replaced on a format
//! change; attached slots keep their original mappings until wl_buffer.release.
const std = @import("std");
const c = @import("c_av");
const sys = @import("c");
const wl = @import("wayland").client.wl;
const Frame = @import("window.zig").Frame;

const little_endian = @import("builtin").cpu.arch.endian() == .little;
const rgb8 = if (little_endian) c.AV_PIX_FMT_BGR0 else c.AV_PIX_FMT_0RGB;
const rgb10 = if (little_endian) c.AV_PIX_FMT_X2RGB10LE else c.AV_PIX_FMT_X2RGB10BE;

pub const Pool = struct {
    slots: [3]Slot = @splat(.{}),
    sws: ?*c.SwsContext = null,

    pub fn deinit(self: *Pool) void {
        for (&self.slots) |*slot| slot.deinit();
        c.sws_freeContext(self.sws);
    }

    pub fn show(self: *Pool, shm: *wl.Shm, ten_bit: bool, f: *c.AVFrame) !?Frame {
        if (f.width <= 0 or f.height <= 0 or f.width > 16384 or f.height > 16384) return error.InvalidSize;
        const slot = for (&self.slots) |*s| {
            if (!s.busy) break s;
        } else return null;
        const desc = c.av_pix_fmt_desc_get(f.format) orelse return error.UnknownPixelFormat;
        const deep = ten_bit and desc.*.comp[0].depth > 8;
        const format: wl.Shm.Format = if (deep) .xrgb2101010 else .xrgb8888;
        if (slot.buffer == null or slot.width != f.width or slot.height != f.height or slot.format != format) {
            slot.deinit();
            try slot.create(shm, f.width, f.height, format);
        }
        self.sws = c.sws_getCachedContext(self.sws, f.width, f.height, f.format, f.width, f.height, if (deep) rgb10 else rgb8, c.SWS_BILINEAR, null, null, null);
        const sws = self.sws orelse return error.ConversionFailed;
        const matrix = switch (f.colorspace) {
            c.AVCOL_SPC_BT709 => c.SWS_CS_ITU709,
            c.AVCOL_SPC_BT2020_CL, c.AVCOL_SPC_BT2020_NCL => c.SWS_CS_BT2020,
            c.AVCOL_SPC_SMPTE240M => c.SWS_CS_SMPTE240M,
            c.AVCOL_SPC_FCC => c.SWS_CS_FCC,
            c.AVCOL_SPC_BT470BG, c.AVCOL_SPC_SMPTE170M => c.SWS_CS_ITU601,
            else => if (f.width >= 1280 or f.height > 576) @as(c_int, c.SWS_CS_ITU709) else c.SWS_CS_ITU601,
        };
        const coeff = c.sws_getCoefficients(matrix);
        if (c.sws_setColorspaceDetails(sws, coeff, @intFromBool(f.color_range == c.AVCOL_RANGE_JPEG), coeff, 1, 0, 1 << 16, 1 << 16) < 0) return error.ConversionFailed;
        const dst = [_][*c]u8{ @ptrCast(slot.memory), null, null, null };
        const strides = [_]c_int{ slot.stride, 0, 0, 0 };
        if (c.sws_scale(sws, &f.data, &f.linesize, 0, f.height, &dst, &strides) != f.height) return error.ConversionFailed;
        slot.busy = true;
        return .{ .buffer = slot.buffer.?, .crop_x = @intCast(f.crop_left), .crop_y = @intCast(f.crop_top), .crop_w = f.width - @as(i32, @intCast(f.crop_left + f.crop_right)), .crop_h = f.height - @as(i32, @intCast(f.crop_top + f.crop_bottom)) };
    }
};

const Slot = struct {
    buffer: ?*wl.Buffer = null,
    memory: ?*anyopaque = null,
    len: usize = 0,
    width: i32 = 0,
    height: i32 = 0,
    stride: i32 = 0,
    format: wl.Shm.Format = .xrgb8888,
    busy: bool = false,

    fn create(self: *Slot, shm: *wl.Shm, w: i32, h: i32, format: wl.Shm.Format) !void {
        const stride = std.mem.alignForward(i32, w * 4, 64);
        const len: usize = @intCast(stride * h);
        const fd = sys.memfd_create("rediwm-video", sys.MFD_CLOEXEC);
        if (fd < 0) return error.ShmFailed;
        defer _ = sys.close(fd);
        if (sys.ftruncate(fd, @intCast(len)) < 0) return error.ShmFailed;
        const mem = sys.mmap(null, len, sys.PROT_READ | sys.PROT_WRITE, sys.MAP_SHARED, fd, 0);
        if (mem == sys.MAP_FAILED) return error.ShmFailed;
        errdefer _ = sys.munmap(mem, len);
        const pool = try shm.createPool(fd, @intCast(len));
        defer pool.destroy();
        self.* = .{ .memory = mem, .len = len, .stride = stride, .width = w, .height = h, .format = format, .buffer = try pool.createBuffer(0, w, h, stride, format) };
        self.buffer.?.setListener(*Slot, release, self);
    }
    fn release(_: *wl.Buffer, _: wl.Buffer.Event, self: *Slot) void {
        self.busy = false;
    }
    fn deinit(self: *Slot) void {
        if (self.buffer) |b| b.destroy();
        if (self.memory) |m| _ = sys.munmap(m, self.len);
        self.* = .{};
    }
};
