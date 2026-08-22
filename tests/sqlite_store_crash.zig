const std = @import("std");
const ltx = @import("ltx");
const sqlite = @import("ltx_sqlite");
const crash_options = @import("crash_options");
const protocol = @import("sqlite_crash_protocol.zig");

const page_size: usize = 512;
const hold_generation_scenario = "hold-generation";
const ready_message = "READY\n";
const ready_timeout: std.Io.Timeout = .{ .duration = .{
    .clock = .awake,
    .raw = .fromSeconds(10),
} };

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

test "live process generation lease blocks writers and releases on owner death" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var seed_gate: Gate = .{};
    var seed_copy_workspace: [67]u8 = undefined;
    var seed_store = try sqlite.Store.init(
        std.testing.io,
        temporary.dir,
        &seed_copy_workspace,
        seed_gate.lifecycle(),
        .{},
    );
    try publish_generation(&seed_store, 1, 0x11);
    const first = (try seed_store.current()).?;

    var child = try spawn_generation_holder(temporary.dir);
    defer force_kill_generation_holder(&child);
    try wait_for_ready(&child);
    try expect_shared_generation(&seed_store, first);

    var writer_gate: Gate = .{};
    var writer_copy_workspace: [71]u8 = undefined;
    var writer = try sqlite.Store.init(
        std.testing.io,
        temporary.dir,
        &writer_copy_workspace,
        writer_gate.lifecycle(),
        .{},
    );
    try std.testing.expectError(error.ApplyBeginFailure, begin_generation(&writer, 2));
    try std.testing.expectEqual(sqlite.Failure.store_busy, writer.last_failure());
    try std.testing.expectEqual(sqlite.StoreState.idle, writer.current_state());
    try expect_gate_balanced(writer_gate, 1);
    try std.testing.expectEqual(first, (try writer.current()).?);
    try std.testing.expectEqual(sqlite.Failure.none, writer.last_failure());

    var recovery_gate: Gate = .{};
    var recovery_copy_workspace: [73]u8 = undefined;
    var recovery = try sqlite.Store.init(
        std.testing.io,
        temporary.dir,
        &recovery_copy_workspace,
        recovery_gate.lifecycle(),
        .{},
    );
    try std.testing.expectError(error.StoreBusy, recovery.recover());
    try std.testing.expectEqual(sqlite.Failure.store_busy, recovery.last_failure());
    try std.testing.expectEqual(sqlite.StoreState.recovery_required, recovery.current_state());
    try std.testing.expect(recovery_gate.held);
    try std.testing.expectEqual(@as(u8, 1), recovery_gate.quiesce_count);
    try std.testing.expectEqual(@as(u8, 0), recovery_gate.release_count);
    try std.testing.expectError(error.InvalidState, recovery.current());

    try kill_generation_holder(&child);
    try std.testing.expectEqual(first, (try recovery.recover()).?);
    try std.testing.expectEqual(sqlite.Failure.none, recovery.last_failure());
    try std.testing.expectEqual(sqlite.StoreState.idle, recovery.current_state());
    try std.testing.expectEqual(first, (try recovery.current()).?);
    try expect_gate_balanced(recovery_gate, 1);
    try publish_generation(&recovery, 2, 0x22);
    try expect_generation(temporary.dir, try recovery.current(), .{
        .number = 2,
        .txid = 2,
        .slot = .b,
        .fill = 0x22,
    });
    try expect_gate_balanced(recovery_gate, 2);
    try expect_path_absent(temporary.dir, sqlite.manifest_temporary_name);
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

fn spawn_generation_holder(dir: std.Io.Dir) !std.process.Child {
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path_length = try dir.realPath(std.testing.io, &path_buffer);
    return std.process.spawn(std.testing.io, .{
        .argv = &.{
            crash_options.child_path,
            hold_generation_scenario,
            path_buffer[0..path_length],
        },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .inherit,
    });
}

fn wait_for_ready(child: *std.process.Child) !void {
    var received: [ready_message.len]u8 = undefined;
    var received_bytes: usize = 0;
    const deadline = ready_timeout.toDeadline(std.testing.io);
    while (received_bytes < received.len) {
        const result = std.testing.io.operateTimeout(.{ .file_read_streaming = .{
            .file = child.stdout.?,
            .data = &.{received[received_bytes..]},
        } }, deadline) catch |err| switch (err) {
            error.Timeout => return error.ChildReadyTimeout,
            else => return err,
        };
        const count = result.file_read_streaming catch |err| switch (err) {
            error.EndOfStream => return error.ChildExitedBeforeReady,
            else => return err,
        };
        if (count == 0 or count > received.len - received_bytes) {
            return error.InvalidChildReadyProgress;
        }
        received_bytes += count;
    }
    try std.testing.expectEqualStrings(ready_message, &received);
}

fn kill_generation_holder(child: *std.process.Child) !void {
    const pid = child.id orelse return error.ChildAlreadyExited;
    try std.posix.kill(pid, .KILL);
    const term = try child.wait(std.testing.io);
    switch (term) {
        .signal => |signal| try std.testing.expectEqual(std.posix.SIG.KILL, signal),
        else => return error.UnexpectedChildTermination,
    }
}

fn force_kill_generation_holder(child: *std.process.Child) void {
    const pid = child.id orelse return;
    std.posix.kill(pid, .KILL) catch {};
    _ = child.wait(std.testing.io) catch {};
}

fn expect_shared_generation(store: *sqlite.Store, expected: sqlite.Current) !void {
    try std.testing.expectEqual(expected, (try store.current()).?);
    var storage: sqlite.GenerationAccessStorage = .{};
    var workspace: sqlite.GenerationAccessWorkspace = .{};
    var access = (try store.acquire_generation(&storage, &workspace)).?;
    try std.testing.expectEqual(expected, try access.current());
    try access.release();
}

fn expect_gate_balanced(gate: Gate, count: u8) !void {
    try std.testing.expect(!gate.held);
    try std.testing.expectEqual(count, gate.quiesce_count);
    try std.testing.expectEqual(count, gate.release_count);
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

fn begin_generation(store: *sqlite.Store, txid: u64) !ltx.ApplyCurrent {
    const backend = store.backend();
    return backend.begin_fn(backend.context, .{
        .format_version = .v3,
        .mode = .contiguous,
        .header = make_header(txid),
        .final_database_size_bytes = page_size,
    });
}

fn publish_generation(store: *sqlite.Store, txid: u64, fill: u8) !void {
    const header = make_header(txid);
    const current = try begin_generation(store, txid);
    const backend = store.backend();
    const page = make_sqlite_page(fill);
    try backend.stage_page_fn(backend.context, .{
        .page_number = 1,
        .offset_bytes = 0,
        .data = &page,
    });
    try backend.publish_fn(backend.context, current, make_verified(header));
}

fn make_header(txid: u64) ltx.Header {
    return .{
        .flags = ltx.header_flag_no_checksum,
        .page_size = page_size,
        .commit = 1,
        .min_txid = .init(txid),
        .max_txid = .init(txid),
        .timestamp_ms = 0,
        .pre_apply_checksum = .init(0),
        .wal_offset = 0,
        .wal_size = 0,
        .wal_salt_1 = 0,
        .wal_salt_2 = 0,
        .node_id = 0,
    };
}

fn make_verified(header: ltx.Header) ltx.VerifiedLTX {
    return .{
        .format_version = .v3,
        .header = header,
        .trailer = .{
            .post_apply_checksum = .init(0),
            .file_checksum = .init(ltx.checksum_flag),
        },
        .page_count = 1,
        .byte_count = 0,
    };
}
