const std = @import("std");

const version_marker = ".version = \"";
const manifest_limit_bytes = 64 * 1024;
const changelog_limit_bytes = 1024 * 1024;
const license_limit_bytes = 64 * 1024;

const RequiredLicense = struct {
    package_path: []const u8,
    sha256: []const u8,
};

const required_licenses = [_]RequiredLicense{
    .{
        .package_path = "LICENSE",
        .sha256 = "8380fbc9b967f2411512125692b08c88143ddaff0352d93dc942bd6e720091b4",
    },
    .{
        .package_path = "LICENSE.pierrec-lz4",
        .sha256 = "81436a8a4ab6927ec69561e406f1f3d15aeff80fcbd0236847fbad725e72c88f",
    },
    .{
        .package_path = "LICENSE.celld-litestream-apache-2.0",
        .sha256 = "cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30",
    },
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 6 and args.len != 7) return error.InvalidArguments;
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
    for (required_licenses, 0..) |license, index| {
        try require_manifest_path(manifest, license.package_path);
        const contents = try std.Io.Dir.cwd().readFileAlloc(
            init.io,
            args[index + 3],
            init.arena.allocator(),
            .limited(license_limit_bytes),
        );
        try require_sha256(contents, license.sha256);
    }
    try require_changelog_version(changelog, version);
    if (args.len == 7) try require_matching_tag(version, args[6]);

    var stdout_buffer: [128]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    try stdout_writer.interface.print(
        "release metadata and license notices verified for {s}\n",
        .{version},
    );
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

fn require_manifest_path(manifest: []const u8, path: []const u8) !void {
    var marker_buffer: [256]u8 = undefined;
    const marker = try std.fmt.bufPrint(&marker_buffer, "\"{s}\",", .{path});
    var lines = std.mem.splitScalar(u8, manifest, '\n');
    var in_paths = false;
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (!in_paths) {
            in_paths = std.mem.eql(u8, trimmed, ".paths = .{");
            continue;
        }
        if (std.mem.eql(u8, trimmed, marker)) return;
        if (std.mem.eql(u8, trimmed, "},")) break;
    }
    return error.PackagePathMissing;
}

fn require_sha256(contents: []const u8, expected_hex: []const u8) !void {
    var expected: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    if (expected_hex.len != expected.len * 2) return error.LicenseDigestMalformed;
    const decoded = try std.fmt.hexToBytes(&expected, expected_hex);
    if (decoded.len != expected.len) return error.LicenseDigestMalformed;
    var actual: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(contents, &actual, .{});
    if (!std.mem.eql(u8, &expected, &actual)) return error.LicenseDigestMismatch;
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

test "required license notices remain in the package paths" {
    const complete =
        \\.{
        \\    .paths = .{
        \\        "LICENSE",
        \\        "LICENSE.pierrec-lz4",
        \\        "LICENSE.celld-litestream-apache-2.0",
        \\    },
        \\}
    ;
    for (required_licenses) |license| {
        try require_manifest_path(complete, license.package_path);
    }
    try std.testing.expectError(
        error.PackagePathMissing,
        require_manifest_path(
            \\.{
            \\    .paths = .{
            \\        // "LICENSE.celld-litestream-apache-2.0",
            \\    },
            \\}
        , required_licenses[2].package_path),
    );
}

test "required license contents are digest locked" {
    try require_sha256(
        "abc",
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
    );
    try std.testing.expectError(
        error.LicenseDigestMismatch,
        require_sha256(
            "abd",
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        ),
    );
}
