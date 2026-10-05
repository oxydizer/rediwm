const std = @import("std");
const posix = std.posix;
const c = std.posix.system;
const wl = @import("wayland").server.wl;

const encode = @import("encode.zig");
const protocol = @import("../ipc/protocol.zig");
const log = std.log.scoped(.screenshot_worker);

pub const Job = struct {
    job_id: u64,
    client_id: ?u64 = null,
    request_id: ?protocol.RequestId = null,
    width: u32,
    height: u32,
    output_name: []const u8,
    capture_mode: []const u8,
    frame_seq: u64,
    path: ?[]const u8,
    pixels: []u32,
    crop_applied: ?protocol.RectData = null,
};

pub const Result = struct {
    job_id: u64,
    client_id: ?u64 = null,
    request_id: ?protocol.RequestId = null,
    width: u32,
    height: u32,
    output_name: []const u8,
    capture_mode: []const u8,
    frame_seq: u64,
    crop_applied: ?protocol.RectData = null,
    path: ?[]const u8 = null,
    data: ?[]const u8 = null,
    png: ?[]const u8 = null,
    err_msg: ?[]const u8 = null,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        allocator.free(self.output_name);
        allocator.free(self.capture_mode);
        if (self.path) |p| allocator.free(p);
        if (self.data) |d| allocator.free(d);
        if (self.png) |p| allocator.free(p);
        if (self.err_msg) |e| allocator.free(e);
    }
};

pub const WorkerPool = struct {
    allocator: std.mem.Allocator,
    event_loop: *wl.EventLoop,
    eventfd: posix.fd_t,
    event_source: ?*wl.EventSource = null,
    mutex: c.pthread_mutex_t = c.PTHREAD_MUTEX_INITIALIZER,
    cond: c.pthread_cond_t = c.PTHREAD_COND_INITIALIZER,
    job_queue: std.ArrayList(Job),
    result_queue: std.ArrayList(Result),
    running: bool = true,
    threads: []std.Thread,
    on_complete: *const fn (res: Result) void,

    pub fn init(
        allocator: std.mem.Allocator,
        event_loop: *wl.EventLoop,
        on_complete: *const fn (res: Result) void,
    ) !*WorkerPool {
        const pool = try allocator.create(WorkerPool);
        errdefer allocator.destroy(pool);

        const efd_res = c.eventfd(0, @intCast(std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.NONBLOCK));
        if (efd_res < 0) return error.EventFdFailed;
        const efd: posix.fd_t = efd_res;
        errdefer _ = c.close(efd);

        pool.* = .{
            .allocator = allocator,
            .event_loop = event_loop,
            .eventfd = efd,
            .job_queue = std.ArrayList(Job).empty,
            .result_queue = std.ArrayList(Result).empty,
            .running = true,
            .threads = &.{},
            .on_complete = on_complete,
        };

        const source = event_loop.addFd(
            *WorkerPool,
            efd,
            .{ .readable = true },
            handleEventFd,
            pool,
        ) catch return error.EventLoopFailed;
        pool.event_source = source;

        const num_workers: usize = 2;
        const threads = try allocator.alloc(std.Thread, num_workers);
        errdefer allocator.free(threads);

        for (threads, 0..) |*t, i| {
            _ = i;
            t.* = try std.Thread.spawn(.{}, workerThreadMain, .{pool});
        }
        pool.threads = threads;

        return pool;
    }

    fn lock(pool: *WorkerPool) void {
        _ = c.pthread_mutex_lock(&pool.mutex);
    }
    fn unlock(pool: *WorkerPool) void {
        _ = c.pthread_mutex_unlock(&pool.mutex);
    }
    fn wait(pool: *WorkerPool) void {
        _ = c.pthread_cond_wait(&pool.cond, &pool.mutex);
    }
    fn signal(pool: *WorkerPool) void {
        _ = c.pthread_cond_signal(&pool.cond);
    }
    fn broadcast(pool: *WorkerPool) void {
        _ = c.pthread_cond_broadcast(&pool.cond);
    }

    pub fn deinit(pool: *WorkerPool) void {
        pool.lock();
        pool.running = false;
        pool.broadcast();
        pool.unlock();

        for (pool.threads) |t| {
            t.join();
        }
        pool.allocator.free(pool.threads);

        if (pool.event_source) |source| {
            source.remove();
        }
        _ = c.close(pool.eventfd);

        pool.lock();
        for (pool.job_queue.items) |*job| {
            pool.allocator.free(job.output_name);
            pool.allocator.free(job.capture_mode);
            if (job.path) |p| pool.allocator.free(p);
            pool.allocator.free(job.pixels);
        }
        pool.job_queue.deinit(pool.allocator);

        for (pool.result_queue.items) |*res| {
            res.deinit(pool.allocator);
        }
        pool.result_queue.deinit(pool.allocator);
        pool.unlock();

        pool.allocator.destroy(pool);
    }

    pub fn enqueue(pool: *WorkerPool, job: Job) !void {
        pool.lock();
        defer pool.unlock();

        try pool.job_queue.append(pool.allocator, job);
        pool.signal();
    }

    fn workerThreadMain(pool: *WorkerPool) void {
        while (true) {
            pool.lock();
            while (pool.running and pool.job_queue.items.len == 0) {
                pool.wait();
            }
            if (!pool.running and pool.job_queue.items.len == 0) {
                pool.unlock();
                break;
            }
            const job = pool.job_queue.orderedRemove(0);
            pool.unlock();

            const res = processJob(pool.allocator, job);

            pool.lock();
            pool.result_queue.append(pool.allocator, res) catch |err| {
                log.err("failed to append worker result: {}", .{err});
            };
            pool.unlock();

            // Notify event loop
            const val: u64 = 1;
            _ = c.write(pool.eventfd, std.mem.asBytes(&val), @sizeOf(u64));
        }
    }

    fn processJob(allocator: std.mem.Allocator, job: Job) Result {
        const result = processJobInner(allocator, job);
        if (result.path == null) if (job.path) |path| allocator.free(path);
        return result;
    }

    fn processJobInner(allocator: std.mem.Allocator, job: Job) Result {
        defer allocator.free(job.pixels);

        const png_bytes = encode.encodePng(
            allocator,
            job.width,
            job.height,
            job.pixels,
            job.width,
        ) catch |err| {
            const msg = std.fmt.allocPrint(allocator, "CaptureFailed: PNG encoding failed ({s})", .{@errorName(err)}) catch null;
            return .{
                .job_id = job.job_id,
                .client_id = job.client_id,
                .request_id = job.request_id,
                .width = job.width,
                .height = job.height,
                .output_name = job.output_name,
                .capture_mode = job.capture_mode,
                .frame_seq = job.frame_seq,
                .crop_applied = job.crop_applied,
                .err_msg = msg,
            };
        };
        defer allocator.free(png_bytes);

        if (png_bytes.len > 64 * 1024 * 1024) {
            const msg = std.fmt.allocPrint(allocator, "CaptureFailed: encoded PNG exceeds 64 MiB limit", .{}) catch null;
            return .{
                .job_id = job.job_id,
                .client_id = job.client_id,
                .request_id = job.request_id,
                .width = job.width,
                .height = job.height,
                .output_name = job.output_name,
                .capture_mode = job.capture_mode,
                .frame_seq = job.frame_seq,
                .crop_applied = job.crop_applied,
                .err_msg = msg,
            };
        }

        if (job.path) |dest_path| {
            // Write PNG to file
            @import("save.zig").writePngFile(dest_path, png_bytes) catch |err| {
                const msg = std.fmt.allocPrint(allocator, "CaptureFailed: could not save {s}: {s}", .{ dest_path, @errorName(err) }) catch null;
                return .{
                    .job_id = job.job_id,
                    .client_id = job.client_id,
                    .request_id = job.request_id,
                    .width = job.width,
                    .height = job.height,
                    .output_name = job.output_name,
                    .capture_mode = job.capture_mode,
                    .frame_seq = job.frame_seq,
                    .crop_applied = job.crop_applied,
                    .err_msg = msg,
                };
            };
            return .{
                .job_id = job.job_id,
                .client_id = job.client_id,
                .request_id = job.request_id,
                .width = job.width,
                .height = job.height,
                .output_name = job.output_name,
                .capture_mode = job.capture_mode,
                .frame_seq = job.frame_seq,
                .crop_applied = job.crop_applied,
                .path = dest_path,
                .data = null,
                .png = if (job.client_id == null) allocator.dupe(u8, png_bytes) catch null else null,
            };
        } else {
            // Encode base64
            const base64_str = encode.encodeBase64(allocator, png_bytes) catch |err| {
                const msg = std.fmt.allocPrint(allocator, "CaptureFailed: base64 encoding failed ({s})", .{@errorName(err)}) catch null;
                return .{
                    .job_id = job.job_id,
                    .client_id = job.client_id,
                    .request_id = job.request_id,
                    .width = job.width,
                    .height = job.height,
                    .output_name = job.output_name,
                    .capture_mode = job.capture_mode,
                    .frame_seq = job.frame_seq,
                    .crop_applied = job.crop_applied,
                    .err_msg = msg,
                };
            };

            if (base64_str.len > 96 * 1024 * 1024) {
                allocator.free(base64_str);
                const msg = std.fmt.allocPrint(allocator, "CaptureFailed: base64 payload exceeds 96 MiB limit", .{}) catch null;
                return .{
                    .job_id = job.job_id,
                    .client_id = job.client_id,
                    .request_id = job.request_id,
                    .width = job.width,
                    .height = job.height,
                    .output_name = job.output_name,
                    .capture_mode = job.capture_mode,
                    .frame_seq = job.frame_seq,
                    .crop_applied = job.crop_applied,
                    .err_msg = msg,
                };
            }

            return .{
                .job_id = job.job_id,
                .client_id = job.client_id,
                .request_id = job.request_id,
                .width = job.width,
                .height = job.height,
                .output_name = job.output_name,
                .capture_mode = job.capture_mode,
                .frame_seq = job.frame_seq,
                .crop_applied = job.crop_applied,
                .path = null,
                .data = base64_str,
            };
        }
    }
};

fn handleEventFd(fd: c_int, mask: wl.EventMask, pool: *WorkerPool) c_int {
    _ = mask;
    var buf: [8]u8 = undefined;
    _ = c.read(fd, &buf, buf.len);

    while (true) {
        pool.lock();
        if (pool.result_queue.items.len == 0) {
            pool.unlock();
            break;
        }
        var res = pool.result_queue.orderedRemove(0);
        pool.unlock();

        pool.on_complete(res);
        res.deinit(pool.allocator);
    }
    return 0;
}
