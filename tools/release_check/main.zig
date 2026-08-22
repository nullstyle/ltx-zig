const std = @import("std");

const version_marker = ".version = \"";
const manifest_limit_bytes = 64 * 1024;
const changelog_limit_bytes = 1024 * 1024;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3 and args.len != 4) return error.InvalidArguments;
    const manifest = try std.Io.Dir.cwd().readFileAlloc(
        init.io,
        args[1],
        init.arena.allocator(),
        .limited(manifest_limit_bytes),
    );
    const changelog = try std.Io.Dir.cwd().readFileAlloc(
        init.io,
        args[2],
        init.arena.allocator(),
        .limited(changelog_limit_bytes),
    );

    const version = try manifest_version(manifest);
    _ = try std.SemanticVersion.parse(version);
    try require_changelog_version(changelog, version);
    if (args.len == 4) try require_matching_tag(version, args[3]);

    var stdout_buffer: [128]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    try stdout_writer.interface.print("release metadata verified for {s}\n", .{version});
    try stdout_writer.interface.flush();
}

fn manifest_version(manifest: []const u8) ![]const u8 {
    const marker_offset = std.mem.indexOf(u8, manifest, version_marker) orelse
        return error.ManifestVersionMissing;
    const value_offset = marker_offset + version_marker.len;
    const relative_end = std.mem.indexOfScalar(u8, manifest[value_offset..], '"') orelse
        return error.ManifestVersionMalformed;
    if (relative_end == 0) return error.ManifestVersionMalformed;
    const value_end = value_offset + relative_end;
    if (std.mem.indexOf(u8, manifest[value_end + 1 ..], version_marker) != null) {
        return error.ManifestVersionDuplicate;
    }
    return manifest[value_offset..value_end];
}

fn require_changelog_version(changelog: []const u8, version: []const u8) !void {
    var heading_buffer: [128]u8 = undefined;
    const heading = try std.fmt.bufPrint(&heading_buffer, "\n## [{s}]", .{version});
    if (std.mem.indexOf(u8, changelog, heading) == null) {
        return error.ChangelogVersionMissing;
    }
}

fn require_matching_tag(version: []const u8, tag: []const u8) !void {
    var expected_buffer: [128]u8 = undefined;
    const expected = try std.fmt.bufPrint(&expected_buffer, "v{s}", .{version});
    if (!std.mem.eql(u8, tag, expected)) return error.ReleaseTagMismatch;
}

test "manifest version is unique and well formed" {
    try std.testing.expectEqualStrings(
        "1.2.3-alpha.1+build.7",
        try manifest_version(".{ .version = \"1.2.3-alpha.1+build.7\", }"),
    );
    try std.testing.expectError(
        error.ManifestVersionMissing,
        manifest_version(".{ .name = .ltx_zig, }"),
    );
    try std.testing.expectError(
        error.ManifestVersionMalformed,
        manifest_version(".{ .version = \"\", }"),
    );
    try std.testing.expectError(
        error.ManifestVersionMalformed,
        manifest_version(".{ .version = \"1.2.3, }"),
    );
    try std.testing.expectError(
        error.ManifestVersionDuplicate,
        manifest_version(".{ .version = \"1.2.3\", .version = \"1.2.4\", }"),
    );
}

test "semantic version, changelog heading, and tag agree" {
    const version = try manifest_version(".{ .version = \"1.2.3-alpha.1+build.7\", }");
    _ = try std.SemanticVersion.parse(version);
    try require_changelog_version(
        "# Changelog\n\n## [1.2.3-alpha.1+build.7] - 2026-08-21\n",
        version,
    );
    try require_matching_tag(version, "v1.2.3-alpha.1+build.7");

    try std.testing.expectError(
        error.ChangelogVersionMissing,
        require_changelog_version("# Changelog\n\n## [1.2.30]\n", "1.2.3"),
    );
    try std.testing.expectError(
        error.ReleaseTagMismatch,
        require_matching_tag("1.2.3", "v1.2.4"),
    );
}
