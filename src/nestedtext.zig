const std = @import("std");
const json = std.json;
const testing = std.testing;
const assert = std.debug.assert;

const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const ArrayList = std.ArrayList;
const StringArrayHashMap = std.StringArrayHashMap;
const Writer = std.io.Writer;

const logger = std.log.scoped(.nestedtext);

// -----------------------------------------------------------------------------
// Helpers
// -----------------------------------------------------------------------------

/// Return a slice corresponding to the first line of the given input,
/// including the terminating newline character(s). If there is no terminating
/// newline the entire input slice is returned. Returns null if the input is
/// empty.
fn readline(input: []const u8) ?[]const u8 {
    if (input.len == 0) return null;
    var idx: usize = 0;
    while (idx < input.len) {
        // Handle '\n'
        if (input[idx] == '\n') {
            idx += 1;
            break;
        }
        // Handle '\r'
        if (input[idx] == '\r') {
            idx += 1;
            // Handle '\r\n'
            if (input.len > idx and input[idx] == '\n') idx += 1;
            break;
        }
        idx += 1;
    }
    return input[0..idx];
}

// -----------------------------------------------------------------------------
// Types
// -----------------------------------------------------------------------------

pub const ParseError = error{
    InvalidIndentation,
    TabIndentation,
    InvalidItem,
    MissingObjectValue,
    UnrecognisedLine,
    DuplicateKey,
};

const StringifyOptions = struct {
    indent: usize = 2,
};

pub const ValueTree = struct {
    arena: ArenaAllocator,
    root: Value,

    pub fn deinit(self: @This()) void {
        self.arena.deinit();
    }
};

pub const Map = StringArrayHashMap(Value);
pub const Array = ArrayList(Value);

pub const Value = union(enum) {
    String: []const u8,
    List: Array,
    Object: Map,

    pub fn stringify(
        value: @This(),
        options: StringifyOptions,
        out_stream: anytype,
    ) @TypeOf(out_stream).Error!void {
        try value.stringifyInternal(options, out_stream, 0, false);
    }

    pub fn toJson(value: @This(), allocator: *Allocator) !json.ValueTree {
        var json_tree: json.ValueTree = undefined;
        json_tree.arena = ArenaAllocator.init(allocator);
        json_tree.root = try value.toJsonValue(&json_tree.arena.allocator);
        return json_tree;
    }

    fn toJsonValue(value: @This(), allocator: *Allocator) anyerror!json.Value {
        switch (value) {
            .String => |inner| return json.Value{ .String = inner },
            .List => |inner| {
                var json_array = json.Array.init(allocator);
                for (inner.items) |elem| {
                    const json_elem = try elem.toJsonValue(allocator);
                    try json_array.append(json_elem);
                }
                return json.Value{ .Array = json_array };
            },
            .Object => |inner| {
                var json_map = json.ObjectMap.init(allocator);
                var iter = inner.iterator();
                while (iter.next()) |elem| {
                    const json_value = try elem.value.toJsonValue(allocator);
                    try json_map.put(elem.key, json_value);
                }
                return json.Value{ .Object = json_map };
            },
        }
    }

    fn stringifyInternal(
        value: @This(),
        options: StringifyOptions,
        out_stream: anytype,
        indent: usize,
        nested: bool,
    ) @TypeOf(out_stream).Error!void {
        switch (value) {
            .String => |string| {
                if (std.mem.indexOfAny(u8, string, "\r\n") == null) {
                    // Single-line string.
                    if (nested and string.len > 0) try out_stream.writeByte(' ');
                    try out_stream.writeAll(string);
                } else {
                    // Multi-line string.
                    if (nested) try out_stream.writeByte('\n');
                    var idx: usize = 0;
                    while (readline(string[idx..])) |line| {
                        try out_stream.writeByteNTimes(' ', indent);
                        try out_stream.writeByte('>');
                        if (line.len > 0)
                            try out_stream.print(" {s}", .{line});
                        idx += line.len;
                    }
                    const last_char = string[string.len - 1];
                    if (last_char == '\n' or last_char == '\r') {
                        try out_stream.writeByteNTimes(' ', indent);
                        try out_stream.writeByte('>');
                    }
                }
            },
            .List => |list| {
                if (nested) try out_stream.writeByte('\n');
                for (list.items) |*elem| {
                    if (elem != &list.items[0]) try out_stream.writeByte('\n');
                    try out_stream.writeByteNTimes(' ', indent);
                    try out_stream.writeByte('-');
                    try elem.stringifyInternal(
                        options,
                        out_stream,
                        indent + options.indent,
                        true,
                    );
                }
            },
            .Object => |object| {
                if (nested) try out_stream.writeByte('\n');
                var iter = object.iterator();
                var first_elem = true;
                while (iter.next()) |elem| {
                    if (!first_elem) try out_stream.writeByte('\n');
                    try out_stream.writeByteNTimes(' ', indent);
                    try out_stream.print("{s}:", .{elem.key});
                    try elem.value.stringifyInternal(
                        options,
                        out_stream,
                        indent + options.indent,
                        true,
                    );
                    first_elem = false;
                }
            },
        }
    }
};

/// Memory owned by caller on success - free with 'ValueTree.deinit()'.
pub fn fromJson(allocator: *Allocator, json_value: json.Value) !ValueTree {
    var tree: ValueTree = undefined;
    tree.arena = ArenaAllocator.init(allocator);
    errdefer tree.deinit();
    tree.root = try fromJsonInternal(&tree.arena.allocator, json_value);
    return tree;
}

fn fromJsonInternal(allocator: *Allocator, json_value: json.Value) anyerror!Value {
    switch (json_value) {
        .Null => return Value{ .String = "null" },
        .Bool => |inner| return Value{ .String = if (inner) "true" else "false" },
        .Integer, .Float, .String => {
            var buffer = ArrayList(u8).init(allocator);
            errdefer buffer.deinit();
            switch (json_value) {
                .Integer => |inner| {
                    try buffer.writer().print("{d}", .{inner});
                },
                .Float => |inner| {
                    try buffer.writer().print("{e}", .{inner});
                },
                .String => |inner| {
                    try buffer.writer().print("{s}", .{inner});
                },
                else => unreachable,
            }
            return Value{ .String = buffer.items };
        },
        .Array => |inner| {
            var array = Array.init(allocator);
            for (inner.items) |elem| {
                try array.append(try fromJsonInternal(allocator, elem));
            }
            return Value{ .List = array };
        },
        .Object => |inner| {
            var map = Map.init(allocator);
            var iter = inner.iterator();
            while (iter.next()) |elem| {
                try map.put(
                    try allocator.dupe(u8, elem.key),
                    try fromJsonInternal(allocator, elem.value),
                );
            }
            return Value{ .Object = map };
        },
    }
}

// -----------------------------------------------------------------------------
// Parsing logic
// -----------------------------------------------------------------------------

pub const Parser = struct {
    allocator: *Allocator,
    options: ParseOptions,
    /// If non-null, this struct is filled in by each call to parse().
    diags: ?*Diags = null,

    const Self = @This();

    pub const ParseOptions = struct {
        /// Behaviour when a duplicate field is encountered.
        duplicate_field_behavior: enum {
            UseFirst,
            UseLast,
            Error,
        } = .Error,

        /// Whether to copy strings or return existing slices.
        copy_strings: bool = true,
    };

    pub const Diags = union(enum) {
        Empty,
        ParseError: struct { lineno: usize, message: []const u8 },
    };

    const LineType = union(enum) {
        Blank,
        Comment,
        String: struct { depth: usize, value: []const u8 },
        ListItem: struct { depth: usize, value: ?[]const u8 },
        ObjectItem: struct { depth: usize, key: []const u8, value: ?[]const u8 },
        ObjectKey: struct { depth: usize, value: []const u8 },
        Unrecognised,
        InvalidTabIndent,

        pub fn isObject(self: @This()) bool {
            return switch (self) {
                .ObjectItem, .ObjectKey => true,
                else => false,
            };
        }
    };

    const Line = struct {
        text: []const u8,
        lineno: usize,
        kind: LineType,

        pub fn getDepth(self: @This()) ?usize {
            return switch (self.kind) {
                .String => |k| k.depth,
                .ListItem => |k| k.depth,
                .ObjectItem => |k| k.depth,
                .ObjectKey => |k| k.depth,
                else => null,
            };
        }
    };

    const LinesIter = struct {
        text: []const u8,
        idx: usize = 0,
        next_line: ?Line = null,

        pub fn init(text: []const u8) LinesIter {
            var self = LinesIter{ .text = text };
            self.advanceToNextContentLine();
            return self;
        }

        pub fn next(self: *LinesIter) ?Line {
            const line = self.next_line;
            self.advanceToNextContentLine();
            return line;
        }

        pub fn peekNext(self: LinesIter) ?Line {
            return self.next_line;
        }

        pub fn peekNextDepth(self: LinesIter) ?usize {
            if (self.peekNext() == null) return null;
            return self.peekNext().?.getDepth();
        }

        fn advanceToNextContentLine(self: *LinesIter) void {
            while (readline(self.text[self.idx..])) |full_line| {
                const lineno = if (self.next_line) |line| line.lineno else 0;
                const line = parseLine(full_line, lineno + 1);
                self.next_line = line;
                self.idx += full_line.len;
                switch (line.kind) {
                    .Blank, .Comment => {}, // continue
                    else => return,
                }
            }
            self.next_line = null;
        }

        fn parseLine(full_line: []const u8, lineno: usize) Line {
            const text = std.mem.trimRight(u8, full_line, &[_]u8{ '\n', '\r' });
            var kind: LineType = undefined;

            // Trim spaces and tabs separately to check tabs are not used in
            // indentation of non-ignored lines.
            const stripped = std.mem.trimLeft(u8, text, " ");
            const tab_stripped = std.mem.trimLeft(u8, text, " \t");
            const depth = text.len - stripped.len;
            if (tab_stripped.len == 0) {
                kind = .Blank;
            } else if (tab_stripped[0] == '#') {
                kind = .Comment;
            } else if (parseString(tab_stripped)) |index| {
                kind = if (tab_stripped.len < stripped.len)
                    .InvalidTabIndent
                else
                    .{
                        .String = .{
                            .depth = depth,
                            .value = full_line[text.len - stripped.len + index ..],
                        },
                    };
            } else if (parseList(tab_stripped)) |value| {
                kind = if (tab_stripped.len < stripped.len)
                    .InvalidTabIndent
                else
                    .{
                        .ListItem = .{
                            .depth = depth,
                            .value = if (value.len > 0) value else null,
                        },
                    };
            } else if (parseObjectKey(tab_stripped)) |index| {
                // Behaves just like string line.
                kind = if (tab_stripped.len < stripped.len)
                    .InvalidTabIndent
                else
                    .{
                        .ObjectKey = .{
                            .depth = depth,
                            .value = full_line[text.len - stripped.len + index ..],
                        },
                    };
            } else if (parseObject(tab_stripped)) |result| {
                kind = if (tab_stripped.len < stripped.len)
                    .InvalidTabIndent
                else
                    .{
                        .ObjectItem = .{
                            .depth = depth,
                            .key = result[0].?,
                            // May be null if the value is on the following line(s).
                            .value = result[1],
                        },
                    };
            } else {
                kind = .Unrecognised;
            }
            return .{ .text = text, .lineno = lineno, .kind = kind };
        }

        fn parseString(text: []const u8) ?usize {
            assert(text.len > 0);
            if (text[0] != '>') return null;
            if (text.len == 1) return 1;
            if (text[1] == ' ') return 2;
            return null;
        }

        fn parseList(text: []const u8) ?[]const u8 {
            assert(text.len > 0);
            if (text[0] != '-') return null;
            if (text.len == 1) return "";
            if (text[1] == ' ') return text[2..];
            return null;
        }

        fn parseObjectKey(text: []const u8) ?usize {
            // Behaves just like string line.
            assert(text.len > 0);
            if (text[0] != ':') return null;
            if (text.len == 1) return 1;
            if (text[1] == ' ') return 2;
            return null;
        }

        fn parseObject(text: []const u8) ?[2]?[]const u8 {
            for (text) |char, i| {
                if (char == ':') {
                    if (text.len > i + 1 and text[i + 1] != ' ') continue;
                    const key = std.mem.trim(u8, text[0..i], " \t");
                    const value = if (text.len > i + 2) text[i + 2 ..] else null;
                    return [_]?[]const u8{ key, value };
                }
            }
            return null;
        }
    };

    pub fn init(allocator: *Allocator, options: ParseOptions) Self {
        return .{
            .allocator = allocator,
            .options = options,
        };
    }

    /// Memory owned by caller on success - free with 'ValueTree.deinit()'.
    pub fn parse(p: Self, input: []const u8) !ValueTree {
        if (p.diags) |diags| diags.* = Diags.Empty;
        var tree: ValueTree = undefined;
        tree.arena = ArenaAllocator.init(p.allocator);
        errdefer tree.deinit();

        var lines = LinesIter.init(input);

        tree.root = if (lines.peekNext() != null)
            try p.readValue(&tree.arena.allocator, &lines) // Recursively parse
        else
            .{ .String = "" };

        return tree;
    }

    fn readValue(p: Self, allocator: *Allocator, lines: *LinesIter) anyerror!Value {
        // Call read<type>() with the first line of the type queued up as the
        // next line in the lines iterator.
        const next_line = lines.peekNext().?;
        return switch (next_line.kind) {
            .String => .{ .String = try p.readString(allocator, lines) },
            .ListItem => .{ .List = try p.readList(allocator, lines) },
            .ObjectItem, .ObjectKey => .{ .Object = try p.readObject(allocator, lines) },
            .Unrecognised => {
                p.maybeStoreDiags(next_line.lineno, "Unrecognised line type");
                return error.UnrecognisedLine;
            },
            .InvalidTabIndent => {
                p.maybeStoreDiags(
                    next_line.lineno,
                    "Tabs not allowed in indentation of non-ignored lines",
                );
                return error.TabIndentation;
            },
            .Blank, .Comment => unreachable, // Skipped by iterator
        };
    }

    fn readString(p: Self, allocator: *Allocator, lines: *LinesIter) ![]const u8 {
        var buffer = ArrayList(u8).init(allocator);
        errdefer buffer.deinit();
        var writer = buffer.writer();

        assert(lines.peekNext().?.kind == .String);
        const depth = lines.peekNextDepth().?;

        while (lines.next()) |line| {
            if (line.kind != .String) {
                p.maybeStoreDiags(
                    line.lineno,
                    "Invalid line type following multi-line string",
                );
                return error.InvalidItem;
            }
            const is_last_line = lines.peekNextDepth() == null or lines.peekNextDepth().? < depth;
            const str_line = line.kind.String;
            if (str_line.depth > depth) {
                p.maybeStoreDiags(line.lineno, "Invalid indentation of multi-line string");
                return error.InvalidIndentation;
            }
            // String must be copied as it's not contiguous in-file.
            if (is_last_line)
                try writer.writeAll(std.mem.trimRight(u8, str_line.value, &[_]u8{ '\n', '\r' }))
            else
                try writer.writeAll(str_line.value);
            if (is_last_line) break;
        }
        return buffer.items;
    }

    fn readList(p: Self, allocator: *Allocator, lines: *LinesIter) !Array {
        var array = Array.init(allocator);
        errdefer array.deinit();

        assert(lines.peekNext().?.kind == .ListItem);
        const depth = lines.peekNextDepth().?;

        while (lines.next()) |line| {
            if (line.kind != .ListItem) {
                p.maybeStoreDiags(line.lineno, "Invalid line type following list item");
                return error.InvalidItem;
            }
            const list_line = line.kind.ListItem;
            if (list_line.depth > depth) {
                p.maybeStoreDiags(line.lineno, "Invalid indentation following list item");
                return error.InvalidIndentation;
            }

            var value: Value = undefined;
            if (list_line.value) |str| {
                value = .{ .String = try p.maybeDupString(allocator, str) };
            } else if (lines.peekNextDepth() != null and lines.peekNextDepth().? > depth) {
                value = try p.readValue(allocator, lines);
            } else {
                value = .{ .String = "" };
            }
            try array.append(value);

            if (lines.peekNextDepth() != null and lines.peekNextDepth().? < depth) break;
        }
        return array;
    }

    fn readObject(p: Self, allocator: *Allocator, lines: *LinesIter) anyerror!Map {
        var map = Map.init(allocator);
        errdefer map.deinit();

        assert(lines.peekNext().?.kind.isObject());
        const depth = lines.peekNextDepth().?;

        while (lines.peekNext()) |line| {
            if (!line.kind.isObject()) {
                p.maybeStoreDiags(line.lineno, "Invalid line type following object item");
                return error.InvalidItem;
            }
            if (line.getDepth().? > depth) {
                p.maybeStoreDiags(line.lineno, "Invalid indentation following object item");
                return error.InvalidIndentation;
            }
            const key = switch (line.kind) {
                .ObjectItem => |obj_line| blk: {
                    _ = lines.next(); // Advance iterator
                    break :blk try p.maybeDupString(allocator, obj_line.key);
                },
                .ObjectKey => try p.readObjectKey(allocator, lines),
                else => unreachable,
            };
            if (map.contains(key)) {
                switch (p.options.duplicate_field_behavior) {
                    .UseFirst => continue,
                    .UseLast => {},
                    .Error => {
                        p.maybeStoreDiags(line.lineno, "Duplicate object key");
                        return error.DuplicateKey;
                    },
                }
            }
            const value: Value = blk: {
                if (line.kind == .ObjectItem and line.kind.ObjectItem.value != null) {
                    const string = line.kind.ObjectItem.value.?;
                    break :blk .{ .String = try p.maybeDupString(allocator, string) };
                } else if (lines.peekNextDepth() != null and lines.peekNextDepth().? > depth) {
                    break :blk try p.readValue(allocator, lines);
                } else if (line.kind == .ObjectKey) {
                    p.maybeStoreDiags(line.lineno, "Multiline object key must be followed by value");
                    return error.MissingObjectValue;
                } else {
                    break :blk .{ .String = "" };
                }
            };
            try map.put(key, value);
            if (lines.peekNextDepth() != null and lines.peekNextDepth().? < depth) break;
        }
        return map;
    }

    fn readObjectKey(p: Self, allocator: *Allocator, lines: *LinesIter) ![]const u8 {
        // Handled just like strings.
        var buffer = ArrayList(u8).init(allocator);
        errdefer buffer.deinit();
        var writer = buffer.writer();

        assert(lines.peekNext().?.kind == .ObjectKey);
        const depth = lines.peekNextDepth().?;

        while (lines.next()) |line| {
            if (line.kind != .ObjectKey) {
                p.maybeStoreDiags(
                    line.lineno,
                    "Invalid line type following object key line",
                );
                return error.InvalidItem;
            }
            const is_last_line = lines.peekNextDepth().? != depth;
            const key_line = line.kind.ObjectKey;
            if (key_line.depth > depth) {
                p.maybeStoreDiags(line.lineno, "Invalid indentation of object key line");
                return error.InvalidIndentation;
            }
            // String must be copied as it's not contiguous in-file.
            if (is_last_line)
                try writer.writeAll(std.mem.trimRight(u8, key_line.value, &[_]u8{ '\n', '\r' }))
            else
                try writer.writeAll(key_line.value);
            if (is_last_line) break;
        }
        return buffer.items;
    }

    fn maybeDupString(p: Self, allocator: *Allocator, string: []const u8) ![]const u8 {
        return if (p.options.copy_strings) try allocator.dupe(u8, string) else string;
    }

    fn maybeStoreDiags(p: Self, lineno: usize, message: []const u8) void {
        if (p.diags) |diags|
            diags.* = .{
                .ParseError = .{
                    .lineno = lineno,
                    .message = message,
                },
            };
    }
};

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

test "parse empty" {
    var p = Parser.init(testing.allocator, .{});

    var tree = try p.parse("");
    defer tree.deinit();

    testing.expectEqual(Value{ .String = "" }, tree.root);
}

test "basic parse: string" {
    var p = Parser.init(testing.allocator, .{});

    const s =
        \\ > this is a
        \\ > multiline
        \\ > string
    ;

    var tree = try p.parse(s);
    defer tree.deinit();

    testing.expectEqualStrings("this is a\nmultiline\nstring", tree.root.String);
}

test "basic parse: list" {
    var p = Parser.init(testing.allocator, .{});

    const s =
        \\ - foo
        \\ - bar
    ;

    var tree = try p.parse(s);
    defer tree.deinit();

    const array: Array = tree.root.List;

    testing.expectEqualStrings("foo", array.items[0].String);
    testing.expectEqualStrings("bar", array.items[1].String);
}

test "basic parse: object" {
    var p = Parser.init(testing.allocator, .{});

    const s =
        \\ foo: 1
        \\ bar: False
    ;

    var tree = try p.parse(s);
    defer tree.deinit();

    const map: Map = tree.root.Object;

    testing.expectEqualStrings("1", map.get("foo").?.String);
    testing.expectEqualStrings("False", map.get("bar").?.String);
}

test "nested parse: object inside object" {
    var p = Parser.init(testing.allocator, .{});

    const s =
        \\ foo: 1
        \\ bar:
        \\   nest1: 2
        \\   nest2: 3
        \\ baz:
    ;

    var tree = try p.parse(s);
    defer tree.deinit();

    const map: Map = tree.root.Object;

    testing.expectEqualStrings("1", map.get("foo").?.String);
    testing.expectEqualStrings("", map.get("baz").?.String);
    testing.expectEqualStrings("2", map.get("bar").?.Object.get("nest1").?.String);
    testing.expectEqualStrings("3", map.get("bar").?.Object.get("nest2").?.String);
}

test "failed parse: multi-line string indent" {
    var p = Parser.init(testing.allocator, .{});
    var diags: Parser.Diags = undefined;
    p.diags = &diags;

    const s =
        \\ > foo
        \\   > bar
    ;

    testing.expectError(error.InvalidIndentation, p.parse(s));
    testing.expectEqual(@as(usize, 2), diags.ParseError.lineno);
    testing.expectEqualStrings(
        "Invalid indentation of multi-line string",
        diags.ParseError.message,
    );
}

test "stringify: empty" {
    var p = Parser.init(testing.allocator, .{});

    var tree = try p.parse("");
    defer tree.deinit();

    var buffer: [128]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    try tree.root.stringify(.{}, fbs.outStream());
    testing.expectEqualStrings("", fbs.getWritten());
}

test "stringify: string" {
    var p = Parser.init(testing.allocator, .{});

    const s =
        \\> this is a
        \\> multiline
        \\> string
    ;

    var tree = try p.parse(s);
    defer tree.deinit();

    var buffer: [128]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    try tree.root.stringify(.{}, fbs.outStream());
    testing.expectEqualStrings(s, fbs.getWritten());
}

test "stringify: list" {
    var p = Parser.init(testing.allocator, .{});

    const s =
        \\- foo
        \\- bar
    ;

    var tree = try p.parse(s);
    defer tree.deinit();

    var buffer: [128]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    try tree.root.stringify(.{}, fbs.outStream());
    testing.expectEqualStrings(s, fbs.getWritten());
}

test "stringify: object" {
    var p = Parser.init(testing.allocator, .{});

    const s =
        \\foo: 1
        \\bar: False
    ;

    var tree = try p.parse(s);
    defer tree.deinit();

    var buffer: [128]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    try tree.root.stringify(.{}, fbs.outStream());
    testing.expectEqualStrings(s, fbs.getWritten());
}

test "stringify: multiline string inside object" {
    var p = Parser.init(testing.allocator, .{});

    const s =
        \\foo:
        \\  > multi
        \\  > line
        \\bar:
    ;

    var tree = try p.parse(s);
    defer tree.deinit();

    var buffer: [128]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    try tree.root.stringify(.{}, fbs.outStream());
    testing.expectEqualStrings(s, fbs.getWritten());
}

test "convert to JSON: empty" {
    var p = Parser.init(testing.allocator, .{});

    var tree = try p.parse("");
    defer tree.deinit();

    var json_tree = try tree.root.toJson(testing.allocator);
    defer json_tree.deinit();

    var buffer: [128]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    try json_tree.root.jsonStringify(.{}, fbs.outStream());
    testing.expectEqualStrings("\"\"", fbs.getWritten());
}

test "convert to JSON: string" {
    var p = Parser.init(testing.allocator, .{});

    const s =
        \\ > this is a
        \\ > multiline
        \\ > string
    ;

    var tree = try p.parse(s);
    defer tree.deinit();

    var json_tree = try tree.root.toJson(testing.allocator);
    defer json_tree.deinit();

    var buffer: [128]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    try json_tree.root.jsonStringify(.{}, fbs.outStream());
    testing.expectEqualStrings("\"this is a\\nmultiline\\nstring\"", fbs.getWritten());
}

test "convert to JSON: list" {
    var p = Parser.init(testing.allocator, .{});

    const s =
        \\ - foo
        \\ - bar
    ;

    var tree = try p.parse(s);
    defer tree.deinit();

    var json_tree = try tree.root.toJson(testing.allocator);
    defer json_tree.deinit();

    var buffer: [128]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    try json_tree.root.jsonStringify(.{}, fbs.outStream());
    const expected_json =
        \\["foo","bar"]
    ;
    testing.expectEqualStrings(expected_json, fbs.getWritten());
}

test "convert to JSON: object" {
    var p = Parser.init(testing.allocator, .{});

    const s =
        \\ foo: 1
        \\ bar: False
    ;

    var tree = try p.parse(s);
    defer tree.deinit();

    var json_tree = try tree.root.toJson(testing.allocator);
    defer json_tree.deinit();

    var buffer: [128]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    try json_tree.root.jsonStringify(.{}, fbs.outStream());
    // TODO: Order of objects not yet guaranteed.
    const expected_json =
        \\{"foo":"1","bar":"False"}
    ;
    testing.expectEqualStrings(expected_json, fbs.getWritten());
}

test "convert to JSON: object inside object" {
    var p = Parser.init(testing.allocator, .{});

    const s =
        \\ bar:
        \\   nest1: 1
        \\   nest2: 2
    ;

    var tree = try p.parse(s);
    defer tree.deinit();

    var json_tree = try tree.root.toJson(testing.allocator);
    defer json_tree.deinit();

    var buffer: [128]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    try json_tree.root.jsonStringify(.{}, fbs.outStream());
    const expected_json =
        \\{"bar":{"nest1":"1","nest2":"2"}}
    ;
    testing.expectEqualStrings(expected_json, fbs.getWritten());
}

test "convert to JSON: list inside object" {
    var p = Parser.init(testing.allocator, .{});

    const s =
        \\ bar:
        \\   - nest1
        \\   - nest2
    ;

    var tree = try p.parse(s);
    defer tree.deinit();

    var json_tree = try tree.root.toJson(testing.allocator);
    defer json_tree.deinit();

    var buffer: [128]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    try json_tree.root.jsonStringify(.{}, fbs.outStream());
    const expected_json =
        \\{"bar":["nest1","nest2"]}
    ;
    testing.expectEqualStrings(expected_json, fbs.getWritten());
}

test "convert to JSON: multiline string inside object" {
    var p = Parser.init(testing.allocator, .{});

    const s =
        \\ foo:
        \\   > multi
        \\   > line
    ;

    var tree = try p.parse(s);
    defer tree.deinit();

    var json_tree = try tree.root.toJson(testing.allocator);
    defer json_tree.deinit();

    var buffer: [128]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    try json_tree.root.jsonStringify(.{}, fbs.outStream());
    const expected_json =
        \\{"foo":"multi\nline"}
    ;
    testing.expectEqualStrings(expected_json, fbs.getWritten());
}

test "convert to JSON: multiline string inside list" {
    var p = Parser.init(testing.allocator, .{});

    const s =
        \\ -
        \\   > multi
        \\   > line
        \\ -
    ;

    var tree = try p.parse(s);
    defer tree.deinit();

    var json_tree = try tree.root.toJson(testing.allocator);
    defer json_tree.deinit();

    var buffer: [128]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    try json_tree.root.jsonStringify(.{}, fbs.outStream());
    const expected_json =
        \\["multi\nline",""]
    ;
    testing.expectEqualStrings(expected_json, fbs.getWritten());
}
