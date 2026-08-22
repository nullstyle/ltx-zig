const std = @import("std");
const ltx = @import("ltx");
const ltx_sqlite = @import("ltx_sqlite");

test "external package exports ltx and ltx_sqlite" {
    const current: ltx_sqlite.Current = .{
        .position = ltx.Position{
            .txid = .init(7),
            .post_apply_checksum = .init(ltx.checksum_flag | 9),
        },
        .page_size = 4096,
        .database_size_bytes = 8192,
        .generation = 2,
        .slot = .a,
    };
    const access_storage: ltx_sqlite.GenerationAccessStorage = .{};
    const access_workspace: ltx_sqlite.GenerationAccessWorkspace = .{};
    const store_state: ltx_sqlite.StoreState = .idle;
    const store_failure: ltx_sqlite.Failure = .invalid_workspace;

    try std.testing.expectEqual(@as(u32, 100), ltx.header_size);
    try std.testing.expectEqual(@as(u64, 7), current.position.txid.value);
    try std.testing.expectEqualStrings(ltx_sqlite.database_a_name, current.database_name());
    try std.testing.expectEqual(@as(u64, 0), access_storage.epoch);
    try std.testing.expectEqual(ltx_sqlite.StoreState.idle, store_state);
    try std.testing.expectEqual(ltx_sqlite.Failure.invalid_workspace, store_failure);
    try std.testing.expectEqual(
        ltx_sqlite.max_generation_path_bytes,
        access_workspace.path_bytes.len,
    );
}
