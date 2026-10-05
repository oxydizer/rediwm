//! Read-only Git snapshots, produced exclusively by the directory worker.
//!
//! A folder's .git comes with the folder: an archive or a USB stick can carry
//! a .git/config whose filter drivers `git status` runs while it compares
//! files. Files never runs a repository's own programs. Such a repository is
//! shown as a plain folder; every other is queried with fsmonitor, hooks,
//! submodule recursion and every transport (lazy fetches included) disabled.
const std = @import("std");
const c = @import("c.zig").api;
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.git);

/// Prepended to every Git command Files runs.
const safe_options = [_][]const u8{ "git", "--no-optional-locks", "--no-pager", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null" };

pub const Status = enum {
    clean,
    modified,
    added,
    deleted,
    renamed,
    conflict,
    untracked,

    pub fn label(self: Status) []const u8 {
        return switch (self) {
            .clean => "—",
            .modified => "M",
            .added => "A",
            .deleted => "D",
            .renamed => "R",
            .conflict => "U",
            .untracked => "?",
        };
    }
};
pub const LineCounts = struct {
    added: u64 = 0,
    removed: u64 = 0,

    pub fn merge(a: ?LineCounts, b: ?LineCounts) ?LineCounts {
        const left = a orelse return b;
        const right = b orelse return a;
        return .{ .added = left.added +| right.added, .removed = left.removed +| right.removed };
    }
};
pub const Change = struct { path: []const u8, status: Status, lines: ?LineCounts = null };
pub const Repository = struct {
    root: []const u8 = "",
    directory: []const u8 = "",
    branch: []const u8 = "",
    /// Local branches, alphabetical. Excludes a detached or unborn HEAD.
    branches: []const []const u8 = &.{},
    oid: []const u8 = "",
    ahead: u64 = 0,
    behind: u64 = 0,
    upstream: bool = false,
    changes: []Change = &.{},
    watch_paths: []const []const u8 = &.{},

    statuses: std.StringHashMapUnmanaged(Status) = .empty,
    line_counts: std.StringHashMapUnmanaged(LineCounts) = .empty,

    pub fn index(self: *Repository, mem: Allocator) !void {
        self.statuses.clearRetainingCapacity();
        self.line_counts.clearRetainingCapacity();
        const prefix = if (self.directory.len > self.root.len) self.directory[self.root.len + 1 ..] else "";
        for (self.changes) |change| {
            var path = change.path;
            if (prefix.len > 0) {
                if (!std.mem.startsWith(u8, path, prefix) or path.len <= prefix.len or path[prefix.len] != '/') continue;
                path = path[prefix.len + 1 ..];
            }
            const name = std.mem.sliceTo(path, '/');
            if (change.lines) |delta| {
                const counts = try self.line_counts.getOrPut(mem, name);
                counts.value_ptr.* = if (counts.found_existing) LineCounts.merge(counts.value_ptr.*, delta).? else delta;
            }
            const entry = try self.statuses.getOrPut(mem, name);
            if (!entry.found_existing) {
                entry.value_ptr.* = change.status;
            } else if (entry.value_ptr.* == .conflict or change.status == .conflict) {
                entry.value_ptr.* = .conflict;
            } else if (entry.value_ptr.* != change.status) {
                entry.value_ptr.* = .modified;
            }
        }
    }

    pub fn status(self: Repository, name: []const u8) Status {
        return self.statuses.get(name) orelse .clean;
    }

    pub fn lines(self: Repository, name: []const u8) ?LineCounts {
        return self.line_counts.get(name);
    }
};

/// Numstat -z keeps tabs/newlines in names and gives renamed files two paths.
/// Counts compare HEAD with the working tree, including staged changes once.
pub fn applyNumstat(repo: *Repository, mem: Allocator, bytes: []const u8) !void {
    var counts: std.StringHashMapUnmanaged(LineCounts) = .empty;
    defer counts.deinit(mem);
    var records = std.mem.splitScalar(u8, bytes, 0);
    while (records.next()) |record| {
        if (record.len == 0) continue;
        const first = std.mem.indexOfScalar(u8, record, '\t') orelse return error.InvalidNumstat;
        const second = std.mem.indexOfScalarPos(u8, record, first + 1, '\t') orelse return error.InvalidNumstat;
        var path = record[second + 1 ..];
        if (path.len == 0) {
            _ = records.next() orelse return error.InvalidNumstat;
            path = records.next() orelse return error.InvalidNumstat;
        }
        // Binary files have '-' for both counts, rather than line numbers.
        if (std.mem.eql(u8, record[0..first], "-")) continue;
        try counts.put(mem, path, .{
            .added = try std.fmt.parseInt(u64, record[0..first], 10),
            .removed = try std.fmt.parseInt(u64, record[first + 1 .. second], 10),
        });
    }
    for (repo.changes) |*change| {
        if (change.status != .untracked) change.lines = counts.get(change.path);
    }
}

/// New text files count as additions. Stream regular files only, with a
/// bounded read; a FIFO, symlink or large/binary file has no line count.
fn untrackedLines(mem: Allocator, root: []const u8, path: []const u8) ?LineCounts {
    const full = std.fmt.allocPrintSentinel(mem, "{s}/{s}", .{ root, path }, 0) catch return null;
    defer mem.free(full);
    const fd = c.open(full, c.O_RDONLY | c.O_CLOEXEC | c.O_NOFOLLOW | c.O_NONBLOCK);
    if (fd < 0) return null;
    defer _ = c.close(fd);
    var stat: c.struct_stat = undefined;
    const limit = 16 * 1024 * 1024;
    if (c.fstat(fd, &stat) != 0 or stat.st_mode & c.S_IFMT != c.S_IFREG or stat.st_size > limit) return null;
    var buf: [16 * 1024]u8 = undefined;
    var total: usize = 0;
    var added: u64 = 0;
    var last: u8 = '\n';
    while (true) {
        const n = c.read(fd, &buf, buf.len);
        if (n < 0) return null;
        if (n == 0) break;
        const bytes = buf[0..@intCast(n)];
        total += bytes.len;
        if (total > limit or std.mem.indexOfScalar(u8, bytes, 0) != null) return null;
        added += std.mem.count(u8, bytes, "\n");
        last = bytes[bytes.len - 1];
    }
    if (last != '\n') added += 1;
    return .{ .added = added };
}

fn command(mem: Allocator, io: std.Io, env: *const std.process.Environ.Map, dir: []const u8, args: []const []const u8) ![]const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(mem);
    try argv.appendSlice(mem, &safe_options);
    try argv.appendSlice(mem, &.{ "-C", dir });
    try argv.appendSlice(mem, args);
    const result = try std.process.run(mem, io, .{
        .argv = argv.items,
        .environ_map = env,
        .stdout_limit = .limited(16 * 1024 * 1024),
        .stderr_limit = .limited(64 * 1024),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } },
    });
    defer mem.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        mem.free(result.stdout);
        return error.GitUnavailable;
    }
    return result.stdout;
}

fn line(bytes: []const u8) []const u8 {
    return if (std.mem.endsWith(u8, bytes, "\n")) bytes[0 .. bytes.len - 1] else bytes;
}

/// A file browser follows its location, even if launched from a Git hook.
/// It never reaches a remote, not even for objects a partial clone lacks
/// (a repository's own config could name the command that fetches them),
/// and never prompts.
fn cleanEnv(mem: Allocator, environ: std.process.Environ) !std.process.Environ.Map {
    var env = try environ.createMap(mem);
    errdefer env.deinit();
    var i: usize = 0;
    while (i < env.count()) {
        const key = env.keys()[i];
        if (std.mem.startsWith(u8, key, "GIT_")) {
            _ = env.swapRemove(key);
        } else i += 1;
    }
    try env.put("GIT_ALLOW_PROTOCOL", "none");
    try env.put("GIT_NO_LAZY_FETCH", "1");
    try env.put("GIT_TERMINAL_PROMPT", "0");
    return env;
}

/// Configuration naming a program Git (or Git LFS, itself a filter) would run
/// while Files compares or checks out files.
fn runsProgram(key: []const u8) bool {
    if (std.ascii.startsWithIgnoreCase(key, "filter.")) {
        const variable = key[(std.mem.lastIndexOfScalar(u8, key, '.') orelse return false) + 1 ..];
        for ([_][]const u8{ "clean", "smudge", "process" }) |name| {
            if (std.ascii.eqlIgnoreCase(variable, name)) return true;
        }
        return false;
    }
    return std.ascii.startsWithIgnoreCase(key, "lfs.extension.") or
        std.ascii.startsWithIgnoreCase(key, "lfs.customtransfer.") or
        std.ascii.eqlIgnoreCase(key, "lfs.standalonetransferagent");
}

/// Whether the repository at `dir` may be queried: none of its own
/// configuration (.git/config, worktree config, and what they include) names
/// a program. The user's and the system's configuration are trusted. Fails
/// closed when Git cannot list the configuration.
fn trustedRepository(mem: Allocator, io: std.Io, env: *const std.process.Environ.Map, dir: []const u8) bool {
    const listing = command(mem, io, env, dir, &.{ "config", "--list", "--show-scope", "--name-only", "-z" }) catch return false;
    defer mem.free(listing);
    // NUL-separated scope/key pairs.
    var fields = std.mem.splitScalar(u8, listing, 0);
    while (fields.next()) |scope| {
        const key = fields.next() orelse break;
        const repository_owned = !(std.mem.eql(u8, scope, "system") or std.mem.eql(u8, scope, "global") or std.mem.eql(u8, scope, "command"));
        if (repository_owned and runsProgram(key)) {
            log.info("not showing Git status for {s}: its {s} configuration sets {s}", .{ dir, scope, key });
            return false;
        }
    }
    return true;
}

pub const max_branches = 200;

fn listBranches(mem: Allocator, io: std.Io, env: *const std.process.Environ.Map, dir: []const u8) []const []const u8 {
    const bytes = command(mem, io, env, dir, &.{ "for-each-ref", "--sort=refname", "--format=%(refname:short)", "refs/heads" }) catch return &.{};
    var list: std.ArrayList([]const u8) = .empty;
    var names = std.mem.splitScalar(u8, bytes, '\n');
    while (names.next()) |name| {
        if (name.len == 0) continue;
        if (list.items.len >= max_branches) break;
        list.append(mem, name) catch break;
    }
    return list.toOwnedSlice(mem) catch &.{};
}

pub const Outcome = struct {
    ok: bool,
    message: [160]u8 = undefined,
    len: usize = 0,

    pub fn text(self: *const Outcome) []const u8 {
        return self.message[0..self.len];
    }
};

/// Switches to `name`, creating it from HEAD when `create` is set. Git itself
/// refuses a switch that would overwrite local changes; its first line of
/// complaint is returned for display.
pub fn switchBranch(mem: Allocator, io: std.Io, environ: std.process.Environ, dir: []const u8, name: []const u8, create: bool) Outcome {
    var out: Outcome = .{ .ok = false };
    const fail = struct {
        fn set(o: *Outcome, msg: []const u8) Outcome {
            const n = @min(msg.len, o.message.len);
            @memcpy(o.message[0..n], msg[0..n]);
            o.len = n;
            return o.*;
        }
    }.set;
    if (name.len == 0) return fail(&out, "Branch name cannot be empty");
    if (name[0] == '-') return fail(&out, "Invalid branch name");
    var env = cleanEnv(mem, environ) catch return fail(&out, "Out of memory");
    defer env.deinit();
    if (!trustedRepository(mem, io, &env, dir)) return fail(&out, "This repository runs its own programs; switch branches in a terminal");
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(mem);
    argv.appendSlice(mem, &safe_options) catch return fail(&out, "Out of memory");
    argv.appendSlice(mem, &.{ "-C", dir, "switch", "--no-recurse-submodules" }) catch return fail(&out, "Out of memory");
    if (create) argv.append(mem, "-c") catch return fail(&out, "Out of memory");
    argv.append(mem, name) catch return fail(&out, "Out of memory");
    const result = std.process.run(mem, io, .{
        .argv = argv.items,
        .environ_map = &env,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
        // A checkout can rewrite many files; do not kill it half way.
        .timeout = .{ .duration = .{ .raw = .fromSeconds(60), .clock = .awake } },
    }) catch return fail(&out, "Could not run git");
    defer mem.free(result.stdout);
    defer mem.free(result.stderr);
    if (result.term == .exited and result.term.exited == 0) {
        out.ok = true;
        return out;
    }
    var lines = std.mem.splitScalar(u8, result.stderr, '\n');
    while (lines.next()) |l| {
        const trimmed = std.mem.trim(u8, l, " \t\r");
        if (trimmed.len == 0) continue;
        return fail(&out, std.mem.trimStart(u8, std.mem.trimStart(u8, trimmed, "fatal:"), " "));
    }
    return fail(&out, "git switch failed");
}

pub fn scan(mem: Allocator, io: std.Io, environ: std.process.Environ, dir: []const u8) !?Repository {
    var canonical: [std.fs.max_path_bytes]u8 = undefined;
    const zdir = try mem.dupeZ(u8, dir);
    defer mem.free(zdir);
    if (c.realpath(zdir, &canonical) == null) return null;
    const directory = try mem.dupe(u8, std.mem.sliceTo(&canonical, 0));
    // Avoid spawning Git for ordinary folders. This also recognizes worktree
    // and submodule .git files; Git itself resolves their metadata location.
    var ancestor: []const u8 = directory;
    while (true) {
        const marker = try std.fmt.allocPrintSentinel(mem, "{s}/.git", .{ancestor}, 0);
        defer mem.free(marker);
        if (c.access(marker, c.F_OK) == 0) break;
        ancestor = std.fs.path.dirname(ancestor) orelse return null;
    }
    var env = try cleanEnv(mem, environ);
    defer env.deinit();
    if (!trustedRepository(mem, io, &env, directory)) return null;
    const root = line(try command(mem, io, &env, directory, &.{ "rev-parse", "--show-toplevel" }));
    // A submodule's status runs under the submodule's own configuration.
    const bytes = try command(mem, io, &env, directory, &.{ "status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all", "--ignore-submodules=all", "--", "." });
    var repo = try parse(mem, bytes);
    repo.root = root;
    repo.branches = listBranches(mem, io, &env, directory);
    repo.directory = directory;
    if (repo.changes.len > 0) {
        // An unborn branch has no HEAD. Hashing the empty tree without -w is
        // read-only and works with either SHA-1 or SHA-256 repositories.
        const base = if (std.mem.eql(u8, repo.oid, "(initial)"))
            line(command(mem, io, &env, root, &.{ "hash-object", "-t", "tree", "--stdin" }) catch "")
        else
            "HEAD";
        if (base.len > 0) {
            const stats = command(mem, io, &env, root, &.{ "diff", "--numstat", "-z", "--no-ext-diff", "--no-textconv", "--ignore-submodules=all", "--find-renames", base, "--", directory }) catch "";
            try applyNumstat(&repo, mem, stats);
        }
        for (repo.changes) |*change| {
            if (change.status == .untracked) change.lines = untrackedLines(mem, root, change.path);
        }
    }
    try repo.index(mem);
    const git_dir = line(try command(mem, io, &env, root, &.{ "rev-parse", "--absolute-git-dir" }));
    const common = line(try command(mem, io, &env, root, &.{ "rev-parse", "--path-format=absolute", "--git-common-dir" }));
    var paths: std.ArrayList([]const u8) = .empty;
    try paths.appendSlice(mem, &.{ git_dir, common });
    // Watch both parent directories (atomic ref replacement) and refs/heads
    // (new branches). Linked worktrees have separate HEAD and shared refs.
    const heads = try std.fmt.allocPrint(mem, "{s}/refs/heads", .{common});
    try paths.append(mem, heads);
    if (!std.mem.eql(u8, repo.branch, "(detached)")) {
        const ref = try std.fmt.allocPrint(mem, "{s}/{s}", .{ heads, repo.branch });
        try paths.append(mem, std.fs.path.dirname(ref).?);
    }
    repo.watch_paths = try paths.toOwnedSlice(mem);
    return repo;
}

/// Porcelain v2's NUL records preserve spaces, newlines and non-UTF8 names.
/// Rename/copy records carry a second path which must never become a row.
pub fn parse(mem: Allocator, bytes: []const u8) !Repository {
    var repo: Repository = .{};
    var changes: std.ArrayList(Change) = .empty;
    var records = std.mem.splitScalar(u8, bytes, 0);
    while (records.next()) |record| {
        if (std.mem.startsWith(u8, record, "# branch.head ")) {
            repo.branch = record[14..];
        } else if (std.mem.startsWith(u8, record, "# branch.oid ")) {
            repo.oid = record[13..];
        } else if (std.mem.startsWith(u8, record, "# branch.upstream ")) {
            repo.upstream = true;
        } else if (std.mem.startsWith(u8, record, "# branch.ab ")) {
            var counts = std.mem.tokenizeScalar(u8, record[12..], ' ');
            repo.ahead = std.fmt.parseInt(u64, std.mem.trimStart(u8, counts.next() orelse "", "+"), 10) catch 0;
            repo.behind = std.fmt.parseInt(u64, std.mem.trimStart(u8, counts.next() orelse "", "-"), 10) catch 0;
        } else if (record.len >= 3 and record[0] == '?') {
            try changes.append(mem, .{ .path = std.mem.trimEnd(u8, record[2..], "/"), .status = .untracked });
        } else if (record.len >= 4 and (record[0] == '1' or record[0] == '2' or record[0] == 'u')) {
            const fields: usize = if (record[0] == '1') 8 else if (record[0] == '2') 9 else 10;
            var offset: usize = 0;
            for (0..fields) |_| {
                offset = (std.mem.indexOfScalarPos(u8, record, offset, ' ') orelse return error.InvalidStatus) + 1;
            }
            const xy = record[2..4];
            const status: Status = if (record[0] == 'u') .conflict else if (std.mem.indexOfScalar(u8, xy, 'D') != null) .deleted else if (std.mem.indexOfScalar(u8, xy, 'R') != null) .renamed else if (std.mem.indexOfScalar(u8, xy, 'A') != null or std.mem.indexOfScalar(u8, xy, 'C') != null) .added else .modified;
            try changes.append(mem, .{ .path = record[offset..], .status = status });
            if (record[0] == '2') _ = records.next();
        }
    }
    repo.changes = try changes.toOwnedSlice(mem);
    return repo;
}
