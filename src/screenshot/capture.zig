const std = @import("std");
const posix = std.posix;
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");

const Server = @import("../Server.zig");
const Output = @import("../Output.zig");
const Toplevel = @import("../Toplevel.zig");
const protocol = @import("../ipc/protocol.zig");
const worker = @import("worker.zig");
const log = std.log.scoped(.screenshot);

const DRM_FORMAT_ARGB8888: u32 = 0x34325241;

pub const PendingJob = struct {
    job_id: u64,
    client_id: ?u64 = null,
    request_id: ?protocol.RequestId = null,
    output: *Output,
    output_name: []const u8,
    capture_mode: []const u8,
    window_id: ?u64 = null,
    path: ?[]const u8,
    include_cursor: bool,
    crop_box: ?wlr.Box, // logical box relative to output
    is_device_crop: bool = false,
    device_crop: ?protocol.RectData = null,
};

pub const Manager = struct {
    server: *Server,
    allocator: std.mem.Allocator,
    worker_pool: *worker.WorkerPool,
    pending_jobs: std.ArrayList(PendingJob),
    next_job_id: u64 = 1,
    frame_seq: u64 = 1,

    pub fn create(server: *Server, allocator: std.mem.Allocator) !*Manager {
        const mgr = try allocator.create(Manager);
        errdefer allocator.destroy(mgr);

        // Store active Manager global reference for worker callback
        global_mgr = mgr;

        const pool = try worker.WorkerPool.init(allocator, server.wl_server.getEventLoop(), onWorkerComplete);
        errdefer pool.deinit();

        mgr.* = .{
            .server = server,
            .allocator = allocator,
            .worker_pool = pool,
            .pending_jobs = std.ArrayList(PendingJob).empty,
        };
        return mgr;
    }

    pub fn deinit(mgr: *Manager) void {
        mgr.worker_pool.deinit();
        for (mgr.pending_jobs.items) |*job| {
            mgr.allocator.free(job.output_name);
            mgr.allocator.free(job.capture_mode);
            if (job.path) |p| mgr.allocator.free(p);
        }
        mgr.pending_jobs.deinit(mgr.allocator);
        global_mgr = null;
        mgr.allocator.destroy(mgr);
    }

    pub fn cancelForOutput(mgr: *Manager, output: *Output) void {
        var idx: usize = 0;
        while (idx < mgr.pending_jobs.items.len) {
            if (mgr.pending_jobs.items[idx].output == output) {
                var job = mgr.pending_jobs.orderedRemove(idx);
                failJob(&job, "Output disconnected");
            } else idx += 1;
        }
    }

    pub fn cancelForClient(mgr: *Manager, client_id: u64) void {
        var idx: usize = 0;
        while (idx < mgr.pending_jobs.items.len) {
            if (mgr.pending_jobs.items[idx].client_id == client_id) {
                const job = mgr.pending_jobs.orderedRemove(idx);
                mgr.allocator.free(job.output_name);
                mgr.allocator.free(job.capture_mode);
                if (job.path) |p| mgr.allocator.free(p);
            } else {
                idx += 1;
            }
        }
    }

    pub fn queueRequest(
        mgr: *Manager,
        params: protocol.ScreenshotParams,
        client_id: ?u64,
        request_id: ?protocol.RequestId,
    ) !protocol.Response {
        if (mgr.server.locker != null) return .{ .err = "SessionLocked" };
        if (mgr.server.polkit_dialog != null) return .{ .err = "AuthenticationActive" };
        if (mgr.pending_jobs.items.len >= 2) {
            return .{ .err = "Busy" };
        }

        // Validate mode
        const mode_str = params.mode orelse if (params.window_id != null) "visible-region" else "output";

        if (!std.mem.eql(u8, mode_str, "output") and
            !std.mem.eql(u8, mode_str, "visible-region") and
            !std.mem.eql(u8, mode_str, "isolated-window"))
        {
            const msg = try std.fmt.allocPrint(mgr.allocator, "InvalidMode: unknown mode {s}", .{mode_str});
            return .{ .err = msg };
        }

        // Validate output
        const target_output: *Output = if (params.output) |name|
            mgr.server.findOutputByName(name) orelse {
                const msg = try std.fmt.allocPrint(mgr.allocator, "UnknownOutput: {s}", .{name});
                return .{ .err = msg };
            }
        else
            mgr.server.getDefaultOutput() orelse return .{ .err = "NoOutput" };

        var out_box: wlr.Box = undefined;
        mgr.server.output_layout.getBox(target_output.wlr_output, &out_box);

        var crop_box: ?wlr.Box = null;
        var is_device_crop: bool = false;
        var dev_crop: ?protocol.RectData = null;

        if (params.crop) |crop| {
            const coord_space = params.crop_space orelse "logical";
            if (std.mem.eql(u8, coord_space, "device")) {
                is_device_crop = true;
                dev_crop = .{
                    .x = crop.x,
                    .y = crop.y,
                    .width = crop.width,
                    .height = crop.height,
                };
            } else {
                crop_box = .{
                    .x = crop.x,
                    .y = crop.y,
                    .width = crop.width,
                    .height = crop.height,
                };
            }
        }

        if (std.mem.eql(u8, mode_str, "visible-region")) {
            const win_id = params.window_id orelse return .{ .err = "InvalidRequest: visible-region mode requires window_id" };
            const toplevel = mgr.server.findToplevelById(win_id) orelse {
                const msg = try std.fmt.allocPrint(mgr.allocator, "UnknownWindow: {d}", .{win_id});
                return .{ .err = msg };
            };

            if (toplevel.minimized) return .{ .err = "WindowIsMinimized" };
            if (!toplevel.isMapped()) return .{ .err = "WindowNotVisible" };

            // Decorated frame geometry
            const a = mgr.server.world.toLayout(@floatFromInt(toplevel.x), @floatFromInt(toplevel.y));
            const b = mgr.server.world.toLayout(@floatFromInt(toplevel.x + toplevel.chrome_width), @floatFromInt(toplevel.y + toplevel.chrome_height));
            const win_x: i32 = @intFromFloat(@round(a.x));
            const win_y: i32 = @intFromFloat(@round(a.y));
            const win_w: i32 = @as(i32, @intFromFloat(@round(b.x))) - win_x;
            const win_h: i32 = @as(i32, @intFromFloat(@round(b.y))) - win_y;

            // Intersect with output logical box
            const ix = @max(win_x, out_box.x);
            const iy = @max(win_y, out_box.y);
            const ix2 = @min(win_x + win_w, out_box.x + out_box.width);
            const iy2 = @min(win_y + win_h, out_box.y + out_box.height);

            if (ix2 <= ix or iy2 <= iy) {
                return .{ .err = "WindowNotVisible" };
            }

            // Store relative to output origin
            crop_box = .{
                .x = ix - out_box.x,
                .y = iy - out_box.y,
                .width = ix2 - ix,
                .height = iy2 - iy,
            };
        } else if (std.mem.eql(u8, mode_str, "isolated-window")) {
            const win_id = params.window_id orelse return .{ .err = "InvalidRequest: isolated-window mode requires window_id" };
            const toplevel = mgr.server.findToplevelById(win_id) orelse {
                const msg = try std.fmt.allocPrint(mgr.allocator, "UnknownWindow: {d}", .{win_id});
                return .{ .err = msg };
            };

            if (toplevel.minimized) return .{ .err = "WindowIsMinimized" };
            if (!toplevel.isMapped()) return .{ .err = "WindowNotVisible" };

            const shadow_margin: i32 = @intFromFloat(@ceil(@import("ui").theme.global.shadow_size));
            const a = mgr.server.world.toLayout(@floatFromInt(toplevel.x), @floatFromInt(toplevel.y));
            const b = mgr.server.world.toLayout(@floatFromInt(toplevel.x + toplevel.chrome_width), @floatFromInt(toplevel.y + toplevel.chrome_height));
            const win_x: i32 = @as(i32, @intFromFloat(@round(a.x))) - shadow_margin;
            const win_y: i32 = @as(i32, @intFromFloat(@round(a.y))) - shadow_margin;
            const win_w: i32 = @as(i32, @intFromFloat(@round(b.x))) - @as(i32, @intFromFloat(@round(a.x))) + 2 * shadow_margin;
            const win_h: i32 = @as(i32, @intFromFloat(@round(b.y))) - @as(i32, @intFromFloat(@round(a.y))) + 2 * shadow_margin + @as(i32, @intFromFloat(@ceil(@import("ui").theme.global.shadow_offset_y)));

            const ix = @max(win_x, out_box.x);
            const iy = @max(win_y, out_box.y);
            const ix2 = @min(win_x + win_w, out_box.x + out_box.width);
            const iy2 = @min(win_y + win_h, out_box.y + out_box.height);

            if (ix2 <= ix or iy2 <= iy) {
                return .{ .err = "WindowNotVisible" };
            }

            crop_box = .{
                .x = ix - out_box.x,
                .y = iy - out_box.y,
                .width = ix2 - ix,
                .height = iy2 - iy,
            };
        }

        // Validate path if provided
        if (params.path) |p| {
            if (!std.fs.path.isAbsolute(p)) {
                return .{ .err = "InvalidPath: compositor path must be absolute" };
            }

            // Check if destination file exists
            if (std.posix.openat(std.posix.AT.FDCWD, p, .{}, 0)) |fd| {
                _ = std.posix.system.close(fd);
                const msg = try std.fmt.allocPrint(mgr.allocator, "FileExists: {s}", .{p});
                return .{ .err = msg };
            } else |_| {}
        }

        const job_id = mgr.next_job_id;
        mgr.next_job_id += 1;

        const out_name = std.mem.span(target_output.wlr_output.name);
        const dup_out_name = try mgr.allocator.dupe(u8, out_name);
        errdefer mgr.allocator.free(dup_out_name);

        const dup_mode = try mgr.allocator.dupe(u8, mode_str);
        errdefer mgr.allocator.free(dup_mode);

        const dup_path = if (params.path) |p| try mgr.allocator.dupe(u8, p) else null;

        try mgr.pending_jobs.append(mgr.allocator, .{
            .job_id = job_id,
            .client_id = client_id,
            .request_id = request_id,
            .output = target_output,
            .output_name = dup_out_name,
            .capture_mode = dup_mode,
            .window_id = params.window_id,
            .path = dup_path,
            .include_cursor = params.include_cursor,
            .crop_box = crop_box,
            .is_device_crop = is_device_crop,
            .device_crop = dev_crop,
        });

        target_output.wlr_output.scheduleFrame();
        return .{ .ok = .async_pending };
    }

    pub fn handleOutputFrame(mgr: *Manager, output: *Output) bool {
        var idx: usize = 0;
        while (idx < mgr.pending_jobs.items.len) {
            if (mgr.pending_jobs.items[idx].output == output) {
                var job = mgr.pending_jobs.orderedRemove(idx);
                mgr.processPendingJob(&job);
                return true;
            } else {
                idx += 1;
            }
        }
        return false;
    }

    fn processPendingJob(mgr: *Manager, job: *PendingJob) void {
        if (mgr.server.polkit_dialog != null) {
            failJob(job, "AuthenticationActive");
            return;
        }
        if (mgr.server.locker != null) {
            failJob(job, "SessionLocked");
            return;
        }
        const scene_output = mgr.server.scene.getSceneOutput(job.output.wlr_output) orelse {
            log.err("processPendingJob: no scene output for {s}", .{job.output_name});
            failJob(job, "CaptureFailed: missing scene output");
            return;
        };

        var disabled_nodes = std.ArrayList(*wlr.SceneNode).empty;
        defer disabled_nodes.deinit(mgr.allocator);

        const is_isolated = std.mem.eql(u8, job.capture_mode, "isolated-window");
        if (is_isolated) {
            if (mgr.server.background_tree.node.enabled) {
                mgr.server.background_tree.node.setEnabled(false);
                disabled_nodes.append(mgr.allocator, &mgr.server.background_tree.node) catch {};
            }
            if (mgr.server.taskbar_tree.node.enabled) {
                mgr.server.taskbar_tree.node.setEnabled(false);
                disabled_nodes.append(mgr.allocator, &mgr.server.taskbar_tree.node) catch {};
            }
            if (mgr.server.overlay_tree.node.enabled) {
                mgr.server.overlay_tree.node.setEnabled(false);
                disabled_nodes.append(mgr.allocator, &mgr.server.overlay_tree.node) catch {};
            }
            var it = mgr.server.world.toplevels.iterator(.forward);
            while (it.next()) |tl| {
                if (job.window_id != null and tl.id != job.window_id.?) {
                    if (tl.frame_tree.node.enabled) {
                        tl.frame_tree.node.setEnabled(false);
                        disabled_nodes.append(mgr.allocator, &tl.frame_tree.node) catch {};
                    }
                    if (tl.shadow_tree.node.enabled) {
                        tl.shadow_tree.node.setEnabled(false);
                        disabled_nodes.append(mgr.allocator, &tl.shadow_tree.node) catch {};
                    }
                }
            }
        }

        var state = wlr.Output.State.init();
        defer state.finish();

        if (!scene_output.buildState(&state, null)) {
            if (is_isolated) {
                for (disabled_nodes.items) |node| node.setEnabled(true);
            }
            log.err("processPendingJob: buildState failed for {s}", .{job.output_name});
            failJob(job, "CaptureFailed: scene render failed");
            return;
        }

        const buffer = state.buffer orelse {
            if (is_isolated) {
                for (disabled_nodes.items) |node| node.setEnabled(true);
            }
            log.err("processPendingJob: output state has no buffer for {s}", .{job.output_name});
            failJob(job, "CaptureFailed: missing frame buffer");
            return;
        };

        const texture = wlr.Texture.fromBuffer(mgr.server.renderer, buffer) orelse {
            if (is_isolated) {
                for (disabled_nodes.items) |node| node.setEnabled(true);
            }
            log.err("processPendingJob: failed to create texture from buffer for {s}", .{job.output_name});
            failJob(job, "CaptureFailed: texture creation failed");
            return;
        };
        defer texture.destroy();

        const scale = job.output.wlr_output.scale;
        const buf_w: u32 = @intCast(job.output.wlr_output.width);
        const buf_h: u32 = @intCast(job.output.wlr_output.height);

        var dev_x: u32 = 0;
        var dev_y: u32 = 0;
        var dev_w: u32 = buf_w;
        var dev_h: u32 = buf_h;

        if (job.is_device_crop and job.device_crop != null) {
            const dc = job.device_crop.?;
            dev_x = if (dc.x < 0) 0 else @intCast(dc.x);
            dev_y = if (dc.y < 0) 0 else @intCast(dc.y);
            const dw: u32 = if (dc.width < 0) 0 else @intCast(dc.width);
            const dh: u32 = if (dc.height < 0) 0 else @intCast(dc.height);
            dev_w = if (dev_x + dw > buf_w) (if (buf_w > dev_x) buf_w - dev_x else 0) else dw;
            dev_h = if (dev_y + dh > buf_h) (if (buf_h > dev_y) buf_h - dev_y else 0) else dh;
        } else if (job.crop_box) |cb| {
            const dx = @as(f32, @floatFromInt(cb.x)) * scale;
            const dy = @as(f32, @floatFromInt(cb.y)) * scale;
            const dw = @as(f32, @floatFromInt(cb.width)) * scale;
            const dh = @as(f32, @floatFromInt(cb.height)) * scale;

            dev_x = @as(u32, @intFromFloat(@round(dx)));
            dev_y = @as(u32, @intFromFloat(@round(dy)));
            dev_w = @as(u32, @intFromFloat(@round(dx + dw))) - dev_x;
            dev_h = @as(u32, @intFromFloat(@round(dy + dh))) - dev_y;

            if (dev_x + dev_w > buf_w) dev_w = if (buf_w > dev_x) buf_w - dev_x else 0;
            if (dev_y + dev_h > buf_h) dev_h = if (buf_h > dev_y) buf_h - dev_y else 0;
        }

        if (dev_w == 0 or dev_h == 0) {
            if (is_isolated) {
                for (disabled_nodes.items) |node| node.setEnabled(true);
            }
            failJob(job, "CaptureFailed: zero-size crop box");
            return;
        }

        const total_pixels = @as(u64, dev_w) * @as(u64, dev_h);
        if (total_pixels > 32_000_000) {
            if (is_isolated) {
                for (disabled_nodes.items) |node| node.setEnabled(true);
            }
            failJob(job, "CaptureFailed: image exceeds 32M pixel limit");
            return;
        }

        const pixels = mgr.allocator.alloc(u32, dev_w * dev_h) catch {
            if (is_isolated) {
                for (disabled_nodes.items) |node| node.setEnabled(true);
            }
            failJob(job, "OutOfMemory");
            return;
        };
        errdefer mgr.allocator.free(pixels);

        var read_opts = wlr.Texture.ReadPixelsOptions{
            .data = pixels.ptr,
            .format = DRM_FORMAT_ARGB8888,
            .stride = dev_w * 4,
            .dst_x = 0,
            .dst_y = 0,
            .src_box = .{
                .x = @intCast(dev_x),
                .y = @intCast(dev_y),
                .width = @intCast(dev_w),
                .height = @intCast(dev_h),
            },
        };

        if (!texture.readPixels(&read_opts)) {
            mgr.allocator.free(pixels);
            if (is_isolated) {
                for (disabled_nodes.items) |node| node.setEnabled(true);
            }
            failJob(job, "CaptureFailed: readPixels failed");
            return;
        }

        if (is_isolated) {
            for (disabled_nodes.items) |node| node.setEnabled(true);
            // Render full normal scene cleanly
            var state_normal = wlr.Output.State.init();
            defer state_normal.finish();
            if (scene_output.buildState(&state_normal, null)) {
                if (!job.output.commitFrameState(&state_normal)) {
                    log.err("processPendingJob: scene commit failed for {s}", .{job.output_name});
                }
            } else {
                log.err("processPendingJob: scene buildState failed for {s}", .{job.output_name});
            }
            var now = Output.timestamp();
            scene_output.sendFrameDone(&now);
        } else {
            // Commit frame state to keep output pipeline in sync
            _ = job.output.commitFrameState(&state);
        }

        // Optionally draw cursor
        if (job.include_cursor and !is_isolated) {
            var out_box: wlr.Box = undefined;
            mgr.server.output_layout.getBox(job.output.wlr_output, &out_box);
            const cur_lx = mgr.server.input.cursor.x - @as(f64, @floatFromInt(out_box.x));
            const cur_ly = mgr.server.input.cursor.y - @as(f64, @floatFromInt(out_box.y));

            const cur_cx = @as(i32, @intFromFloat(@round(cur_lx * scale))) - @as(i32, @intCast(dev_x));
            const cur_cy = @as(i32, @intFromFloat(@round(cur_ly * scale))) - @as(i32, @intCast(dev_y));

            drawCursor(pixels, dev_w, dev_h, cur_cx, cur_cy);
        }

        var crop_applied: ?protocol.RectData = null;
        if (job.crop_box != null or job.is_device_crop) {
            crop_applied = .{
                .x = @intCast(dev_x),
                .y = @intCast(dev_y),
                .width = @intCast(dev_w),
                .height = @intCast(dev_h),
            };
        }

        mgr.worker_pool.enqueue(.{
            .job_id = job.job_id,
            .client_id = job.client_id,
            .request_id = job.request_id,
            .width = dev_w,
            .height = dev_h,
            .output_name = job.output_name,
            .capture_mode = job.capture_mode,
            .frame_seq = job.output.frame_seq,
            .path = job.path,
            .pixels = pixels,
            .crop_applied = crop_applied,
        }) catch {
            mgr.allocator.free(pixels);
            failJob(job, "CaptureFailed: worker queue full");
        };
    }
};

var global_mgr: ?*Manager = null;

fn failJob(job: *PendingJob, err_msg: []const u8) void {
    if (global_mgr) |mgr| {
        defer mgr.allocator.free(job.output_name);
        defer mgr.allocator.free(job.capture_mode);
        const res = worker.Result{
            .job_id = job.job_id,
            .client_id = job.client_id,
            .request_id = job.request_id,
            .width = 0,
            .height = 0,
            .output_name = job.output_name,
            .capture_mode = job.capture_mode,
            .frame_seq = 0,
            .crop_applied = null,
            .err_msg = mgr.allocator.dupe(u8, err_msg) catch null,
        };
        onWorkerComplete(res);
        if (res.err_msg) |e| mgr.allocator.free(e);
        if (job.path) |p| mgr.allocator.free(p);
    }
}

fn onWorkerComplete(res: worker.Result) void {
    const mgr = global_mgr orelse return;
    if (res.client_id == null) {
        const picker = @import("selector.zig");
        if (res.err_msg) |err| {
            picker.report(mgr.server, "Screenshot failed", err);
            return;
        }
        if (mgr.server.locker != null or mgr.server.shutting_down) return;
        if (res.png) |png| {
            @import("../clipboard.zig").copyPng(mgr.server, png) catch {
                picker.report(mgr.server, "Screenshot saved; clipboard failed", res.path orelse "");
                return;
            };
            picker.report(mgr.server, "Screenshot saved and copied", res.path orelse "");
        } else picker.report(mgr.server, "Screenshot saved; clipboard failed", res.path orelse "");
        return;
    }
    const ipc = mgr.server.ipc orelse return;
    const client_id = res.client_id.?;
    const client = ipc.findClientById(client_id) orelse return;

    const bw = protocol.BufferWriter{ .list = &client.write_buf, .allocator = ipc.allocator };

    if (res.err_msg) |err_msg| {
        protocol.stringifyResponseWithId(res.request_id, .{ .err = err_msg }, bw) catch {};
    } else {
        const sr = protocol.ScreenshotResult{
            .width = res.width,
            .height = res.height,
            .format = "png",
            .data = res.data,
            .path = res.path,
            .output_name = res.output_name,
            .capture_mode = res.capture_mode,
            .frame_seq = res.frame_seq,
            .crop_applied = res.crop_applied,
        };
        protocol.stringifyResponseWithId(res.request_id, .{ .ok = .{ .screenshot = sr } }, bw) catch {};
    }
    client.updateFdInterest() catch {};
}

fn drawCursor(pixels: []u32, width: u32, height: u32, cursor_x: i32, cursor_y: i32) void {
    const arrow = [_][]const u8{
        "*...........",
        "**..........",
        "*O*.........",
        "*OO*........",
        "*OOO*.......",
        "*OOOO*......",
        "*OOOOO*.....",
        "*OOOOOO*....",
        "*OOOOOOO*...",
        "*OOOOOOOO*..",
        "*OOOOO*****.",
        "*OO*OO*.....",
        "*O*.*OO*....",
        "**...*OO*...",
        "*.....*OO*..",
        ".......**...",
    };

    for (arrow, 0..) |row, ry| {
        const py = cursor_y + @as(i32, @intCast(ry));
        if (py < 0 or py >= height) continue;
        for (row, 0..) |ch, rx| {
            const px = cursor_x + @as(i32, @intCast(rx));
            if (px < 0 or px >= width) continue;
            const idx = @as(usize, @intCast(py)) * width + @as(usize, @intCast(px));
            if (ch == '*') {
                pixels[idx] = 0xFF000000;
            } else if (ch == 'O') {
                pixels[idx] = 0xFFFFFFFF;
            }
        }
    }
}
