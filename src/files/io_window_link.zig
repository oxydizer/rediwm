//! Window-side helpers for talking to the Files I/O Service without ever
//! waiting (docs/plans/files-io-threading-and-ownership.md §3).
//!
//! The Service fails fast with `ServiceBusy` when the coordinator happens to
//! hold its mutex. That is transient, not an error the user sees:
//!
//! * `Outbox` keeps commands refused with `ServiceBusy` and retries them, in
//!   order, before anything newer is sent.
//! * `Reader` remembers a refused fetch, so the event loop polls with a short
//!   timeout instead of waiting for a wake that was already drained.
//!
//! Neither loops or spins inside one event-loop iteration.
const std = @import("std");
const io_service = @import("io_service.zig");

pub const Outbox = struct {
    commands: [io_service.outbox_capacity]io_service.Command = undefined,
    head: usize = 0,
    count: usize = 0,

    /// Sends now, or queues behind earlier refused commands. On success the
    /// command's payload belongs to the Service or to the outbox, and the
    /// caller's pointer is cleared. On error (a refusal the user should see,
    /// or `OutboxFull`) it stays with the caller.
    pub fn send(self: *Outbox, handle: io_service.Handle, command: *io_service.Command) !void {
        try self.flush(handle);
        if (self.count == 0) {
            const accepted = if (handle.trySendOwned(command)) |_| true else |err| switch (err) {
                error.ServiceBusy => false,
                else => |e| return e,
            };
            if (accepted) return;
        }
        if (self.count == self.commands.len) return error.OutboxFull;
        self.commands[(self.head + self.count) % self.commands.len] = command.*;
        self.count += 1;
        command.payload = null;
    }

    /// Retries queued commands in order and stops at the first `ServiceBusy`.
    /// A refusal the user must see is returned; that command is dropped and
    /// its payload freed.
    pub fn flush(self: *Outbox, handle: io_service.Handle) !void {
        while (self.count > 0) {
            const command = &self.commands[self.head];
            handle.trySendOwned(command) catch |err| switch (err) {
                error.ServiceBusy => return,
                else => |e| {
                    command.deinitPayload();
                    self.pop();
                    return e;
                },
            };
            self.pop();
        }
    }

    pub fn pending(self: *const Outbox) bool {
        return self.count > 0;
    }

    /// Frees the payloads of commands never sent.
    pub fn deinit(self: *Outbox) void {
        while (self.count > 0) {
            self.commands[self.head].deinitPayload();
            self.pop();
        }
    }

    fn pop(self: *Outbox) void {
        self.head = (self.head + 1) % self.commands.len;
        self.count -= 1;
    }
};

pub const Reader = struct {
    /// A fetch was refused with ServiceBusy, or stopped with `more` set.
    pending: bool = false,

    /// One bounded read. Returns null when the Service was busy; the
    /// window then retries on its next iteration.
    pub fn fetch(self: *Reader, handle: io_service.Handle, out: []io_service.JobRecord) !?io_service.FetchResult {
        const result = handle.fetchChanges(out) catch |err| switch (err) {
            error.ServiceBusy => {
                self.pending = true;
                return null;
            },
            else => |e| return e,
        };
        self.pending = result.more;
        return result;
    }

    /// The poll timeout the event loop should use while this reader has
    /// unfinished work: 0 to continue a bounded sweep, 1 ms after a busy
    /// refusal; null when it can wait for the update wake.
    pub fn pollTimeoutMs(self: *const Reader, last: ?io_service.FetchResult) ?i32 {
        if (!self.pending) return null;
        return if (last == null) 1 else 0;
    }
};

test {
    _ = @import("io_window_link_tests.zig");
}
