//! Closing the last window while I/O service jobs run (stage S3b): Files
//! asks first. Keep running finishes them with no window, as the service
//! does anyway (threading §10); Stop them cancels them; Cancel keeps the
//! window open. Any other window closes as before: the jobs live on.
const std = @import("std");
const tr = @import("i18n").tr;
const App = @import("app.zig").App;
const io_service = @import("io_service.zig");
const jobs_card = @import("app_jobs_card.zig");

pub const Choice = enum { keep, stop, cancel };

/// A close request from the compositor.
pub fn requestClose(self: *App) void {
    if (!self.quit_confirmed and self.dialog == null and runningJobs(self) > 0 and isLastWindow(self)) {
        self.dialog = .{ .kind = .quit_jobs, .title = tr("File operations are running") };
        self.invalidate();
        return;
    }
    self.terminalRequestClose();
}

pub fn choose(self: *App, choice: Choice) void {
    self.closeDialog();
    switch (choice) {
        .cancel => return,
        .keep => {},
        .stop => {
            var out: [io_service.max_live_jobs]io_service.JobRecord = undefined;
            for (self.service.jobs.active(&out)) |record| jobs_card.send(self, .cancel_job, record.id);
        },
    }
    self.quit_confirmed = true;
    self.terminalRequestClose();
}

pub fn runningJobs(self: *const App) usize {
    var out: [io_service.max_live_jobs]io_service.JobRecord = undefined;
    return self.service.jobs.active(&out).len;
}

fn isLastWindow(self: *const App) bool {
    const handle = self.service.handle orelse return true;
    return handle.service.openWindowCount() <= 1;
}

/// "2 file operations are still running."
pub fn message(self: *const App, buf: []u8) []const u8 {
    const count = runningJobs(self);
    const i18n = @import("i18n");
    return i18n.fmt(buf, i18n.trn("{count} file operation is still running.", "{count} file operations are still running.", count), .{ .count = count }) catch tr("File operations are still running.");
}
