const std = @import("std");
const json = std.json;
const testing = std.testing;

const nestedtext = @import("nestedtext");

const Allocator = std.mem.Allocator;
const Dir = std.fs.Dir;

const testcases_path = "tests/official_tests/test_cases/";

const max_file_size: usize = 1024 * 1024;

const skipped_testcases = [_][]const u8{
    "dict_05", // Root-level leading whitespace (bug...)
    "dict_06", // Bug (whitespace object value?)
    "dict_07", // Bug (tab indentation)
    "dict_14", // Bug (handle duplicate keys)
    "dict_15", // Bug (tab indentation)
    "dict_16", // Bug (colon in key, empty value)
    "dict_17", // Key quoting - to be removed from spec
    "dict_18", // Whitespace in object key (bug...)
    "dict_19", // Bug (allow trailing whitespace after object keys)
    "dict_20", // Weird object keys (bug...)
    "dict_23", // Bug (allow trailing whitespace after object keys)
    "empty_1", // Bad testcase - empty file maps to null??
    "holistic_1", // Whitespace in object key (bug...)
    "holistic_4", // Whitespace in object key (bug...)
    "holistic_6", // Whitespace in object key (bug...)
    "holistic_7", // Bug (allow trailing whitespace after object keys)
    "list_5", // Root-level leading whitespace (bug...)
    "list_7", // Bug (tab indentation)
    "string_1", // Whitespace in object key (bug...)
    "string_9", // Whitespace in object key (bug...)
    "string_multiline_04", // Whitespace in object key (bug...)
    "string_multiline_07", // Root-level leading whitespace (bug...)
    "string_multiline_08", // Bug (tab indentation)
    "string_multiline_09", // Bug (tab indentation)
    "string_multiline_11", // Whitespace in object key (bug...)
};

const fail_fast = false;

const ParseErrorInfo = struct {
    lineno: usize,
    colno: ?usize,
    message: []const u8,
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
    std.debug.print("DEBUG: Checking for parsing success\n", .{});
    var p = nestedtext.Parser.init(testing.allocator, .{});
    var diags: nestedtext.Parser.Diags = undefined;
    p.diags = &diags;
    var nt_tree = p.parse(input_nt) catch |e| {
        std.debug.print(
            "ERROR: {s} (line {d})\n",
            .{ diags.ParseError.message, diags.ParseError.lineno },
        );
        return e;
    };
    defer nt_tree.deinit();
    var json_tree = try nt_tree.root.toJson(testing.allocator);
    defer json_tree.deinit();

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();
    try json_tree.root.jsonStringify(.{}, buffer.writer());

    testing.expectEqualStrings(expected_json, buffer.items);
}

fn testParseError(input_nt: []const u8, expected_error: ParseErrorInfo) !void {
    std.debug.print("DEBUG: Checking for parsing error\n", .{});
    var p = nestedtext.Parser.init(testing.allocator, .{});
    var diags: nestedtext.Parser.Diags = undefined;
    p.diags = &diags;
    // Hacky way to check whether the result was an error...
    if (p.parse(input_nt)) |tree| {
        tree.deinit();
        return error.UnexpectedParseSuccess;
    } else |_| {}
    std.debug.print("DEBUG: Got parse error: {s}\n", .{diags.ParseError.message});
    testing.expectEqual(expected_error.lineno, diags.ParseError.lineno);
    // TODO: Check message.
}

fn testDumpSuccess(input_json: []const u8, expected_nt: []const u8) !void {
    std.debug.print("DEBUG: Checking for dumping success\n", .{});
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
        "WARN: Skipping checking dumped output (std.json ignores JSON object order)\n",
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
            const json_parse_opts = json.ParseOptions{ .allocator = allocator };
            var stream = json.TokenStream.init(load_err);
            const err_json = try json.parse(ParseErrorInfo, &stream, json_parse_opts);
            defer json.parseFree(ParseErrorInfo, err_json, json_parse_opts);
            try testParseError(input, err_json);
        } else {
            std.debug.print("ERROR: Expected one of 'load_out.json' or 'load_err.json'\n", .{});
            return error.InvalidTestcase;
        }
        tested_something = true;
    }

    if (try readFileIfExists(dir, allocator, "dump_in.json")) |input| {
        if (try readFileIfExists(dir, allocator, "dump_out.nt")) |dump_out| {
            const expected = std.mem.trimRight(u8, dump_out, "\r\n");
            try testDumpSuccess(input, expected);
        } else if (try readFileIfExists(dir, allocator, "dump_err.json")) |load_err| {
            std.debug.print("WARN: Checking dump errors not yet implemented\n", .{});
        } else {
            std.debug.print("ERROR: Expected one of 'dump_out.nt' or 'dump_err.json'\n", .{});
            return error.InvalidTestcase;
        }
        tested_something = true;
    }

    if (!tested_something) {
        std.debug.print("WARN: Nothing found to test\n", .{});
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
            std.debug.print("INFO: Skipping testcase: {s}\n\n", .{entry.name});
            continue;
        }
        var dir = try base_dir.openDir(entry.name, .{});
        defer dir.close();
        std.debug.print("--- Running testcase: {s} ---\n", .{entry.name});
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        testSingle(&arena.allocator, dir) catch |e| {
            std.debug.print("--- Testcase failed: {} ---\n\n", .{e});
            num_failures += 1;
            if (fail_fast) return e else continue;
        };
        std.debug.print("--- Testcase passed ---\n\n", .{});
    }
    return num_failures;
}

test "All testcases" {
    var testcases_dir = try std.fs.cwd().openDir(testcases_path, .{ .iterate = true });
    defer testcases_dir.close();
    const failures = try testAll(testcases_dir);
    std.debug.print("\n", .{});
    if (failures == 0 and skipped_testcases.len == 0)
        std.debug.print("All testcases passed!\n", .{});
    if (skipped_testcases.len > 0)
        std.debug.print("{d} testcases skipped\n", .{skipped_testcases.len});
    if (failures > 0) {
        std.debug.print("{d} testcases failed\n", .{failures});
        testing.expect(false);
    }
}
