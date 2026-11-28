//! Two shm buffers with Cairo image surfaces over them, reused until the
//! compositor releases them. A busy buffer is never written. Each remembers
//! what changed while the other one was shown (`stale`), so a partial repaint
//! of a recycled buffer catches up on it (`ui/repaint.zig`).
const std = @import("std");
const wl = @import("wayland").client.wl;
const c = @import("c_gfx");
const Region = @import("ui").repaint.Region;
const a = std.heap.c_allocator;

pub const Pool = struct {
    shm: *wl.Shm = undefined,
    /// memfd name, for /proc/<pid>/maps.
    name: [*:0]const u8 = "app",
    /// Buffers attached and not yet released.
    outstanding: usize = 0,
    slots: [2]?*Buffer = @splat(null),

    /// A free buffer of `w` x `h`, replacing a free one of another size; null
    /// while both are held by the compositor.
    pub fn acquire(self: *Pool, w: i32, h: i32) !?*Buffer {
        for (self.slots) |slot| if (slot) |buffer| {
            if (!buffer.busy and buffer.w == w and buffer.h == h) return buffer;
        };
        for (&self.slots) |*slot| {
            if (slot.*) |buffer| {
                if (buffer.busy) continue;
                buffer.destroy();
                slot.* = null;
            }
            slot.* = try Buffer.create(self, w, h);
            return slot.*;
        }
        return null;
    }

    /// `damage` was drawn into `buffer`: it is current, and the other buffer
    /// now misses that much too.
    pub fn painted(self: *Pool, buffer: *Buffer, damage: *const Region) void {
        for (self.slots) |slot| if (slot) |other| {
            if (other != buffer) other.stale.merge(damage);
        };
        buffer.stale.clear();
    }

    /// Marks `buffer` held until its release event.
    pub fn submit(self: *Pool, buffer: *Buffer) void {
        buffer.busy = true;
        self.outstanding += 1;
    }

    pub fn deinit(self: *Pool) void {
        for (&self.slots) |*slot| {
            if (slot.*) |buffer| buffer.destroy();
            slot.* = null;
        }
    }
};

pub const Buffer = struct {
    pool: *Pool,
    wl_buffer: *wl.Buffer,
    image: *c.cairo_surface_t,
    memory: *anyopaque,
    len: usize,
    w: i32,
    h: i32,
    busy: bool = false,
    /// What changed since this buffer was last drawn; a new one is all stale.
    stale: Region = .whole,

    fn create(pool: *Pool, w: i32, h: i32) !*Buffer {
        if (w <= 0 or h <= 0 or w > 16384 or h > 16384) return error.InvalidSize;
        const len: usize = @intCast(w * h * 4);
        const fd = c.memfd_create(pool.name, c.MFD_CLOEXEC);
        if (fd < 0) return error.ShmFailed;
        defer _ = c.close(fd);

        if (c.ftruncate(fd, @intCast(len)) != 0) return error.ShmFailed;
        const memory = c.mmap(null, len, c.PROT_READ | c.PROT_WRITE, c.MAP_SHARED, fd, 0);
        if (memory == c.MAP_FAILED) return error.ShmFailed;
        errdefer _ = c.munmap(memory, len);

        const shm_pool = try pool.shm.createPool(fd, @intCast(len));
        defer shm_pool.destroy();

        const buffer = try shm_pool.createBuffer(0, w, h, w * 4, .argb8888);
        errdefer buffer.destroy();

        const image = c.cairo_image_surface_create_for_data(
            @ptrCast(memory),
            c.CAIRO_FORMAT_ARGB32,
            w,
            h,
            w * 4,
        ) orelse return error.CairoFailed;
        errdefer c.cairo_surface_destroy(image);
        if (c.cairo_surface_status(image) != c.CAIRO_STATUS_SUCCESS) return error.CairoFailed;

        const self = try a.create(Buffer);
        self.* = .{
            .pool = pool,
            .wl_buffer = buffer,
            .image = image,
            .memory = memory.?,
            .len = len,
            .w = w,
            .h = h,
        };
        buffer.setListener(*Buffer, released, self);
        return self;
    }

    fn released(_: *wl.Buffer, _: wl.Buffer.Event, self: *Buffer) void {
        self.busy = false;
        self.pool.outstanding -= 1;
    }

    fn destroy(self: *Buffer) void {
        self.wl_buffer.destroy();
        c.cairo_surface_destroy(self.image);
        _ = c.munmap(self.memory, self.len);
        a.destroy(self);
    }
};
