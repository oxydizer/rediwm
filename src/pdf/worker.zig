//! Dedicated background worker thread owning the Poppler document handle.
//! All document parsing, rendering and text extraction take place here.
const std = @import("std");
const c = @import("c.zig");
const layout = @import("layout.zig");
const document = @import("document.zig");

const a = std.heap.c_allocator;

fn freePassword(password: [:0]u8) void {
    std.crypto.secureZero(u8, password);
    _ = c.api.munlock(password.ptr, password.len + 1);
    std.heap.page_allocator.free(password);
}

pub const JobKind = enum {
    open,
    fetch_sizes,
    render_page,
    render_thumb,
    extract_content,
    search,
};

pub const Job = struct {
    kind: JobKind,
    priority: u8, // 0 = highest, 5 = lowest
    generation: u64,

    // Open params
    password: ?[:0]u8 = null,

    // Page / Thumb params
    page_index: usize = 0,
    scale: f64 = 1.0,
    rotation: layout.Rotation = .deg0,
    clip: ?layout.Rect = null,
    card_w: f64 = 0,
    card_h: f64 = 0,

    // Fetch sizes params
    start_page: usize = 0,
    batch_count: usize = 0,

    // Search params
    query: ?[:0]const u8 = null,

    pub fn deinit(self: *Job) void {
        if (self.password) |p| freePassword(p);
        if (self.query) |q| a.free(q);
        self.* = undefined;
    }
};

pub const ResultKind = enum {
    open_done,
    open_failed,
    page_rendered,
    page_failed,
    thumb_rendered,
    page_sizes_batch,
    content_extracted,
    search_matches,
};

pub const OpenDone = struct {
    page_count: usize,
    first_page_size: layout.PageSize,
    outline: ?[]document.OutlineItem = null,
};

pub const PageRendered = struct {
    page_index: usize,
    scale: f64,
    rotation: layout.Rotation,
    clip: ?layout.Rect,
    rendered: document.RenderedPage,
};

pub const ThumbRendered = struct {
    page_index: usize,
    rotation: layout.Rotation,
    card_w: u16,
    card_h: u16,
    rendered: document.RenderedPage,
};

pub const PageSizesBatch = struct {
    start: usize,
    sizes: []layout.PageSize,
};

pub const ContentExtracted = struct {
    page_index: usize,
    text: ?[:0]u8,
    links: []document.Link,
};

pub const SearchMatches = struct {
    page_index: usize,
    rects: []layout.Rect,
};

pub const ResultPayload = union(ResultKind) {
    open_done: OpenDone,
    open_failed: struct { err: anyerror },
    page_rendered: PageRendered,
    page_failed: struct { page_index: usize, err: anyerror },
    thumb_rendered: ThumbRendered,
    page_sizes_batch: PageSizesBatch,
    content_extracted: ContentExtracted,
    search_matches: SearchMatches,
};

pub const Result = struct {
    generation: u64,
    payload: ResultPayload,

    pub fn deinit(self: *Result) void {
        switch (self.payload) {
            .open_done => |od| {
                if (od.outline) |items| {
                    for (items) |it| it.deinit(a);
                    a.free(items);
                }
            },
            .page_rendered => |pr| pr.rendered.deinit(),
            .thumb_rendered => |tr| tr.rendered.deinit(),
            .page_sizes_batch => |b| a.free(b.sizes),
            .content_extracted => |ce| {
                if (ce.text) |t| a.free(t);
                for (ce.links) |l| l.deinit(a);
                a.free(ce.links);
            },
            .search_matches => |sm| a.free(sm.rects),
            else => {},
        }
    }
};

pub const Worker = struct {
    /// Borrowed for this worker's lifetime. Only this file can be opened.
    document_fd: c_int,
    mutex: c.api.pthread_mutex_t = undefined,
    cond: c.api.pthread_cond_t = undefined,
    thread: ?std.Thread = null,
    fds: [2]c_int = undefined,
    stop: bool = false,

    generation: u64 = 0,
    doc: ?document.Document = null,

    // Bounded priority job queue
    jobs: [128]?Job = @splat(null),
    job_count: usize = 0,

    // Bounded results ring buffer
    results: [32]?Result = @splat(null),
    res_head: usize = 0,
    res_tail: usize = 0,
    res_count: usize = 0,

    pub fn init(document_fd: c_int) !*Worker {
        const self = try a.create(Worker);
        errdefer a.destroy(self);
        self.* = .{ .document_fd = document_fd };

        if (c.api.pthread_mutex_init(&self.mutex, null) != 0) return error.MutexFailed;
        errdefer _ = c.api.pthread_mutex_destroy(&self.mutex);

        if (c.api.pthread_cond_init(&self.cond, null) != 0) return error.CondFailed;
        errdefer _ = c.api.pthread_cond_destroy(&self.cond);

        if (c.api.pipe2(&self.fds, c.api.O_CLOEXEC | c.api.O_NONBLOCK) != 0) return error.PipeFailed;
        errdefer {
            _ = c.api.close(self.fds[0]);
            _ = c.api.close(self.fds[1]);
        }

        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }

    pub fn deinit(self: *Worker) void {
        _ = c.api.pthread_mutex_lock(&self.mutex);
        self.stop = true;
        _ = c.api.pthread_cond_signal(&self.cond);
        _ = c.api.pthread_mutex_unlock(&self.mutex);

        if (self.thread) |t| t.join();

        _ = c.api.pthread_mutex_lock(&self.mutex);
        if (self.doc) |*d| d.deinit();

        for (&self.jobs) |*slot| {
            if (slot.*) |*job| {
                job.deinit();
                slot.* = null;
            }
        }
        for (&self.results) |*slot| {
            if (slot.*) |*res| {
                res.deinit();
                slot.* = null;
            }
        }
        _ = c.api.pthread_mutex_unlock(&self.mutex);

        _ = c.api.close(self.fds[0]);
        _ = c.api.close(self.fds[1]);
        _ = c.api.pthread_cond_destroy(&self.cond);
        _ = c.api.pthread_mutex_destroy(&self.mutex);
        a.destroy(self);
    }

    pub fn requestOpen(self: *Worker, password: ?[:0]const u8, generation: u64) !void {
        _ = c.api.pthread_mutex_lock(&self.mutex);
        defer _ = c.api.pthread_mutex_unlock(&self.mutex);

        self.generation = generation;
        self.clearPendingLocked();

        const dup_pass = if (password) |p| blk: {
            const copy = try std.heap.page_allocator.dupeZ(u8, p);
            if (c.api.mlock(copy.ptr, copy.len + 1) != 0) {
                std.crypto.secureZero(u8, copy);
                std.heap.page_allocator.free(copy);
                return error.PasswordMemoryFailed;
            }
            break :blk copy;
        } else null;
        errdefer if (dup_pass) |p| freePassword(p);

        self.jobs[0] = .{
            .kind = .open,
            .priority = 0,
            .generation = generation,
            .password = dup_pass,
        };
        self.job_count = 1;
        _ = c.api.pthread_cond_signal(&self.cond);
    }

    pub fn setRenderJobs(self: *Worker, jobs: []const Job, generation: u64) void {
        _ = c.api.pthread_mutex_lock(&self.mutex);
        defer _ = c.api.pthread_mutex_unlock(&self.mutex);

        if (generation != self.generation) return;

        // Clear existing pending render jobs while preserving open/content/search jobs
        var write_idx: usize = 0;
        for (0..self.job_count) |read_idx| {
            if (self.jobs[read_idx]) |*j| {
                if (j.kind == .render_page or j.kind == .render_thumb) {
                    j.deinit();
                    self.jobs[read_idx] = null;
                } else {
                    self.jobs[write_idx] = self.jobs[read_idx];
                    if (write_idx != read_idx) self.jobs[read_idx] = null;
                    write_idx += 1;
                }
            }
        }
        self.job_count = write_idx;

        // Append new jobs
        for (jobs) |j| {
            if (self.job_count >= self.jobs.len) break;
            self.jobs[self.job_count] = j;
            self.job_count += 1;
        }

        _ = c.api.pthread_cond_signal(&self.cond);
    }

    pub fn requestContent(self: *Worker, page_index: usize, generation: u64) void {
        _ = c.api.pthread_mutex_lock(&self.mutex);
        defer _ = c.api.pthread_mutex_unlock(&self.mutex);

        if (generation != self.generation or self.job_count >= self.jobs.len) return;

        self.jobs[self.job_count] = .{
            .kind = .extract_content,
            .priority = 3,
            .generation = generation,
            .page_index = page_index,
        };
        self.job_count += 1;
        _ = c.api.pthread_cond_signal(&self.cond);
    }

    pub fn requestSearch(self: *Worker, query: [:0]const u8, page_index: usize, generation: u64) !void {
        _ = c.api.pthread_mutex_lock(&self.mutex);
        defer _ = c.api.pthread_mutex_unlock(&self.mutex);

        if (generation != self.generation or self.job_count >= self.jobs.len) return;

        const q = try a.dupeZ(u8, query);
        self.jobs[self.job_count] = .{
            .kind = .search,
            .priority = 4,
            .generation = generation,
            .page_index = page_index,
            .query = q,
        };
        self.job_count += 1;
        _ = c.api.pthread_cond_signal(&self.cond);
    }

    pub fn takeResult(self: *Worker) ?Result {
        _ = c.api.pthread_mutex_lock(&self.mutex);
        defer _ = c.api.pthread_mutex_unlock(&self.mutex);

        if (self.res_count == 0) return null;

        var byte: [1]u8 = undefined;
        _ = c.api.read(self.fds[0], &byte, 1);

        const r = self.results[self.res_head];
        self.results[self.res_head] = null;
        self.res_head = (self.res_head + 1) % self.results.len;
        self.res_count -= 1;

        _ = c.api.pthread_cond_signal(&self.cond);
        return r;
    }

    fn clearPendingLocked(self: *Worker) void {
        for (&self.jobs) |*slot| {
            if (slot.*) |*j| {
                j.deinit();
                slot.* = null;
            }
        }
        self.job_count = 0;

        // Drain older results
        for (&self.results) |*slot| {
            if (slot.*) |*r| {
                r.deinit();
                slot.* = null;
                var byte: [1]u8 = undefined;
                _ = c.api.read(self.fds[0], &byte, 1);
            }
        }
        self.res_head = 0;
        self.res_tail = 0;
        self.res_count = 0;
    }

    fn pushResultLocked(self: *Worker, res: Result) void {
        if (self.stop or res.generation != self.generation) {
            var mut_res = res;
            mut_res.deinit();
            return;
        }

        if (self.res_count >= self.results.len) {
            // Drop oldest result to stay bounded
            var old = self.results[self.res_head].?;
            old.deinit();
            self.results[self.res_head] = null;
            self.res_head = (self.res_head + 1) % self.results.len;
            self.res_count -= 1;
            var byte: [1]u8 = undefined;
            _ = c.api.read(self.fds[0], &byte, 1);
        }

        self.results[self.res_tail] = res;
        self.res_tail = (self.res_tail + 1) % self.results.len;
        self.res_count += 1;
        _ = c.api.write(self.fds[1], "x", 1);
    }

    fn pickBestJobLocked(self: *Worker) ?Job {
        if (self.job_count == 0) return null;

        var best_idx: usize = 0;
        var best_prio: u8 = 255;

        for (0..self.job_count) |i| {
            if (self.jobs[i]) |j| {
                if (j.generation != self.generation) continue;
                if (j.priority < best_prio) {
                    best_prio = j.priority;
                    best_idx = i;
                }
            }
        }

        if (best_prio == 255) {
            // All remaining jobs are stale
            for (0..self.job_count) |i| {
                if (self.jobs[i]) |*j| j.deinit();
                self.jobs[i] = null;
            }
            self.job_count = 0;
            return null;
        }

        const picked = self.jobs[best_idx].?;
        self.jobs[best_idx] = null;

        // Compact remaining
        var w: usize = 0;
        for (0..self.job_count) |r| {
            if (self.jobs[r]) |j| {
                self.jobs[w] = j;
                if (w != r) self.jobs[r] = null;
                w += 1;
            }
        }
        self.job_count = w;

        return picked;
    }

    fn run(self: *Worker) void {
        _ = c.api.pthread_mutex_lock(&self.mutex);
        defer _ = c.api.pthread_mutex_unlock(&self.mutex);

        while (!self.stop) {
            const maybe_job = self.pickBestJobLocked();
            if (maybe_job == null) {
                _ = c.api.pthread_cond_wait(&self.cond, &self.mutex);
                continue;
            }

            var job = maybe_job.?;
            const current_gen = self.generation;
            if (job.generation != current_gen) {
                job.deinit();
                continue;
            }

            switch (job.kind) {
                .open => {
                    const pass = job.password;
                    if (self.doc) |*d| d.deinit();
                    self.doc = null;

                    // Release mutex during disk/library open
                    _ = c.api.pthread_mutex_unlock(&self.mutex);

                    var open_err: ?anyerror = null;
                    var new_doc = document.Document.openFd(self.document_fd, pass) catch |err| blk: {
                        open_err = err;
                        break :blk null;
                    };

                    _ = c.api.pthread_mutex_lock(&self.mutex);

                    if (self.stop or self.generation != current_gen) {
                        if (new_doc) |*d| d.deinit();
                        job.deinit();
                        continue;
                    }

                    if (open_err) |err| {
                        self.pushResultLocked(.{
                            .generation = current_gen,
                            .payload = .{ .open_failed = .{ .err = err } },
                        });
                    } else if (new_doc) |d| {
                        self.doc = d;
                        const count = d.pageCount();
                        const sz0 = d.getPageSize(0) catch layout.PageSize{ .width = 612.0, .height = 792.0 };
                        const outline = d.getOutline(a) catch null;

                        self.pushResultLocked(.{
                            .generation = current_gen,
                            .payload = .{ .open_done = .{
                                .page_count = count,
                                .first_page_size = sz0,
                                .outline = outline,
                            } },
                        });

                        // Queue incremental page size fetches if count > 1
                        if (count > 1 and self.job_count < self.jobs.len) {
                            self.jobs[self.job_count] = .{
                                .kind = .fetch_sizes,
                                .priority = 4,
                                .generation = current_gen,
                                .start_page = 1,
                                .batch_count = @min(count - 1, 100),
                            };
                            self.job_count += 1;
                        }
                    }
                    job.deinit();
                },

                .fetch_sizes => {
                    const doc = self.doc orelse continue;
                    const start = job.start_page;
                    const count = @min(job.batch_count, doc.pageCount() - start);

                    _ = c.api.pthread_mutex_unlock(&self.mutex);

                    const batch = a.alloc(layout.PageSize, count) catch null;
                    if (batch) |b| {
                        for (0..count) |i| {
                            b[i] = doc.getPageSize(start + i) catch layout.PageSize{ .width = 612.0, .height = 792.0 };
                        }
                    }

                    _ = c.api.pthread_mutex_lock(&self.mutex);

                    if (self.stop or self.generation != current_gen) {
                        if (batch) |b| a.free(b);
                        job.deinit();
                        continue;
                    }

                    if (batch) |b| {
                        self.pushResultLocked(.{
                            .generation = current_gen,
                            .payload = .{ .page_sizes_batch = .{ .start = start, .sizes = b } },
                        });

                        const next_start = start + count;
                        if (next_start < doc.pageCount() and self.job_count < self.jobs.len) {
                            self.jobs[self.job_count] = .{
                                .kind = .fetch_sizes,
                                .priority = 4,
                                .generation = current_gen,
                                .start_page = next_start,
                                .batch_count = @min(doc.pageCount() - next_start, 100),
                            };
                            self.job_count += 1;
                        }
                    }
                    job.deinit();
                },

                .render_page => {
                    const doc = self.doc orelse continue;
                    const p_idx = job.page_index;
                    const scale = job.scale;
                    const rot = job.rotation;
                    const clip = job.clip;

                    _ = c.api.pthread_mutex_unlock(&self.mutex);

                    var render_err: ?anyerror = null;
                    const rendered = doc.renderPage(p_idx, .{ .scale = scale, .rotation = rot, .clip = clip }, a) catch |e| blk: {
                        render_err = e;
                        break :blk null;
                    };

                    _ = c.api.pthread_mutex_lock(&self.mutex);

                    if (self.stop or self.generation != current_gen) {
                        if (rendered) |r| r.deinit();
                        job.deinit();
                        continue;
                    }

                    if (rendered) |r| {
                        self.pushResultLocked(.{
                            .generation = current_gen,
                            .payload = .{ .page_rendered = .{
                                .page_index = p_idx,
                                .scale = scale,
                                .rotation = rot,
                                .clip = clip,
                                .rendered = r,
                            } },
                        });
                    } else if (render_err) |e| {
                        self.pushResultLocked(.{
                            .generation = current_gen,
                            .payload = .{ .page_failed = .{ .page_index = p_idx, .err = e } },
                        });
                    }
                    job.deinit();
                },

                .render_thumb => {
                    const doc = self.doc orelse continue;
                    const p_idx = job.page_index;
                    const rot = job.rotation;
                    const scale = job.scale;
                    const card_w: u16 = @intFromFloat(job.card_w);
                    const card_h: u16 = @intFromFloat(job.card_h);

                    _ = c.api.pthread_mutex_unlock(&self.mutex);

                    const rendered = doc.renderPage(p_idx, .{ .scale = scale, .rotation = rot }, a) catch null;

                    _ = c.api.pthread_mutex_lock(&self.mutex);

                    if (self.stop or self.generation != current_gen) {
                        if (rendered) |r| r.deinit();
                        job.deinit();
                        continue;
                    }

                    if (rendered) |r| {
                        self.pushResultLocked(.{
                            .generation = current_gen,
                            .payload = .{ .thumb_rendered = .{
                                .page_index = p_idx,
                                .rotation = rot,
                                .card_w = card_w,
                                .card_h = card_h,
                                .rendered = r,
                            } },
                        });
                    }
                    job.deinit();
                },

                .extract_content => {
                    const doc = self.doc orelse continue;
                    const p_idx = job.page_index;

                    _ = c.api.pthread_mutex_unlock(&self.mutex);

                    const text = doc.getPageText(p_idx, a) catch null;
                    const links = doc.getPageLinks(p_idx, a) catch a.alloc(document.Link, 0) catch null;

                    _ = c.api.pthread_mutex_lock(&self.mutex);

                    if (self.stop or self.generation != current_gen) {
                        if (text) |t| a.free(t);
                        if (links) |ls| {
                            for (ls) |l| l.deinit(a);
                            a.free(ls);
                        }
                        job.deinit();
                        continue;
                    }

                    if (links) |ls| {
                        self.pushResultLocked(.{
                            .generation = current_gen,
                            .payload = .{ .content_extracted = .{
                                .page_index = p_idx,
                                .text = text,
                                .links = ls,
                            } },
                        });
                    }
                    job.deinit();
                },

                .search => {
                    const doc = self.doc orelse continue;
                    const p_idx = job.page_index;
                    const query = job.query orelse continue;

                    _ = c.api.pthread_mutex_unlock(&self.mutex);

                    const rects = doc.findText(p_idx, query, a) catch null;

                    _ = c.api.pthread_mutex_lock(&self.mutex);

                    if (self.stop or self.generation != current_gen) {
                        if (rects) |rs| a.free(rs);
                        job.deinit();
                        continue;
                    }

                    if (rects) |rs| {
                        self.pushResultLocked(.{
                            .generation = current_gen,
                            .payload = .{ .search_matches = .{
                                .page_index = p_idx,
                                .rects = rs,
                            } },
                        });
                    }
                    job.deinit();
                },
            }
        }
    }
};
