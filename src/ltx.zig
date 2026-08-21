const checksum_impl = @import("checksum.zig");
const format = @import("format.zig");
const limits = @import("limits.zig");
const transport = @import("transport.zig");

pub const Error = format.Error;
pub const FormatVersion = format.FormatVersion;
pub const TXID = format.TXID;
pub const Checksum = format.Checksum;
pub const Position = format.Position;
pub const Header = format.Header;
pub const PageHeader = format.PageHeader;
pub const PageIndexEntry = format.PageIndexEntry;
pub const Trailer = format.Trailer;
pub const UnverifiedPage = format.UnverifiedPage;
pub const VerifiedLTX = format.VerifiedLTX;
pub const Limits = limits.Limits;
pub const Reader = transport.Reader;
pub const Writer = transport.Writer;
pub const SliceReader = transport.SliceReader;
pub const SliceWriter = transport.SliceWriter;
pub const Decoder = @import("decoder.zig").Decoder;
pub const DecoderState = @import("decoder.zig").DecoderState;
pub const DecoderEvent = @import("decoder.zig").DecoderEvent;
pub const Encoder = @import("encoder.zig").Encoder;
pub const EncoderState = @import("encoder.zig").EncoderState;

pub const checksum_page = checksum_impl.checksum_page;
pub const rolling_checksum_initial = checksum_impl.rolling_initial;
pub const rolling_checksum_add = checksum_impl.rolling_add;

pub const checksum_flag = format.checksum_flag;
pub const header_flag_no_checksum = format.header_flag_no_checksum;
pub const page_header_flag_size = format.page_header_flag_size;
pub const header_size = format.header_size;
pub const page_header_size = format.page_header_size;
pub const trailer_size = format.trailer_size;
pub const sqlite_pending_byte = format.sqlite_pending_byte;
pub const lock_page_number = format.lock_page_number;

test {
    _ = @import("format.zig");
    _ = @import("limits.zig");
    _ = @import("transport.zig");
    _ = @import("checksum.zig");
    _ = @import("lz4_block.zig");
    _ = @import("page_index.zig");
    _ = @import("decoder.zig");
    _ = @import("encoder.zig");
    _ = @import("workspace.zig");
}
