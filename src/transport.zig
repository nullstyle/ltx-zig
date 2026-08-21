const std = @import("std");

pub const Reader = struct {
    context: *anyopaque,
    read_fn: *const fn (context: *anyopaque, destination: []u8) error{InputFailure}!usize,
    at_end_fn: *const fn (context: *anyopaque) error{InputFailure}!bool,
    backing_bytes: ?[]const u8 = null,

    pub fn read(self: Reader, destination: []u8) error{InputFailure}!usize {
        const count = try self.read_fn(self.context, destination);
        if (count > destination.len) return error.InputFailure;
        return count;
    }

    pub fn at_end(self: Reader) error{InputFailure}!bool {
        return self.at_end_fn(self.context);
    }
};

pub const Writer = struct {
    context: *anyopaque,
    write_all_fn: *const fn (context: *anyopaque, bytes: []const u8) error{OutputFailure}!void,
    backing_bytes: ?[]u8 = null,

    pub fn write_all(self: Writer, bytes: []const u8) error{OutputFailure}!void {
        try self.write_all_fn(self.context, bytes);
    }
};

pub const SliceReader = struct {
    bytes: []const u8,
    offset: usize = 0,

    pub fn init(bytes: []const u8) SliceReader {
        return .{ .bytes = bytes };
    }

    pub fn reader(self: *SliceReader) Reader {
        return .{
            .context = self,
            .read_fn = read,
            .at_end_fn = at_end,
            .backing_bytes = self.bytes,
        };
    }

    fn read(context: *anyopaque, destination: []u8) error{InputFailure}!usize {
        const self: *SliceReader = @ptrCast(@alignCast(context));
        const count = @min(destination.len, self.bytes.len - self.offset);
        @memcpy(destination[0..count], self.bytes[self.offset..][0..count]);
        self.offset += count;
        return count;
    }

    fn at_end(context: *anyopaque) error{InputFailure}!bool {
        const self: *SliceReader = @ptrCast(@alignCast(context));
        return self.offset == self.bytes.len;
    }
};

pub const SliceWriter = struct {
    buffer: []u8,
    offset: usize = 0,

    pub fn init(buffer: []u8) SliceWriter {
        return .{ .buffer = buffer };
    }

    pub fn writer(self: *SliceWriter) Writer {
        return .{
            .context = self,
            .write_all_fn = write_all,
            .backing_bytes = self.buffer,
        };
    }

    pub fn written(self: *const SliceWriter) []const u8 {
        return self.buffer[0..self.offset];
    }

    fn write_all(context: *anyopaque, bytes: []const u8) error{OutputFailure}!void {
        const self: *SliceWriter = @ptrCast(@alignCast(context));
        const end = std.math.add(usize, self.offset, bytes.len) catch {
            return error.OutputFailure;
        };
        if (end > self.buffer.len) return error.OutputFailure;
        @memcpy(self.buffer[self.offset..end], bytes);
        self.offset = end;
    }
};

test "slice transports preserve bytes" {
    var storage: [4]u8 = undefined;
    var sink = SliceWriter.init(&storage);
    try sink.writer().write_all("LTX1");
    try std.testing.expectEqualStrings("LTX1", sink.written());

    var source = SliceReader.init(sink.written());
    var read_buffer: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 4), try source.reader().read(&read_buffer));
    try std.testing.expectEqualStrings("LTX1", &read_buffer);
}

test "reader rejects an adapter that over-reports progress" {
    const InvalidReader = struct {
        fn read(_: *anyopaque, destination: []u8) error{InputFailure}!usize {
            return destination.len + 1;
        }

        fn at_end(_: *anyopaque) error{InputFailure}!bool {
            return false;
        }
    };
    var context: u8 = 0;
    const reader = Reader{
        .context = &context,
        .read_fn = InvalidReader.read,
        .at_end_fn = InvalidReader.at_end,
    };
    var byte: [1]u8 = undefined;
    try std.testing.expectError(error.InputFailure, reader.read(&byte));
}
