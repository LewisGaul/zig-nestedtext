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
    while (idx < input.len) : (idx += 1) {
        // Handle '\n'
        if (input[idx] == '\n') return input[0 .. idx + 1];
        // Handle '\r'
        if (input[idx] == '\r') {
            // Handle '\r\n'
            if (input.len > idx + 1 and input[idx + 1] == '\n')
                return input[0 .. idx + 2]
            else
                return input[0 .. idx + 1];
        }
    }
    return input;
}

// -----------------------------------------------------------------------------
// Types
// -----------------------------------------------------------------------------

pub const ParseError = error{
    RootLevelIndent,
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
    root: ?Value,

    pub fn deinit(self: @This()) void {
        self.arena.deinit();
    }

    pub fn stringify(
        self: @This(),
        options: StringifyOptions,
        out_stream: anytype,
    ) @TypeOf(out_stream).Error!void {
        if (self.root) |value|
            try value.stringify(options, out_stream);
    }

    pub fn toJson(self: @This(), allocator: *Allocator) !json.ValueTree {
        if (self.root) |value|
            return value.toJson(allocator)
        else
            return json.ValueTree{
                .arena = ArenaAllocator.init(allocator),
                .root = json.Value.Null,
            };
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
        try value.stringifyInternal(options, out_stream, 0, false, false);
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
                    const json_value = try elem.value_ptr.*.toJsonValue(allocator);
                    try json_map.put(elem.key_ptr.*, json_value);
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
        force_multiline_string: bool,
    ) @TypeOf(out_stream).Error!void {
        switch (value) {
            .String => |string| {
                if (nested and
                    std.mem.indexOfAny(u8, string, "\r\n") == null and
                    !force_multiline_string)
                {
                    // Single-line string.
                    if (string.len > 0) try out_stream.writeByte(' ');
                    try out_stream.writeAll(string);
                } else else_blk: {
                    // Multi-line string.
                    if (nested) try out_stream.writeByte('\n');
                    if (string.len == 0) {
                        try out_stream.writeByteNTimes(' ', indent);
                        try out_stream.writeByte('>');
                        break :else_blk;
                    }
                    var idx: usize = 0;
                    while (readline(string[idx..])) |line| {
                        try out_stream.writeByteNTimes(' ', indent);
                        try out_stream.writeByte('>');
                        if (line[0] == '\n' or line[0] == '\r')
                            try out_stream.print("{s}", .{line})
                        else if (line.len > 0)
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
                if (list.items.len == 0) {
                    try out_stream.writeAll("[]");
                    return;
                }
                for (list.items) |*elem| {
                    if (elem != &list.items[0]) try out_stream.writeByte('\n');
                    try out_stream.writeByteNTimes(' ', indent);
                    try out_stream.writeByte('-');
                    try elem.stringifyInternal(
                        options,
                        out_stream,
                        indent + options.indent,
                        true,
                        false,
                    );
                }
            },
            .Object => |object| {
                if (nested) try out_stream.writeByte('\n');
                if (object.count() == 0) {
                    try out_stream.writeAll("{}");
                    return;
                }
                var iter = object.iterator();
                var first_elem = true;
                while (iter.next()) |elem| {
                    var force_multiline_string_next = false;
                    if (!first_elem) try out_stream.writeByte('\n');
                    const key = elem.key_ptr.*;
                    if (key.len > 0 and
                        // No newlines
                        std.mem.indexOfAny(u8, key, "\r\n") == null and
                        // No leading whitespace or other special characters
                        std.mem.indexOfAny(u8, key[0..1], "#[{ \t") == null and
                        // No trailing whitespace
                        std.mem.indexOfAny(u8, key[key.len - 1 ..], " \t") == null and
                        // No leading special characters followed by a space
                        !(std.mem.indexOfAny(u8, key[0..1], ">-") != null and (key.len == 1 or key[1] == ' ')) and
                        // No internal colons followed by a space
                        std.mem.indexOf(u8, key, ": ") == null)
                    {
                        // Simple key.
                        try out_stream.writeByteNTimes(' ', indent);
                        try out_stream.print("{s}:", .{key});
                    } else else_blk: {
                        // Multi-line key.
                        force_multiline_string_next = true;
                        if (key.len == 0) {
                            try out_stream.writeByte(':');
                            break :else_blk;
                        }
                        var idx: usize = 0;
                        while (readline(key[idx..])) |line| {
                            try out_stream.writeByteNTimes(' ', indent);
                            try out_stream.writeByte(':');
                            if (line.len > 0)
                                try out_stream.print(" {s}", .{line});
                            idx += line.len;
                        }
                        const last_char = key[key.len - 1];
                        if (last_char == '\n' or last_char == '\r') {
                            try out_stream.writeByteNTimes(' ', indent);
                            try out_stream.writeByte(':');
                        }
                    }
                    try elem.value_ptr.*.stringifyInternal(
                        options,
                        out_stream,
                        indent + options.indent,
                        true,
                        force_multiline_string_next,
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
        .Integer,
        .Float,
        .String,
        .NumberString,
        => {
            var buffer = ArrayList(u8).init(allocator);
            errdefer buffer.deinit();
            switch (json_value) {
                .Integer => |inner| {
                    try buffer.writer().print("{d}", .{inner});
                },
                .Float => |inner| {
                    try buffer.writer().print("{e}", .{inner});
                },
                .String, .NumberString => |inner| {
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
                    try allocator.dupe(u8, elem.key_ptr.*),
                    try fromJsonInternal(allocator, elem.value_ptr.*),
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
        String: struct { value: []const u8 },
        ListItem: struct { value: ?[]const u8 },
        ObjectItem: struct { key: []const u8, value: ?[]const u8 },
        ObjectKey: struct { value: []const u8 },
        InlineContainer: struct { value: []const u8 },
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
        depth: usize,
        kind: LineType,
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
                else .{
                    .String = .{
                        .value = full_line[text.len - stripped.len + index ..],
                    },
                };
            } else if (parseList(tab_stripped)) |value| {
                kind = if (tab_stripped.len < stripped.len)
                    .InvalidTabIndent
                else .{
                    .ListItem = .{
                        .value = if (value.len > 0) value else null,
                    },
                };
            } else if (parseInlineContainer(tab_stripped)) {
                kind = if (tab_stripped.len < stripped.len)
                    .InvalidTabIndent
                else .{
                    .InlineContainer = .{
                        .value = std.mem.trimRight(u8, stripped, " \t"),
                    },
                };
            } else if (parseObjectKey(tab_stripped)) |index| {
                // Behaves just like string line.
                kind = if (tab_stripped.len < stripped.len)
                    .InvalidTabIndent
                else .{
                    .ObjectKey = .{
                        .value = full_line[text.len - stripped.len + index ..],
                    },
                };
            } else if (parseObject(tab_stripped)) |result| {
                kind = if (tab_stripped.len < stripped.len)
                    .InvalidTabIndent
                else .{
                    .ObjectItem = .{
                        .key = result[0].?,
                        // May be null if the value is on the following line(s).
                        .value = result[1],
                    },
                };
            } else {
                kind = .Unrecognised;
            }
            return .{ .text = text, .lineno = lineno, .depth = depth, .kind = kind };
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

        fn parseInlineContainer(text: []const u8) bool {
            assert(text.len > 0);
            return (text[0] == '[' or text[0] == '{');
        }
    };

    const CharIter = struct {
        text: []const u8,
        idx: usize = 0,

        pub fn next(self: *@This()) ?u8 {
            if (self.idx >= self.text.len) return null;
            const char = self.text[self.idx];
            self.idx += 1;
            return char;
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

        tree.root = if (lines.peekNext()) |first_line| blk: {
            if (first_line.depth > 0) {
                p.maybeStoreDiags(
                    first_line.lineno,
                    "Unexpected indentation on first content line",
                );
                return ParseError.RootLevelIndent;
            }
            // Recursively parse
            break :blk try p.readValue(&tree.arena.allocator, &lines);
        } else null;

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
            .InlineContainer => try p.readInlineContainer(allocator, lines),
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
        const depth = lines.peekNext().?.depth;

        while (lines.next()) |line| {
            if (line.kind != .String) {
                p.maybeStoreDiags(
                    line.lineno,
                    "Invalid line type following multi-line string",
                );
                return error.InvalidItem;
            }
            const is_last_line = lines.peekNext() == null or lines.peekNext().?.depth < depth;
            const str_line = line.kind.String;
            if (line.depth > depth) {
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
        const depth = lines.peekNext().?.depth;

        while (lines.next()) |line| {
            if (line.kind != .ListItem) {
                p.maybeStoreDiags(line.lineno, "Invalid line type following list item");
                return error.InvalidItem;
            }
            const list_line = line.kind.ListItem;
            if (line.depth > depth) {
                p.maybeStoreDiags(line.lineno, "Invalid indentation following list item");
                return error.InvalidIndentation;
            }

            var value: Value = undefined;
            if (list_line.value) |str| {
                value = .{ .String = try p.maybeDupString(allocator, str) };
            } else if (lines.peekNext() != null and lines.peekNext().?.depth > depth) {
                value = try p.readValue(allocator, lines);
            } else {
                value = .{ .String = "" };
            }
            try array.append(value);

            if (lines.peekNext() != null and lines.peekNext().?.depth < depth) break;
        }
        return array;
    }

    fn readObject(p: Self, allocator: *Allocator, lines: *LinesIter) anyerror!Map {
        var map = Map.init(allocator);
        errdefer map.deinit();

        assert(lines.peekNext().?.kind.isObject());
        const depth = lines.peekNext().?.depth;

        while (lines.peekNext()) |line| {
            if (!line.kind.isObject()) {
                p.maybeStoreDiags(line.lineno, "Invalid line type following object item");
                return error.InvalidItem;
            }
            if (line.depth > depth) {
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
                } else if (lines.peekNext() != null and lines.peekNext().?.depth > depth) {
                    break :blk try p.readValue(allocator, lines);
                } else if (line.kind == .ObjectKey) {
                    p.maybeStoreDiags(line.lineno, "Multiline object key must be followed by value");
                    return error.MissingObjectValue;
                } else {
                    break :blk .{ .String = "" };
                }
            };
            try map.put(key, value);
            if (lines.peekNext() != null and lines.peekNext().?.depth < depth) break;
        }
        return map;
    }

    fn readObjectKey(p: Self, allocator: *Allocator, lines: *LinesIter) ![]const u8 {
        // Handled just like strings.
        var buffer = ArrayList(u8).init(allocator);
        errdefer buffer.deinit();
        var writer = buffer.writer();

        assert(lines.peekNext().?.kind == .ObjectKey);
        const depth = lines.peekNext().?.depth;

        while (lines.next()) |line| {
            if (line.kind != .ObjectKey) {
                p.maybeStoreDiags(
                    line.lineno,
                    "Invalid line type following object key line",
                );
                return error.InvalidItem;
            }
            const is_last_line = lines.peekNext() == null or lines.peekNext().?.depth != depth;
            const key_line = line.kind.ObjectKey;
            if (line.depth > depth) {
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

    fn readInlineContainer(p: Self, allocator: *Allocator, lines: *LinesIter) !Value {
        const line = lines.next().?;
        assert(line.kind == .InlineContainer);
        const line_text = line.kind.InlineContainer.value;

        var text_iter = CharIter{ .text = line_text };
        const value: Value = switch (text_iter.next().?) {
            '[' => .{ .List = try p.parseInlineList(allocator, &text_iter, line.lineno) },
            '{' => .{ .Object = try p.parseInlineObject(allocator, &text_iter, line.lineno) },
            else => unreachable,
        };
        if (text_iter.idx != text_iter.text.len) {
            p.maybeStoreDiags(line.lineno, "Unexpected text following closing bracket/brace");
            return error.InvalidItem;
        }

        // Check next content line is dedented.
        if (lines.peekNext() != null and lines.peekNext().?.depth >= line.depth) {
            p.maybeStoreDiags(line.lineno, "Invalid indentation following list item");
            return error.InvalidIndentation;
        }

        return value;
    }

    fn parseInlineList(p: Self, allocator: *Allocator, text_iter: *CharIter, lineno: usize) anyerror!Array {
        var array = Array.init(allocator);
        errdefer array.deinit();

        // TODO: Tidy this up - look at p.parseInlineObject().

        var found_closing_bracket = false;
        var expecting_value = false;
        var value: ?Value = null;
        // First character is the first one after the opening '['.
        while (text_iter.next()) |char| {
            if (value) |val| {
                expecting_value = false;
                if (char == '[' or char == '{') {
                    p.maybeStoreDiags(
                        lineno,
                        "Unexpected opening bracket following inline list value",
                    );
                    return error.InvalidItem;
                }
                try array.append(val);
                value = null;
                if (char == ',') {
                    expecting_value = true;
                    continue;
                }
            }
            switch (char) {
                ' ', '\t' => continue,
                '[' => value = .{ .List = try p.parseInlineList(allocator, text_iter, lineno) },
                '{' => value = .{ .Object = try p.parseInlineObject(allocator, text_iter, lineno) },
                ']' => {
                    if (expecting_value) {
                        p.maybeStoreDiags(lineno, "Missing value after comma");
                        return error.InvalidItem;
                    }
                    found_closing_bracket = true;
                    break; // Caller responsible for checking remainder of line
                },
                ',' => {
                    p.maybeStoreDiags(lineno, "Missing value before comma");
                    return error.InvalidItem;
                },
                '}' => {
                    p.maybeStoreDiags(lineno, "Unexpected closing brace '}'");
                    return error.InvalidItem;
                },
                else => {
                    const start_idx = text_iter.idx - 1;
                    const end_idx = blk: {
                        if (std.mem.indexOfAnyPos(u8, text_iter.text, start_idx, "[]{},")) |idx|
                            break :blk idx
                        else
                            break; // Exit loop - no closing bracket
                    };
                    const string = std.mem.trimRight(u8, text_iter.text[start_idx..end_idx], " \t");
                    value = .{ .String = try p.maybeDupString(allocator, string) };
                    text_iter.idx = end_idx;
                },
            }
        }
        if (!found_closing_bracket) {
            p.maybeStoreDiags(lineno, "Missing closing bracket ']'");
            return error.InvalidItem;
        }

        return array;
    }

    fn parseInlineObject(p: Self, allocator: *Allocator, text_iter: *CharIter, lineno: usize) anyerror!Map {
        var map = Map.init(allocator);
        errdefer map.deinit();

        // State machine:
        //  1. Looking for key (or closing brace -> finished)
        //  2. Looking for colon
        //  3. Looking for value
        //  4. Looking for comma (or closing brace -> finished)
        //  5. Looking for key
        //  6. Looking for colon
        //  ...
        const Token = enum {
            Key,
            KeyOrEnd,
            Colon,
            Value,
            CommaOrEnd,
            Finished,
        };

        var next_token = Token.KeyOrEnd;
        var parsed_key: ?[]const u8 = null;
        var parsed_value: ?Value = null;
        // First character is the first one after the opening '{'.
        while (text_iter.next()) |char| {
            // Skip over whitespace between the tokens.
            if (char == ' ' or char == '\t') continue;
            // Check the character and/or consume some text for the expected token.
            switch (next_token) {
                .Key, .KeyOrEnd => {
                    if (next_token == .KeyOrEnd and char == '}') {
                        next_token = .Finished;
                        break;
                    }
                    if (p.parseInlineContainerString(text_iter, "[]{},:")) |key|
                        parsed_key = key
                    else {
                        p.maybeStoreDiags(lineno, "Expected an inline object key");
                        return error.InvalidItem;
                    }
                    next_token = .Colon;
                },
                .Colon => {
                    if (char != ':') {
                        p.maybeStoreDiags(lineno, "Unexpected character after inline object key");
                        return error.InvalidItem;
                    }
                    next_token = .Value;
                },
                .Value => {
                    if (char == '[')
                        parsed_value = .{
                            .List = try p.parseInlineList(allocator, text_iter, lineno),
                        }
                    else if (char == '{')
                        parsed_value = .{
                            .Object = try p.parseInlineObject(allocator, text_iter, lineno),
                        }
                    else if (p.parseInlineContainerString(text_iter, "[]{},:")) |value|
                        parsed_value = .{ .String = try p.maybeDupString(allocator, value) }
                    else {
                        p.maybeStoreDiags(lineno, "Expected an inline object value");
                        return error.InvalidItem;
                    }
                    next_token = .CommaOrEnd;
                },
                .CommaOrEnd => {
                    if (char != ',' and char != '}') {
                        p.maybeStoreDiags(lineno, "Unexpected character after inline object value");
                        return error.InvalidItem;
                    }
                    try map.put(parsed_key.?, parsed_value.?);
                    parsed_key = null;
                    parsed_value = null;
                    if (char == '}') {
                        next_token = .Finished;
                        break;
                    }
                    next_token = .Key;
                },
                .Finished => unreachable,
            }
        }
        if (next_token != .Finished) {
            p.maybeStoreDiags(lineno, "Missing closing brace '}'");
            return error.InvalidItem;
        }
        return map;
    }

    fn parseInlineContainerString(p: Self, text_iter: *CharIter, disallowed_chars: []const u8) ?[]const u8 {
        const start_idx = text_iter.idx - 1;
        const end_idx = blk: {
            if (std.mem.indexOfAnyPos(u8, text_iter.text, start_idx, disallowed_chars)) |idx|
                break :blk idx
            else
                break :blk text_iter.text.len;
        };
        if (end_idx == start_idx) return null; // Zero-length (empty string)
        text_iter.idx = end_idx;
        return std.mem.trim(u8, text_iter.text[start_idx..end_idx], " \t");
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

    try testing.expectEqual(@as(?Value, null), tree.root);
}

test "basic parse: string" {
    var p = Parser.init(testing.allocator, .{});

    const s =
        \\> this is a
        \\> multiline
        \\> string
    ;

    var tree = try p.parse(s);
    defer tree.deinit();

    try testing.expectEqualStrings("this is a\nmultiline\nstring", tree.root.?.String);
}

test "basic parse: list" {
    var p = Parser.init(testing.allocator, .{});

    const s =
        \\- foo
        \\- bar
    ;

    var tree = try p.parse(s);
    defer tree.deinit();

    const array: Array = tree.root.?.List;

    try testing.expectEqualStrings("foo", array.items[0].String);
    try testing.expectEqualStrings("bar", array.items[1].String);
}

test "basic parse: object" {
    var p = Parser.init(testing.allocator, .{});

    const s =
        \\foo: 1
        \\bar: False
    ;

    var tree = try p.parse(s);
    defer tree.deinit();

    const map: Map = tree.root.?.Object;

    try testing.expectEqualStrings("1", map.get("foo").?.String);
    try testing.expectEqualStrings("False", map.get("bar").?.String);
}

test "nested parse: object inside object" {
    var p = Parser.init(testing.allocator, .{});

    const s =
        \\foo: 1
        \\bar:
        \\  nest1: 2
        \\  nest2: 3
        \\baz:
    ;

    var tree = try p.parse(s);
    defer tree.deinit();

    const map: Map = tree.root.?.Object;

    try testing.expectEqualStrings("1", map.get("foo").?.String);
    try testing.expectEqualStrings("", map.get("baz").?.String);
    try testing.expectEqualStrings("2", map.get("bar").?.Object.get("nest1").?.String);
    try testing.expectEqualStrings("3", map.get("bar").?.Object.get("nest2").?.String);
}

test "failed parse: multi-line string indent" {
    var p = Parser.init(testing.allocator, .{});
    var diags: Parser.Diags = undefined;
    p.diags = &diags;

    const s =
        \\> foo
        \\  > bar
    ;

    try testing.expectError(error.InvalidIndentation, p.parse(s));
    try testing.expectEqual(@as(usize, 2), diags.ParseError.lineno);
    try testing.expectEqualStrings(
        "Invalid indentation of multi-line string",
        diags.ParseError.message,
    );
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
    try tree.root.?.stringify(.{}, fbs.writer());
    try testing.expectEqualStrings(s, fbs.getWritten());
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
    try tree.root.?.stringify(.{}, fbs.writer());
    try testing.expectEqualStrings(s, fbs.getWritten());
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
    try tree.root.?.stringify(.{}, fbs.writer());
    try testing.expectEqualStrings(s, fbs.getWritten());
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
    try tree.root.?.stringify(.{}, fbs.writer());
    try testing.expectEqualStrings(s, fbs.getWritten());
}

test "convert to JSON: string" {
    var p = Parser.init(testing.allocator, .{});

    const s =
        \\> this is a
        \\> multiline
        \\> string
    ;

    var tree = try p.parse(s);
    defer tree.deinit();

    var json_tree = try tree.root.?.toJson(testing.allocator);
    defer json_tree.deinit();

    var buffer: [128]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    try json_tree.root.jsonStringify(.{}, fbs.writer());
    try testing.expectEqualStrings("\"this is a\\nmultiline\\nstring\"", fbs.getWritten());
}

test "convert to JSON: list" {
    var p = Parser.init(testing.allocator, .{});

    const s =
        \\- foo
        \\- bar
    ;

    var tree = try p.parse(s);
    defer tree.deinit();

    var json_tree = try tree.root.?.toJson(testing.allocator);
    defer json_tree.deinit();

    var buffer: [128]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    try json_tree.root.jsonStringify(.{}, fbs.writer());
    const expected_json =
        \\["foo","bar"]
    ;
    try testing.expectEqualStrings(expected_json, fbs.getWritten());
}

test "convert to JSON: object" {
    var p = Parser.init(testing.allocator, .{});

    const s =
        \\foo: 1
        \\bar: False
    ;

    var tree = try p.parse(s);
    defer tree.deinit();

    var json_tree = try tree.root.?.toJson(testing.allocator);
    defer json_tree.deinit();

    var buffer: [128]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    try json_tree.root.jsonStringify(.{}, fbs.writer());
    // TODO: Order of objects not yet guaranteed.
    const expected_json =
        \\{"foo":"1","bar":"False"}
    ;
    try testing.expectEqualStrings(expected_json, fbs.getWritten());
}

test "convert to JSON: object inside object" {
    var p = Parser.init(testing.allocator, .{});

    const s =
        \\bar:
        \\  nest1: 1
        \\  nest2: 2
    ;

    var tree = try p.parse(s);
    defer tree.deinit();

    var json_tree = try tree.root.?.toJson(testing.allocator);
    defer json_tree.deinit();

    var buffer: [128]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    try json_tree.root.jsonStringify(.{}, fbs.writer());
    const expected_json =
        \\{"bar":{"nest1":"1","nest2":"2"}}
    ;
    try testing.expectEqualStrings(expected_json, fbs.getWritten());
}

test "convert to JSON: list inside object" {
    var p = Parser.init(testing.allocator, .{});

    const s =
        \\bar:
        \\  - nest1
        \\  - nest2
    ;

    var tree = try p.parse(s);
    defer tree.deinit();

    var json_tree = try tree.root.?.toJson(testing.allocator);
    defer json_tree.deinit();

    var buffer: [128]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    try json_tree.root.jsonStringify(.{}, fbs.writer());
    const expected_json =
        \\{"bar":["nest1","nest2"]}
    ;
    try testing.expectEqualStrings(expected_json, fbs.getWritten());
}

test "convert to JSON: multiline string inside object" {
    var p = Parser.init(testing.allocator, .{});

    const s =
        \\foo:
        \\  > multi
        \\  > line
    ;

    var tree = try p.parse(s);
    defer tree.deinit();

    var json_tree = try tree.root.?.toJson(testing.allocator);
    defer json_tree.deinit();

    var buffer: [128]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    try json_tree.root.jsonStringify(.{}, fbs.writer());
    const expected_json =
        \\{"foo":"multi\nline"}
    ;
    try testing.expectEqualStrings(expected_json, fbs.getWritten());
}

test "convert to JSON: multiline string inside list" {
    var p = Parser.init(testing.allocator, .{});

    const s =
        \\-
        \\  > multi
        \\  > line
        \\-
    ;

    var tree = try p.parse(s);
    defer tree.deinit();

    var json_tree = try tree.root.?.toJson(testing.allocator);
    defer json_tree.deinit();

    var buffer: [128]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    try json_tree.root.jsonStringify(.{}, fbs.writer());
    const expected_json =
        \\["multi\nline",""]
    ;
    try testing.expectEqualStrings(expected_json, fbs.getWritten());
}
