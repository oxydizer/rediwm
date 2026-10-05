// Small, disposable warmup after the first successful scene submission.
// Icon decoding stays on its worker; font caches stay on the compositor thread.
const std = @import("std");
const wl = @import("wayland").server.wl;
const Server = @import("Server.zig");
const text = @import("ui").text;
const theme = @import("ui").theme;
const geometry = @import("geometry.zig");
const Model = @import("start_menu/model.zig").Model;
const gpa = @import("main.zig").gpa;

const Warmup = @This();
started: bool = false,
timer: ?*wl.EventSource = null,
step: usize = 0,

pub fn schedule(self: *Warmup, server: *Server) void {
    if (self.started) return;
    self.started = true;
    self.timer = server.wl_server.getEventLoop().addTimer(*Server, tick, server) catch return;
    self.timer.?.timerUpdate(1) catch self.deinit();
}

pub fn deinit(self: *Warmup) void {
    if (self.timer) |timer| timer.remove();
    self.timer = null;
}

fn tick(server: *Server) c_int {
    const self = &server.startup_warmup;
    if (self.step == 0) {
        // The desktop's worker scans ~/Desktop and loads icons off-thread;
        // starting it after the first frame keeps it out of startup.
        server.syncDesktop();
        // Match the launcher's initial alphabetical ordering, including Settings.
        // Eight rows is a bounded first-page approximation, not a catalog sweep.
        // If the user already opened the menu, its requests own the queue.
        if (server.input.open_start_menu == null) prefetchFirstPage(server);
    } else {
        // One font/size per turn. Use actual UI sizes and a small character set;
        // arbitrary titles, languages and sizes continue to populate on demand.
        const Job = struct { font: text.Font = .manrope, size: f32, chars: []const u8 = common };
        const jobs = [_]Job{
            .{ .font = .manrope_bold, .size = 13.5 },
            .{ .size = 11.5 },
            .{ .size = theme.global.font_size },
            .{ .size = theme.global.title_size },
            .{ .size = theme.global.taskbar_title_size },
            .{ .size = theme.global.button_font_size },
            .{ .size = 14, .chars = "0123456789: APMapm" },
            .{ .size = 11 },
            .{ .font = .mono, .size = 12, .chars = "0123456789:%" },
            .{ .font = .mono_bold, .size = @import("taskbar/start_button.zig").glyph_size_px, .chars = "R" },
        };
        const job = jobs[self.step - 1];
        text.warmGlyphs(job.font, job.size, server.maxOutputScale(), job.chars) catch |err| {
            std.log.scoped(.startup).debug("font warmup skipped: {}", .{err});
        };
        if (self.step == jobs.len) {
            self.deinit();
            return 0;
        }
    }
    self.step += 1;
    self.timer.?.timerUpdate(1) catch self.deinit();
    return 0;
}

const common = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 .,!?-_:()/…";

pub fn onCatalogReady(self: *Warmup, server: *Server) void {
    if (!self.started) return;
    if (server.input.open_start_menu != null) return;
    prefetchFirstPage(server);
}

fn prefetchFirstPage(server: *Server) void {
    var model = Model.init(gpa);
    defer model.deinit();
    const snap = server.start_menu_catalog.retainSnapshot();
    defer snap.release();
    model.bindSnapshot(snap, false) catch return;
    for (model.results[0..@min(8, model.results.len)]) |result| {
        if (result.icon) |name| server.iconPrefetch(name, geometry.devicePixels(38, server.maxOutputScale()));
    }
}
