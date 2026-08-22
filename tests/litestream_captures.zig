const capture_root = "fixtures/celld_litestream_v0511/replica/ltx/0/";

pub const tx1 = @embedFile(capture_root ++ "0000000000000001-0000000000000001.ltx");
pub const tx2 = @embedFile(capture_root ++ "0000000000000002-0000000000000002.ltx");
pub const tx3 = @embedFile(capture_root ++ "0000000000000003-0000000000000003.ltx");
pub const tx4 = @embedFile(capture_root ++ "0000000000000004-0000000000000004.ltx");

pub const compaction_inputs = [_][]const u8{ tx1, tx2, tx3, tx4 };
