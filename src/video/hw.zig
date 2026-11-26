//! VAAPI decoding on the compositor's render node, and decoded surfaces
//! exported as dmabufs the compositor imports without a copy.
const std = @import("std");
const c = @import("c_av");

pub const Device = struct {
    ref: *c.AVBufferRef,
    display: c.VADisplay,

    /// A VAAPI device on `node` (a DRM render node path), or null when the
    /// node has no usable driver.
    pub fn open(node: [:0]const u8) ?Device {
        var ref: ?*c.AVBufferRef = null;
        if (c.av_hwdevice_ctx_create(&ref, c.AV_HWDEVICE_TYPE_VAAPI, node.ptr, null, 0) < 0) return null;
        const hw: *c.AVHWDeviceContext = @ptrCast(@alignCast(ref.?.data));
        const va: *c.AVVAAPIDeviceContext = @ptrCast(@alignCast(hw.hwctx));
        return .{ .ref = ref.?, .display = va.display };
    }

    pub fn deinit(self: *Device) void {
        var ref: ?*c.AVBufferRef = self.ref;
        c.av_buffer_unref(&ref);
    }
};

/// Whether `codec` decodes into VAAPI surfaces through a device context.
pub fn decodes(codec: *const c.AVCodec) bool {
    var i: c_int = 0;
    while (c.avcodec_get_hw_config(codec, i)) |config| : (i += 1) {
        if (config.*.device_type == c.AV_HWDEVICE_TYPE_VAAPI and
            config.*.methods & c.AV_CODEC_HW_CONFIG_METHOD_HW_DEVICE_CTX != 0) return true;
    }
    return false;
}

/// A decoder for `preferred`'s codec that can use VAAPI: `preferred` itself
/// when it can, else another one for the same codec. FFmpeg prefers
/// libdav1d for AV1, which has no hardware path; its native `av1` decoder does.
pub fn decoderFor(preferred: *const c.AVCodec) ?*const c.AVCodec {
    if (decodes(preferred)) return preferred;
    var it: ?*anyopaque = null;
    while (c.av_codec_iterate(&it)) |codec| {
        if (c.av_codec_is_decoder(codec) != 0 and codec.*.id == preferred.id and decodes(codec)) return codec;
    }
    return null;
}

/// Negotiate only VAAPI on the hardware context. A rejected profile
/// restarts the generation on the preferred software decoder.
pub fn getFormat(_: [*c]c.AVCodecContext, formats: [*c]const c.enum_AVPixelFormat) callconv(.c) c.enum_AVPixelFormat {
    var i: usize = 0;
    while (formats[i] != c.AV_PIX_FMT_NONE) : (i += 1) {
        if (formats[i] == c.AV_PIX_FMT_VAAPI) return formats[i];
    }
    return c.AV_PIX_FMT_NONE;
}

/// The VA surface a VAAPI frame decoded into.
pub fn surfaceOf(frame: *const c.AVFrame) c.VASurfaceID {
    return @intCast(@intFromPtr(frame.data[3]));
}

/// One VA surface as a single-layer dmabuf (NV12, P010, …). The descriptors
/// stay open until `close`; the compositor dups what it imports.
pub const Export = struct {
    format: u32,
    modifier: u64,
    width: u32,
    height: u32,
    objects: [4]std.posix.fd_t = @splat(-1),
    object_count: usize = 0,
    planes: [4]Plane = undefined,
    plane_count: usize = 0,

    pub const Plane = struct { fd: std.posix.fd_t, offset: u32, pitch: u32 };

    pub fn close(self: *Export) void {
        for (self.objects[0..self.object_count]) |fd| _ = std.c.close(fd);
        self.object_count = 0;
    }
};

/// Exports `surface` as one multi-plane format (NV12, P010, …), or null when
/// the driver refuses or the planes use different modifiers (linux-dmabuf
/// v5 rejects that). Composed layers come first (Intel, AMD); a driver that
/// only exports one layer per plane (nvidia-vaapi-driver: R8 + RG88, one
/// object each) is recombined under the surface's own format.
pub fn exportSurface(display: c.VADisplay, surface: c.VASurfaceID) ?Export {
    var d: c.VADRMPRIMESurfaceDescriptor = undefined;
    const read_only = c.VA_EXPORT_SURFACE_READ_ONLY;
    if (c.vaExportSurfaceHandle(display, surface, c.VA_SURFACE_ATTRIB_MEM_TYPE_DRM_PRIME_2, read_only | c.VA_EXPORT_SURFACE_COMPOSED_LAYERS, &d) == c.VA_STATUS_SUCCESS) {
        return fromDescriptor(&d, d.layers[0].drm_format, d.num_layers == 1);
    }
    if (c.vaExportSurfaceHandle(display, surface, c.VA_SURFACE_ATTRIB_MEM_TYPE_DRM_PRIME_2, read_only | c.VA_EXPORT_SURFACE_SEPARATE_LAYERS, &d) == c.VA_STATUS_SUCCESS) {
        var single = true;
        for (d.layers[0..@min(d.num_layers, d.layers.len)]) |layer| single = single and layer.num_planes == 1;
        return fromDescriptor(&d, drmFormat(d.fourcc) orelse 0, single and d.num_layers >= 2);
    }
    return null;
}

/// The DRM format of a VA surface format, for recombined layers.
fn drmFormat(fourcc: u32) ?u32 {
    return switch (fourcc) {
        c.VA_FOURCC_NV12 => c.DRM_FORMAT_NV12,
        c.VA_FOURCC_P010 => c.DRM_FORMAT_P010,
        c.VA_FOURCC_P012 => c.DRM_FORMAT_P012,
        c.VA_FOURCC_P016 => c.DRM_FORMAT_P016,
        else => null,
    };
}

/// Takes the descriptor's objects and lists every layer's planes in order.
/// `usable` is the caller's verdict on the layer layout; the descriptors are
/// closed when anything is off.
fn fromDescriptor(d: *const c.VADRMPRIMESurfaceDescriptor, format: u32, usable: bool) ?Export {
    var out: Export = .{ .format = format, .modifier = d.objects[0].drm_format_modifier, .width = d.width, .height = d.height };
    out.object_count = @min(d.num_objects, out.objects.len);
    for (0..out.object_count) |i| out.objects[i] = d.objects[i].fd;
    // Close anything past what we keep before deciding.
    for (out.object_count..d.num_objects) |i| _ = std.c.close(d.objects[i].fd);
    if (!usable or format == 0 or d.num_objects > out.objects.len or d.num_layers > d.layers.len) {
        out.close();
        return null;
    }
    for (d.layers[0..d.num_layers]) |layer| {
        for (0..layer.num_planes) |p| {
            const object = layer.object_index[p];
            if (out.plane_count == out.planes.len or object >= out.object_count or
                d.objects[object].drm_format_modifier != out.modifier)
            {
                out.close();
                return null;
            }
            out.planes[out.plane_count] = .{ .fd = out.objects[object], .offset = layer.offset[p], .pitch = layer.pitch[p] };
            out.plane_count += 1;
        }
    }
    if (out.plane_count == 0) {
        out.close();
        return null;
    }
    return out;
}

/// Waits for the decoder to finish writing `surface`; required before the
/// compositor samples the exported memory.
pub fn sync(display: c.VADisplay, surface: c.VASurfaceID) bool {
    return c.vaSyncSurface(display, surface) == c.VA_STATUS_SUCCESS;
}

/// The render node of DRM device `dev` (from linux-dmabuf feedback), written
/// into `buf`.
pub fn renderNode(dev: u64, buf: []u8) ?[:0]const u8 {
    var device: c.drmDevicePtr = null;
    if (c.drmGetDeviceFromDevId(@intCast(dev), 0, &device) != 0 or device == null) return null;
    defer c.drmFreeDevice(&device);
    if (device.*.available_nodes & (1 << c.DRM_NODE_RENDER) == 0) return null;
    const path = std.mem.span(device.*.nodes[c.DRM_NODE_RENDER]);
    if (path.len + 1 > buf.len) return null;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return buf[0..path.len :0];
}
