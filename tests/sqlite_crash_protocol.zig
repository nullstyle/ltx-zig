const std = @import("std");
const sqlite = @import("ltx_sqlite");

pub const crash_exit_code: u8 = 86;
pub const real_snapshot_name = "crash-a.ltx";
pub const real_incremental_name = "crash-b.ltx";
pub const real_reuse_name = "crash-c.ltx";

pub const Scenario = enum {
    baseline,
    first_publication,
    existing_publication,
    real_first_publication,
    real_existing_publication,
    real_reuse_publication,
};

pub const baseline_points = [_]sqlite.FaultPoint{
    .baseline_manifest_sync,
    .baseline_directory_sync,
    .baseline_manifest_rename,
    .baseline_commit_directory_sync,
};

pub const handoff_points = [_]sqlite.FaultPoint{
    .loaded_manifest_directory_sync,
};

pub const publication_cases = [_]struct {
    point: sqlite.FaultPoint,
    new_visible: bool,
}{
    .{ .point = .database_sync, .new_visible = false },
    .{ .point = .database_directory_sync, .new_visible = false },
    .{ .point = .manifest_sync, .new_visible = false },
    .{ .point = .manifest_directory_sync, .new_visible = false },
    .{ .point = .manifest_rename, .new_visible = true },
    .{ .point = .commit_directory_sync, .new_visible = true },
};

comptime {
    const point_count = std.meta.fields(sqlite.FaultPoint).len;
    var seen: [point_count]bool = @splat(false);
    for (baseline_points) |point| mark_covered(&seen, point);
    for (handoff_points) |point| mark_covered(&seen, point);
    for (publication_cases) |case| mark_covered(&seen, case.point);
    for (seen) |covered| {
        if (!covered) @compileError("SQLite crash fault point lacks subprocess coverage");
    }
}

fn mark_covered(seen: []bool, point: sqlite.FaultPoint) void {
    const index = @intFromEnum(point);
    if (seen[index]) @compileError("duplicate SQLite crash fault point");
    seen[index] = true;
}

pub fn scenario_accepts(scenario: Scenario, point: sqlite.FaultPoint) bool {
    return switch (scenario) {
        .baseline => contains(sqlite.FaultPoint, &baseline_points, point),
        .first_publication, .real_first_publication => contains_publication(point),
        .existing_publication, .real_existing_publication, .real_reuse_publication => contains(sqlite.FaultPoint, &handoff_points, point) or contains_publication(point),
    };
}

fn contains_publication(point: sqlite.FaultPoint) bool {
    for (publication_cases) |case| {
        if (case.point == point) return true;
    }
    return false;
}

fn contains(comptime T: type, values: []const T, needle: T) bool {
    for (values) |value| {
        if (value == needle) return true;
    }
    return false;
}

pub fn run_child(
    allocator: std.mem.Allocator,
    io: std.Io,
    child_path: []const u8,
    dir: std.Io.Dir,
    scenario: Scenario,
    point: sqlite.FaultPoint,
) !void {
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path_length = try dir.realPath(io, &path_buffer);
    const result = try std.process.run(allocator, io, .{
        .argv = &.{
            child_path,
            @tagName(scenario),
            @tagName(point),
            path_buffer[0..path_length],
        },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
        .timeout = .{ .duration = .{
            .clock = .awake,
            .raw = .fromSeconds(10),
        } },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != crash_exit_code) {
            std.debug.print("crash child exited {d}: {s}\n", .{ code, result.stderr });
            return error.UnexpectedChildTermination;
        },
        else => {
            std.debug.print("crash child terminated {any}: {s}\n", .{ result.term, result.stderr });
            return error.UnexpectedChildTermination;
        },
    }
}
