//! Git porcelain parsing and archive extraction tests.

const std = @import("std");
const archive = @import("archive.zig");
const ops_mod = @import("ops.zig");
const c = @import("c.zig").api;
const files_tests = @import("../files_tests.zig");
const makeTestDir = files_tests.makeTestDir;
const writeTestFile = files_tests.writeTestFile;
const readTestFile = files_tests.readTestFile;

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

fn archiveBenchmarkRoot(
    allocator: std.mem.Allocator,
    fallback_buf: []u8,
) ![]u8 {
    const configured = getenv("REDIWM_ARCHIVE_BENCH_DIR") orelse {
        const fallback = try makeTestDir(fallback_buf);
        return allocator.dupe(u8, fallback);
    };

    const base = std.mem.span(configured);
    if (base.len == 0) return error.InvalidBenchmarkDirectory;

    const template = try std.fmt.allocPrintSentinel(
        allocator,
        "{s}/rediwm_archive_bench_XXXXXX",
        .{base},
        0,
    );
    defer allocator.free(template);

    const created = c.mkdtemp(template) orelse
        return error.BenchmarkDirectoryCreationFailed;

    return allocator.dupe(u8, std.mem.span(created)) catch |err| {
        _ = c.rmdir(created);
        return err;
    };
}

fn writeArchiveBenchmarkFixture(
    allocator: std.mem.Allocator,
    path: []const u8,
    directory_count: usize,
    files_per_directory: usize,
    interleaved: bool,
    directory_depth: usize,
) !void {
    const api = @import("c_archive");
    const writer = api.archive_write_new() orelse return error.OutOfMemory;
    defer _ = api.archive_write_free(writer);
    try std.testing.expectEqual(@as(c_int, 0), api.archive_write_set_format_zip(writer));
    const zpath = try allocator.dupeSentinel(u8, path, 0);
    defer allocator.free(zpath);
    try std.testing.expectEqual(@as(c_int, 0), api.archive_write_open_filename(writer, zpath));

    const total_files = directory_count * files_per_directory;
    for (0..total_files) |position| {
        const directory_index = if (interleaved)
            position % directory_count
        else
            position / files_per_directory;
        const file_index = if (interleaved)
            position / directory_count
        else
            position % files_per_directory;
        const name = if (directory_depth == 1)
            try std.fmt.allocPrintSentinel(
                allocator,
                "directory-{d}/file-{d}.bin",
                .{ directory_index, file_index },
                0,
            )
        else
            try std.fmt.allocPrintSentinel(
                allocator,
                "level-0/level-1/level-2/level-3/level-4/level-5/level-6/directory-{d}/file-{d}.bin",
                .{ directory_index, file_index },
                0,
            );
        defer allocator.free(name);

        const entry = api.archive_entry_new() orelse return error.OutOfMemory;
        defer api.archive_entry_free(entry);
        api.archive_entry_set_pathname(entry, name);
        api.archive_entry_set_filetype(entry, c.S_IFREG);
        api.archive_entry_set_perm(entry, 0o600);
        api.archive_entry_set_size(entry, 0);
        try std.testing.expectEqual(@as(c_int, 0), api.archive_write_header(writer, entry));
    }
    try std.testing.expectEqual(@as(c_int, 0), api.archive_write_close(writer));
}

fn archiveBenchmarkNowNs() u64 {
    var ts: std.c.timespec = undefined;
    const result = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    std.debug.assert(result == 0);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s +
        @as(u64, @intCast(ts.nsec));
}

fn measureArchiveExtraction(
    allocator: std.mem.Allocator,
    source: []const u8,
    parent: []const u8,
    metrics: ?*archive.ExtractMetrics,
) !u64 {
    const stage = try archive.temporary(allocator, parent);
    defer {
        ops_mod.deleteRecursive(allocator, stage) catch {};
        allocator.free(stage);
    }
    var cancel: archive.Cancel = .init(false);
    const start = archiveBenchmarkNowNs();
    if (metrics) |m| {
        try archive.extractMeasured(allocator, source, stage, &cancel, m);
    } else {
        try archive.extract(allocator, source, stage, null, &cancel);
    }
    return archiveBenchmarkNowNs() - start;
}

fn benchmarkArchiveLayout(
    allocator: std.mem.Allocator,
    source: []const u8,
    parent: []const u8,
    layout: []const u8,
    file_count: usize,
    directory_count: usize,
) !void {
    _ = try measureArchiveExtraction(allocator, source, parent, null);
    var samples: [3]u64 = undefined;
    for (&samples) |*sample| {
        sample.* = try measureArchiveExtraction(allocator, source, parent, null);
    }
    // Three samples: select the median without allocating or sorting.
    const median = @max(@min(samples[0], samples[1]), @min(@max(samples[0], samples[1]), samples[2]));
    const files_per_second = @as(f64, @floatFromInt(file_count)) *
        std.time.ns_per_s / @as(f64, @floatFromInt(median));
    std.debug.print(
        "BENCH,archive_extract,{s},{d},{d},{d},{d:.2}\n",
        .{ layout, file_count, directory_count, median, files_per_second },
    );

    var metrics: archive.ExtractMetrics = .{};
    const measured_ns = try measureArchiveExtraction(allocator, source, parent, &metrics);
    std.debug.print(
        "METRIC,archive_extract,{s},{d},headers={d},header_ns={d},cache_hits={d},cache_misses={d},directory_lookup_ns={d},directory_components={d},mkdir_calls={d},mkdir_existing={d},directory_open_calls={d},directory_component_ns={d},file_creates={d},file_create_ns={d},chmod_calls={d},chmod_ns={d},bytes={d},measured_total_ns={d}\n",
        .{
            layout,
            file_count,
            metrics.header_calls,
            metrics.header_ns,
            metrics.directory_cache_hits,
            metrics.directory_cache_misses,
            metrics.directory_lookup_ns,
            metrics.directory_components,
            metrics.mkdir_calls,
            metrics.mkdir_existing,
            metrics.directory_open_calls,
            metrics.directory_component_ns,
            metrics.file_create_calls,
            metrics.file_create_ns,
            metrics.chmod_calls,
            metrics.chmod_ns,
            metrics.extracted_bytes,
            measured_ns,
        },
    );
}

test "Git porcelain preserves paths, rename pairs, conflicts and directory boundaries" {
    const git = @import("git.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var repo = try git.parse(
        arena.allocator(),
        "# branch.oid abcdef0123456789\x00# branch.head main\x00# branch.upstream origin/main\x00# branch.ab +3 -2\x00" ++
            "1 .M N... 100644 100644 100644 abc abc src/a file\n.txt\x00" ++
            "1 D. N... 100644 000000 000000 abc abc gone.txt\x00" ++
            "2 R. N... 100644 100644 100644 abc abc R100 renamed.txt\x00old name.txt\x00" ++
            "u UU N... 100644 100644 100644 100644 abc abc abc src/conflict.txt\x00" ++
            "? new directory/\x00? src2/other.txt\x00",
    );
    repo.root = "/repo";
    repo.directory = "/repo";
    try git.applyNumstat(&repo, arena.allocator(), "28\t3\tsrc/a file\n.txt\x00" ++
        "0\t7\tgone.txt\x00" ++
        "2\t1\t\x00old name.txt\x00renamed.txt\x00" ++
        "-\t-\tsrc/conflict.txt\x00" ++
        "9\t4\tsrc2/other.txt\x00");
    try repo.index(arena.allocator());
    try std.testing.expectEqualStrings("main", repo.branch);
    try std.testing.expect(repo.upstream);
    try std.testing.expectEqual(@as(u64, 3), repo.ahead);
    try std.testing.expectEqual(@as(u64, 2), repo.behind);
    try std.testing.expectEqual(@as(usize, 6), repo.changes.len);
    try std.testing.expectEqual(git.Status.deleted, repo.status("gone.txt"));
    try std.testing.expectEqual(git.Status.renamed, repo.status("renamed.txt"));
    try std.testing.expectEqual(git.Status.clean, repo.status("old name.txt"));
    try std.testing.expectEqual(git.Status.conflict, repo.status("src"));
    try std.testing.expectEqual(git.Status.untracked, repo.status("new directory"));
    try std.testing.expectEqualDeep(git.LineCounts{ .added = 28, .removed = 3 }, repo.lines("src").?);
    try std.testing.expectEqualDeep(git.LineCounts{ .added = 2, .removed = 1 }, repo.lines("renamed.txt").?);
    try std.testing.expectEqual(@as(u64, 7), repo.lines("gone.txt").?.removed);
    repo.directory = "/repo/src";
    try repo.index(arena.allocator());
    try std.testing.expectEqual(git.Status.modified, repo.status("a file\n.txt"));
    try std.testing.expectEqual(git.Status.clean, repo.status("other.txt"));
    try std.testing.expectEqual(git.Status.conflict, repo.status("conflict.txt"));
    try std.testing.expectEqualDeep(git.LineCounts{ .added = 28, .removed = 3 }, repo.lines("a file\n.txt").?);
    try std.testing.expect(repo.lines("conflict.txt") == null);
    try std.testing.expect(repo.lines("other.txt") == null);
}

pub fn writeArchiveFixture(path: []const u8, names: []const [:0]const u8) !void {
    try writeArchiveFixtureLinks(path, names, &.{});
}

pub const ArchiveLinkFixture = struct { name: [:0]const u8, target: [:0]const u8 };

pub fn writeArchiveFixtureLinks(path: []const u8, names: []const [:0]const u8, links: []const ArchiveLinkFixture) !void {
    const api = @import("c_archive");
    const writer = api.archive_write_new() orelse return error.OutOfMemory;
    defer _ = api.archive_write_free(writer);
    if (std.mem.endsWith(u8, path, ".zip")) {
        try std.testing.expectEqual(@as(c_int, 0), api.archive_write_set_format_zip(writer));
    } else {
        try std.testing.expectEqual(@as(c_int, 0), api.archive_write_set_format_pax_restricted(writer));
        try std.testing.expectEqual(@as(c_int, 0), api.archive_write_add_filter_gzip(writer));
    }
    const zpath = try std.testing.allocator.dupeSentinel(u8, path, 0);
    defer std.testing.allocator.free(zpath);
    try std.testing.expectEqual(@as(c_int, 0), api.archive_write_open_filename(writer, zpath));
    for (names) |name| {
        const entry = api.archive_entry_new() orelse return error.OutOfMemory;
        defer api.archive_entry_free(entry);
        api.archive_entry_set_pathname(entry, name);
        const directory = std.mem.endsWith(u8, name, "/");
        api.archive_entry_set_filetype(entry, if (directory) c.S_IFDIR else c.S_IFREG);
        api.archive_entry_set_perm(entry, 0o644);
        api.archive_entry_set_size(entry, if (directory) 0 else 7);
        try std.testing.expectEqual(@as(c_int, 0), api.archive_write_header(writer, entry));
        if (!directory) try std.testing.expectEqual(@as(isize, 7), api.archive_write_data(writer, "payload", 7));
    }
    for (links) |link| {
        const entry = api.archive_entry_new() orelse return error.OutOfMemory;
        defer api.archive_entry_free(entry);
        api.archive_entry_set_pathname(entry, link.name);
        api.archive_entry_set_filetype(entry, c.S_IFLNK);
        api.archive_entry_set_perm(entry, 0o777);
        api.archive_entry_set_symlink(entry, link.target);
        try std.testing.expectEqual(@as(c_int, 0), api.archive_write_header(writer, entry));
    }
    try std.testing.expectEqual(@as(c_int, 0), api.archive_write_close(writer));
}

test "archive directory fd benchmark" {
    const enabled = getenv("REDIWM_RUN_BENCHMARKS") orelse return error.SkipZigTest;
    if (!std.mem.eql(u8, std.mem.span(enabled), "1")) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const directory_count = 64;
    const files_per_directory = 128;
    const file_count = directory_count * files_per_directory;
    var buf: [256]u8 = undefined;
    const root = try archiveBenchmarkRoot(allocator, &buf);
    defer allocator.free(root);
    defer ops_mod.deleteRecursive(allocator, root) catch {};
    const source = try std.fmt.allocPrint(allocator, "{s}/archive.zip", .{root});
    defer allocator.free(source);

    std.debug.print(
        "BENCH,operation,layout,files,directories,median_ns,files_per_second\n",
        .{},
    );
    for ([_]struct {
        name: []const u8,
        interleaved: bool,
        directory_depth: usize,
    }{
        .{ .name = "grouped", .interleaved = false, .directory_depth = 1 },
        .{ .name = "interleaved", .interleaved = true, .directory_depth = 1 },
        .{ .name = "deep_grouped", .interleaved = false, .directory_depth = 8 },
        .{ .name = "deep_interleaved", .interleaved = true, .directory_depth = 8 },
    }) |layout| {
        try writeArchiveBenchmarkFixture(
            allocator,
            source,
            directory_count,
            files_per_directory,
            layout.interleaved,
            layout.directory_depth,
        );
        try benchmarkArchiveLayout(
            allocator,
            source,
            root,
            layout.name,
            file_count,
            directory_count + layout.directory_depth - 1,
        );
    }
}

test "archive relative symlinks survive publication and cannot escape staging" {
    const mem = std.testing.allocator;
    for ([_][]const u8{ ".zip", ".tar.gz" }) |extension| {
        var buf: [256]u8 = undefined;
        const root = try makeTestDir(&buf);
        defer ops_mod.deleteRecursive(mem, root) catch {};
        const source = try std.fmt.allocPrint(mem, "{s}/sample{s}", .{ root, extension });
        defer mem.free(source);
        try writeArchiveFixtureLinks(source, &.{"repo/dank-qml-common/DCommon/item.txt"}, &.{
            .{ .name = "repo/quickshell/DCommon", .target = "../dank-qml-common/DCommon" },
            .{ .name = "repo/alias", .target = "quickshell/DCommon" },
            .{ .name = "repo/dangling", .target = "missing" },
        });
        var runner = try ops_mod.JobRunner.init(mem);
        defer runner.deinit();
        try runner.startArchive(source, root, null);
        runner.thread.?.join();
        runner.thread = null;
        try std.testing.expectEqual(@as(usize, 1), runner.pollProgress().success_count);
        const link = try std.fmt.allocPrintSentinel(mem, "{s}/repo/quickshell/DCommon", .{root}, 0);
        defer mem.free(link);
        var target: [128]u8 = undefined;
        const n = c.readlink(link, &target, target.len);
        try std.testing.expect(n > 0);
        try std.testing.expectEqualStrings("../dank-qml-common/DCommon", target[0..@intCast(n)]);
        const alias = try std.fmt.allocPrint(mem, "{s}/repo/alias/item.txt", .{root});
        defer mem.free(alias);
        var content: [32]u8 = undefined;
        try std.testing.expectEqualStrings("payload", try readTestFile(alias, &content));

        const unsafe: []const []const ArchiveLinkFixture = &.{
            &.{.{ .name = "link", .target = "/tmp/outside" }},
            &.{.{ .name = "repo/link", .target = "../../outside" }},
            &.{.{ .name = "link", .target = "link" }},
            &.{ .{ .name = "repo/up", .target = ".." }, .{ .name = "repo/link", .target = "up/../outside" } },
            &.{ .{ .name = "a", .target = "b" }, .{ .name = "b", .target = "a" } },
        };
        var cancel: archive.Cancel = .init(false);
        for (unsafe) |links| {
            try writeArchiveFixtureLinks(source, &.{"safe.txt"}, links);
            const stage = try archive.temporary(mem, root);
            defer mem.free(stage);
            try std.testing.expectError(error.UnsafeArchivePath, archive.extract(mem, source, stage, null, &cancel));
            try runner.startArchive(source, root, null);
            runner.thread.?.join();
            runner.thread = null;
            try std.testing.expectEqual(@as(usize, 1), runner.pollProgress().failed_count);
            const safe = try std.fmt.allocPrintSentinel(mem, "{s}/safe.txt", .{root}, 0);
            defer mem.free(safe);
            try std.testing.expect(c.access(safe, c.F_OK) != 0);
        }
        // A link cannot turn an archived child path into a redirected write.
        try writeArchiveFixtureLinks(source, &.{"repo/link/item.txt"}, &.{.{ .name = "repo/link", .target = "../other" }});
        const stage = try archive.temporary(mem, root);
        defer mem.free(stage);
        try std.testing.expectError(error.WriteFailed, archive.extract(mem, source, stage, null, &cancel));
        try std.testing.expectError(error.UnsupportedArchiveEntry, archive.extract(mem, source, stage, "repo/link", &cancel));
    }
}

test "archive index, staged extraction and member reads preserve destination boundaries" {
    for ([_][]const u8{ ".zip", ".tar.gz" }) |extension| {
        const mem = std.testing.allocator;
        var buf: [256]u8 = undefined;
        const root = try makeTestDir(&buf);
        defer ops_mod.deleteRecursive(mem, root) catch {};
        const source = try std.fmt.allocPrint(mem, "{s}/sample{s}", .{ root, extension });
        defer mem.free(source);
        try writeArchiveFixture(source, &.{ "/", "nested/item.txt", "other.txt" });
        var cancel: archive.Cancel = .init(false);
        var index = try archive.Index.read(mem, source, &cancel);
        defer index.deinit();
        try std.testing.expectEqual(@as(usize, 3), index.entries.len);
        try std.testing.expectEqualStrings("nested", index.entries[0].path);
        try std.testing.expect(index.entries[0].directory);
        const stage = try archive.temporary(mem, root);
        defer mem.free(stage);
        try archive.extract(mem, source, stage, "nested/item.txt", &cancel);
        const member = try std.fmt.allocPrint(mem, "{s}/nested/item.txt", .{stage});
        defer mem.free(member);
        var content: [32]u8 = undefined;
        try std.testing.expectEqualStrings("payload", try readTestFile(member, &content));
        try std.testing.expectError(error.WriteFailed, archive.extract(mem, source, stage, "nested/item.txt", &cancel));
        const full_stage = try archive.temporary(mem, root);
        defer mem.free(full_stage);
        try archive.extract(mem, source, full_stage, null, &cancel);
        const other = try std.fmt.allocPrint(mem, "{s}/other.txt", .{full_stage});
        defer mem.free(other);
        try std.testing.expectEqualStrings("payload", try readTestFile(other, &content));
        cancel.store(true, .release);
        try std.testing.expectError(error.Cancelled, archive.extract(mem, source, stage, null, &cancel));
        cancel.store(false, .release);

        // An unsafe member prevents publication of even earlier valid members.
        try writeArchiveFixture(source, &.{ "safe.txt", "../escaped.txt" });
        var runner = try ops_mod.JobRunner.init(mem);
        defer runner.deinit();
        try runner.startArchive(source, root, null);
        runner.thread.?.join();
        runner.thread = null;
        try std.testing.expectEqual(@as(usize, 1), runner.pollProgress().failed_count);
        const safe = try std.fmt.allocPrintSentinel(mem, "{s}/safe.txt", .{root}, 0);
        defer mem.free(safe);
        try std.testing.expect(c.access(safe, c.F_OK) != 0);
        for ([_][]const u8{ "/absolute", "//", "dir/../../escape", "a\\b" }) |name| {
            try std.testing.expectError(error.UnsafeArchivePath, archive.normalize(mem, name));
        }

        // Extraction shares the transfer conflict policy, preserving existing data.
        try writeArchiveFixture(source, &.{"same.txt"});
        const same = try std.fmt.allocPrint(mem, "{s}/same.txt", .{root});
        defer mem.free(same);
        try writeTestFile(same, "original");
        try runner.start(.extract, &.{source}, root, .skip);
        runner.thread.?.join();
        runner.thread = null;
        try std.testing.expectEqual(@as(usize, 1), runner.pollProgress().skipped_count);
        try std.testing.expectEqualStrings("original", try readTestFile(same, &content));
        try runner.start(.extract, &.{source}, root, .rename);
        runner.thread.?.join();
        runner.thread = null;
        const renamed = try std.fmt.allocPrint(mem, "{s}/same (1).txt", .{root});
        defer mem.free(renamed);
        try std.testing.expectEqualStrings("payload", try readTestFile(renamed, &content));
    }
}

test "selected archive members extract with relative paths and reject invalid selections" {
    const mem = std.testing.allocator;
    for ([_][]const u8{ ".zip", ".tar.gz" }) |extension| {
        var buf: [256]u8 = undefined;
        const root = try makeTestDir(&buf);
        defer ops_mod.deleteRecursive(mem, root) catch {};
        const source = try std.fmt.allocPrint(mem, "{s}/selected{s}", .{ root, extension });
        defer mem.free(source);
        try writeArchiveFixture(source, &.{
            "nested/",
            "nested/deep/",
            "nested/one.txt",
            "nested/deep/two.txt",
            "nestedish/other.txt",
            "empty/",
            "two.txt",
        });

        var cancel: archive.Cancel = .init(false);
        const stage = try archive.temporary(mem, root);
        defer mem.free(stage);
        try archive.extractMembers(mem, source, stage, &.{ "nested/one.txt", "two.txt" }, &cancel);

        var content: [32]u8 = undefined;
        const one = try std.fmt.allocPrint(mem, "{s}/nested/one.txt", .{stage});
        defer mem.free(one);
        try std.testing.expectEqualStrings("payload", try readTestFile(one, &content));
        const two = try std.fmt.allocPrint(mem, "{s}/two.txt", .{stage});
        defer mem.free(two);
        try std.testing.expectEqualStrings("payload", try readTestFile(two, &content));

        const duplicate_stage = try archive.temporary(mem, root);
        defer mem.free(duplicate_stage);
        try std.testing.expectError(
            error.InvalidArchive,
            archive.extractMembers(mem, source, duplicate_stage, &.{ "two.txt", "./two.txt" }, &cancel),
        );

        const directory_stage = try archive.temporary(mem, root);
        defer mem.free(directory_stage);
        try archive.extractMembers(
            mem,
            source,
            directory_stage,
            &.{ "nested", "nested/deep/two.txt", "empty", "two.txt" },
            &cancel,
        );

        const nested_file = try std.fmt.allocPrint(
            mem,
            "{s}/nested/one.txt",
            .{directory_stage},
        );
        defer mem.free(nested_file);
        try std.testing.expectEqualStrings("payload", try readTestFile(nested_file, &content));

        const deep_file = try std.fmt.allocPrint(
            mem,
            "{s}/nested/deep/two.txt",
            .{directory_stage},
        );
        defer mem.free(deep_file);
        try std.testing.expectEqualStrings("payload", try readTestFile(deep_file, &content));

        const prefix_collision = try std.fmt.allocPrint(
            mem,
            "{s}/nestedish/other.txt",
            .{directory_stage},
        );
        defer mem.free(prefix_collision);
        const prefix_collision_z = try mem.dupeSentinel(u8, prefix_collision, 0);
        defer mem.free(prefix_collision_z);
        try std.testing.expect(c.access(prefix_collision_z, c.F_OK) != 0);

        const root_file = try std.fmt.allocPrint(
            mem,
            "{s}/two.txt",
            .{directory_stage},
        );
        defer mem.free(root_file);
        try std.testing.expectEqualStrings("payload", try readTestFile(root_file, &content));

        const empty_dir = try std.fmt.allocPrint(
            mem,
            "{s}/empty",
            .{directory_stage},
        );
        defer mem.free(empty_dir);
        const empty_dir_z = try mem.dupeSentinel(u8, empty_dir, 0);
        defer mem.free(empty_dir_z);
        const empty_dir_fd = c.open(
            empty_dir_z,
            c.O_RDONLY | c.O_DIRECTORY | c.O_CLOEXEC,
        );
        try std.testing.expect(empty_dir_fd >= 0);
        _ = c.close(empty_dir_fd);

        const missing_stage = try archive.temporary(mem, root);
        defer mem.free(missing_stage);
        try std.testing.expectError(
            error.MemberNotFound,
            archive.extractMembers(mem, source, missing_stage, &.{"missing.txt"}, &cancel),
        );

        const empty_stage = try archive.temporary(mem, root);
        defer mem.free(empty_stage);
        try std.testing.expectError(
            error.MemberNotFound,
            archive.extractMembers(mem, source, empty_stage, &.{}, &cancel),
        );

        try writeArchiveFixtureLinks(source, &.{"nested/regular.txt"}, &.{.{
            .name = "nested/link.txt",
            .target = "regular.txt",
        }});
        const link_stage = try archive.temporary(mem, root);
        defer mem.free(link_stage);
        try std.testing.expectError(
            error.UnsupportedArchiveEntry,
            archive.extractMembers(mem, source, link_stage, &.{"nested"}, &cancel),
        );
    }
}
