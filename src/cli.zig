const std = @import("std");
const json = std.json;
const time = std.time;

const clap = @import("clap");

const nestedtext = @import("nestedtext.zig");

const WriteError = std.posix.WriteError;
const File = std.fs.File;
const Allocator = std.mem.Allocator;

var allocator: Allocator = undefined;

const logger = std.log.scoped(.cli);
// pub const log_level = std.log.Level.debug;

// Time that the program starts (milliseconds since epoch).
var start: i64 = undefined;

const Format = enum {
    NestedText,
    Json,
};

const Args = struct {
    input_file: File,
    output_file: File,
    input_format: Format = .NestedText,
    output_format: Format = .Json,
};

fn elapsed() i64 {
    return time.milliTimestamp() - start;
}

// -----------------------------------------------------------------------------
// Main
// -----------------------------------------------------------------------------

fn parseFormat(fmt: []const u8) !Format {
    if (std.mem.eql(u8, fmt, "nt") or std.mem.eql(u8, fmt, "nestedtext")) {
        return .NestedText;
    } else if (std.mem.eql(u8, fmt, "json")) {
        return .Json;
    } else {
        return error.UnrecognisedFormat;
    }
}

fn parseArgs() !Args {
    var stderr = std.io.getStdErr().writer();

    // First we specify what parameters our program can take.
    // We can use 'parseParam()' to parse a string to a 'Param(Help)'.
    const params = comptime [_]clap.Param(clap.Help){
        clap.parseParam("-h, --help              Display this help and exit") catch unreachable,
        clap.parseParam("-f, --infile <PATH>     Input file (defaults to stdin)") catch unreachable,
        clap.parseParam("-o, --outfile <PATH>    Output file (defaults to stdout)") catch unreachable,
        clap.parseParam("-F, --infmt <FMT>   Input format (defaults to 'nt')") catch unreachable,
        clap.parseParam("-O, --outfmt <FMT>  Output format (defaults to 'json')") catch unreachable,
    };

    // Initalize diagnostics for reporting parsing errors.
    var diag = clap.Diagnostic{};
    var clap_res = clap.parse(
        clap.Help,
        &params,
        .{ .PATH = clap.parsers.string, .FMT = clap.parsers.string },
        .{ .allocator = allocator, .diagnostic = &diag },
    ) catch |err| {
        diag.report(stderr, err) catch {};
        return err;
    };
    defer clap_res.deinit();

    if (clap_res.args.help != 0) {
        try stderr.print("{?s} ", .{clap_res.exe_arg});
        try clap.usage(stderr, clap.Help, &params);
        try stderr.writeByte('\n');
        try clap.help(
            stderr,
            clap.Help,
            &params,
            .{
                .markdown_lite = false,
                .indent = 2,
                .description_on_new_line = false,
                .description_indent = 0,
                .spacing_between_parameters = 0,
                .max_width = 80,
            },
        );
        std.process.exit(0);
    }

    var args = Args{ .input_file = undefined, .output_file = undefined };

    if (clap_res.args.infmt) |fmt| {
        args.input_format = parseFormat(fmt) catch |err| {
            try stderr.print(
                "Unrecognised input format '{s}', should be one of 'json' or 'nt'\n",
                .{fmt},
            );
            return err;
        };
    }

    if (clap_res.args.outfmt) |fmt| {
        args.output_format = parseFormat(fmt) catch |err| {
            try stderr.print(
                "Unrecognised output format '{s}', should be one of 'json' or 'nt'\n",
                .{fmt},
            );
            return err;
        };
    }

    if (clap_res.args.infile) |infile| {
        args.input_file = std.fs.cwd().openFile(infile, .{}) catch |err| {
            try stderr.print("Failed to open file {s}\n", .{infile});
            return err;
        };
    } else {
        args.input_file = std.io.getStdIn();
    }

    if (clap_res.args.outfile) |outfile| {
        args.output_file = std.fs.cwd().createFile(outfile, .{}) catch |err| {
            try stderr.print("Failed to create file {s}\n", .{outfile});
            return err;
        };
    } else {
        args.output_file = std.io.getStdOut();
    }

    return args;
}

fn mainWorker() WriteError!u8 {
    var stderr = std.io.getStdErr().writer();

    logger.debug("{d:6} Starting up", .{elapsed()});

    const args = parseArgs() catch |err| switch (err) {
        error.InvalidArgument,
        error.MissingValue,
        error.DoesntTakeValue,
        error.UnrecognisedFormat,
        => return 2,
        else => return 1,
    };
    logger.debug("{d:6} Parsed args", .{elapsed()});

    const max_size = 1024 * 1024 * 1024; // 1GB
    const input = args.input_file.readToEndAlloc(
        allocator,
        max_size,
    ) catch |err| switch (err) {
        error.FileTooBig => {
            try stderr.print("Failed to read input, {s} - 1GB max\n", .{@errorName(err)});
            return 1;
        },
        else => {
            try stderr.print("Failed to read input, {s}\n", .{@errorName(err)});
            return 1;
        },
    };
    logger.debug("{d:6} Finished reading input", .{elapsed()});

    var buffered_writer = std.io.bufferedWriter(args.output_file.writer());
    const out_stream = buffered_writer.writer();
    switch (args.input_format) {
        .NestedText => {
            var parser = nestedtext.Parser.init(allocator, .{ .copy_strings = false });
            var diags: nestedtext.Parser.Diags = undefined;
            parser.diags = &diags;
            const tree = parser.parse(input) catch |err| {
                if (diags == nestedtext.Parser.Diags.ParseError) {
                    try stderr.print(
                        "Failed to parse input as NestedText: {s} (line {d})\n",
                        .{ diags.ParseError.message, diags.ParseError.lineno },
                    );
                } else {
                    try stderr.print(
                        "Failed to parse input NestedText: {s}\n",
                        .{@errorName(err)},
                    );
                }
                return 1;
            };
            if (tree.root == null) {
                try stderr.print("An empty file is not valid NestedText\n", .{});
                return 1;
            }
            logger.debug("{d:6} Parsed NestedText", .{elapsed()});

            switch (args.output_format) {
                .Json => {
                    const json_tree = tree.root.?.toJsonLeaky(allocator) catch {
                        try stderr.writeAll("Failed to convert NestedText to JSON\n");
                        return 1;
                    };
                    logger.debug("{d:6} Converted to JSON", .{elapsed()});
                    try json.stringify(json_tree, .{}, out_stream);
                    logger.debug("{d:6} Stringified JSON", .{elapsed()});
                },
                .NestedText => {
                    try tree.root.?.stringify(.{}, out_stream);
                    logger.debug("{d:6} Stringified NestedText", .{elapsed()});
                },
            }
        },
        .Json => {
            const tree = json.parseFromSliceLeaky(json.Value, allocator, input, .{}) catch {
                try stderr.writeAll("Failed to parse input as JSON\n");
                return 1;
            };
            logger.debug("{d:6} Parsed JSON", .{elapsed()});

            switch (args.output_format) {
                .Json => {
                    try json.stringify(tree, .{}, out_stream);
                    logger.debug("{d:6} Stringified JSON", .{elapsed()});
                },
                .NestedText => {
                    var nt_tree = nestedtext.fromJson(allocator, tree) catch {
                        try stderr.writeAll("Failed to convert JSON to NestedText\n");
                        return 1;
                    };
                    logger.debug("{d:6} Converted to NestedText", .{elapsed()});
                    try nt_tree.root.?.stringify(.{}, out_stream);
                    logger.debug("{d:6} Stringified NestedText", .{elapsed()});
                },
            }
        },
    }
    try buffered_writer.flush();

    return 0;
}

pub fn main() u8 {
    start = time.milliTimestamp();
    // Use an arena allocator - no need to free memory as we go.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    allocator = arena.allocator();
    const rc = mainWorker() catch 1;
    logger.debug("{d:6} Exiting with: {d}", .{ elapsed(), rc });
    return rc;
}
