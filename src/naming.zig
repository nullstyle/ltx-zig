//! LTX object naming shared by every replication layer.
//!
//! Ported from the pinned `denoland/celld` LTX crate: `parse_txid` and the
//! filename codec follow Go's `ltx.ParseTXID` and `ltx.ParseFileName`
//! semantics, and the level-directory layouts match Litestream's filesystem
//! replica (`ltx/<decimal-level>/`) and object-store replica
//! (`<four-hex-digit-level>/`) byte for byte.

const std = @import("std");
const format = @import("format.zig");

const TXID = format.TXID;

pub const Error = error{
    InvalidTXIDText,
    InvalidFileName,
    InvalidLevel,
    PathTooLong,
};

pub const file_extension = ".ltx";
pub const txid_text_bytes = 16;
pub const file_name_bytes = txid_text_bytes + 1 + txid_text_bytes + file_extension.len;
/// The level holding complete database snapshots; not a compaction level.
pub const snapshot_level: u8 = 9;
/// The highest valid level index.
pub const max_level: u8 = snapshot_level;
pub const ltx_directory_name = "ltx";

const hex_digits = "0123456789abcdef";

/// Formats a TXID as its canonical 16-character zero-padded lowercase hex.
pub fn format_txid(value: TXID, destination: *[txid_text_bytes]u8) *const [txid_text_bytes]u8 {
    var remaining = value.value;
    var index: usize = txid_text_bytes;
    while (index > 0) {
        index -= 1;
        destination[index] = hex_digits[@intCast(remaining & 0xf)];
        remaining >>= 4;
    }
    return destination;
}

/// Parses the canonical 16-character hex TXID. Exactly sixteen hex digits are
/// accepted, in either letter case, matching Go `strconv.ParseUint` with base
/// sixteen; sign prefixes and other lengths are rejected.
pub fn parse_txid(text: []const u8) Error!TXID {
    if (text.len != txid_text_bytes) return error.InvalidTXIDText;
    var value: u64 = 0;
    for (text) |byte| {
        const digit = hex_digit(byte) orelse return error.InvalidTXIDText;
        value = (value << 4) | digit;
    }
    return TXID.init(value);
}

pub const FileIdentity = struct {
    min_txid: TXID,
    max_txid: TXID,
};

/// Formats the canonical object file name `<min:016x>-<max:016x>.ltx`.
pub fn format_file_name(
    min_txid: TXID,
    max_txid: TXID,
    destination: *[file_name_bytes]u8,
) *const [file_name_bytes]u8 {
    _ = format_txid(min_txid, destination[0..txid_text_bytes]);
    destination[txid_text_bytes] = '-';
    _ = format_txid(max_txid, destination[txid_text_bytes + 1 ..][0..txid_text_bytes]);
    @memcpy(
        destination[2 * txid_text_bytes + 1 ..][0..file_extension.len],
        file_extension,
    );
    return destination;
}

/// Parses a canonical object file name. The exact 37-byte layout is required;
/// hexadecimal letters may use either case, matching Go.
pub fn parse_file_name(name: []const u8) Error!FileIdentity {
    if (name.len != file_name_bytes) return error.InvalidFileName;
    if (name[txid_text_bytes] != '-') return error.InvalidFileName;
    if (!std.mem.eql(
        u8,
        name[2 * txid_text_bytes + 1 ..][0..file_extension.len],
        file_extension,
    )) return error.InvalidFileName;
    return .{
        .min_txid = parse_txid(name[0..txid_text_bytes]) catch
            return error.InvalidFileName,
        .max_txid = parse_txid(name[txid_text_bytes + 1 ..][0..txid_text_bytes]) catch
            return error.InvalidFileName,
    };
}

/// One listed replication object. The level and TXID range come from the
/// storage layout; `created_at_ms` is the object's creation timestamp in Unix
/// milliseconds when the backend reports one (object metadata or file mtime),
/// and `null` otherwise. It only tie-breaks restore candidate selection.
pub const FileInfo = struct {
    level: u8,
    min_txid: TXID,
    max_txid: TXID,
    created_at_ms: ?i64 = null,
};

/// Formats the decimal level-directory name used by filesystem replicas.
pub fn format_filesystem_level_name(
    level: u8,
    destination: *[1]u8,
) Error!*const [1]u8 {
    if (level > max_level) return error.InvalidLevel;
    destination[0] = '0' + level;
    return destination;
}

/// Formats the four-hex-digit level prefix used by object-store replicas.
pub fn format_object_level_name(
    level: u8,
    destination: *[4]u8,
) Error!*const [4]u8 {
    if (level > max_level) return error.InvalidLevel;
    var value: u32 = level;
    var index: usize = destination.len;
    while (index > 0) {
        index -= 1;
        destination[index] = hex_digits[@intCast(value & 0xf)];
        value >>= 4;
    }
    return destination;
}

/// Builds `<root>/ltx/<level>/<min>-<max>.ltx` with the decimal filesystem
/// layout. `root` must already be a clean relative path under the caller's
/// directory handle; no path cleaning is applied.
pub fn format_file_path(
    root: []const u8,
    level: u8,
    identity: FileIdentity,
    destination: []u8,
) Error![]const u8 {
    if (level > max_level) return error.InvalidLevel;
    var offset = root.len;
    if (offset > destination.len) return error.PathTooLong;
    @memcpy(destination[0..offset], root);
    try append_separator(destination, &offset);
    try append_bytes(destination, &offset, ltx_directory_name);
    try append_separator(destination, &offset);
    var level_name: [1]u8 = undefined;
    try append_bytes(
        destination,
        &offset,
        try format_filesystem_level_name(level, &level_name),
    );
    try append_separator(destination, &offset);
    var file_name: [file_name_bytes]u8 = undefined;
    _ = format_file_name(identity.min_txid, identity.max_txid, &file_name);
    try append_bytes(destination, &offset, &file_name);
    return destination[0..offset];
}

/// Appends a path separator only between components: never leading, so an
/// empty root keeps the result a valid relative subpath.
fn append_separator(destination: []u8, offset: *usize) Error!void {
    if (offset.* == 0) return;
    try append_bytes(destination, offset, "/");
}

fn append_bytes(destination: []u8, offset: *usize, bytes: []const u8) Error!void {
    const end = std.math.add(usize, offset.*, bytes.len) catch
        return error.PathTooLong;
    if (end > destination.len) return error.PathTooLong;
    @memcpy(destination[offset.*..end], bytes);
    offset.* = end;
}

fn hex_digit(byte: u8) ?u4 {
    return switch (byte) {
        '0'...'9' => @intCast(byte - '0'),
        'a'...'f' => @intCast(byte - 'a' + 10),
        'A'...'F' => @intCast(byte - 'A' + 10),
        else => null,
    };
}

test "txid text round-trips with the Go known answers" {
    var buffer: [txid_text_bytes]u8 = undefined;
    try std.testing.expectEqualStrings(
        "0000000000000001",
        format_txid(TXID.init(1), &buffer),
    );
    try std.testing.expectEqualStrings(
        "ffffffffffffffff",
        format_txid(TXID.init(std.math.maxInt(u64)), &buffer),
    );
    try std.testing.expectEqual(TXID.init(1), try parse_txid("0000000000000001"));
    try std.testing.expectEqual(TXID.init(0xdead_beef), try parse_txid("00000000DEADBEEF"));
    try std.testing.expectError(error.InvalidTXIDText, parse_txid("1"));
    try std.testing.expectError(error.InvalidTXIDText, parse_txid("0000000000000001 "));
    try std.testing.expectError(error.InvalidTXIDText, parse_txid("+000000000000001"));
    try std.testing.expectError(error.InvalidTXIDText, parse_txid("000000000000000g"));
}

test "file names round-trip and reject malformed shapes" {
    var name: [file_name_bytes]u8 = undefined;
    try std.testing.expectEqualStrings(
        "0000000000000001-0000000000000003.ltx",
        format_file_name(TXID.init(1), TXID.init(3), &name),
    );
    const identity = try parse_file_name("0000000000000001-0000000000000003.ltx");
    try std.testing.expectEqual(@as(u64, 1), identity.min_txid.value);
    try std.testing.expectEqual(@as(u64, 3), identity.max_txid.value);
    // Upper-case hex digits parse, matching Go; the extension stays lowercase.
    const upper = try parse_file_name("000000000000000A-000000000000000f.ltx");
    try std.testing.expectEqual(@as(u64, 10), upper.min_txid.value);
    try std.testing.expectEqual(@as(u64, 15), upper.max_txid.value);
    try std.testing.expectError(error.InvalidFileName, parse_file_name(""));
    try std.testing.expectError(
        error.InvalidFileName,
        parse_file_name("0000000000000001-0000000000000003.txt"),
    );
    try std.testing.expectError(
        error.InvalidFileName,
        parse_file_name("0000000000000001X0000000000000003.ltx"),
    );
    try std.testing.expectError(
        error.InvalidFileName,
        parse_file_name("000000000000000g-0000000000000003.ltx"),
    );
}

test "level names match the two replica layouts" {
    var filesystem_name: [1]u8 = undefined;
    var object_name: [4]u8 = undefined;
    try std.testing.expectEqualStrings("0", try format_filesystem_level_name(0, &filesystem_name));
    try std.testing.expectEqualStrings("9", try format_filesystem_level_name(9, &filesystem_name));
    try std.testing.expectEqualStrings("0000", try format_object_level_name(0, &object_name));
    try std.testing.expectEqualStrings("0009", try format_object_level_name(9, &object_name));
    try std.testing.expectError(error.InvalidLevel, format_filesystem_level_name(10, &filesystem_name));
    try std.testing.expectError(error.InvalidLevel, format_object_level_name(10, &object_name));
}

test "file paths join the litestream filesystem layout exactly" {
    var path: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        "replica/ltx/0/0000000000000001-0000000000000003.ltx",
        try format_file_path(
            "replica",
            0,
            .{ .min_txid = TXID.init(1), .max_txid = TXID.init(3) },
            &path,
        ),
    );
    try std.testing.expectEqualStrings(
        "replica/ltx/9/0000000000000005-0000000000000005.ltx",
        try format_file_path(
            "replica",
            9,
            .{ .min_txid = TXID.init(5), .max_txid = TXID.init(5) },
            &path,
        ),
    );
    try std.testing.expectError(
        error.PathTooLong,
        format_file_path(
            "replica",
            0,
            .{ .min_txid = TXID.init(1), .max_txid = TXID.init(3) },
            path[0..20],
        ),
    );
    try std.testing.expectError(
        error.InvalidLevel,
        format_file_path(
            "replica",
            10,
            .{ .min_txid = TXID.init(1), .max_txid = TXID.init(3) },
            &path,
        ),
    );
}
