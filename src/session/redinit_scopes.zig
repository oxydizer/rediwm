//! Bounded off-thread adoption. No compositor frame waits on the user manager.
const std = @import("std");
const c = @import("c");
const platform = @import("platform");
const a = std.heap.c_allocator;
const Job = struct { pid: i32, name: [48]u8 = @splat(0) };

pub const Worker = struct {
    socket: [:0]u8,
    mutex: c.pthread_mutex_t = undefined,
    condition: c.pthread_cond_t = undefined,
    jobs: [32]Job = undefined,
    count: usize = 0,
    stop: bool = false,
    thread: ?std.Thread = null,

    pub fn create(environ: std.process.Environ) !?*Worker {
        const runtime = environ.getPosix("XDG_RUNTIME_DIR") orelse return null;
        const socket = (try platform.redinit.path(a, runtime)) orelse return null;
        errdefer a.free(socket);
        const self = try a.create(Worker);
        errdefer a.destroy(self);
        self.* = .{ .socket = socket };
        if (c.pthread_mutex_init(&self.mutex, null) != 0) return error.MutexFailed;
        errdefer _ = c.pthread_mutex_destroy(&self.mutex);
        if (c.pthread_cond_init(&self.condition, null) != 0) return error.ConditionFailed;
        errdefer _ = c.pthread_cond_destroy(&self.condition);
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }
    pub fn destroy(self: *Worker) void {
        _ = c.pthread_mutex_lock(&self.mutex);
        self.stop = true;
        _ = c.pthread_cond_signal(&self.condition);
        _ = c.pthread_mutex_unlock(&self.mutex);
        if (self.thread) |thread| thread.join();
        _ = c.pthread_cond_destroy(&self.condition);
        _ = c.pthread_mutex_destroy(&self.mutex);
        a.free(self.socket);
        a.destroy(self);
    }
    pub fn place(self: *Worker, pid: i32, id: []const u8) void {
        var job: Job = .{ .pid = pid };
        var app: [20]u8 = undefined;
        const n = @min(id.len, app.len);
        for (id[0..n], 0..) |ch, i| app[i] = if (std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '.') ch else '-';
        _ = std.fmt.bufPrintSentinel(&job.name, "app-{s}-{d}", .{ app[0..n], pid }, 0) catch return;
        _ = c.pthread_mutex_lock(&self.mutex);
        defer _ = c.pthread_mutex_unlock(&self.mutex);
        if (self.stop or self.count == self.jobs.len) return;
        self.jobs[self.count] = job;
        self.count += 1;
        _ = c.pthread_cond_signal(&self.condition);
    }
    fn run(self: *Worker) void {
        while (true) {
            _ = c.pthread_mutex_lock(&self.mutex);
            while (self.count == 0 and !self.stop) _ = c.pthread_cond_wait(&self.condition, &self.mutex);
            if (self.stop) { _ = c.pthread_mutex_unlock(&self.mutex); return; }
            const job = self.jobs[0];
            self.count -= 1;
            std.mem.copyForwards(Job, &self.jobs, self.jobs[1 .. self.count + 1]);
            _ = c.pthread_mutex_unlock(&self.mutex);
            platform.redinit.adopt(self.socket, std.mem.sliceTo(&job.name, 0), job.pid) catch |err|
                std.log.scoped(.app_scope).debug("Redinit adoption for pid {d}: {t}", .{ job.pid, err });
        }
    }
};
