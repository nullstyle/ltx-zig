const std = @import("std");
const ltx = @import("ltx");
const sqlite = @import("ltx_sqlite");
const protocol = @import("sqlite_crash_protocol.zig");

const page_size: u32 = 512;
const real_page_size: u32 = 1024;
const real_max_pages: u32 = 64;
const real_max_database_bytes = real_max_pages * real_page_size;
const real_max_compressed_bytes: u32 = 1100;
const real_max_ltx_bytes: u32 = 128 * 1024;

const real_codec_limits = ltx.Limits{
    .max_input_bytes = real_max_ltx_bytes,
    .max_output_bytes = real_max_ltx_bytes,
    .max_pages = real_max_pages,
    .max_page_size = real_page_size,
    .max_compressed_page_size = real_max_compressed_bytes,
    .max_page_index_bytes = 2048,
    .max_page_index_entries = real_max_pages,
    .max_varint_bytes = 10,
    .max_transaction_span = 1,
};

const Gate = struct {
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
    }

    fn release(context: *anyopaque) void {
        const self: *Gate = @ptrCast(@alignCast(context));
        std.debug.assert(self.held);
        self.held = false;
    }
};

const Crash = struct {
    target: sqlite.FaultPoint,

    fn hit(context: ?*anyopaque, point: sqlite.FaultPoint) void {
        const pointer = context orelse @panic("missing crash context");
        const self: *const Crash = @ptrCast(@alignCast(pointer));
        if (point == self.target) std.process.exit(protocol.crash_exit_code);
    }

    fn injection(self: *Crash) sqlite.FaultInjection {
        return .{ .context = self, .hit_fn = hit };
    }
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 4) return error.InvalidArguments;
    const scenario = std.meta.stringToEnum(protocol.Scenario, args[1]) orelse
        return error.InvalidArguments;
    const point = std.meta.stringToEnum(sqlite.FaultPoint, args[2]) orelse
        return error.InvalidArguments;
    if (!protocol.scenario_accepts(scenario, point)) return error.InvalidArguments;

    var dir = try std.Io.Dir.openDirAbsolute(init.io, args[3], .{});
    defer dir.close(init.io);
    switch (scenario) {
        .baseline => try crash_baseline(init.io, dir, point),
        .first_publication => try crash_first_publication(init.io, dir, point),
        .existing_publication => try crash_existing_publication(init.io, dir, point),
        .real_first_publication => try crash_real_first_publication(init.io, dir, point),
        .real_existing_publication => try crash_real_existing_publication(init.io, dir, point),
        .real_reuse_publication => try crash_real_reuse_publication(init.io, dir, point),
    }
    return error.CrashPointNotReached;
}

fn crash_baseline(io: std.Io, dir: std.Io.Dir, point: sqlite.FaultPoint) !void {
    var gate: Gate = .{};
    var copy_workspace: [73]u8 = undefined;
    var crash: Crash = .{ .target = point };
    const injection = crash.injection();
    var store = try sqlite.Store.init(
        io,
        dir,
        &copy_workspace,
        gate.lifecycle(),
        .{ .fault_injection = &injection },
    );
    _ = try store.recover();
}

fn crash_first_publication(
    io: std.Io,
    dir: std.Io.Dir,
    point: sqlite.FaultPoint,
) !void {
    var gate: Gate = .{};
    var copy_workspace: [73]u8 = undefined;
    var crash: Crash = .{ .target = point };
    const injection = crash.injection();
    var store = try sqlite.Store.init(
        io,
        dir,
        &copy_workspace,
        gate.lifecycle(),
        .{ .fault_injection = &injection },
    );
    try publish_generation(&store, 1, 0x11);
}

fn crash_existing_publication(
    io: std.Io,
    dir: std.Io.Dir,
    point: sqlite.FaultPoint,
) !void {
    var first_gate: Gate = .{};
    var first_copy_workspace: [73]u8 = undefined;
    var first = try sqlite.Store.init(
        io,
        dir,
        &first_copy_workspace,
        first_gate.lifecycle(),
        .{},
    );
    try publish_generation(&first, 1, 0x11);
    std.debug.assert(!first_gate.held);

    var crash_gate: Gate = .{};
    var crash_copy_workspace: [73]u8 = undefined;
    var crash: Crash = .{ .target = point };
    const injection = crash.injection();
    var second = try sqlite.Store.init(
        io,
        dir,
        &crash_copy_workspace,
        crash_gate.lifecycle(),
        .{ .fault_injection = &injection },
    );
    try publish_generation(&second, 2, 0x22);
}

fn crash_real_first_publication(
    io: std.Io,
    dir: std.Io.Dir,
    point: sqlite.FaultPoint,
) !void {
    var gate: Gate = .{};
    var copy_workspace: [4096]u8 = undefined;
    var crash: Crash = .{ .target = point };
    const injection = crash.injection();
    var store = try sqlite.Store.init(
        io,
        dir,
        &copy_workspace,
        gate.lifecycle(),
        .{ .fault_injection = &injection },
    );
    _ = try apply_transition_file(io, dir, protocol.real_snapshot_name, &store);
}

fn crash_real_existing_publication(
    io: std.Io,
    dir: std.Io.Dir,
    point: sqlite.FaultPoint,
) !void {
    var first_gate: Gate = .{};
    var first_copy_workspace: [4096]u8 = undefined;
    var first = try sqlite.Store.init(
        io,
        dir,
        &first_copy_workspace,
        first_gate.lifecycle(),
        .{},
    );
    _ = try apply_transition_file(io, dir, protocol.real_snapshot_name, &first);

    var crash_gate: Gate = .{};
    var crash_copy_workspace: [4096]u8 = undefined;
    var crash: Crash = .{ .target = point };
    const injection = crash.injection();
    var second = try sqlite.Store.init(
        io,
        dir,
        &crash_copy_workspace,
        crash_gate.lifecycle(),
        .{ .fault_injection = &injection },
    );
    _ = try apply_transition_file(io, dir, protocol.real_incremental_name, &second);
}

fn crash_real_reuse_publication(
    io: std.Io,
    dir: std.Io.Dir,
    point: sqlite.FaultPoint,
) !void {
    var first_gate: Gate = .{};
    var first_copy_workspace: [4096]u8 = undefined;
    var first = try sqlite.Store.init(
        io,
        dir,
        &first_copy_workspace,
        first_gate.lifecycle(),
        .{},
    );
    _ = try apply_transition_file(io, dir, protocol.real_snapshot_name, &first);
    _ = try apply_transition_file(io, dir, protocol.real_incremental_name, &first);

    var crash_gate: Gate = .{};
    var crash_copy_workspace: [4096]u8 = undefined;
    var crash: Crash = .{ .target = point };
    const injection = crash.injection();
    var second = try sqlite.Store.init(
        io,
        dir,
        &crash_copy_workspace,
        crash_gate.lifecycle(),
        .{ .fault_injection = &injection },
    );
    _ = try apply_transition_file(io, dir, protocol.real_reuse_name, &second);
}

fn apply_transition_file(
    io: std.Io,
    dir: std.Io.Dir,
    name: []const u8,
    store: *sqlite.Store,
) !ltx.VerifiedLTX {
    var encoded: [real_max_ltx_bytes]u8 = undefined;
    const length = try read_transition_file(io, dir, name, &encoded);

    var source = ltx.SliceReader.init(encoded[0..length]);
    var page_workspace: [real_page_size]u8 = undefined;
    var compressed_workspace: [real_max_compressed_bytes]u8 = undefined;
    var index_workspace: [real_max_pages]ltx.PageIndexEntry = undefined;
    var applier = try ltx.StagedApplier.init(
        .v3,
        real_codec_limits,
        .{
            .max_database_pages = real_max_pages,
            .max_database_bytes = real_max_database_bytes,
        },
        .contiguous,
        source.reader(),
        store.backend(),
        &page_workspace,
        &compressed_workspace,
        &index_workspace,
    );
    return applier.apply();
}

fn read_transition_file(
    io: std.Io,
    dir: std.Io.Dir,
    name: []const u8,
    destination: []u8,
) !usize {
    var file = try dir.openFile(io, name, .{
        .mode = .read_only,
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    });
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.size == 0 or stat.size > destination.len) return error.InvalidTransitionSize;
    const length: usize = @intCast(stat.size);
    const read = try file.readPositionalAll(io, destination[0..length], 0);
    if (read != length) return error.ShortTransitionRead;
    return length;
}

fn publish_generation(store: *sqlite.Store, txid: u64, fill: u8) !void {
    const header = make_header(txid);
    const backend = store.backend();
    const current = try backend.begin_fn(backend.context, .{
        .format_version = .v3,
        .mode = .contiguous,
        .header = header,
        .final_database_size_bytes = page_size,
    });
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
