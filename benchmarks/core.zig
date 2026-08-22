const std = @import("std");
const ltx = @import("ltx");
const resource_model = @import("resource_model");
const workloads = @import("core/workloads.zig");

const default_iterations: u32 = 128;
const max_iterations: u32 = 10_000;
const warmup_limit: u32 = 8;
const sample_count: usize = 7;
const max_argument_count: usize = 6;
const max_argument_bytes: usize = 64;
/// Scratch for hosts whose argument iterator materializes an encoded command line.
const argument_iterator_bytes: usize = 4096;

const Filter = enum {
    all,
    encode,
    decode,
    compact,
    apply,

    fn includes(self: Filter, workload: workloads.Workload) bool {
        return self == .all or
            (self == .encode and workload.is_encode()) or
            (self == .decode and workload.is_decode()) or
            (self == .compact and workload.is_compact()) or
            (self == .apply and workload.is_apply());
    }
};

const Options = struct {
    filter: Filter = .all,
    iterations: u32 = default_iterations,
    smoke: bool = false,
    help: bool = false,
};

const ParseState = struct {
    options: Options = .{},
    filter_seen: bool = false,
    iterations_seen: bool = false,
    smoke_seen: bool = false,
};

const Samples = struct {
    nanoseconds_per_operation: [sample_count]u128,

    fn summary(self: Samples) Summary {
        var sorted = self.nanoseconds_per_operation;
        var index: usize = 1;
        while (index < sorted.len) : (index += 1) {
            const value = sorted[index];
            var insertion = index;
            while (insertion > 0 and sorted[insertion - 1] > value) : (insertion -= 1) {
                sorted[insertion] = sorted[insertion - 1];
            }
            sorted[insertion] = value;
        }
        return .{
            .minimum_ns = sorted[0],
            .median_ns = sorted[sorted.len / 2],
            .maximum_ns = sorted[sorted.len - 1],
        };
    }
};

const Summary = struct {
    minimum_ns: u128,
    median_ns: u128,
    maximum_ns: u128,
};

const DecimalRate = struct {
    whole: u128,
    hundredths: u128,
};

pub fn main(init: std.process.Init) !void {
    const options = parse_process_options(init.minimal.args) catch |err| {
        try write_usage(init.io, .stderr());
        return err;
    };
    if (options.help) {
        try write_usage(init.io, .stdout());
        return;
    }

    const harness = try init.gpa.create(workloads.Harness);
    defer init.gpa.destroy(harness);
    try harness.init();
    try validate_resource_model(harness);

    var output_buffer: [4096]u8 = undefined;
    var output_file: std.Io.File.Writer = .init(.stdout(), init.io, &output_buffer);
    const writer = &output_file.interface;
    try write_resource_summary(writer);
    try run_selected(init.io, writer, harness, options);
    try writer.flush();
}

fn parse_process_options(process_args: std.process.Args) !Options {
    var iterator_storage: [argument_iterator_bytes]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&iterator_storage);
    var iterator = process_args.iterateAllocator(fixed.allocator()) catch {
        return error.InvalidArguments;
    };
    defer iterator.deinit();

    var args: [max_argument_count][]const u8 = undefined;
    var count: usize = 0;
    for (&args) |*slot| {
        const argument = iterator.next() orelse break;
        if (count != 0 and (argument.len == 0 or argument.len > max_argument_bytes)) {
            return error.InvalidArguments;
        }
        slot.* = argument;
        count += 1;
    }
    if (iterator.skip()) return error.InvalidArguments;
    return parse_options(args[0..count]);
}

fn parse_options(args: []const []const u8) !Options {
    if (args.len == 0 or args.len > max_argument_count) return error.InvalidArguments;
    var state: ParseState = .{};
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const argument = args[index];
        if (argument.len == 0 or argument.len > max_argument_bytes) {
            return error.InvalidArguments;
        }
        if (std.mem.eql(u8, argument, "--help")) {
            if (args.len != 2) return error.InvalidArguments;
            state.options.help = true;
        } else if (std.mem.eql(u8, argument, "--smoke")) {
            if (state.smoke_seen) return error.DuplicateOption;
            state.smoke_seen = true;
            state.options.smoke = true;
        } else if (std.mem.startsWith(u8, argument, "--filter=")) {
            try set_filter(&state, argument["--filter=".len..]);
        } else if (std.mem.eql(u8, argument, "--filter")) {
            index += 1;
            if (index >= args.len) return error.OptionValueMissing;
            try set_filter(&state, args[index]);
        } else if (std.mem.startsWith(u8, argument, "--iterations=")) {
            try set_iterations(&state, argument["--iterations=".len..]);
        } else if (std.mem.eql(u8, argument, "--iterations")) {
            index += 1;
            if (index >= args.len) return error.OptionValueMissing;
            try set_iterations(&state, args[index]);
        } else {
            return error.UnknownOption;
        }
    }
    if (state.options.smoke and state.iterations_seen) return error.ConflictingOptions;
    if (state.options.smoke) state.options.iterations = 1;
    return state.options;
}

fn set_filter(state: *ParseState, value: []const u8) !void {
    if (state.filter_seen) return error.DuplicateOption;
    if (value.len == 0 or value.len > max_argument_bytes) return error.InvalidFilter;
    state.options.filter = if (std.mem.eql(u8, value, "all"))
        .all
    else if (std.mem.eql(u8, value, "encode"))
        .encode
    else if (std.mem.eql(u8, value, "decode"))
        .decode
    else if (std.mem.eql(u8, value, "compact"))
        .compact
    else if (std.mem.eql(u8, value, "apply"))
        .apply
    else
        return error.InvalidFilter;
    state.filter_seen = true;
}

fn set_iterations(state: *ParseState, value: []const u8) !void {
    if (state.iterations_seen) return error.DuplicateOption;
    if (value.len == 0 or value.len > 10) return error.InvalidIterations;
    const parsed = std.fmt.parseInt(u32, value, 10) catch return error.InvalidIterations;
    if (parsed == 0 or parsed > max_iterations) return error.InvalidIterations;
    state.options.iterations = parsed;
    state.iterations_seen = true;
}

fn run_selected(
    io: std.Io,
    writer: *std.Io.Writer,
    harness: *workloads.Harness,
    options: Options,
) !void {
    inline for (comptime std.meta.tags(workloads.Workload)) |workload| {
        if (options.filter.includes(workload)) {
            try run_case(workload, io, writer, harness, options);
        }
    }
}

fn run_case(
    comptime workload: workloads.Workload,
    io: std.Io,
    writer: *std.Io.Writer,
    harness: *workloads.Harness,
    options: Options,
) !void {
    const metrics = try harness.metrics(workload);
    try validate_workload_model(workload, metrics);
    if (options.smoke) {
        const outcome = try repeat_operation(workload, harness, 1);
        try harness.verify(workload, outcome);
        try write_smoke_result(writer, workload, metrics);
        return;
    }

    const warmup_iterations = @min(options.iterations, warmup_limit);
    const warmup = try repeat_operation(workload, harness, warmup_iterations);
    try harness.verify(workload, warmup);
    const samples = try collect_samples(workload, io, harness, options.iterations);
    try write_timing_result(writer, workload, metrics, samples.summary(), options.iterations);
}

fn collect_samples(
    comptime workload: workloads.Workload,
    io: std.Io,
    harness: *workloads.Harness,
    iterations: u32,
) !Samples {
    var result: Samples = undefined;
    var sample_index: usize = 0;
    while (sample_index < sample_count) : (sample_index += 1) {
        const started = std.Io.Clock.awake.now(io).nanoseconds;
        const outcome = try repeat_operation(workload, harness, iterations);
        const finished = std.Io.Clock.awake.now(io).nanoseconds;
        if (finished < started) return error.ClockMovedBackwards;
        const elapsed_ns: u128 = @intCast(finished - started);
        const per_operation = elapsed_ns / iterations;
        result.nanoseconds_per_operation[sample_index] = @max(per_operation, 1);
        try harness.verify(workload, outcome);
    }
    return result;
}

fn repeat_operation(
    comptime workload: workloads.Workload,
    harness: *workloads.Harness,
    iterations: u32,
) !workloads.Outcome {
    std.debug.assert(iterations > 0 and iterations <= max_iterations);
    var last: workloads.Outcome = undefined;
    var fingerprint: u64 = 0;
    var iteration: u32 = 0;
    while (iteration < iterations) : (iteration += 1) {
        last = try harness.run(workload);
        fingerprint +%= last.fingerprint ^ last.result_wire_bytes ^ iteration;
        std.mem.doNotOptimizeAway(last);
    }
    std.mem.doNotOptimizeAway(fingerprint);
    return last;
}

fn write_timing_result(
    writer: *std.Io.Writer,
    comptime workload: workloads.Workload,
    metrics: workloads.Metrics,
    summary: Summary,
    iterations: u32,
) !void {
    const logical_rate = try throughput_mib(metrics.logical_bytes, summary.median_ns);
    const wire_rate = try throughput_mib(metrics.wire_bytes, summary.median_ns);
    if (metrics.work_pages == 0) return error.InvalidPageCount;
    const median_ns_per_page = @max(summary.median_ns / metrics.work_pages, 1);
    try writer.print(
        "{s}: min/median/max={d}/{d}/{d} ns/op; median={d} ns/page; " ++
            "logical={d}.{d:0>2} MiB/s; wire={d}.{d:0>2} MiB/s; iterations={d}; ",
        .{
            workload.name(),
            summary.minimum_ns,
            summary.median_ns,
            summary.maximum_ns,
            median_ns_per_page,
            logical_rate.whole,
            logical_rate.hundredths,
            wire_rate.whole,
            wire_rate.hundredths,
            iterations,
        },
    );
    try write_metrics(writer, metrics);
}

fn write_smoke_result(
    writer: *std.Io.Writer,
    comptime workload: workloads.Workload,
    metrics: workloads.Metrics,
) !void {
    try writer.print("{s}: smoke ok; ", .{workload.name()});
    try write_metrics(writer, metrics);
}

fn write_metrics(writer: *std.Io.Writer, metrics: workloads.Metrics) !void {
    try writer.print(
        "logical/wire/result={d}/{d}/{d} bytes; " ++
            "work/events/pages/emitted={d}/{d}/{d}/{d}; " ++
            "callbacks stage/read/publish={d}/{d}/{d}\n",
        .{
            metrics.logical_bytes,
            metrics.wire_bytes,
            metrics.result_wire_bytes,
            metrics.work_pages,
            metrics.decoded_events,
            metrics.decoded_pages,
            metrics.emitted_pages,
            metrics.stage_callbacks,
            metrics.read_callbacks,
            metrics.publish_callbacks,
        },
    );
}

fn throughput_mib(bytes_per_operation: u64, nanoseconds_per_operation: u128) !DecimalRate {
    const scaled_bytes = std.math.mul(
        u128,
        bytes_per_operation,
        std.time.ns_per_s,
    ) catch return error.ThroughputOverflow;
    const numerator = std.math.mul(u128, scaled_bytes, 100) catch
        return error.ThroughputOverflow;
    const denominator = std.math.mul(
        u128,
        @max(nanoseconds_per_operation, 1),
        1024 * 1024,
    ) catch return error.ThroughputOverflow;
    const hundredths = numerator / denominator;
    return .{ .whole = hundredths / 100, .hundredths = hundredths % 100 };
}

fn validate_resource_model(harness: *const workloads.Harness) !void {
    try ltx.FormatVersion.v3.validate();
    const decoder_bytes = try resource_model.decoder_workspace_bytes(workloads.codec_limits);
    const encoder_bytes = try resource_model.encoder_workspace_bytes(workloads.codec_limits);
    const compact_bytes = try resource_model.compactor_workspace_bytes(
        workloads.codec_limits,
        workloads.max_inputs,
    );
    const apply_bytes = try resource_model.staged_apply_workspace_bytes(workloads.codec_limits);
    if (decoder_bytes == 0 or encoder_bytes == 0 or compact_bytes == 0 or apply_bytes == 0) {
        return error.InvalidResourceModel;
    }
    inline for (comptime std.meta.tags(workloads.Workload)) |workload| {
        try validate_workload_model(workload, try harness.metrics(workload));
    }
}

fn validate_workload_model(
    comptime workload: workloads.Workload,
    metrics: workloads.Metrics,
) !void {
    const wire_bound = try resource_model.configured_wire_bound_bytes(
        workloads.codec_limits,
        @intCast(metrics.emitted_pages),
    );
    if (metrics.result_wire_bytes > wire_bound) return error.WireBoundExceeded;
    const total_event_budget = std.math.mul(
        u64,
        try resource_model.decoder_event_budget(workloads.codec_limits),
        workload.decoder_count(),
    ) catch return error.EventBudgetOverflow;
    if (metrics.decoded_events > total_event_budget) {
        return error.EventBudgetExceeded;
    }
    if (workload == .apply_checked or workload == .apply_no_checksum) {
        const expected_reads = try resource_model.apply_read_callback_count(
            workload == .apply_checked,
            @intCast(metrics.emitted_pages),
            workloads.small_page_size_bytes,
        );
        if (metrics.read_callbacks != expected_reads) return error.ApplyReadModelMismatch;
    }
}

fn write_resource_summary(writer: *std.Io.Writer) !void {
    const decoder = try resource_model.decoder_workspace_bytes(workloads.codec_limits);
    const encoder = try resource_model.encoder_workspace_bytes(workloads.codec_limits);
    const compactor = try resource_model.compactor_workspace_bytes(
        workloads.codec_limits,
        workloads.max_inputs,
    );
    const apply = try resource_model.staged_apply_workspace_bytes(workloads.codec_limits);
    const wire_bound = try resource_model.configured_wire_bound_bytes(
        workloads.codec_limits,
        workloads.max_pages,
    );
    try writer.print(
        "configured workspace bytes decoder/encoder/compactor({d})/apply={d}/{d}/{d}/{d}; " ++
            "wire bound={d}\n",
        .{ workloads.max_inputs, decoder, encoder, compactor, apply, wire_bound },
    );
}

fn write_usage(io: std.Io, file: std.Io.File) !void {
    var buffer: [1024]u8 = undefined;
    var file_writer: std.Io.File.Writer = .init(file, io, &buffer);
    try file_writer.interface.print(
        "usage: ltx-core-benchmark [--filter all|encode|decode|compact|apply] " ++
            "[--iterations 1..{d}] [--smoke]\n" ++
            "       ltx-core-benchmark --help\n",
        .{max_iterations},
    );
    try file_writer.interface.flush();
}
