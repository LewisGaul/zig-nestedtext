const std = @import("std");
const json = std.json;

const clap = @import("clap");

const nestedtext = @import("nestedtext.zig");

const WriteError = std.os.WriteError;
const File = std.fs.File;

const Format = enum {
    NestedText,
    Json,
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

fn mainWorker() WriteError!u8 {
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

    // Initalize our diagnostics, which can be used for reporting useful errors.
    // This is optional. You can also just pass 'null' to 'parser.next' if you
    // don't care about the extra information 'Diagnostics' provides.
    var diag: clap.Diagnostic = undefined;

    var args = clap.parse(clap.Help, &params, std.heap.page_allocator, &diag) catch |err| {
        diag.report(stderr, err) catch {};
        return 2;
    };
    defer args.deinit();

    if (args.flag("--help")) {
        try stderr.writeAll("nt-cli ");
        try clap.usage(stderr, &params);
        try stderr.writeByte('\n');
        try clap.help(stderr, &params);
        return 0;
    }

    var input_format: Format = .NestedText;
    if (args.option("--informat")) |fmt| {
        input_format = parseFormat(fmt) catch {
            try stderr.print(
                "Unrecognised input format '{s}', should be one of 'json' or 'nt'\n",
                .{fmt},
            );
            return 1;
        };
    }

    var output_format: Format = .Json;
    if (args.option("--outformat")) |fmt| {
        output_format = parseFormat(fmt) catch {
            try stderr.print(
                "Unrecognised output format '{s}', should be one of 'json' or 'nt'\n",
                .{fmt},
            );
            return 1;
        };
    }

    var input_file: File = undefined;
    if (args.option("--infile")) |infile| {
        input_file = std.fs.cwd().openFile(infile, .{}) catch {
            try stderr.print("Failed to open file {s}\n", .{infile});
            return 1;
        };
    } else {
        input_file = std.io.getStdIn();
    }

    const max_size = 1024 * 1024 * 1024; // 1GB
    const input = input_file.readToEndAlloc(std.heap.page_allocator, max_size) catch |err| switch (err) {
        error.FileTooBig => {
            try stderr.print("Failed to read file, {s} - 1GB max\n", .{@errorName(err)});
            return 1;
        },
        else => {
            try stderr.print("Failed to read file, {s}\n", .{@errorName(err)});
            return 1;
        },
    };

    var output_file: File = undefined;
    if (args.option("--outfile")) |outfile| {
        output_file = std.fs.cwd().createFile(outfile, .{}) catch {
            try stderr.print("Failed to create file {s}\n", .{outfile});
            return 1;
        };
    } else {
        output_file = std.io.getStdOut();
    }

    switch (input_format) {
        .NestedText => {
            const parser = nestedtext.Parser.init(
                std.heap.page_allocator,
                .{ .copy_strings = false },
            );
            const tree = parser.parse(input) catch {
                try stderr.writeAll("Failed to parse file as NestedText\n");
                return 1;
            };
            defer tree.deinit();

            switch (output_format) {
                .Json => {
                    var json_tree = tree.root.toJson(std.heap.page_allocator) catch {
                        try stderr.writeAll("Failed to convert NestedText to JSON\n");
                        return 1;
                    };
                    defer json_tree.deinit();
                    try json_tree.root.jsonStringify(.{}, output_file.writer());
                },
                .NestedText => {
                    try tree.root.stringify(.{}, output_file.writer());
                },
            }
        },
        .Json => {
            var parser = json.Parser.init(std.heap.page_allocator, false);
            defer parser.deinit();
            var tree = parser.parse(input) catch {
                try stderr.writeAll("Failed to parse file as JSON\n");
                return 1;
            };
            defer tree.deinit();

            switch (output_format) {
                .Json => {
                    try tree.root.jsonStringify(.{}, output_file.writer());
                },
                .NestedText => {
                    var nt_tree = nestedtext.fromJson(std.heap.page_allocator, tree.root) catch {
                        try stderr.writeAll("Failed to convert JSON to NestedText\n");
                        return 1;
                    };
                    defer nt_tree.deinit();
                    try nt_tree.root.stringify(.{}, output_file.writer());
                },
            }
        },
    }

    return 0;
}

pub fn main() void {
    const rc = mainWorker() catch 1;
    std.process.exit(rc);
}
