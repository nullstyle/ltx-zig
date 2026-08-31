const std = @import("std");
const builtin = @import("builtin");

const child_output_limit_bytes: usize = 64 * 1024;
const diagnostic_output_limit_bytes: usize = 4096;
const archive_limit_bytes: u64 = 4 * 1024 * 1024;
const archive_entry_limit_count: usize = 512;
const archive_entry_limit_bytes: u64 = 4 * 1024 * 1024;
const archive_content_limit_bytes: u64 = 12 * 1024 * 1024;
const archive_expanded_limit_bytes: usize = 16 * 1024 * 1024;
const hash_limit_bytes: usize = 192;
const copy_buffer_bytes: usize = 4096;
const child_timeout: std.Io.Timeout = .{ .duration = .{
    .clock = .awake,
    .raw = .fromSeconds(120),
} };

const BoundedPath = struct {
    bytes: [std.fs.max_path_bytes + 1]u8 = undefined,
    length: usize = 0,

    fn resolve_file(io: std.Io, path: []const u8) !BoundedPath {
        if (path.len == 0 or path.len > std.fs.max_path_bytes) return error.InvalidPath;
        var result: BoundedPath = .{};
        result.length = try std.Io.Dir.cwd().realPathFile(
            io,
            path,
            result.bytes[0..std.fs.max_path_bytes],
        );
        if (result.length >= result.bytes.len) return error.NameTooLong;
        result.bytes[result.length] = 0;
        return result;
    }

    fn resolve_directory(io: std.Io, path: []const u8) !BoundedPath {
        if (path.len == 0 or path.len > std.fs.max_path_bytes) return error.InvalidPath;
        var dir = try std.Io.Dir.cwd().openDir(io, path, .{});
        defer dir.close(io);
        return directory_path(io, dir);
    }

    fn join(directory: *const BoundedPath, name: []const u8) !BoundedPath {
        if (name.len == 0) return error.InvalidPath;
        var result: BoundedPath = .{};
        const separator_length: usize = @intFromBool(
            directory.length == 0 or directory.bytes[directory.length - 1] != '/',
        );
        const name_offset = std.math.add(usize, directory.length, separator_length) catch
            return error.NameTooLong;
        const end = std.math.add(usize, name_offset, name.len) catch
            return error.NameTooLong;
        if (end >= result.bytes.len) return error.NameTooLong;
        @memcpy(result.bytes[0..directory.length], directory.slice());
        if (separator_length == 1) result.bytes[directory.length] = '/';
        @memcpy(result.bytes[name_offset..end], name);
        result.bytes[end] = 0;
        result.length = end;
        return result;
    }

    fn slice(self: *const BoundedPath) []const u8 {
        return self.bytes[0..self.length];
    }
};

const TemporaryDirectory = struct {
    const prefix = "ltx-zig-archive-smoke-";
    const random_bytes_count = 12;
    const encoded_bytes_count = std.base64.url_safe.Encoder.calcSize(random_bytes_count);
    const name_bytes = prefix.len + encoded_bytes_count;

    parent: std.Io.Dir,
    dir: std.Io.Dir,
    name: [name_bytes]u8,

    fn create(io: std.Io) !TemporaryDirectory {
        var parent = try std.Io.Dir.openDirAbsolute(io, "/tmp", .{});
        errdefer parent.close(io);
        for (0..8) |_| {
            var random_bytes: [random_bytes_count]u8 = undefined;
            io.random(&random_bytes);
            var name: [name_bytes]u8 = undefined;
            @memcpy(name[0..prefix.len], prefix);
            _ = std.base64.url_safe.Encoder.encode(name[prefix.len..], &random_bytes);
            parent.createDir(io, &name, @enumFromInt(0o700)) catch |err| switch (err) {
                error.PathAlreadyExists => continue,
                else => return err,
            };
            errdefer parent.deleteTree(io, &name) catch {};
            const dir = try parent.openDir(io, &name, .{});
            return .{ .parent = parent, .dir = dir, .name = name };
        }
        return error.TemporaryDirectoryCollision;
    }

    fn cleanup(self: *TemporaryDirectory, io: std.Io) void {
        self.dir.close(io);
        self.parent.deleteTree(io, &self.name) catch {};
        self.parent.close(io);
        self.* = undefined;
    }
};

pub fn main(init: std.process.Init) !void {
    switch (builtin.os.tag) {
        .linux, .macos => {},
        else => return error.UnsupportedPlatform,
    }
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 4) return error.InvalidArguments;
    const zig = try BoundedPath.resolve_file(init.io, args[1]);
    const repository = try BoundedPath.resolve_directory(init.io, args[2]);
    try require_optimize(args[3]);

    var temporary = try TemporaryDirectory.create(init.io);
    defer temporary.cleanup(init.io);
    try write_wrapper_package(init.io, temporary.dir);
    var root = try directory_path(init.io, temporary.dir);
    const fetch_cache = try create_directory(init.io, temporary.dir, &root, "fetch-cache");
    const source = try create_directory(init.io, temporary.dir, &root, "source");
    const hash = try fetch_archive(init, &zig, &repository, &fetch_cache, &root);
    const archive = try archive_path(&fetch_cache, hash);
    try extract_archive(init.io, temporary.dir, &source, &archive);
    try run_archived_builds(init, &zig, &source, &root, args[3]);

    var stdout_buffer: [192]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    try stdout_writer.interface.print(
        "canonical source archive {s} passed isolated consumer and example builds\n",
        .{hash},
    );
    try stdout_writer.interface.flush();
}

fn require_optimize(value: []const u8) !void {
    const valid = [_][]const u8{ "Debug", "ReleaseSafe", "ReleaseFast", "ReleaseSmall" };
    for (valid) |candidate| {
        if (std.mem.eql(u8, value, candidate)) return;
    }
    return error.InvalidOptimizeMode;
}

fn directory_path(io: std.Io, dir: std.Io.Dir) !BoundedPath {
    var result: BoundedPath = .{};
    result.length = try dir.realPath(io, result.bytes[0..std.fs.max_path_bytes]);
    if (result.length >= result.bytes.len) return error.NameTooLong;
    result.bytes[result.length] = 0;
    return result;
}

fn create_directory(
    io: std.Io,
    parent: std.Io.Dir,
    root: *const BoundedPath,
    name: []const u8,
) !BoundedPath {
    try parent.createDir(io, name, @enumFromInt(0o700));
    return BoundedPath.join(root, name);
}

fn write_wrapper_package(io: std.Io, root: std.Io.Dir) !void {
    try write_file(io, root, "build.zig",
        \\const std = @import("std");
        \\pub fn build(b: *std.Build) void { _ = b; }
        \\
    );
    try write_file(io, root, "build.zig.zon",
        \\.{
        \\    .name = .ltx_archive_smoke_wrapper,
        \\    .version = "0.0.0",
        \\    .fingerprint = 0xe42165d6ec43212a,
        \\    .minimum_zig_version = "0.16.0",
        \\    .dependencies = .{},
        \\    .paths = .{ "build.zig", "build.zig.zon" },
        \\}
        \\
    );
}

fn write_file(io: std.Io, root: std.Io.Dir, name: []const u8, contents: []const u8) !void {
    var file = try root.createFile(io, name, .{ .exclusive = true });
    defer file.close(io);
    var buffer: [512]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try writer.interface.writeAll(contents);
    try writer.interface.flush();
}

fn fetch_archive(
    init: std.process.Init,
    zig: *const BoundedPath,
    repository: *const BoundedPath,
    fetch_cache: *const BoundedPath,
    working_directory: *const BoundedPath,
) ![]const u8 {
    const result = try run_child(init, &.{
        zig.slice(),
        "fetch",
        "--global-cache-dir",
        fetch_cache.slice(),
        repository.slice(),
    }, working_directory.slice());
    defer init.gpa.free(result.stdout);
    defer init.gpa.free(result.stderr);
    try require_success("zig fetch local package", &result);
    if (result.stderr.len != 0) {
        print_child_result("zig fetch wrote stderr", &result);
        return error.FetchDiagnostic;
    }
    const hash = std.mem.trim(u8, result.stdout, " \t\r\n");
    try validate_hash(hash);
    return try init.arena.allocator().dupe(u8, hash);
}

fn validate_hash(hash: []const u8) !void {
    if (hash.len == 0 or hash.len > hash_limit_bytes) return error.InvalidPackageHash;
    for (hash) |byte| switch (byte) {
        'a'...'z', 'A'...'Z', '0'...'9', '-', '_', '.' => {},
        else => return error.InvalidPackageHash,
    };
    if (std.mem.indexOf(u8, hash, "..") != null) return error.InvalidPackageHash;
}

fn archive_path(fetch_cache: *const BoundedPath, hash: []const u8) !BoundedPath {
    const package_directory = try BoundedPath.join(fetch_cache, "p");
    var name_buffer: [hash_limit_bytes + ".tar.gz".len]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buffer, "{s}.tar.gz", .{hash});
    return BoundedPath.join(&package_directory, name);
}

fn extract_archive(
    io: std.Io,
    root: std.Io.Dir,
    source: *const BoundedPath,
    archive: *const BoundedPath,
) !void {
    var archive_file = try std.Io.Dir.cwd().openFile(io, archive.slice(), .{
        .mode = .read_only,
        .allow_directory = false,
    });
    defer archive_file.close(io);
    const stat = try archive_file.stat(io);
    if (stat.kind != .file or stat.size == 0 or stat.size > archive_limit_bytes) {
        return error.InvalidSourceArchive;
    }
    var source_dir = try root.openDir(io, "source", .{});
    defer source_dir.close(io);
    var file_buffer: [copy_buffer_bytes]u8 = undefined;
    var file_reader = archive_file.reader(io, &file_buffer);
    var decompress_buffer: [std.compress.flate.max_window_len]u8 = undefined;
    var decompressor: std.compress.flate.Decompress = .init(
        &file_reader.interface,
        .gzip,
        &decompress_buffer,
    );
    var expanded_buffer: [copy_buffer_bytes]u8 = undefined;
    var expanded_reader = decompressor.reader.limited(
        .limited(archive_expanded_limit_bytes + 1),
        &expanded_buffer,
    );
    try extract_bounded_tar(io, source_dir, &expanded_reader.interface);
    _ = try expanded_reader.interface.discardRemaining();
    if (expanded_reader.remaining == .nothing) {
        return error.ArchiveExpandedLimitExceeded;
    }
    try require_extracted_file(io, source, "build.zig.zon");
    try require_extracted_file(io, source, "LICENSE");
    try require_extracted_file(io, source, "tests/consumer/build.zig.zon");
}

const ArchivePrefix = struct {
    bytes: [std.fs.max_path_bytes]u8 = undefined,
    length: usize = 0,

    fn require(prefix: *ArchivePrefix, candidate: []const u8) !void {
        if (candidate.len == 0 or candidate.len > prefix.bytes.len) {
            return error.InvalidArchivePath;
        }
        if (prefix.length == 0) {
            @memcpy(prefix.bytes[0..candidate.len], candidate);
            prefix.length = candidate.len;
            return;
        }
        if (!std.mem.eql(u8, prefix.bytes[0..prefix.length], candidate)) {
            return error.MultipleArchiveRoots;
        }
    }
};

const ArchiveBudget = struct {
    entry_count: usize = 0,
    content_bytes: u64 = 0,

    fn account(budget: *ArchiveBudget, kind: std.tar.FileKind, size_bytes: u64) !void {
        if (budget.entry_count >= archive_entry_limit_count) {
            return error.ArchiveEntryLimitExceeded;
        }
        budget.entry_count += 1;
        switch (kind) {
            .sym_link => return error.UnsupportedArchiveEntry,
            .directory => if (size_bytes != 0) return error.InvalidArchiveEntry,
            .file => {
                if (size_bytes > archive_entry_limit_bytes) {
                    return error.ArchiveEntryTooLarge;
                }
                budget.content_bytes = std.math.add(
                    u64,
                    budget.content_bytes,
                    size_bytes,
                ) catch return error.ArchiveContentLimitExceeded;
                if (budget.content_bytes > archive_content_limit_bytes) {
                    return error.ArchiveContentLimitExceeded;
                }
            },
        }
    }
};

const ArchivePath = struct {
    prefix: []const u8,
    relative: []const u8,
};

fn extract_bounded_tar(io: std.Io, destination: std.Io.Dir, reader: *std.Io.Reader) !void {
    var file_name_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var link_name_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var iterator: std.tar.Iterator = .init(reader, .{
        .file_name_buffer = &file_name_buffer,
        .link_name_buffer = &link_name_buffer,
    });
    var prefix: ArchivePrefix = .{};
    var budget: ArchiveBudget = .{};
    for (0..archive_entry_limit_count + 1) |_| {
        const file = try iterator.next() orelse {
            if (prefix.length == 0) return error.EmptySourceArchive;
            return;
        };
        try budget.account(file.kind, file.size);
        const path = try sanitize_archive_path(file.name, file.kind);
        try prefix.require(path.prefix);
        try extract_archive_entry(io, destination, &iterator, file, path.relative);
    }
    return error.ArchiveEntryLimitExceeded;
}

fn extract_archive_entry(
    io: std.Io,
    destination: std.Io.Dir,
    iterator: *std.tar.Iterator,
    file: std.tar.Iterator.File,
    relative_path: []const u8,
) !void {
    switch (file.kind) {
        .sym_link => return error.UnsupportedArchiveEntry,
        .directory => {
            if (relative_path.len != 0) try destination.createDirPath(io, relative_path);
        },
        .file => {
            const parent = std.fs.path.dirname(relative_path);
            if (parent) |name| try destination.createDirPath(io, name);
            var output = try destination.createFile(io, relative_path, .{
                .exclusive = true,
                .resolve_beneath = true,
            });
            defer output.close(io);
            var output_buffer: [copy_buffer_bytes]u8 = undefined;
            var writer = output.writer(io, &output_buffer);
            try iterator.streamRemaining(file, &writer.interface);
            try writer.interface.flush();
        },
    }
}

fn sanitize_archive_path(path: []const u8, kind: std.tar.FileKind) !ArchivePath {
    if (path.len == 0 or path.len > std.fs.max_path_bytes or path[0] == '/') {
        return error.InvalidArchivePath;
    }
    var normalized = path;
    if (path[path.len - 1] == '/') {
        if (kind != .directory) return error.InvalidArchivePath;
        normalized = path[0 .. path.len - 1];
        if (normalized.len == 0 or normalized[normalized.len - 1] == '/') {
            return error.InvalidArchivePath;
        }
    }
    const separator = std.mem.indexOfScalar(u8, normalized, '/');
    const prefix = if (separator) |index| normalized[0..index] else normalized;
    const relative = if (separator) |index| normalized[index + 1 ..] else "";
    try validate_archive_component(prefix);
    if (relative.len == 0) {
        if (kind != .directory) return error.InvalidArchivePath;
    } else {
        try validate_archive_relative_path(relative);
    }
    return .{ .prefix = prefix, .relative = relative };
}

fn validate_archive_relative_path(path: []const u8) !void {
    const component_limit = std.fs.max_path_bytes / 2 + 1;
    var offset: usize = 0;
    for (0..component_limit) |_| {
        const relative_end = std.mem.indexOfScalar(u8, path[offset..], '/');
        const end = if (relative_end) |index| offset + index else path.len;
        try validate_archive_component(path[offset..end]);
        if (end == path.len) return;
        offset = end + 1;
    }
    return error.InvalidArchivePath;
}

fn validate_archive_component(component: []const u8) !void {
    if (component.len == 0 or
        std.mem.eql(u8, component, ".") or
        std.mem.eql(u8, component, "..")) return error.InvalidArchivePath;
    for (component) |byte| {
        if (byte == 0 or byte == '\\') return error.InvalidArchivePath;
    }
}

fn require_extracted_file(io: std.Io, root: *const BoundedPath, name: []const u8) !void {
    const path = try BoundedPath.join(root, name);
    var file = try std.Io.Dir.cwd().openFile(io, path.slice(), .{
        .mode = .read_only,
        .allow_directory = false,
    });
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.kind != .file or stat.size == 0) return error.InvalidExtractedPackage;
}

fn run_archived_builds(
    init: std.process.Init,
    zig: *const BoundedPath,
    source: *const BoundedPath,
    root: *const BoundedPath,
    optimize: []const u8,
) !void {
    const consumer = try BoundedPath.join(source, "tests/consumer");
    const consumer_local = try BoundedPath.join(root, "consumer-local-cache");
    const consumer_global = try BoundedPath.join(root, "consumer-global-cache");
    try run_zig_build(init, zig, &consumer, "test", &consumer_local, &consumer_global, optimize);

    const example_local = try BoundedPath.join(root, "example-local-cache");
    const example_global = try BoundedPath.join(root, "example-global-cache");
    const example_steps = [_][]const u8{
        "example-round-trip",
        "example-apply-snapshot",
        "example-sqlite-store",
        "example-replicate-once",
    };
    for (example_steps) |step| {
        try run_zig_build(
            init,
            zig,
            source,
            step,
            &example_local,
            &example_global,
            optimize,
        );
    }
}

fn run_zig_build(
    init: std.process.Init,
    zig: *const BoundedPath,
    cwd: *const BoundedPath,
    step: []const u8,
    local_cache: *const BoundedPath,
    global_cache: *const BoundedPath,
    optimize: []const u8,
) !void {
    var optimize_buffer: [64]u8 = undefined;
    const optimize_arg = try std.fmt.bufPrint(&optimize_buffer, "-Doptimize={s}", .{optimize});
    const result = try run_child(init, &.{
        zig.slice(),
        "build",
        step,
        "--cache-dir",
        local_cache.slice(),
        "--global-cache-dir",
        global_cache.slice(),
        optimize_arg,
    }, cwd.slice());
    defer init.gpa.free(result.stdout);
    defer init.gpa.free(result.stderr);
    try require_success(step, &result);
}

fn run_child(
    init: std.process.Init,
    argv: []const []const u8,
    cwd: ?[]const u8,
) !std.process.RunResult {
    return std.process.run(init.gpa, init.io, .{
        .argv = argv,
        .cwd = if (cwd) |path| .{ .path = path } else .inherit,
        .stdout_limit = .limited(child_output_limit_bytes),
        .stderr_limit = .limited(child_output_limit_bytes),
        .timeout = child_timeout.toDeadline(init.io),
    });
}

fn require_success(operation: []const u8, result: *const std.process.RunResult) !void {
    switch (result.term) {
        .exited => |code| if (code == 0) return,
        else => {},
    }
    print_child_result(operation, result);
    return error.ChildProcessFailed;
}

fn print_child_result(operation: []const u8, result: *const std.process.RunResult) void {
    const stdout = result.stdout[0..@min(result.stdout.len, diagnostic_output_limit_bytes)];
    const stderr = result.stderr[0..@min(result.stderr.len, diagnostic_output_limit_bytes)];
    std.debug.print(
        "{s}: term={any}, stdout {d} bytes: {s}\nstderr {d} bytes: {s}\n",
        .{ operation, result.term, result.stdout.len, stdout, result.stderr.len, stderr },
    );
}

test "package hashes are bounded safe path components" {
    try validate_hash("ltx_zig-0.1.0-Abc_123");
    try std.testing.expectError(error.InvalidPackageHash, validate_hash(""));
    try std.testing.expectError(error.InvalidPackageHash, validate_hash("../escape"));
    try std.testing.expectError(error.InvalidPackageHash, validate_hash("a/b"));
    const too_long: [hash_limit_bytes + 1]u8 = @splat('a');
    try std.testing.expectError(error.InvalidPackageHash, validate_hash(&too_long));
}

test "only standard optimization modes reach nested builds" {
    try require_optimize("Debug");
    try require_optimize("ReleaseSafe");
    try require_optimize("ReleaseFast");
    try require_optimize("ReleaseSmall");
    try std.testing.expectError(error.InvalidOptimizeMode, require_optimize("unsafe"));
}

test "archive paths have one safe stripped prefix" {
    const nested = try sanitize_archive_path("package/src/main.zig", .file);
    try std.testing.expectEqualStrings("package", nested.prefix);
    try std.testing.expectEqualStrings("src/main.zig", nested.relative);
    const root = try sanitize_archive_path("package/", .directory);
    try std.testing.expectEqualStrings("package", root.prefix);
    try std.testing.expectEqualStrings("", root.relative);

    const invalid = [_][]const u8{
        "/package/file", "package/../file", "package/./file",  "package//file",
        "package/file/", "package\\file",   "../package/file",
    };
    for (invalid) |path| {
        try std.testing.expectError(error.InvalidArchivePath, sanitize_archive_path(path, .file));
    }

    var prefix: ArchivePrefix = .{};
    try prefix.require("package");
    try prefix.require("package");
    try std.testing.expectError(error.MultipleArchiveRoots, prefix.require("other"));
}

test "archive budgets reject links and every configured limit" {
    var budget: ArchiveBudget = .{};
    try budget.account(.directory, 0);
    try budget.account(.file, archive_entry_limit_bytes);
    try std.testing.expectError(
        error.ArchiveEntryTooLarge,
        budget.account(.file, archive_entry_limit_bytes + 1),
    );
    try std.testing.expectError(
        error.UnsupportedArchiveEntry,
        budget.account(.sym_link, 0),
    );

    budget.content_bytes = archive_content_limit_bytes;
    try std.testing.expectError(
        error.ArchiveContentLimitExceeded,
        budget.account(.file, 1),
    );
    budget.entry_count = archive_entry_limit_count;
    try std.testing.expectError(
        error.ArchiveEntryLimitExceeded,
        budget.account(.file, 0),
    );
    var directory_budget: ArchiveBudget = .{};
    try std.testing.expectError(
        error.InvalidArchiveEntry,
        directory_budget.account(.directory, 1),
    );
}
