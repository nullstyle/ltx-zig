const std = @import("std");
const cases = @import("valid_chain_cases");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2 and args.len != 3) return error.InvalidArguments;

    const kind = try parse_case(args[1]);
    var chain: cases.BuiltChain = undefined;
    try cases.build(kind, &chain);
    if (args.len == 3) {
        const input_index = std.fmt.parseUnsigned(usize, args[2], 10) catch
            return error.InvalidArguments;
        if (input_index >= chain.input_count) return error.InvalidArguments;
        return write_stdout(init, chain.inputs[input_index].slice());
    }
    var compacted: cases.Compacted = .{};
    try cases.compact(&chain, &compacted);
    try write_stdout(init, compacted.slice());
}

fn write_stdout(init: std.process.Init, bytes: []const u8) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    try stdout_file_writer.interface.writeAll(bytes);
    try stdout_file_writer.interface.flush();
}

fn parse_case(argument: []const u8) !cases.CaseKind {
    for (cases.all) |kind| {
        if (std.mem.eql(u8, argument, cases.name(kind))) return kind;
    }
    return error.InvalidArguments;
}
