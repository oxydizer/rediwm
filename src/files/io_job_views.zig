//! Job views: per-entry state of a job's tree for what a window shows
//! (docs/plans/files-io-service-architecture.md §14). A window watches a
//! level of a job's tree in one of its view slots; the coordinator writes a
//! bounded snapshot of that level and the Service hands it over, latest wins.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const slots_per_window = 4;
pub const max_rows = 512;

/// What a window asks to see: the children of `entry_id` (0: the job's
/// roots), rows `offset` to `offset + limit`.
pub const Watch = struct {
    slot: u8,
    job_id: u64,
    entry_id: u64 = 0,
    offset: u32 = 0,
    limit: u32 = max_rows,
};

pub const Kind = enum(u8) { directory, regular_file, symlink, other };

pub const RowState = enum(u8) {
    /// Not started, or a folder whose contents are not all done.
    pending,
    running,
    done,
    failed,
    skipped,
    cancelled,
};

pub const Row = struct {
    entry_id: u64,
    /// Into the snapshot's `names`.
    name_start: u32,
    name_len: u16,
    kind: Kind,
    state: RowState,
    /// Children known so far, for a folder.
    child_count: u32 = 0,
    completed_bytes: u64,
    total_bytes: u64,
};

/// An owned snapshot of one watched level.
pub const Snapshot = struct {
    allocator: Allocator,
    slot: u8,
    job_id: u64,
    entry_id: u64,
    offset: u32,
    /// Children of the level in all, not only those in `rows`.
    total_children: u32,
    rows: []Row,
    names: []u8,

    pub fn name(self: *const Snapshot, row: Row) []const u8 {
        return self.names[row.name_start..][0..row.name_len];
    }

    pub fn destroy(self: *Snapshot) void {
        self.allocator.free(self.rows);
        self.allocator.free(self.names);
        self.allocator.destroy(self);
    }
};
