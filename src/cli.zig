const std = @import("std");

const clap = @import("clap");

const nestedtext = @import("nestedtext.zig");

const WriteError = std.os.WriteError;
const File = std.fs.File;

// -----------------------------------------------------------------------------
// Main
// -----------------------------------------------------------------------------

fn mainWorker() WriteError!u8 {
    var stderr = std.io.getStdErr().writer();

    // First we specify what parameters our program can take.
    // We can use 'parseParam()' to parse a string to a 'Param(Help)'.
    const params = comptime [_]clap.Param(clap.Help){
        clap.parseParam("-h, --help            Display this help and exit") catch unreachable,
        clap.parseParam("-f, --infile <PATH>   Input file (defaults to stdin)") catch unreachable,
        clap.parseParam("-o, --outfile <PATH>  Output file (defaults to stdout)") catch unreachable,
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

    var parser = nestedtext.Parser.init(std.heap.page_allocator, .{});
    const tree = parser.parse(input) catch {
        try stderr.writeAll("Failed to parse file as NestedText\n");
        return 1;
    };
    defer tree.deinit();
    var json_tree = tree.toJson(std.heap.page_allocator) catch {
        try stderr.writeAll("Failed to convert to JSON\n");
        return 1;
    };
    defer json_tree.deinit();
    try json_tree.root.jsonStringify(.{}, output_file.writer());

    return 0;
}

pub fn main() void {
    const rc = mainWorker() catch 1;
    std.process.exit(rc);
}
