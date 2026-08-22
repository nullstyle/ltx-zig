const std = @import("std");

const version_marker = ".version = \"";
const package_name_marker = ".name = .";
const minimum_zig_marker = ".minimum_zig_version = \"";
const required_package_name = "ltx_zig";
const required_minimum_zig_version = "0.16.0";
const manifest_limit_bytes = 64 * 1024;
const changelog_limit_bytes = 1024 * 1024;
const documentation_limit_bytes = 1024 * 1024;
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

const Cli = struct {
    manifest_path: []const u8,
    changelog_path: []const u8,
    readme_path: []const u8,
    releasing_path: []const u8,
    license_paths: [required_licenses.len][]const u8,
    release_tag: ?[]const u8,
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const cli = parse_cli(args) catch |err| {
        try write_usage(init);
        return err;
    };
    const manifest = try read_bounded(init, cli.manifest_path, manifest_limit_bytes);
    const changelog = try read_bounded(init, cli.changelog_path, changelog_limit_bytes);
    const readme = try read_bounded(init, cli.readme_path, documentation_limit_bytes);
    const releasing = try read_bounded(init, cli.releasing_path, documentation_limit_bytes);

    const version = try manifest_version(manifest);
    _ = std.SemanticVersion.parse(version) catch return error.ManifestVersionMalformed;
    try require_package_name(manifest);
    try require_minimum_zig_version(manifest);
    try require_readme_version(readme, version);
    try require_releasing_version(releasing, version);
    try require_release_state(changelog, version, cli.release_tag);
    for (required_licenses, 0..) |license, index| {
        try require_manifest_path(manifest, license.package_path);
        const contents = try read_bounded(init, cli.license_paths[index], license_limit_bytes);
        try require_sha256(contents, license.sha256);
    }

    var stdout_buffer: [128]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    try stdout_writer.interface.print(
        "release metadata, documentation, and notices verified for {s}\n",
        .{version},
    );
    try stdout_writer.interface.flush();
}

fn parse_cli(args: anytype) !Cli {
    if (args.len != 8 and args.len != 9) return error.InvalidArguments;
    return .{
        .manifest_path = args[1],
        .changelog_path = args[2],
        .readme_path = args[3],
        .releasing_path = args[4],
        .license_paths = .{ args[5], args[6], args[7] },
        .release_tag = if (args.len == 9) args[8] else null,
    };
}

fn write_usage(init: std.process.Init) !void {
    var buffer: [512]u8 = undefined;
    var writer: std.Io.File.Writer = .init(.stderr(), init.io, &buffer);
    try writer.interface.writeAll(
        "usage: ltx-release-check <build.zig.zon> <CHANGELOG.md> <README.md> " ++
            "<docs/releasing.md> <LICENSE> <LICENSE.pierrec-lz4> " ++
            "<LICENSE.celld-litestream-apache-2.0> [release-tag]\n",
    );
    try writer.interface.flush();
}

fn read_bounded(init: std.process.Init, path: []const u8, limit_bytes: usize) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        init.io,
        path,
        init.arena.allocator(),
        .limited(limit_bytes),
    );
}

fn manifest_version(manifest: []const u8) ![]const u8 {
    return unique_delimited_value(manifest, version_marker, "\"") catch |err| switch (err) {
        error.ValueMissing => error.ManifestVersionMissing,
        error.ValueMalformed => error.ManifestVersionMalformed,
        error.ValueDuplicate => error.ManifestVersionDuplicate,
    };
}

fn require_package_name(manifest: []const u8) !void {
    const name = unique_delimited_value(manifest, package_name_marker, ",") catch |err| switch (err) {
        error.ValueMissing => return error.ManifestPackageNameMissing,
        error.ValueMalformed => return error.ManifestPackageNameMalformed,
        error.ValueDuplicate => return error.ManifestPackageNameDuplicate,
    };
    if (!std.mem.eql(u8, name, required_package_name)) {
        return error.ManifestPackageNameMismatch;
    }
}

fn require_minimum_zig_version(manifest: []const u8) !void {
    const version = unique_delimited_value(manifest, minimum_zig_marker, "\"") catch |err| switch (err) {
        error.ValueMissing => return error.ManifestMinimumZigVersionMissing,
        error.ValueMalformed => return error.ManifestMinimumZigVersionMalformed,
        error.ValueDuplicate => return error.ManifestMinimumZigVersionDuplicate,
    };
    _ = std.SemanticVersion.parse(version) catch return error.ManifestMinimumZigVersionMalformed;
    if (!std.mem.eql(u8, version, required_minimum_zig_version)) {
        return error.ManifestMinimumZigVersionMismatch;
    }
}

fn unique_delimited_value(
    source: []const u8,
    marker: []const u8,
    delimiter: []const u8,
) error{ ValueMissing, ValueMalformed, ValueDuplicate }![]const u8 {
    const marker_offset = std.mem.indexOf(u8, source, marker) orelse
        return error.ValueMissing;
    const value_offset = marker_offset + marker.len;
    const relative_end = std.mem.indexOf(u8, source[value_offset..], delimiter) orelse
        return error.ValueMalformed;
    if (relative_end == 0) return error.ValueMalformed;
    const value_end = value_offset + relative_end;
    if (std.mem.indexOf(u8, source[value_end + delimiter.len ..], marker) != null) {
        return error.ValueDuplicate;
    }
    return source[value_offset..value_end];
}

fn require_readme_version(readme: []const u8, version: []const u8) !void {
    const actual = unique_delimited_value(
        readme,
        "archive/refs/tags/v",
        ".tar.gz",
    ) catch |err| switch (err) {
        error.ValueMissing => return error.READMEVersionMissing,
        error.ValueMalformed => return error.READMEVersionMalformed,
        error.ValueDuplicate => return error.READMEVersionDuplicate,
    };
    _ = std.SemanticVersion.parse(actual) catch return error.READMEVersionMalformed;
    if (!std.mem.eql(u8, actual, version)) return error.READMEVersionMismatch;
}

fn require_releasing_version(releasing: []const u8, version: []const u8) !void {
    const marker = "-Drelease-tag=v";
    const marker_offset = std.mem.indexOf(u8, releasing, marker) orelse
        return error.ReleasingVersionMissing;
    if (std.mem.indexOf(u8, releasing[marker_offset + marker.len ..], marker) != null) {
        return error.ReleasingVersionDuplicate;
    }
    const start = marker_offset + marker.len;
    var end = start;
    while (end < releasing.len and is_semantic_version_byte(releasing[end])) : (end += 1) {}
    if (end == start) return error.ReleasingVersionMalformed;
    const actual = releasing[start..end];
    _ = std.SemanticVersion.parse(actual) catch return error.ReleasingVersionMalformed;
    if (!std.mem.eql(u8, actual, version)) return error.ReleasingVersionMismatch;
}

fn is_semantic_version_byte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '.' or byte == '-' or byte == '+';
}

const ReleaseState = enum {
    pending,
    dated,
};

fn changelog_release_state(changelog: []const u8, version: []const u8) !ReleaseState {
    var heading_buffer: [128]u8 = undefined;
    const prefix = try std.fmt.bufPrint(&heading_buffer, "## [{s}]", .{version});
    var matched: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, changelog, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, trimmed, prefix)) continue;
        if (matched != null) return error.ChangelogVersionDuplicate;
        matched = trimmed;
    }
    const heading = matched orelse return error.ChangelogVersionMissing;
    if (heading.len <= prefix.len or !std.mem.startsWith(u8, heading[prefix.len..], " - ")) {
        return error.ChangelogReleaseStateMalformed;
    }
    const value = heading[prefix.len + 3 ..];
    if (std.mem.eql(u8, value, "TBD")) return .pending;
    if (!is_release_date(value)) return error.ChangelogReleaseStateMalformed;
    return .dated;
}

fn is_release_date(value: []const u8) bool {
    if (value.len != 10 or value[4] != '-' or value[7] != '-') return false;
    if (!all_decimal_digits(value[0..4]) or
        !all_decimal_digits(value[5..7]) or
        !all_decimal_digits(value[8..10])) return false;
    const year = std.fmt.parseInt(u16, value[0..4], 10) catch return false;
    const month = std.fmt.parseInt(u8, value[5..7], 10) catch return false;
    const day = std.fmt.parseInt(u8, value[8..10], 10) catch return false;
    if (year == 0 or month == 0 or month > 12 or day == 0) return false;
    const leap = year % 400 == 0 or (year % 4 == 0 and year % 100 != 0);
    const days_in_month: u8 = switch (month) {
        2 => if (leap) 29 else 28,
        4, 6, 9, 11 => 30,
        else => 31,
    };
    return day <= days_in_month;
}

fn all_decimal_digits(value: []const u8) bool {
    for (value) |byte| {
        if (!std.ascii.isDigit(byte)) return false;
    }
    return true;
}

fn require_release_state(
    changelog: []const u8,
    version: []const u8,
    release_tag: ?[]const u8,
) !void {
    const state = try changelog_release_state(changelog, version);
    if (release_tag) |tag| {
        try require_matching_tag(version, tag);
        if (state != .dated) return error.ReleaseDateRequired;
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

test "CLI accepts metadata, notice paths, and an optional release tag" {
    const base = [_][]const u8{
        "check",             "build.zig.zon", "CHANGELOG.md",        "README.md",
        "docs/releasing.md", "LICENSE",       "LICENSE.pierrec-lz4", "LICENSE.celld-litestream-apache-2.0",
    };
    const prerelease = try parse_cli(&base);
    try std.testing.expect(prerelease.release_tag == null);
    try std.testing.expectEqualStrings("README.md", prerelease.readme_path);

    const tagged = base ++ [_][]const u8{"v0.1.0"};
    const release = try parse_cli(&tagged);
    try std.testing.expectEqualStrings("v0.1.0", release.release_tag.?);
    try std.testing.expectError(error.InvalidArguments, parse_cli(base[0..7]));
}

test "manifest release metadata is exact, unique, and well formed" {
    const complete =
        \\.{
        \\    .name = .ltx_zig,
        \\    .version = "1.2.3-alpha.1+build.7",
        \\    .minimum_zig_version = "0.16.0",
        \\}
    ;
    const version = try manifest_version(complete);
    try std.testing.expectEqualStrings("1.2.3-alpha.1+build.7", version);
    _ = try std.SemanticVersion.parse(version);
    try require_package_name(complete);
    try require_minimum_zig_version(complete);

    try std.testing.expectError(error.ManifestVersionMissing, manifest_version(".{ .name = .ltx_zig, }"));
    try std.testing.expectError(error.ManifestVersionMalformed, manifest_version(".{ .version = \"\", }"));
    try std.testing.expectError(error.ManifestVersionDuplicate, manifest_version(
        ".version = \"1.2.3\"\n.version = \"1.2.4\"",
    ));
    try std.testing.expectError(
        error.ManifestPackageNameMismatch,
        require_package_name(".name = .ltx,"),
    );
    try std.testing.expectError(
        error.ManifestPackageNameDuplicate,
        require_package_name(".name = .ltx_zig,\n.name = .ltx_zig,"),
    );
    try std.testing.expectError(
        error.ManifestMinimumZigVersionMismatch,
        require_minimum_zig_version(".minimum_zig_version = \"0.15.2\","),
    );
    try std.testing.expectError(
        error.ManifestMinimumZigVersionMalformed,
        require_minimum_zig_version(".minimum_zig_version = \"development\","),
    );
}

test "README and release checklist examples match the package version" {
    const readme = "zig fetch https://host/archive/refs/tags/v0.1.0.tar.gz\n";
    const releasing = "zig build release-check -Drelease-tag=v0.1.0\n";
    try require_readme_version(readme, "0.1.0");
    try require_releasing_version(releasing, "0.1.0");
    try std.testing.expectError(error.READMEVersionMismatch, require_readme_version(readme, "0.2.0"));
    try std.testing.expectError(
        error.ReleasingVersionMismatch,
        require_releasing_version(releasing, "0.2.0"),
    );
    try std.testing.expectError(
        error.READMEVersionDuplicate,
        require_readme_version(readme ++ readme, "0.1.0"),
    );
    try std.testing.expectError(
        error.ReleasingVersionMalformed,
        require_releasing_version("zig build -Drelease-tag=vnext\n", "0.1.0"),
    );
}

test "changelog state is unique and TBD is allowed only before tagging" {
    const pending = "# Changelog\n\n## [Unreleased]\n\n## [0.1.0] - TBD\n";
    const released = "# Changelog\n\n## [0.1.0] - 2026-08-21\n";
    try require_release_state(pending, "0.1.0", null);
    try require_release_state(released, "0.1.0", null);
    try require_release_state(released, "0.1.0", "v0.1.0");
    try std.testing.expectError(
        error.ReleaseDateRequired,
        require_release_state(pending, "0.1.0", "v0.1.0"),
    );
    try std.testing.expectError(
        error.ReleaseTagMismatch,
        require_release_state(released, "0.1.0", "v0.1.1"),
    );
    try std.testing.expectError(
        error.ChangelogVersionDuplicate,
        changelog_release_state(released ++ "\n## [0.1.0] - 2026-08-22\n", "0.1.0"),
    );
    try std.testing.expectError(
        error.ChangelogVersionMissing,
        changelog_release_state("## [0.1.00] - TBD\n", "0.1.0"),
    );
}

test "release dates are real YYYY-MM-DD calendar dates" {
    try std.testing.expect(is_release_date("2024-02-29"));
    try std.testing.expect(is_release_date("2026-08-21"));
    try std.testing.expect(!is_release_date("2025-02-29"));
    try std.testing.expect(!is_release_date("2026-13-01"));
    try std.testing.expect(!is_release_date("2026-04-31"));
    try std.testing.expect(!is_release_date("2026-8-21"));
    try std.testing.expect(!is_release_date("+026-08-21"));
    try std.testing.expect(!is_release_date("0000-01-01"));
    try std.testing.expectError(
        error.ChangelogReleaseStateMalformed,
        changelog_release_state("## [0.1.0] - 2025-02-29\n", "0.1.0"),
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
