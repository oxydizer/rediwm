//! One wl_buffer per decoder surface, kept for the surface's life. The
//! compositor caches its EGLImage on the buffer (scene_pass_yuv.c), so a new
//! wl_buffer per frame would mean a new import per frame. While attached, a
//! buffer holds a reference to the frame it shows, so the decoder cannot
//! write that surface again before the compositor releases it.
const std = @import("std");
const wl = @import("wayland").client.wl;
const zwp = @import("wayland").client.zwp;
const c = @import("c_av");
const hw = @import("hw.zig");
const Feedback = @import("feedback.zig").Feedback;
const a = std.heap.c_allocator;

pub const Cache = struct {
    display: *wl.Display,
    dmabuf: *zwp.LinuxDmabufV1,
    va: c.VADisplay,
    /// The frames context the live entries come from; a new one (a mid-stream
    /// size change) retires them.
    frames: ?*c.AVBufferRef = null,
    entries: std.ArrayList(*Entry) = .empty,

    pub fn deinit(self: *Cache) void {
        for (self.entries.items) |entry| entry.destroy();
        self.entries.deinit(a);
        c.av_buffer_unref(&self.frames);
    }

    /// The buffer showing `frame` (a VAAPI frame), made on first sight of its
    /// surface. Holds a reference to `frame` until the compositor releases the
    /// buffer. Null when the frame can't be shown this way.
    pub fn show(self: *Cache, frame: *c.AVFrame, feedback: *const Feedback) ?*wl.Buffer {
        const surface = hw.surfaceOf(frame);
        const frames = frame.hw_frames_ctx orelse return null;
        if (self.frames == null or self.frames.?.data != frames.*.data) {
            const ref = c.av_buffer_ref(frames) orelse return null;
            self.retire();
            c.av_buffer_unref(&self.frames);
            self.frames = ref;
        }
        const entry = self.find(surface) orelse self.create(surface, feedback) orelse return null;
        if (entry.held == null) entry.held = c.av_frame_clone(frame) orelse return null;
        return entry.buffer;
    }

    fn find(self: *Cache, surface: c.VASurfaceID) ?*Entry {
        for (self.entries.items) |entry| {
            if (!entry.retired and entry.surface == surface) return entry;
        }
        return null;
    }

    /// Retires every entry: unheld ones go now, held ones on release.
    fn retire(self: *Cache) void {
        var i: usize = 0;
        while (i < self.entries.items.len) {
            const entry = self.entries.items[i];
            entry.retired = true;
            if (entry.held == null) {
                _ = self.entries.swapRemove(i);
                entry.destroy();
            } else i += 1;
        }
    }

    fn create(self: *Cache, surface: c.VASurfaceID, feedback: *const Feedback) ?*Entry {
        var image = hw.exportSurface(self.va, surface) orelse {
            std.log.info("the VAAPI driver did not export a single-layer dmabuf; using shm", .{});
            return null;
        };
        if (!feedback.supports(image.format, image.modifier)) {
            std.log.info("compositor does not import {s} modifier 0x{x}; using shm", .{ fourcc(image.format), image.modifier });
            image.close();
            return null;
        }
        const buffer = self.import(&image) orelse {
            std.log.info("compositor refused a {s} dmabuf (modifier 0x{x}, {d} planes); using shm", .{ fourcc(image.format), image.modifier, image.plane_count });
            image.close();
            return null;
        };
        const entry = a.create(Entry) catch {
            buffer.destroy();
            image.close();
            return null;
        };
        entry.* = .{ .cache = self, .surface = surface, .buffer = buffer, .image = image };
        self.entries.append(a, entry) catch {
            entry.destroy();
            return null;
        };
        buffer.setListener(*Entry, Entry.release, entry);
        return entry;
    }

    fn import(self: *Cache, image: *const hw.Export) ?*wl.Buffer {
        const params = self.dmabuf.createParams() catch return null;
        defer params.destroy();
        for (image.planes[0..image.plane_count], 0..) |plane, i| {
            params.add(plane.fd, @intCast(i), plane.offset, plane.pitch, @truncate(image.modifier >> 32), @truncate(image.modifier));
        }
        const w: i32 = @intCast(image.width);
        const h: i32 = @intCast(image.height);
        var probe: Probe = .{};
        params.setListener(*Probe, Probe.event, &probe);
        params.create(w, h, image.format, .{});
        while (!probe.done) {
            if (self.display.roundtrip() != .SUCCESS) return null;
        }
        return probe.buffer;
    }
};

const Probe = struct {
    done: bool = false,
    buffer: ?*wl.Buffer = null,

    fn event(_: *zwp.LinuxBufferParamsV1, ev: zwp.LinuxBufferParamsV1.Event, self: *Probe) void {
        switch (ev) {
            .created => |created| self.buffer = created.buffer,
            .failed => {},
        }
        self.done = true;
    }
};

const Entry = struct {
    cache: *Cache,
    surface: c.VASurfaceID,
    buffer: *wl.Buffer,
    image: hw.Export,
    held: ?*c.AVFrame = null,
    retired: bool = false,

    fn release(_: *wl.Buffer, _: wl.Buffer.Event, self: *Entry) void {
        self.drop();
        if (!self.retired) return;
        const entries = &self.cache.entries;
        for (entries.items, 0..) |entry, i| {
            if (entry == self) {
                _ = entries.swapRemove(i);
                break;
            }
        }
        self.destroy();
    }

    fn drop(self: *Entry) void {
        var held = self.held;
        if (held != null) c.av_frame_free(&held);
        self.held = null;
    }

    fn destroy(self: *Entry) void {
        self.drop();
        self.buffer.destroy();
        self.image.close();
        a.destroy(self);
    }
};

pub fn fourcc(format: u32) [4]u8 {
    return @bitCast(format);
}
