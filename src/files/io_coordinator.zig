//! Dedicated process thread for Files Runtime ownership and I/O scheduling.
//!
//! The coordinator is the only consumer of the process Service command queue.
//! It owns all access to Runtime after startup; windows retain only Service
//! handles and immutable updates.
const std = @import("std");
const Allocator = std.mem.Allocator;
const io_runtime = @import("io_runtime.zig");
const io_service = @import("io_service.zig");

const JobId = io_service.JobId;

const RejectionCode = enum(u8) {
    unsupported_command = 1,
    unknown_job = 2,
    invalid_job_state = 3,
    job_not_terminal = 4,
    other = 255,
};

pub const Coordinator = struct {
    allocator: Allocator,
    service: *io_service.Service,
    runtime: *io_runtime.Runtime,
    thread: ?std.Thread = null,

    /// Initialize at a stable address. The Runtime is allocated separately
    /// because its executors retain pointers into it and into its Manager.
    pub fn init(
        self: *Coordinator,
        allocator: Allocator,
        service: *io_service.Service,
    ) !void {
        self.* = .{
            .allocator = allocator,
            .service = service,
            .runtime = undefined,
        };

        const runtime = try allocator.create(io_runtime.Runtime);
        errdefer allocator.destroy(runtime);
        runtime.* = io_runtime.Runtime.init(allocator);
        errdefer runtime.deinit();

        // Keep the existing bounded worker-pool sizes. Creating both pools
        // before the thread starts gives its poll set stable wake descriptors.
        _ = try runtime.ensureDiscoveryExecutor();
        _ = try runtime.ensureOperationExecutor();

        self.runtime = runtime;
        self.thread = try std.Thread.spawn(.{}, threadMain, .{self});
    }

    /// Stops admission, wakes the coordinator and joins its thread. Runtime
    /// teardown happens on the coordinator thread after its loop has ended.
    pub fn deinit(self: *Coordinator) void {
        self.service.beginShutdown();
        if (self.thread) |thread| thread.join();
        self.* = undefined;
    }

    fn threadMain(self: *Coordinator) void {
        defer {
            self.runtime.deinit();
            self.allocator.destroy(self.runtime);
        }

        while (true) {
            _ = self.service.drainCommandWake();
            while (self.service.tryReceiveCommand()) |routed| {
                self.handleCommand(routed);
            }

            self.pumpExecutors();
            self.retireReadyJobs();

            if (self.service.isStopping()) break;
            self.waitForWork();
        }
    }

    fn waitForWork(self: *Coordinator) void {
        const discovery = if (self.runtime.discovery_executor) |*executor|
            executor
        else
            unreachable;
        const operation = if (self.runtime.operation_executor) |*executor|
            executor
        else
            unreachable;
        var fds = [_]std.posix.pollfd{
            .{
                .fd = self.service.commandWakeFd(),
                .events = std.posix.POLL.IN,
                .revents = 0,
            },
            .{
                .fd = discovery.wakeFd(),
                .events = std.posix.POLL.IN,
                .revents = 0,
            },
            .{
                .fd = operation.wakeFd(),
                .events = std.posix.POLL.IN,
                .revents = 0,
            },
        };

        while (true) {
            const rc = std.posix.system.poll(&fds, fds.len, -1);
            switch (std.posix.errno(rc)) {
                .SUCCESS => return,
                .INTR => continue,
                else => std.debug.panic(
                    "Files I/O coordinator poll failed: {s}",
                    .{@tagName(std.posix.errno(rc))},
                ),
            }
        }
    }

    fn pumpExecutors(self: *Coordinator) void {
        if (self.runtime.discovery_executor) |*executor| {
            _ = executor.drainWake();
            _ = executor.drainCompletions(&self.runtime.manager) catch |err| blk: {
                std.log.err("Files discovery completion reconciliation failed: {s}", .{@errorName(err)});
                break :blk 0;
            };
            _ = executor.dispatchReady(&self.runtime.manager) catch |err| blk: {
                std.log.err("Files discovery scheduling failed: {s}", .{@errorName(err)});
                break :blk 0;
            };
        }

        if (self.runtime.operation_executor) |*executor| {
            _ = executor.drainWake();
            _ = executor.drainCompletions() catch |err| blk: {
                std.log.err("Files operation completion reconciliation failed: {s}", .{@errorName(err)});
                break :blk 0;
            };
            _ = executor.dispatchReady() catch |err| blk: {
                std.log.err("Files operation scheduling failed: {s}", .{@errorName(err)});
                break :blk 0;
            };
        }
    }

    fn handleCommand(
        self: *Coordinator,
        routed: io_service.RoutedCommand,
    ) void {
        self.applyCommand(routed.command) catch |err| {
            const code = rejectionCode(err);
            _ = self.service.publishUpdate(routed.window_id, .{
                .job_id = routed.command.job_id,
                .kind = .command_rejected,
                .state_code = @intFromEnum(code),
            }) catch {};
        };
    }

    fn applyCommand(
        self: *Coordinator,
        command: io_service.Command,
    ) anyerror!void {
        switch (command.kind) {
            .pause_job => try self.runtime.manager.pauseJob(command.job_id),
            .resume_job => try self.runtime.manager.resumeJob(command.job_id),
            .cancel_job => try self.runtime.cancelJob(command.job_id),
            .retire_job => try self.runtime.requestJobRetirement(command.job_id),

            // These commands need owned operation payloads or opaque resource
            // handles that the current v1 Command value does not yet carry.
            .submit_job,
            .start_discovery,
            .prioritize_discovery,
            .resolve_conflict,
            .release_resource,
            => return error.UnsupportedCommand,
        }
    }

    fn retireReadyJobs(self: *Coordinator) void {
        while (true) {
            var candidate: ?JobId = null;
            var iterator = self.runtime.retirement_requests.keyIterator();
            while (iterator.next()) |job_id| {
                if (self.runtime.isJobRetirementReady(job_id.*)) {
                    candidate = job_id.*;
                    break;
                }
            }

            const job_id = candidate orelse return;
            if (!self.runtime.retireJobIfReady(job_id)) return;
        }
    }
};

fn rejectionCode(err: anyerror) RejectionCode {
    return if (err == error.UnsupportedCommand)
        .unsupported_command
    else if (err == error.UnknownJob)
        .unknown_job
    else if (err == error.InvalidJobState)
        .invalid_job_state
    else if (err == error.JobNotTerminal)
        .job_not_terminal
    else
        .other;
}
