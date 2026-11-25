//! Job views: what running jobs are bringing into a folder, for the window
//! showing it (docs/plans/files-io-service-architecture.md §14). A window
//! watches a folder by path in a view slot; the coordinator finds every job
//! writing into it, at any depth of the job's tree, and writes a bounded
//! snapshot of their entries there. The Service hands it over, latest wins.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const slots_per_window = 4;
pub const max_rows = 512;

/// What a window asks to see: the entries jobs are bringing into `path`,
/// rows `offset` to `offset + limit`.
pub const Watch = struct {
    slot: u8,
    /// Owned by the payload that carries it.
    path: []const u8,
    offset: u32 = 0,
    limit: u32 = max_rows,
    /// Chosen by the window, echoed in every snapshot of this watch.
    generation: u64 = 0,
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
    /// The job and the entry of its tree: what a priority request names.
    job_id: u64 = 0,
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

/// An owned snapshot of one watched folder.
pub const Snapshot = struct {
    allocator: Allocator,
    slot: u8,
    /// Which watch of the slot this answers: a window ignores snapshots of
    /// a watch it has replaced.
    generation: u64 = 0,
    offset: u32,
    /// Entries in all, not only those in `rows`.
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
