const std = @import("std");

pub const Limits = struct {
    max_input_bytes: u64,
    max_output_bytes: u64,
    max_pages: u32,
    max_page_size: u32,
    max_compressed_page_size: u32,
    max_page_index_bytes: u64,
    max_page_index_entries: u32,
    max_varint_bytes: u8,
    max_transaction_span: u64,

    pub fn validate(self: Limits) error{InvalidLimits}!void {
        if (self.max_input_bytes == 0) return error.InvalidLimits;
        if (self.max_output_bytes == 0) return error.InvalidLimits;
        if (self.max_pages == 0) return error.InvalidLimits;
        if (self.max_page_size < 512 or self.max_page_size > 65_536) {
            return error.InvalidLimits;
        }
        if (self.max_compressed_page_size == 0) return error.InvalidLimits;
        if (self.max_page_index_bytes < 9) return error.InvalidLimits;
        if (self.max_page_index_entries == 0) return error.InvalidLimits;
        if (self.max_varint_bytes == 0 or self.max_varint_bytes > 10) {
            return error.InvalidLimits;
        }
        if (self.max_transaction_span == 0) return error.InvalidLimits;
    }
};

test "limits reject configurations that cannot bound work" {
    var limits = Limits{
        .max_input_bytes = 1,
        .max_output_bytes = 1,
        .max_pages = 1,
        .max_page_size = 512,
        .max_compressed_page_size = 515,
        .max_page_index_bytes = 9,
        .max_page_index_entries = 1,
        .max_varint_bytes = 10,
        .max_transaction_span = 1,
    };
    try limits.validate();
    limits.max_varint_bytes = 11;
    try std.testing.expectError(error.InvalidLimits, limits.validate());
}
