const std = @import("std");
const ltx = @import("ltx");
const ltx_capture = @import("ltx_capture");
const ltx_object = @import("ltx_object");
const ltx_replica = @import("ltx_replica");
const ltx_replication = @import("ltx_replication");
const ltx_resources = @import("ltx_resources");
const ltx_s3 = @import("ltx_s3");
const ltx_sqlite = @import("ltx_sqlite");
const ltx_wal = @import("ltx_wal");

test "external path dependency exposes the current public modules" {
    try ltx.FormatVersion.v3.validate();
    try std.testing.expect(ltx.header_size != 0);
    try std.testing.expect(ltx_sqlite.database_a_name.len != 0);

    try (ltx_wal.Limits{
        .max_page_size = 4096,
        .max_pages = 1,
        .max_frames = 1,
    }).validate();
    try std.testing.expect(ltx_wal.header_size_bytes != 0);

    try std.testing.expect(ltx_object.Error.ConformanceFailure != error.StorageFailure);
    _ = ltx_object.FileClient;

    try std.testing.expect(ltx.file_name_bytes != 0);
    _ = ltx_s3.S3Client;

    try std.testing.expect(ltx_replica.default_levels[0].interval_ms == 0);
    try std.testing.expect(ltx_replica.default_levels.len == 4);

    try std.testing.expect(ltx_capture.Error.CaptureUnchanged != error.StorageFailure);
    _ = ltx_replication.Controller;

    var storage: [32]u8 align(8) = undefined;
    var cursor = ltx_resources.ArenaCursor.init(&storage);
    const words = try cursor.bind_slice(u64, 2);
    try std.testing.expectEqual(@as(usize, 2), words.len);
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(words.ptr) % @alignOf(u64));
}
