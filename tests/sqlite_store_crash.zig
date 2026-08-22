const std = @import("std");
const sqlite = @import("ltx_sqlite");
const crash_options = @import("crash_options");

const crash_exit_code: u8 = 86;
const page_size: usize = 512;

const Scenario = enum {
    baseline,
    first_publication,
    existing_publication,
};

const Expected = union(enum) {
    empty,
    generation: struct {
        number: u64,
        txid: u64,
        slot: sqlite.Slot,
        fill: u8,
    },
};

const Gate = struct {
    quiesce_count: u8 = 0,
    release_count: u8 = 0,
    held: bool = false,

    fn lifecycle(self: *Gate) sqlite.Lifecycle {
        return .{
            .context = self,
            .quiesce_fn = quiesce,
            .release_fn = release,
        };
    }

    fn quiesce(context: *anyopaque) error{QuiesceFailure}!void {
        const self: *Gate = @ptrCast(@alignCast(context));
        std.debug.assert(!self.held);
        self.held = true;
        self.quiesce_count += 1;
    }

    fn release(context: *anyopaque) void {
        const self: *Gate = @ptrCast(@alignCast(context));
        std.debug.assert(self.held);
        self.held = false;
        self.release_count += 1;
    }
};

const baseline_points = [_]sqlite.FaultPoint{
    .baseline_manifest_sync,
    .baseline_directory_sync,
    .baseline_manifest_rename,
    .baseline_commit_directory_sync,
};

const handoff_points = [_]sqlite.FaultPoint{
    .loaded_manifest_directory_sync,
};

const publication_cases = [_]struct {
    point: sqlite.FaultPoint,
    first: Expected,
    existing: Expected,
}{
    .{ .point = .database_sync, .first = .empty, .existing = first_generation() },
    .{ .point = .database_directory_sync, .first = .empty, .existing = first_generation() },
    .{ .point = .manifest_sync, .first = .empty, .existing = first_generation() },
    .{ .point = .manifest_directory_sync, .first = .empty, .existing = first_generation() },
    .{ .point = .manifest_rename, .first = first_generation(), .existing = second_generation() },
    .{ .point = .commit_directory_sync, .first = first_generation(), .existing = second_generation() },
};

comptime {
    const point_count = std.meta.fields(sqlite.FaultPoint).len;
    var seen: [point_count]bool = @splat(false);
    for (baseline_points) |point| {
        const index = @intFromEnum(point);
        if (seen[index]) @compileError("duplicate SQLite crash fault point");
        seen[index] = true;
    }
    for (handoff_points) |point| {
        const index = @intFromEnum(point);
        if (seen[index]) @compileError("duplicate SQLite crash fault point");
        seen[index] = true;
    }
    for (publication_cases) |case| {
        const index = @intFromEnum(case.point);
        if (seen[index]) @compileError("duplicate SQLite crash fault point");
        seen[index] = true;
    }
    for (seen) |covered| {
        if (!covered) @compileError("SQLite crash fault point lacks subprocess coverage");
    }
}

test "process crash at every empty-baseline boundary recovers canonical empty state" {
    for (baseline_points) |point| {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        try run_crash_child(temporary.dir, .baseline, point);
        try expect_recovery(temporary.dir, .empty);
    }
}

test "process crash at every first-publication boundary recovers one atomic state" {
    for (publication_cases) |case| {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        try run_crash_child(temporary.dir, .first_publication, case.point);
        try expect_recovery(temporary.dir, case.first);
    }
}

test "process crash at every later-publication boundary preserves old or new generation" {
    for (publication_cases) |case| {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        try run_crash_child(temporary.dir, .existing_publication, case.point);
        try expect_recovery(temporary.dir, case.existing);
    }
}

test "process crash while stabilizing an observed manifest preserves its selected slot" {
    for (handoff_points) |point| {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        try run_crash_child(temporary.dir, .existing_publication, point);
        try expect_recovery(temporary.dir, first_generation());
    }
}

fn run_crash_child(
    dir: std.Io.Dir,
    scenario: Scenario,
    point: sqlite.FaultPoint,
) !void {
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path_length = try dir.realPath(std.testing.io, &path_buffer);
    const result = try std.process.run(
        std.testing.allocator,
        std.testing.io,
        .{
            .argv = &.{
                crash_options.child_path,
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
        },
    );
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
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

fn expect_recovery(dir: std.Io.Dir, expected: Expected) !void {
    var gate: Gate = .{};
    var copy_workspace: [67]u8 = undefined;
    var store = try sqlite.Store.init(
        std.testing.io,
        dir,
        &copy_workspace,
        gate.lifecycle(),
        .{},
    );
    const recovered = try store.recover();
    try std.testing.expect(!gate.held);
    try std.testing.expectEqual(@as(u8, 1), gate.quiesce_count);
    try std.testing.expectEqual(gate.quiesce_count, gate.release_count);
    try std.testing.expectEqualDeep(recovered, try store.current());
    try expect_path_absent(dir, sqlite.manifest_temporary_name);
    switch (expected) {
        .empty => try expect_empty(dir, recovered),
        .generation => |generation| try expect_generation(dir, recovered, generation),
    }
}

fn expect_empty(dir: std.Io.Dir, recovered: ?sqlite.Current) !void {
    try std.testing.expectEqual(null, recovered);
    try expect_path_absent(dir, sqlite.database_a_name);
    try expect_path_absent(dir, sqlite.database_b_name);
}

fn expect_generation(
    dir: std.Io.Dir,
    recovered: ?sqlite.Current,
    expected: @FieldType(Expected, "generation"),
) !void {
    const current = recovered orelse return error.ExpectedGeneration;
    try std.testing.expectEqual(expected.number, current.generation);
    try std.testing.expectEqual(expected.txid, current.position.txid.value);
    try std.testing.expectEqual(@as(u64, 0), current.position.post_apply_checksum.value);
    try std.testing.expectEqual(expected.slot, current.slot);
    try std.testing.expectEqual(@as(u32, page_size), current.page_size);
    try std.testing.expectEqual(@as(u64, page_size), current.database_size_bytes);

    var file = try dir.openFile(std.testing.io, current.database_name(), .{
        .mode = .read_only,
        .follow_symlinks = false,
        .resolve_beneath = true,
    });
    defer file.close(std.testing.io);
    var page: [page_size]u8 = undefined;
    const read = try file.readPositionalAll(std.testing.io, &page, 0);
    try std.testing.expectEqual(page.len, read);
    const expected_page = make_sqlite_page(expected.fill);
    try std.testing.expectEqualSlices(u8, &expected_page, &page);
}

fn make_sqlite_page(fill: u8) [page_size]u8 {
    var page: [page_size]u8 = @splat(0);
    @memcpy(page[0..16], "SQLite format 3\x00");
    std.mem.writeInt(u16, page[16..18], page_size, .big);
    page[18] = 1;
    page[19] = 1;
    page[21] = 64;
    page[22] = 32;
    page[23] = 32;
    std.mem.writeInt(u32, page[24..28], 1, .big);
    std.mem.writeInt(u32, page[28..32], 1, .big);
    std.mem.writeInt(u32, page[40..44], 1, .big);
    std.mem.writeInt(u32, page[44..48], 4, .big);
    std.mem.writeInt(u32, page[56..60], 1, .big);
    std.mem.writeInt(u32, page[92..96], 1, .big);
    std.mem.writeInt(u32, page[96..100], 3_051_000, .big);
    page[100] = 13;
    std.mem.writeInt(u16, page[105..107], page_size, .big);
    @memset(page[108..], fill);
    return page;
}

fn expect_path_absent(dir: std.Io.Dir, name: []const u8) !void {
    try std.testing.expectError(
        error.FileNotFound,
        dir.statFile(std.testing.io, name, .{ .follow_symlinks = false }),
    );
}

fn first_generation() Expected {
    return .{ .generation = .{
        .number = 1,
        .txid = 1,
        .slot = .a,
        .fill = 0x11,
    } };
}

fn second_generation() Expected {
    return .{ .generation = .{
        .number = 2,
        .txid = 2,
        .slot = .b,
        .fill = 0x22,
    } };
}
