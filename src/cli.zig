const std = @import("std");

const clap = @import("clap");

const nestedtext = @import("nestedtext.zig");

// -----------------------------------------------------------------------------
// Main
// -----------------------------------------------------------------------------

pub fn main() void {
    std.debug.print("nestedtext: {}\n", .{nestedtext});
    std.debug.print("clap: {}\n", .{clap});
}
