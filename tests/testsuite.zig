const std = @import("std");
const json = std.json;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Dir = std.fs.Dir;
const print = std.debug.print;

const nestedtext = @import("nestedtext");

const logger = std.log.scoped(.testsuite);

const testcases_path = "tests/official_tests/test_cases/";

const max_file_size: usize = 1024 * 1024;

const skipped_testcases = [_][]const u8{
    "dict_21", // Unrepresentable
    "dict_22", // Unrepresentable
    // TODO: Testcase for different line endings in same file (error lineno)
    // TODO: Testcase for multiline key without following value (error lineno)
    // TODO: Testcase for bad object keys ('-', '>', ':', '[', '{')
};

const fail_fast = true;

const ParseErrorInfo = struct {
    lineno: usize,
    colno: ?usize,
    message: []const u8,
};

// Modified std.testing functions
// -----------------------------------------------------------------------------

/// Slightly modified from std.testing to return error instead of panic.
fn expectEqualStrings(expected: []const u8, actual: []const u8) !void {
    if (std.mem.indexOfDiff(u8, actual, expected)) |diff_index| {
        print("\n====== expected this output: =========\n", .{});
        printWithVisibleNewlines(expected);
        print("\n======== instead found this: =========\n", .{});
        printWithVisibleNewlines(actual);
        print("\n======================================\n", .{});

        var diff_line_number: usize = 1;
        for (expected[0..diff_index]) |value| {
            if (value == '\n') diff_line_number += 1;
        }
        print("First difference occurs on line {}:\n", .{diff_line_number});

        print("expected:\n", .{});
        printIndicatorLine(expected, diff_index);

        print("found:\n", .{});
        printIndicatorLine(actual, diff_index);

        return error.TestingAssert;
    }
}

fn printIndicatorLine(source: []const u8, indicator_index: usize) void {
    const line_begin_index = if (std.mem.lastIndexOfScalar(u8, source[0..indicator_index], '\n')) |line_begin|
        line_begin + 1
    else
        0;
    const line_end_index = if (std.mem.indexOfScalar(u8, source[indicator_index..], '\n')) |line_end|
        (indicator_index + line_end)
    else
        source.len;

    printLine(source[line_begin_index..line_end_index]);
    {
        var i: usize = line_begin_index;
        while (i < indicator_index) : (i += 1)
            print(" ", .{});
    }
    print("^\n", .{});
}

fn printWithVisibleNewlines(source: []const u8) void {
    var i: usize = 0;
    while (std.mem.indexOf(u8, source[i..], "\n")) |nl| : (i += nl + 1) {
        printLine(source[i .. i + nl]);
    }
    print("{s}<ETX>\n", .{source[i..]}); // End of Text (ETX)
}

fn printLine(line: []const u8) void {
    if (line.len != 0) switch (line[line.len - 1]) {
        ' ', '\t' => print("{s}<CR>\n", .{line}), // Carriage return
        else => {},
    };
    print("{s}\n", .{line});
}

// Helpers
// -----------------------------------------------------------------------------

/// Returned memory is owned by the caller.
fn canonicaliseJson(allocator: Allocator, json_input: []const u8) ![]const u8 {
    var json_tree = try json.Parser.init(allocator, false).parse(json_input);
    defer json_tree.deinit();
    var buffer = std.ArrayList(u8).init(allocator);
    errdefer buffer.deinit();
    try json_tree.root.jsonStringify(.{}, buffer.writer());
    return buffer.items;
}

fn readFileIfExists(dir: Dir, allocator: Allocator, file_path: []const u8) !?[]const u8 {
    return dir.readFileAlloc(allocator, file_path, max_file_size) catch |e| switch (e) {
        error.FileNotFound => null,
        else => return e,
    };
}

fn skipTestcase(name: []const u8) bool {
    for (skipped_testcases) |skip| {
        if (std.mem.eql(u8, name, skip)) return true;
    }
    return false;
}

// Testing mechanism
// -----------------------------------------------------------------------------

fn testParseSuccess(input_nt: []const u8, expected_json: []const u8) !void {
    logger.debug("Checking for parsing success", .{});
    var p = nestedtext.Parser.init(testing.allocator, .{});
    var diags: nestedtext.Parser.Diags = undefined;
    p.diags = &diags;
    var nt_tree = p.parse(input_nt) catch |e| {
        logger.err(
            "{s} (line {d})",
            .{ diags.ParseError.message, diags.ParseError.lineno },
        );
        return e;
    };
    defer nt_tree.deinit();
    var json_tree = try nt_tree.toJson(testing.allocator);
    defer json_tree.deinit();

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();
    try json_tree.root.jsonStringify(.{}, buffer.writer());

    try expectEqualStrings(expected_json, buffer.items);
}

fn testParseError(input_nt: []const u8, expected_error: ParseErrorInfo) !void {
    logger.debug("Checking for parsing error", .{});
    var p = nestedtext.Parser.init(testing.allocator, .{});
    var diags: nestedtext.Parser.Diags = undefined;
    p.diags = &diags;
    // TODO: Use std.meta.isError() (Zig 0.8).
    if (p.parse(input_nt)) |tree| {
        tree.deinit();
        return error.UnexpectedParseSuccess;
    } else |_| {}
    logger.debug("Got parse error: {s}", .{diags.ParseError.message});
    const expected = expected_error.lineno;
    const actual = diags.ParseError.lineno;
    if (expected != actual) {
        print("expected {}, found {}", .{ expected, actual });
        return error.TestingAssert;
    }
    // TODO: Check message.
}

fn testDumpSuccess(input_json: []const u8, expected_nt: []const u8) !void {
    logger.debug("Checking for dumping success", .{});
    var json_parser = json.Parser.init(testing.allocator, false);
    defer json_parser.deinit();
    var json_tree = try json_parser.parse(input_json);
    defer json_tree.deinit();
    var nt_tree = try nestedtext.fromJson(testing.allocator, json_tree.root);
    defer nt_tree.deinit();

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();
    try nt_tree.stringify(.{ .indent = 4 }, buffer.writer());

    try expectEqualStrings(expected_nt, buffer.items);
}

fn testSingle(allocator: Allocator, dir: std.fs.Dir) !void {
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
            logger.err("Expected one of 'load_out.json' or 'load_err.json'", .{});
            return error.InvalidTestcase;
        }
        tested_something = true;
    }

    if (try readFileIfExists(dir, allocator, "dump_in.json")) |input| {
        if (try readFileIfExists(dir, allocator, "dump_out.nt")) |dump_out| {
            const expected = std.mem.trimRight(u8, dump_out, "\r\n");
            try testDumpSuccess(input, expected);
        } else if (try readFileIfExists(dir, allocator, "dump_err.json")) |load_err| {
            // TODO: Should be impossible?
            _ = load_err;
            logger.warn("Checking dump errors not yet implemented", .{});
        } else {
            logger.err("Expected one of 'dump_out.nt' or 'dump_err.json'", .{});
            return error.InvalidTestcase;
        }
        tested_something = true;
    }

    if (!tested_something) {
        logger.warn("Nothing found to test", .{});
    }
}

fn testAll(base_dir: std.fs.IterableDir) !void {
    var passed: usize = 0;
    var skipped: usize = 0;
    var failed: usize = 0;
    var failures = ArrayList([]const u8).init(testing.allocator);
    defer failures.deinit();

    print("\n", .{});
    var iter = base_dir.iterate();
    while (try iter.next()) |*entry| {
        std.debug.assert(entry.kind == .Directory);
        if (skipTestcase(entry.name)) {
            print("--- Skipping testcase: {s} ---\n\n", .{entry.name});
            skipped += 1;
            continue;
        }
        var dir = try base_dir.dir.openDir(entry.name, .{});
        defer dir.close();
        print("--- Running testcase: {s} ---\n", .{entry.name});
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        testSingle(arena.allocator(), dir) catch |e| {
            print("--- Testcase failed: {} ---\n\n", .{e});
            failed += 1;
            try failures.append(entry.name);
            if (fail_fast) return e else continue;
        };
        print("--- Testcase passed ---\n\n", .{});
        passed += 1;
    }

    print("{d} testcases passed\n", .{passed});
    print("{d} testcases skipped\n", .{skipped});
    print("{d} testcases failed\n", .{failed});
    if (failed > 0) {
        print("\nFailed testcases:\n", .{});
        for (failures.items) |name|
            print(" {s}\n", .{name});
        print("\n", .{});
        return error.TestFailure;
    }
}

test "All testcases" {
    std.testing.log_level = .debug;
    print("\n", .{});
    var testcases_dir = try std.fs.cwd().openIterableDir(testcases_path, .{});
    defer testcases_dir.close();
    try testAll(testcases_dir);
}
