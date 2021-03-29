const std = @import("std");
const json = std.json;
const testing = std.testing;
const assert = std.debug.assert;

const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const ArrayList = std.ArrayList;
const StringHashMap = std.StringHashMap;
const Writer = std.io.Writer;

const clap = @import("clap");

// -----------------------------------------------------------------------------
// Types
// -----------------------------------------------------------------------------

pub const ValueTree = struct {
    arena: ArenaAllocator,
    root: ?Value,

    pub fn deinit(self: @This()) void {
        self.arena.deinit();
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

pub const Map = StringHashMap(Value);
pub const Array = ArrayList(Value);

pub const Value = union(enum) {
    String: []const u8,
    List: Array,
    Object: Map,

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
};

// -----------------------------------------------------------------------------
// Parsing logic
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
            if (input.len >= idx and input[idx] == '\n') idx += 1;
            break;
        }
        idx += 1;
    }
    return input[0..idx];
}

pub const Parser = struct {
    allocator: *Allocator,
    options: ParseOptions,

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

    const LineType = enum {
        Blank,
        Comment,
        String,
        List,
        Object,
        Unrecognised,
    };

    const Line = struct {
        text: []const u8,
        lineno: usize,
        kind: LineType,
        depth: ?usize,
        key: ?[]const u8,
        value: ?[]const u8,
    };

    const LinesIter = struct {
        next_idx: usize,
        lines: ArrayList(Line),

        pub fn init(lines: ArrayList(Line)) LinesIter {
            var self = LinesIter{ .next_idx = 0, .lines = lines };
            self.skipIgnorableLines();
            return self;
        }

        pub fn peekNext(self: LinesIter) ?Line {
            if (self.next_idx >= self.len()) return null;
            return self.lines.items[self.next_idx];
        }

        pub fn next(self: *LinesIter) ?Line {
            if (self.next_idx >= self.len()) return null;
            const line = self.lines.items[self.next_idx];
            self.advanceToNextContentLine();
            return line;
        }

        fn len(self: LinesIter) usize {
            return self.lines.items.len;
        }

        fn advanceToNextContentLine(self: *LinesIter) void {
            self.next_idx += 1;
            self.skipIgnorableLines();
        }

        fn skipIgnorableLines(self: *LinesIter) void {
            while (self.next_idx < self.len()) {
                switch (self.lines.items[self.next_idx].kind) {
                    .Blank, .Comment => self.next_idx += 1,
                    else => return,
                }
            }
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
        var tree = ValueTree{
            .arena = ArenaAllocator.init(p.allocator),
            .root = null,
        };
        errdefer tree.deinit();

        // TODO: This should be an iterator, i.e. don't loop over all lines
        //       up front (unnecessary performance and memory cost). We should
        //       only need access to the current (and next?) line.
        //       Note that it's only the struct instances that are allocated,
        //       the string slices are from the input and owned by the caller.
        const lines = try p.parseLines(input);
        defer lines.deinit();

        var iter = LinesIter.init(lines);

        if (iter.peekNext() != null)
            tree.root = try p.readValue(&tree.arena.allocator, &iter); // Recursively parse

        return tree;
    }

    /// Split the given input into an array of lines, where each entry is a
    /// struct instance containing relevant info.
    fn parseLines(p: Self, input: []const u8) !ArrayList(Line) {
        var lines_array = ArrayList(Line).init(p.allocator);
        var buf_idx: usize = 0;
        var lineno: usize = 0;
        std.debug.print("\n", .{});
        while (readline(input[buf_idx..])) |full_line| {
            buf_idx += full_line.len;
            const text = std.mem.trimRight(u8, full_line, &[_]u8{ '\n', '\r' });
            lineno += 1;
            var kind: LineType = undefined;
            var depth: ?usize = undefined;
            var key: ?[]const u8 = null;
            var value: ?[]const u8 = null;

            std.debug.print("Line {}: {s}\n", .{ lineno, text });

            // TODO: Check leading space is entirely made up of space characters.
            const stripped = std.mem.trimLeft(u8, text, &[_]u8{ ' ', '\t' });
            depth = text.len - stripped.len;
            if (stripped.len == 0) {
                kind = .Blank;
                depth = null;
            } else if (stripped[0] == '#') {
                kind = .Comment;
            } else if (std.mem.startsWith(u8, stripped, "- ")) {
                kind = .List;
                value = stripped[2..];
            } else if (std.mem.startsWith(u8, stripped, "> ")) {
                kind = .String;
                value = full_line[text.len - stripped.len + 2 ..];
            } else if (parseObject(stripped)) |result| {
                kind = .Object;
                key = result[0];
                value = result[1];
            } else {
                kind = .Unrecognised;
            }
            try lines_array.append(Line{
                .text = text,
                .lineno = lineno,
                .kind = kind,
                .depth = depth,
                .key = key,
                .value = value,
            });
        }
        std.debug.print("\n", .{});
        return lines_array;
    }

    fn parseObject(text: []const u8) ?[2][]const u8 {
        // TODO: Handle edge cases!
        for (text) |char, i| {
            if (char == ' ') return null;
            if (char == ':') {
                if (text[i + 1] != ' ') return null;
                return [_][]const u8{ text[0..i], text[i + 2 ..] };
            }
        }
        return null;
    }

    fn readValue(p: Self, allocator: *Allocator, lines: *LinesIter) !Value {
        // Call read<type>() with the first line of the type queued up as the
        // next line in the lines iterator.
        return switch (lines.peekNext().?.kind) {
            .String => .{ .String = try p.readString(allocator, lines) },
            .List => .{ .List = try p.readList(allocator, lines) },
            .Object => .{ .Object = try p.readObject(allocator, lines) },
            .Unrecognised => return error.UnrecognisedLine,
            .Blank, .Comment => unreachable,
        };
    }

    fn readString(p: Self, allocator: *Allocator, lines: *LinesIter) ![]const u8 {
        var buffer = ArrayList(u8).init(allocator);
        errdefer buffer.deinit();
        var writer = buffer.writer();

        assert(lines.peekNext().?.kind == .String);
        const depth = lines.peekNext().?.depth.?;

        while (lines.next()) |line| {
            if (line.kind != .String) return error.InvalidItem;
            if (line.depth.? > depth) return error.InvalidIndentation;
            if (line.depth.? < depth) break;
            // String copied as it's not contiguous in-file.
            try writer.writeAll(line.value.?);
        }
        return buffer.items;
    }

    fn readList(p: Self, allocator: *Allocator, lines: *LinesIter) !Array {
        var array = Array.init(allocator);
        errdefer array.deinit();

        assert(lines.peekNext().?.kind == .List);
        const depth = lines.peekNext().?.depth.?;

        while (lines.next()) |line| {
            if (line.kind != .List) return error.InvalidItem;
            if (line.depth.? > depth) return error.InvalidIndentation;
            if (line.depth.? < depth) break;
            try array.append(
                .{ .String = try p.maybeDupString(allocator, line.value.?) },
            );
        }
        return array;
    }

    fn readObject(p: Self, allocator: *Allocator, lines: *LinesIter) !Map {
        var map = Map.init(allocator);
        errdefer map.deinit();

        assert(lines.peekNext().?.kind == .Object);
        const depth = lines.peekNext().?.depth.?;

        while (lines.next()) |line| {
            if (line.kind != .Object) return error.InvalidItem;
            if (line.depth.? > depth) return error.InvalidIndentation;
            if (line.depth.? < depth) break;
            try map.put(
                try p.maybeDupString(allocator, line.key.?),
                .{ .String = try p.maybeDupString(allocator, line.value.?) },
            );
        }
        return map;
    }

    fn maybeDupString(p: Self, allocator: *Allocator, string: []const u8) ![]const u8 {
        return if (p.options.copy_strings) try allocator.dupe(u8, string) else string;
    }
};

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

test "parse empty" {
    var p = Parser.init(testing.allocator, .{});

    var tree = try p.parse("");
    defer tree.deinit();

    testing.expectEqual(@as(?Value, null), tree.root);
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

    var root: Value = tree.root.?;
    var string: []const u8 = root.String;

    testing.expectEqualStrings("this is a\nmultiline\nstring", string);
}

test "basic parse: list" {
    var p = Parser.init(testing.allocator, .{});

    const s =
        \\ - foo
        \\ - bar
    ;

    var tree = try p.parse(s);
    defer tree.deinit();

    var root: Value = tree.root.?;
    var array: Array = root.List;

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

    var root: Value = tree.root.?;
    var map: Map = root.Object;

    testing.expectEqualStrings("1", map.get("foo").?.String);
    testing.expectEqualStrings("False", map.get("bar").?.String);
}

test "convert to JSON: empty" {
    var p = Parser.init(testing.allocator, .{});

    var tree = try p.parse("");
    defer tree.deinit();

    var json_tree = try tree.toJson(testing.allocator);
    defer json_tree.deinit();

    var buffer: [128]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    try json_tree.root.jsonStringify(.{}, fbs.outStream());
    testing.expectEqualStrings("null", fbs.getWritten());
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

    var json_tree = try tree.toJson(testing.allocator);
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

    var json_tree = try tree.toJson(testing.allocator);
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

    var json_tree = try tree.toJson(testing.allocator);
    defer json_tree.deinit();

    var buffer: [128]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    try json_tree.root.jsonStringify(.{}, fbs.outStream());
    const expected_json =
        \\{"foo":"1","bar":"False"}
    ;
    testing.expectEqualStrings(expected_json, fbs.getWritten());
}

// -----------------------------------------------------------------------------
// Main
// -----------------------------------------------------------------------------

pub fn main() void {
    std.debug.print("{}", .{clap});
}
