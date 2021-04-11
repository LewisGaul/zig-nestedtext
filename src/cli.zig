const std = @import("std");
const json = std.json;

const clap = @import("clap");

const nestedtext = @import("nestedtext.zig");

const WriteError = std.os.WriteError;
const File = std.fs.File;

const allocator = std.heap.page_allocator;

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
        clap.parseParam("-F, --informat <PATH>   Input format (defaults to 'nt')") catch unreachable,
        clap.parseParam("-O, --outformat <PATH>  Output format (defaults to 'json')") catch unreachable,
    };

    // Initalize diagnostics for reporting parsing errors.
    var diag: clap.Diagnostic = undefined;
    var clap_args = clap.parse(clap.Help, &params, allocator, &diag) catch |err| {
        diag.report(stderr, err) catch {};
        return err;
    };
    defer clap_args.deinit();

    if (clap_args.flag("--help")) {
        try stderr.print("{s} ", .{clap_args.exe_arg});
        try clap.usage(stderr, &params);
        try stderr.writeByte('\n');
        try clap.help(stderr, &params);
        std.process.exit(0);
    }

    var args = Args{ .input_file = undefined, .output_file = undefined };

    if (clap_args.option("--informat")) |fmt| {
        args.input_format = parseFormat(fmt) catch |err| {
            try stderr.print(
                "Unrecognised input format '{s}', should be one of 'json' or 'nt'\n",
                .{fmt},
            );
            return err;
        };
    }

    if (clap_args.option("--outformat")) |fmt| {
        args.output_format = parseFormat(fmt) catch |err| {
            try stderr.print(
                "Unrecognised output format '{s}', should be one of 'json' or 'nt'\n",
                .{fmt},
            );
            return err;
        };
    }

    if (clap_args.option("--infile")) |infile| {
        args.input_file = std.fs.cwd().openFile(infile, .{}) catch |err| {
            try stderr.print("Failed to open file {s}\n", .{infile});
            return err;
        };
    } else {
        args.input_file = std.io.getStdIn();
    }

    if (clap_args.option("--outfile")) |outfile| {
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

    const args = parseArgs() catch |err| switch (err) {
        error.InvalidArgument,
        error.MissingValue,
        error.DoesntTakeValue,
        error.UnrecognisedFormat,
        => return 2,
        else => return 1,
    };

    const max_size = 1024 * 1024 * 1024; // 1GB
    const input = args.input_file.readToEndAlloc(
        std.heap.page_allocator,
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

    switch (args.input_format) {
        .NestedText => {
            var parser = nestedtext.Parser.init(
                std.heap.page_allocator,
                .{ .copy_strings = false },
            );
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
            defer tree.deinit();

            switch (args.output_format) {
                .Json => {
                    var json_tree = tree.root.toJson(std.heap.page_allocator) catch {
                        try stderr.writeAll("Failed to convert NestedText to JSON\n");
                        return 1;
                    };
                    defer json_tree.deinit();
                    try json_tree.root.jsonStringify(.{}, args.output_file.writer());
                },
                .NestedText => {
                    try tree.root.stringify(.{}, args.output_file.writer());
                },
            }
        },
        .Json => {
            var parser = json.Parser.init(std.heap.page_allocator, false);
            defer parser.deinit();
            var tree = parser.parse(input) catch {
                try stderr.writeAll("Failed to parse input as JSON\n");
                return 1;
            };
            defer tree.deinit();

            switch (args.output_format) {
                .Json => {
                    try tree.root.jsonStringify(.{}, args.output_file.writer());
                },
                .NestedText => {
                    var nt_tree = nestedtext.fromJson(std.heap.page_allocator, tree.root) catch {
                        try stderr.writeAll("Failed to convert JSON to NestedText\n");
                        return 1;
                    };
                    defer nt_tree.deinit();
                    try nt_tree.root.stringify(.{}, args.output_file.writer());
                },
            }
        },
    }

    return 0;
}

pub fn main() u8 {
    return mainWorker() catch 1;
}
