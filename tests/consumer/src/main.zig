const std = @import("std");
const ltx = @import("ltx");
const ltx_sqlite = @import("ltx_sqlite");

test "external path dependency exposes the current public modules" {
    try ltx.FormatVersion.v3.validate();
    try std.testing.expect(ltx.header_size != 0);
    try std.testing.expect(ltx_sqlite.database_a_name.len != 0);
}
