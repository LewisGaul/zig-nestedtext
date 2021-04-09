const std = @import("std");
const json = std.json;
const testing = std.testing;

const nestedtext = @import("nestedtext.zig");

const Allocator = std.mem.Allocator;

const testcases_path = "nestedtext_tests/test_cases/";

const max_file_size: usize = 1024 * 1024;

/// Memory owned by the caller.
fn canonicalise_json(allocator: *Allocator, json_input: []const u8) ![]const u8 {
    var json_tree = try json.Parser.init(allocator, false).parse(json_input);
    defer json_tree.deinit();
    var buffer = std.ArrayList(u8).init(allocator);
    errdefer buffer.deinit();
    try json_tree.root.jsonStringify(.{}, buffer.writer());
    return buffer.items;
}

fn test_parse(input_nt: []const u8, expected_json: []const u8) !void {
        var nt_tree = try nestedtext.Parser.init(testing.allocator, .{}).parse(input_nt);
        defer nt_tree.deinit();
        var json_tree = try nt_tree.root.toJson(testing.allocator);
        defer json_tree.deinit();

        var buffer = std.ArrayList(u8).init(testing.allocator);
        defer buffer.deinit();
        try json_tree.root.jsonStringify(.{}, buffer.writer());

        testing.expectEqualStrings(expected_json, buffer.items);
}

fn test_dump(input_json: []const u8, expected_nt: []const u8) !void {
        var json_parser = json.Parser.init(testing.allocator, false);
        defer json_parser.deinit();
        var json_tree = try json_parser.parse(input_json);
        defer json_tree.deinit();
        var nt_tree = try nestedtext.fromJson(testing.allocator, json_tree.root);
        defer nt_tree.deinit();

        var buffer = std.ArrayList(u8).init(testing.allocator);
        defer buffer.deinit();
        try nt_tree.root.stringify(.{}, buffer.writer());

        testing.expectEqualStrings(expected_nt, buffer.items);
}

fn test_single(allocator: *Allocator, dir: std.fs.Dir) !void {
    const load_in: ?[]const u8 = dir.readFileAlloc(
        allocator,
        "load_in.nt",
        max_file_size,
    ) catch |e| switch (e) {
        error.FileNotFound => null,
        else => return e,
    };
    if (load_in) |input| {
        // TODO: Currently assuming the parsing is supposed to succeed.
        const load_out: []const u8 = try dir.readFileAlloc(
            allocator,
            "load_out.json",
            max_file_size,
        );
        const expected = try canonicalise_json(allocator, load_out);
        try test_parse(input, expected);
    }

    // TODO: Not working because of unordered JSON parsing in std.
    // const dump_in: ?[]const u8 = dir.readFileAlloc(
    //     allocator,
    //     "dump_in.json",
    //     max_file_size,
    // ) catch |e| switch (e) {
    //     error.FileNotFound => null,
    //     else => return e,
    // };
    // if (dump_in) |input| {
    //     const dump_out: []const u8 = try dir.readFileAlloc(
    //         allocator,
    //         "dump_out.nt",
    //         max_file_size,
    //     );
    //     const expected = std.mem.trimRight(u8, dump_out, "\r\n");
    //     try test_dump(input, expected);
    // }
}

fn test_all(base_dir: std.fs.Dir) !void {
    std.debug.print("\n", .{});
    for ([_][]const u8{"dict_01"}) |subdir| {  // TODO: Iterate over all tests
        var dir = try base_dir.openDir(subdir, .{});
        defer dir.close();
        std.debug.print("Running testcase: {s}\n", .{subdir});
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        try test_single(&arena.allocator, dir);
    }
}

test "All testcases" {
    var testcases_dir = try std.fs.cwd().openDir(testcases_path, .{ .iterate = true });
    defer testcases_dir.close();
    try test_all(testcases_dir);
}
