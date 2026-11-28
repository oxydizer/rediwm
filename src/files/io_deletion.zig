//! Deletion jobs: Delete, Move to Trash, Empty Trash and deleting from the
//! Trash view (docs/plans/files-io-threading-and-ownership.md §8, audit U4 to
//! U6). They are service jobs, not Manager jobs: there is no tree to plan,
//! only paths handed to `rm` or `gio`, or Trash entries removed with their
//! metadata.
//!
//! Each job runs on a worker of this pool, never on the coordinator or a
//! window. The worker works through the paths in small batches, so the job
//! reports progress per batch and a cancel takes effect between batches; a
//! running child is terminated when the job is cancelled.
//!
//! Like every worker task, a job carries an immutable, independently owned
//! payload, reads no Manager state and performs no lifecycle transition. The
//! only shared state is its `Control`, written by the worker with atomics and
//! read by the coordinator.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const platform = @import("platform");
const io_service = @import("io_service.zig");
const io_workers = @import("io_workers.zig");
const trash = @import("trash.zig");

pub const JobId = io_service.JobId;

/// Two workers: one deletion stalled on a hung mount leaves the other free.
pub const worker_count = 2;
/// While workers are stuck, up to this many run (worker-pools §4.3).
pub const worker_cap = 6;
/// Deletion jobs are live jobs, so the live table bounds them.
pub const capacity = io_service.max_live_jobs;
/// Paths per `rm` or `gio` run: progress and cancellation granularity,
/// against the cost of a process per batch.
pub const batch_size = 32;
/// How often a worker checks a running child and the cancel flag.
const child_poll_ms = 20;

/// Shared between the coordinator, which owns it, and the worker running the
/// job.
pub const Control = struct {
    cancel: std.atomic.Value(bool) = .init(false),
    started: std.atomic.Value(bool) = .init(false),
    done_items: std.atomic.Value(u64) = .init(0),
};

pub const Task = struct {
    job_id: JobId,
    /// The submit's payload, moved out of the command. Always `.deletion`.
    payload: *io_service.OwnedPayload,
    control: *Control,
};

pub const Outcome = struct {
    state: io_service.JobState,
    err: ?anyerror = null,
};

pub const Result = struct {
    job_id: JobId,
    payload: *io_service.OwnedPayload,
    outcome: Outcome,
};

pub const Pool = io_workers.WorkerPool(Task, Result);

pub const Context = struct {
    allocator: Allocator,
    /// For spawning `rm` and `gio`; workers only spawn, never wait through it.
    io: std.Io,
};

pub fn create(context: *Context) !*Pool {
    return Pool.initElastic(context.allocator, worker_count, worker_cap, capacity, context, execute, discard);
}

/// How many items the job counts in its progress.
pub fn itemCount(request: *const io_service.DeletionRequest) u64 {
    return if (request.kind == .empty_trash) 1 else request.paths.len;
}

fn execute(raw_context: ?*anyopaque, task: Task) Result {
    const context: *Context = @ptrCast(@alignCast(raw_context.?));
    task.control.started.store(true, .release);
    const request = &task.payload.data.deletion;
    return .{
        .job_id = task.job_id,
        .payload = task.payload,
        .outcome = run(context, request, task.control),
    };
}

fn discard(_: ?*anyopaque, result: Result) void {
    result.payload.deinit();
}

const Tally = struct {
    done: u64 = 0,
    failed: u64 = 0,
};

fn run(context: *Context, request: *const io_service.DeletionRequest, control: *Control) Outcome {
    var tally: Tally = .{};
    const err: ?anyerror = switch (request.kind) {
        .delete, .trash => runBatches(context, request, control, &tally),
        .empty_trash => emptyTrash(context, request, control, &tally),
        .delete_from_trash => deleteFromTrash(context, request, control, &tally),
    };
    const total = itemCount(request);
    if (control.cancel.load(.acquire) and tally.done < total) return .{ .state = .cancelled };
    if (err) |e| if (tally.done == 0) return .{ .state = .failed, .err = e };
    if (tally.failed == 0) return .{ .state = .completed };
    if (tally.failed >= total) return .{ .state = .failed, .err = err orelse error.DeletionFailed };
    return .{ .state = .completed_with_errors, .err = err orelse error.DeletionFailed };
}

/// `rm -r` or `gio trash` over the paths, a batch at a time. Returns the
/// error that stopped the job early (a missing program), or null.
fn runBatches(context: *Context, request: *const io_service.DeletionRequest, control: *Control, tally: *Tally) ?anyerror {
    // GNU rm takes `--interactive=never`; FreeBSD's rm only has `-f`.
    const never_prompt = if (builtin.os.tag == .linux) "--interactive=never" else "-f";
    const prefix: []const []const u8 = if (request.kind == .delete)
        &.{ "rm", "-r", never_prompt, "--" }
    else
        &.{ "gio", "trash", "--" };
    var argv: [4 + batch_size][]const u8 = undefined;
    @memcpy(argv[0..prefix.len], prefix);

    var index: usize = 0;
    while (index < request.paths.len) {
        if (control.cancel.load(.acquire)) return null;
        const batch = request.paths[index..@min(index + batch_size, request.paths.len)];
        for (batch, 0..) |path, i| argv[prefix.len + i] = path;
        switch (runChild(context.io, argv[0 .. prefix.len + batch.len], control)) {
            .ok => tally.done += batch.len,
            .failed => {
                tally.done += batch.len;
                tally.failed += batch.len;
            },
            .cancelled => return null,
            .missing => return if (request.kind == .trash) error.GioNotAvailable else error.DeletionFailed,
            .spawn_failed => {
                tally.done += batch.len;
                tally.failed += batch.len;
            },
        }
        control.done_items.store(tally.done, .release);
        index += batch.len;
    }
    return null;
}

fn emptyTrash(context: *Context, request: *const io_service.DeletionRequest, control: *Control, tally: *Tally) ?anyerror {
    switch (runChild(context.io, &.{ "gio", "trash", "--empty" }, control)) {
        .ok => {},
        .cancelled => return null,
        .missing => return error.GioNotAvailable,
        .failed, .spawn_failed => {
            tally.done = 1;
            tally.failed = 1;
            control.done_items.store(1, .release);
            return error.TrashFailed;
        },
    }
    // gio empties Trash; sweep what it leaves, so no metadata outlives its item.
    if (request.trash_dir) |dir| trash.sweepOrphans(context.allocator, dir);
    tally.done = 1;
    control.done_items.store(1, .release);
    return null;
}

/// Only top-level entries of the Trash have metadata and may go this way;
/// any other path counts as a failure.
fn deleteFromTrash(context: *Context, request: *const io_service.DeletionRequest, control: *Control, tally: *Tally) ?anyerror {
    const dir = request.trash_dir orelse return error.MissingTrashDirectory;
    for (request.paths) |path| {
        if (control.cancel.load(.acquire)) return null;
        const parent = std.fs.path.dirname(path) orelse "";
        const ok = std.mem.eql(u8, parent, dir) and
            trash.deleteMany(context.allocator, dir, &.{std.fs.path.basename(path)}).failed == 0;
        tally.done += 1;
        if (!ok) tally.failed += 1;
        control.done_items.store(tally.done, .release);
    }
    return null;
}

pub const ChildOutcome = enum { ok, failed, cancelled, missing, spawn_failed };

/// Runs `argv` to completion, polling so a cancel can terminate it. Never
/// blocks in a wait: the child is collected with WNOHANG.
pub fn runChild(io: std.Io, argv: []const []const u8, control: *Control) ChildOutcome {
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch |err| return if (err == error.FileNotFound) .missing else .spawn_failed;
    const pid = child.id.?;
    // Collected below; the Child must not wait or kill again.
    child.id = null;
    var terminated = false;
    while (true) {
        if (platform.child.reap(pid)) |status| {
            if (terminated) return .cancelled;
            return if (status == 0) .ok else .failed;
        }
        if (!terminated and control.cancel.load(.acquire)) {
            _ = std.posix.system.kill(pid, .TERM);
            terminated = true;
        }
        _ = std.posix.system.poll(&.{}, 0, child_poll_ms);
    }
}

