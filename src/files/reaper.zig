//! Finishes a closing window's helper threads off the UI thread (threading
//! §10, U16). The listing worker, folder sizes, thumbnails and the Trash count
//! each run threads of their own. A window that goes away tells them to stop
//! and hands them here; the reaper's one thread joins and frees them, so a
//! helper stuck in a syscall on a hung mount holds its memory, not the UI.
//!
//! Items finish in the order they were handed over. A helper that writes
//! another helper's descriptor (the Trash count writes the listing worker's
//! `wake_main`) is therefore joined before that descriptor is closed, as long
//! as it is handed over first; a window retires its listing worker last.
//!
//! The process owns one reaper (`main.run`). It is finished after the windows
//! are gone and the compositor connection is closed; that join, like the
//! coordinator's drain, is the only wait on the main thread.
const std = @import("std");
const c = @import("c.zig").api;

const a = std.heap.c_allocator;

/// A helper to finish: `finish` joins its threads and frees it.
pub const Item = struct {
    context: *anyopaque,
    finish: *const fn (*anyopaque) void,

    pub fn of(helper: anytype, comptime finish: fn (@TypeOf(helper)) void) Item {
        const P = @TypeOf(helper);
        return .{ .context = helper, .finish = struct {
            fn call(context: *anyopaque) void {
                finish(@as(P, @ptrCast(@alignCast(context))));
            }
        }.call };
    }
};

pub const Reaper = struct {
    mutex: c.pthread_mutex_t = undefined,
    cond: c.pthread_cond_t = undefined,
    // Under `mutex`.
    queue: std.ArrayList(Item) = .empty,
    stopping: bool = false,
    finished: usize = 0,
    thread: ?std.Thread = null,

    pub fn start(self: *Reaper) !void {
        self.* = .{};
        if (c.pthread_mutex_init(&self.mutex, null) != 0) return error.MutexInitFailed;
        errdefer _ = c.pthread_mutex_destroy(&self.mutex);
        if (c.pthread_cond_init(&self.cond, null) != 0) return error.CondInitFailed;
        errdefer _ = c.pthread_cond_destroy(&self.cond);
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    /// Takes `item` and returns at once; the reaper thread finishes it. The
    /// lock is never held across a finish, so this never waits on a join.
    /// Out of memory, the item is finished here instead, as before the reaper.
    pub fn hand(self: *Reaper, item: Item) void {
        _ = c.pthread_mutex_lock(&self.mutex);
        const queued = if (self.stopping) false else if (self.queue.append(a, item)) |_| true else |_| false;
        if (queued) _ = c.pthread_cond_signal(&self.cond);
        _ = c.pthread_mutex_unlock(&self.mutex);
        if (!queued) item.finish(item.context);
    }

    /// How many items have been finished; for tests.
    pub fn finishedCount(self: *Reaper) usize {
        _ = c.pthread_mutex_lock(&self.mutex);
        defer _ = c.pthread_mutex_unlock(&self.mutex);
        return self.finished;
    }

    /// Finishes everything handed over, then joins the reaper thread. Blocks
    /// for as long as the slowest helper takes to stop.
    pub fn deinit(self: *Reaper) void {
        _ = c.pthread_mutex_lock(&self.mutex);
        self.stopping = true;
        _ = c.pthread_cond_signal(&self.cond);
        _ = c.pthread_mutex_unlock(&self.mutex);
        if (self.thread) |thread| thread.join();
        self.queue.deinit(a);
        _ = c.pthread_cond_destroy(&self.cond);
        _ = c.pthread_mutex_destroy(&self.mutex);
        self.* = undefined;
    }

    fn run(self: *Reaper) void {
        _ = c.pthread_mutex_lock(&self.mutex);
        while (true) {
            if (self.queue.items.len > 0) {
                const item = self.queue.orderedRemove(0);
                _ = c.pthread_mutex_unlock(&self.mutex);
                item.finish(item.context);
                _ = c.pthread_mutex_lock(&self.mutex);
                self.finished += 1;
                continue;
            }
            if (self.stopping) break;
            _ = c.pthread_cond_wait(&self.cond, &self.mutex);
        }
        _ = c.pthread_mutex_unlock(&self.mutex);
    }
};

/// Tells `helper` to stop (`requestStop`, which never waits) and has `finish`
/// join and free it on `reaper`, or here when there is no reaper (tests that
/// build an App on its own).
pub fn retire(reaper: ?*Reaper, helper: anytype, comptime finish: fn (@TypeOf(helper)) void) void {
    helper.requestStop();
    const r = reaper orelse return finish(helper);
    r.hand(Item.of(helper, finish));
}

test {
    _ = @import("reaper_tests.zig");
}
