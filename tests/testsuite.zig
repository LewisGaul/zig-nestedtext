const std = @import("std");
const json = std.json;
const testing = std.testing;

const nestedtext = @import("nestedtext");

const Allocator = std.mem.Allocator;
const Dir = std.fs.Dir;

const logger = std.log.scoped(.testsuite);

const testcases_path = "tests/official_tests/test_cases/";

const max_file_size: usize = 1024 * 1024;

const skipped_testcases = [_][]const u8{
    "dict_02", // Bug? (should error when dumping keys with newlines)
    "dict_03", // Weird object keys (bug?)
    "dict_05", // Root-level leading whitespace (bug...)
    "dict_07", // Bug (tab indentation)
    "dict_14", // Bug (handle duplicate keys)
    "dict_15", // Bug (tab indentation)
    "dict_17", // Key quoting - to be removed from spec
    "dict_20", // Weird object keys (bug...)
    "dict_21", // Unrepresentable
    "dict_22", // Unrepresentable
    "dict_23", // Key quoting - to be removed from spec
    "empty_1", // Bad testcase - empty file maps to null??
    "holistic_1", // Key quoting - to be removed from spec
    "list_5", // Root-level leading whitespace (bug...)
    "list_7", // Bug (tab indentation)
    "string_multiline_07", // Root-level leading whitespace (bug...)
    "string_multiline_08", // Bug (tab indentation)
    "string_multiline_09", // Bug (tab indentation)
};

var passed: usize = 0;
var skipped: usize = 0;
var failed: usize = 0;

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
    var json_tree = try nt_tree.root.toJson(testing.allocator);
    defer json_tree.deinit();

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();
    try json_tree.root.jsonStringify(.{}, buffer.writer());

    testing.expectEqualStrings(expected_json, buffer.items);
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
    testing.expectEqual(expected_error.lineno, diags.ParseError.lineno);
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
    try nt_tree.root.stringify(.{}, buffer.writer());

    // TODO: Not working because of unordered JSON parsing in std.
    logger.warn(
        "Skipping checking dumped output (std.json ignores JSON object order)",
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

fn skipTestcase(name: []const u8) bool {
    for (skipped_testcases) |skip| {
        if (std.mem.eql(u8, name, skip)) return true;
    }
    return false;
}

fn testAll(base_dir: std.fs.Dir) !void {
    std.debug.print("\n", .{});
    var iter = base_dir.iterate();
    while (try iter.next()) |*entry| {
        std.debug.assert(entry.kind == .Directory);
        if (skipTestcase(entry.name)) {
            std.debug.print("--- Skipping testcase: {s} ---\n\n", .{entry.name});
            skipped += 1;
            continue;
        }
        var dir = try base_dir.openDir(entry.name, .{});
        defer dir.close();
        std.debug.print("--- Running testcase: {s} ---\n", .{entry.name});
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        testSingle(&arena.allocator, dir) catch |e| {
            std.debug.print("--- Testcase failed: {} ---\n\n", .{e});
            failed += 1;
            if (fail_fast) return e else continue;
        };
        std.debug.print("--- Testcase passed ---\n\n", .{});
        passed += 1;
    }
}

test "All testcases" {
    std.testing.log_level = .debug;
    std.debug.print("\n", .{});
    var testcases_dir = try std.fs.cwd().openDir(testcases_path, .{ .iterate = true });
    defer testcases_dir.close();
    try testAll(testcases_dir);
    std.debug.print("{d} testcases passed\n", .{passed});
    std.debug.print("{d} testcases skipped\n", .{skipped});
    std.debug.print("{d} testcases failed\n", .{failed});
    if (failed > 0) testing.expect(false);
}
