//! Why a submit or a job failed: the `error_code` of its record.
//! Re-exported by io_coordinator.zig.

pub const RejectionCode = enum(u8) {
    unsupported_command = 1,
    unknown_job = 2,
    invalid_job_state = 3,
    job_not_terminal = 4,
    missing_payload = 5,
    invalid_destination = 6,
    invalid_source = 7,
    unsupported_source = 8,
    destination_inside_source = 9,
    overlapping_move_roots = 10,
    mounted_directory_move = 11,
    nothing_to_transfer = 12,
    /// `gio` is not installed: Move to Trash and Empty Trash cannot run.
    trash_unavailable = 13,
    /// `rm`, `gio` or a Trash entry removal failed.
    deletion_failed = 14,
    folder_exists = 15,
    folder_create_failed = 16,
    atomic_rename_unavailable = 17,
    other = 255,
};

pub fn rejectionCode(err: anyerror) RejectionCode {
    return if (err == error.UnsupportedCommand)
        .unsupported_command
    else if (err == error.MissingTransferPayload or
        err == error.MissingDiscoveryPayload or
        err == error.MissingConflictResolutionPayload)
        .missing_payload
    else if (err == error.UnknownJob)
        .unknown_job
    else if (err == error.InvalidJobState)
        .invalid_job_state
    else if (err == error.JobNotTerminal)
        .job_not_terminal
    else if (err == error.PathAlreadyExists)
        .folder_exists
    else if (err == error.CreateFailed or err == error.AccessDenied)
        .folder_create_failed
    else if (err == error.AtomicRenameUnavailable)
        .atomic_rename_unavailable
    else if (err == error.InvalidTransferDestination)
        .invalid_destination
    else if (err == error.InvalidTransferSource or err == error.EmptyTransfer)
        .invalid_source
    else if (err == error.UnsupportedTransferSource)
        .unsupported_source
    else if (err == error.TransferDestinationInsideSource)
        .destination_inside_source
    else if (err == error.OverlappingMoveRoots)
        .overlapping_move_roots
    else if (err == error.MountedDirectoryMoveUnsupported)
        .mounted_directory_move
    else if (err == error.TransferSourceEqualsDestination)
        .nothing_to_transfer
    else if (err == error.GioNotAvailable)
        .trash_unavailable
    else if (err == error.DeletionFailed or err == error.TrashFailed or err == error.MissingTrashDirectory)
        .deletion_failed
    else
        .other;
}


