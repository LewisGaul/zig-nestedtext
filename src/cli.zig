const std = @import("std");

const clap = @import("clap");

const nestedtext = @import("nestedtext.zig");

const WriteError = std.os.WriteError;

// -----------------------------------------------------------------------------
// Main
// -----------------------------------------------------------------------------

fn mainWorker() WriteError!u8 {
    var stderr_stream = std.io.getStdErr().writer();

    // First we specify what parameters our program can take.
    // We can use 'parseParam()' to parse a string to a 'Param(Help)'.
    const params = comptime [_]clap.Param(clap.Help){
        clap.parseParam("-h, --help               Display this help and exit") catch unreachable,
        clap.parseParam("-f, --infile <PATH>      Input file (defaults to stdin)") catch unreachable,
        clap.parseParam("-o, --outfile <PATH>...  Output file (defaults to stdout)") catch unreachable,
    };

    // Initalize our diagnostics, which can be used for reporting useful errors.
    // This is optional. You can also just pass 'null' to 'parser.next' if you
    // don't care about the extra information 'Diagnostics' provides.
    var diag: clap.Diagnostic = undefined;

    var args = clap.parse(clap.Help, &params, std.heap.page_allocator, &diag) catch |err| {
        // Report useful error and exit
        diag.report(stderr_stream, err) catch {};
        return 2;
    };
    defer args.deinit();

    if (args.flag("--help")) {
        try stderr_stream.writeAll("nt-cli ");
        try clap.usage(stderr_stream, &params);
        try stderr_stream.writeByte('\n');
        try clap.help(stderr_stream, &params);
        return 0;
    }

    return 0;
}

pub fn main() void {
    const rc = mainWorker() catch 1;
    std.process.exit(rc);
}
