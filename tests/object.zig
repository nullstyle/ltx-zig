//! `ltx_object` tests: the filesystem backend against the backend-agnostic
//! conformance suite, plus the exact Litestream on-disk layout.

const std = @import("std");
const ltx = @import("ltx");
const object = @import("ltx_object");

test "file client passes the backend conformance suite" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var file_client = try object.FileClient.init(temporary.dir, std.testing.io, "");
    try object.run_conformance(file_client.client());

    // The suite cleaned up after itself: levels 0 and 1 are empty again.
    var infos: [8]ltx.FileInfo = undefined;
    var client = file_client.client();
    try std.testing.expectEqual(
        @as(usize, 0),
        (try client.list(0, ltx.TXID.init(0), &infos)).len,
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        (try client.list(1, ltx.TXID.init(0), &infos)).len,
    );
}

test "file client writes the litestream filesystem layout" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var file_client = try object.FileClient.init(temporary.dir, std.testing.io, "replica");
    var client = file_client.client();
    const identity = ltx.FileIdentity{
        .min_txid = ltx.TXID.init(1),
        .max_txid = ltx.TXID.init(1),
    };
    try client.write(0, identity, 1234, "snapshot bytes");
    _ = try temporary.dir.statFile(
        std.testing.io,
        "replica/ltx/0/0000000000000001-0000000000000001.ltx",
        .{},
    );
    // No temporary file survives publication.
    try std.testing.expectError(
        error.FileNotFound,
        temporary.dir.statFile(
            std.testing.io,
            "replica/ltx/0/0000000000000001-0000000000000001.ltx.tmp",
            .{},
        ),
    );

    var storage: [32]u8 = undefined;
    try std.testing.expectEqualStrings(
        "snapshot bytes",
        try client.open(0, identity, &storage),
    );
    var small: [4]u8 = undefined;
    try std.testing.expectError(error.ObjectTooLarge, client.open(0, identity, &small));
    try std.testing.expectError(
        error.ObjectNotFound,
        client.open(0, .{ .min_txid = ltx.TXID.init(9), .max_txid = ltx.TXID.init(9) }, &storage),
    );
}

test "file client ignores foreign and hidden files when listing" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var file_client = try object.FileClient.init(temporary.dir, std.testing.io, "");
    var client = file_client.client();
    const first = ltx.FileIdentity{
        .min_txid = ltx.TXID.init(1),
        .max_txid = ltx.TXID.init(1),
    };
    const second = ltx.FileIdentity{
        .min_txid = ltx.TXID.init(2),
        .max_txid = ltx.TXID.init(5),
    };
    try client.write(0, first, 1, "one");
    try client.write(0, second, 2, "two");

    // Foreign names in the level directory are ignored by listings.
    const foreign = try temporary.dir.createFile(std.testing.io, "ltx/0/README.md", .{});
    foreign.close(std.testing.io);
    const stale = try temporary.dir.createFile(
        std.testing.io,
        "ltx/0/0000000000000001-0000000000000001.ltx.tmp",
        .{ .truncate = true },
    );
    stale.close(std.testing.io);

    var infos: [4]ltx.FileInfo = undefined;
    const listed = try client.list(0, ltx.TXID.init(0), &infos);
    try std.testing.expectEqual(@as(usize, 2), listed.len);
    try std.testing.expectEqual(@as(u64, 1), listed[0].min_txid.value);
    try std.testing.expectEqual(@as(u64, 1), listed[0].max_txid.value);
    try std.testing.expectEqual(@as(u64, 2), listed[1].min_txid.value);
    try std.testing.expectEqual(@as(u64, 5), listed[1].max_txid.value);
}
