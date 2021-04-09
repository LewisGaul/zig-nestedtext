const std = @import("std");
const json = std.json;
const testing = std.testing;

const nestedtext = @import("nestedtext.zig");

const Allocator = std.mem.Allocator;
const Dir = std.fs.Dir;

const testcases_path = "tests/official_tests/test_cases/";

const max_file_size: usize = 1024 * 1024;

const skipped_testcases = [_][]const u8{
    "empty_1", // Bad testcase - empty file maps to null??
    "string_9", // Bug?
};

/// Returned memory is owned by the caller.
fn canonicaliseJson(allocator: *Allocator, json_input: []const u8) ![]const u8 {
    var json_tree = try json.Parser.init(allocator, false).parse(json_input);
    defer json_tree.deinit();
    var buffer = std.ArrayList(u8).init(allocator);
    errdefer buffer.deinit();
    try json_tree.root.jsonStringify(.{}, buffer.writer());
    return buffer.items;
}

fn readFileIfExists(dir: Dir, allocator: *Allocator, file_path: []const u8) !?[]const u8 {
    return dir.readFileAlloc(allocator, file_path, max_file_size) catch |e| switch (e) {
        error.FileNotFound => null,
        else => return e,
    };
}

fn testParseSuccess(input_nt: []const u8, expected_json: []const u8) !void {
    var nt_tree = try nestedtext.Parser.init(testing.allocator, .{}).parse(input_nt);
    defer nt_tree.deinit();
    var json_tree = try nt_tree.root.toJson(testing.allocator);
    defer json_tree.deinit();

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();
    try json_tree.root.jsonStringify(.{}, buffer.writer());

    testing.expectEqualStrings(expected_json, buffer.items);
}

fn testDumpSuccess(input_json: []const u8, expected_nt: []const u8) !void {
    var json_parser = json.Parser.init(testing.allocator, false);
    defer json_parser.deinit();
    var json_tree = try json_parser.parse(input_json);
    defer json_tree.deinit();
    var nt_tree = try nestedtext.fromJson(testing.allocator, json_tree.root);
    defer nt_tree.deinit();

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();
    try nt_tree.root.stringify(.{}, buffer.writer());

    // TODO: Not working because of unordered JSON parsing in std.
    std.debug.print(
        "Warning: Not checking dumped output due to std.json order not being maintained\n",
        .{},
    );
    // testing.expectEqualStrings(expected_nt, buffer.items);
}

fn testSingle(allocator: *Allocator, dir: std.fs.Dir) !void {
    var tested_something = false;

    if (try readFileIfExists(dir, allocator, "load_in.nt")) |input| {
        if (try readFileIfExists(dir, allocator, "load_out.json")) |load_out| {
            const expected = try canonicaliseJson(allocator, load_out);
            try testParseSuccess(input, expected);
        } else if (try readFileIfExists(dir, allocator, "load_err.json")) |load_err| {
            std.debug.print("Warning: Checking parse errors not yet implemented\n", .{});
        } else {
            std.debug.print("Error: Expected one of 'load_out.json' or 'load_err.json'\n", .{});
            return error.InvalidTestcase;
        }
        tested_something = true;
    }

    if (try readFileIfExists(dir, allocator, "dump_in.json")) |input| {
        if (try readFileIfExists(dir, allocator, "dump_out.nt")) |dump_out| {
            const expected = std.mem.trimRight(u8, dump_out, "\r\n");
            try testDumpSuccess(input, expected);
        } else if (try readFileIfExists(dir, allocator, "dump_err.json")) |load_err| {
            std.debug.print("Warning: Checking dump errors not yet implemented\n", .{});
        } else {
            std.debug.print("Error: Expected one of 'dump_out.nt' or 'dump_err.json'\n", .{});
            return error.InvalidTestcase;
        }
        tested_something = true;
    }

    if (!tested_something) {
        std.debug.print("Error: Nothing found to test\n", .{});
        return error.InvalidTestcase;
    }
}

fn skipTestcase(name: []const u8) bool {
    for (skipped_testcases) |skip| {
        if (std.mem.eql(u8, name, skip)) return true;
    }
    return false;
}

/// Returns the number of testcases that failed.
fn testAll(base_dir: std.fs.Dir) !usize {
    var num_failures: usize = 0;
    std.debug.print("\n", .{});
    var iter = base_dir.iterate();
    while (try iter.next()) |*entry| {
        std.debug.assert(entry.kind == .Directory);
        if (skipTestcase(entry.name)) {
            std.debug.print("Skipping testcase: {s}\n", .{entry.name});
            num_failures += 1;
            continue;
        }
        var dir = try base_dir.openDir(entry.name, .{});
        defer dir.close();
        std.debug.print("Running testcase: {s}\n", .{entry.name});
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        testSingle(&arena.allocator, dir) catch |e| {
            std.debug.print("Testcase failure: {}\n", .{e});
            num_failures += 1;
        };
    }
    return num_failures;
}

test "All testcases" {
    var testcases_dir = try std.fs.cwd().openDir(testcases_path, .{ .iterate = true });
    defer testcases_dir.close();
    const failures = try testAll(testcases_dir);
    if (failures == 0) {
        std.debug.print("All tests passed!\n", .{});
    } else {
        std.debug.print("{d} tests failed\n", .{failures});
        testing.expect(false);
    }
}
