//! Connects Manager-owned operations to their filesystem handlers through
//! the generic bounded Executor.
const std = @import("std");
const Allocator = std.mem.Allocator;
const io_manager = @import("io_manager.zig");
const io_executor = @import("io_executor.zig");
const io_copy = @import("io_copy.zig");
const io_directory = @import("io_directory.zig");
const io_symlink = @import("io_symlink.zig");

const Context = struct {
    allocator: Allocator,
    manager: *io_manager.Manager,
};

pub const Runtime = struct {
    allocator: Allocator,
    context: *Context,
    executor: io_executor.Executor,

    pub fn init(
        allocator: Allocator,
        manager: *io_manager.Manager,
        worker_count: usize,
        capacity: usize,
    ) !Runtime {
        const context = try allocator.create(Context);
        errdefer allocator.destroy(context);
        context.* = .{
            .allocator = allocator,
            .manager = manager,
        };

        const executor = try io_executor.Executor.init(
            allocator,
            .{
                .worker_count = worker_count,
                .capacity = capacity,
            },
            @ptrCast(context),
            .{
                .prepare = prepare,
                .execute = execute,
                .complete = complete,
                .discard = discard,
            },
        );

        return .{
            .allocator = allocator,
            .context = context,
            .executor = executor,
        };
    }

    pub fn deinit(self: *Runtime) void {
        self.executor.deinit();
        self.allocator.destroy(self.context);
        self.* = undefined;
    }

    pub fn wakeFd(self: *Runtime) std.posix.fd_t {
        return self.executor.wakeFd();
    }

    pub fn drainWake(self: *Runtime) u64 {
        return self.executor.drainWake();
    }

    pub fn dispatchReady(self: *Runtime) !usize {
        return self.executor.dispatchReady(self.context.manager);
    }

    pub fn drainCompletions(self: *Runtime) !usize {
        return self.executor.drainCompletions(self.context.manager);
    }
};

fn prepare(
    raw_context: ?*anyopaque,
    token: io_manager.WorkToken,
) anyerror!io_executor.PreparedWork {
    const context: *Context = @ptrCast(@alignCast(raw_context.?));
    const details = context.manager.operationDetails(token) orelse
        return error.StaleOperation;
    const tree = context.manager.treeIndex(token.job_id) orelse
        return error.UnknownJob;
    const entry = tree.getConst(details.entry_id) orelse return error.UnknownEntry;
    const destination = try context.manager.destinationPath(
        context.allocator,
        token.job_id,
        details.entry_id,
    );
    defer context.allocator.free(destination);

    const input = switch (details.kind) {
        .create_directory, .copy_file => blk: {
            const source = try context.manager.sourcePath(
                context.allocator,
                token.job_id,
                details.entry_id,
            );
            defer context.allocator.free(source);
            break :blk if (details.kind == .create_directory)
                try io_directory.makeInput(context.allocator, source, destination)
            else
                try io_copy.makeInput(context.allocator, source, destination);
        },
        .copy_symlink => try io_symlink.makeInput(
            context.allocator,
            entry.symlink_target orelse return error.MissingSymlinkTarget,
            destination,
        ),
        else => return error.UnsupportedOperation,
    };

    return .{
        .operation_kind = details.kind,
        .input = input,
    };
}

fn execute(
    raw_context: ?*anyopaque,
    item: io_executor.WorkItem,
) io_executor.WorkCompletion {
    const context: *Context = @ptrCast(@alignCast(raw_context.?));
    return switch (item.operation_kind) {
        .create_directory => io_directory.execute(context.allocator, item),
        .copy_file => io_copy.execute(context.allocator, item),
        .copy_symlink => io_symlink.execute(context.allocator, item),
        else => failWork(item),
    };
}

fn failWork(item_arg: io_executor.WorkItem) io_executor.WorkCompletion {
    var item = item_arg;
    if (item.continuation) |*continuation| {
        continuation.deinit();
        item.continuation = null;
    }
    return .{
        .token = item.token,
        .outcome = .failed,
        .operation_kind = item.operation_kind,
        .input = item.input,
    };
}

fn complete(
    raw_context: ?*anyopaque,
    token: io_manager.WorkToken,
    outcome: io_manager.WorkResult,
    result: ?io_executor.OwnedPayload,
) void {
    const context: *Context = @ptrCast(@alignCast(raw_context.?));
    if (tokenOperationKind(context.manager, token)) |kind| {
        switch (kind) {
            .create_directory => io_directory.complete(null, token, outcome, result),
            .copy_file => io_copy.complete(null, token, outcome, result),
            .copy_symlink => io_symlink.complete(null, token, outcome, result),
            else => deinitOptional(result),
        }
    } else {
        deinitOptional(result);
    }
}

fn tokenOperationKind(
    manager: *const io_manager.Manager,
    token: io_manager.WorkToken,
) ?io_manager.OperationKind {
    const snapshot = manager.snapshotJob(std.heap.page_allocator, token.job_id) catch
        return null;
    defer {
        var owned = snapshot;
        owned.deinit();
    }
    for (snapshot.operations) |operation| {
        if (operation.id == token.operation_id) return operation.kind;
    }
    return null;
}

fn discard(
    _: ?*anyopaque,
    operation_kind: io_manager.OperationKind,
    input: io_executor.OwnedPayload,
    continuation: ?io_executor.OwnedPayload,
    result: ?io_executor.OwnedPayload,
) void {
    switch (operation_kind) {
        .create_directory => io_directory.discard(null, operation_kind, input, continuation, result),
        .copy_file => io_copy.discard(null, operation_kind, input, continuation, result),
        .copy_symlink => io_symlink.discard(null, operation_kind, input, continuation, result),
        else => {
            var owned_input = input;
            owned_input.deinit();
            deinitOptional(continuation);
            deinitOptional(result);
        },
    }
}

fn deinitOptional(payload: ?io_executor.OwnedPayload) void {
    if (payload) |value| {
        var owned = value;
        owned.deinit();
    }
}
