const std = @import("std");
const sqlite = @import("ltx_sqlite");
const crash_options = @import("crash_options");
const protocol = @import("sqlite_crash_protocol.zig");

const page_size: usize = 512;

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

test "process crash at every empty-baseline boundary recovers canonical empty state" {
    for (protocol.baseline_points) |point| {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        try run_crash_child(temporary.dir, .baseline, point);
        try expect_recovery(temporary.dir, .empty);
    }
}

test "process crash at every first-publication boundary recovers one atomic state" {
    for (protocol.publication_cases) |case| {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        try run_crash_child(temporary.dir, .first_publication, case.point);
        try expect_recovery(
            temporary.dir,
            if (case.new_visible) first_generation() else .empty,
        );
    }
}

test "process crash at every later-publication boundary preserves old or new generation" {
    for (protocol.publication_cases) |case| {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        try run_crash_child(temporary.dir, .existing_publication, case.point);
        try expect_recovery(
            temporary.dir,
            if (case.new_visible) second_generation() else first_generation(),
        );
    }
}

test "process crash while stabilizing an observed manifest preserves its selected slot" {
    for (protocol.handoff_points) |point| {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        try run_crash_child(temporary.dir, .existing_publication, point);
        try expect_recovery(temporary.dir, first_generation());
    }
}

fn run_crash_child(
    dir: std.Io.Dir,
    scenario: protocol.Scenario,
    point: sqlite.FaultPoint,
) !void {
    try protocol.run_child(
        std.testing.allocator,
        std.testing.io,
        crash_options.child_path,
        dir,
        scenario,
        point,
    );
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
