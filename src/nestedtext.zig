const std = @import("std");
const testing = std.testing;
const assert = std.debug.assert;

const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const ArrayList = std.ArrayList;
const StringHashMap = std.StringHashMap;

pub const ValueTree = struct {
    arena: ArenaAllocator,
    root: ?Value,

    pub fn deinit(self: *ValueTree) void {
        self.arena.deinit();
    }
};

pub const Map = StringHashMap(Value);
pub const Array = ArrayList(Value);

pub const Value = union(enum) {
    String: []const u8,
    List: Array,
    Object: Map,
};

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

    pub fn deinit(p: Self) void {}

    pub fn parse(p: Self, input: []const u8) !ValueTree {
        var arena = ArenaAllocator.init(p.allocator);
        errdefer arena.deinit();

        // TODO: This should be an iterator, i.e. don't loop over all lines
        //       up front (unnecessary performance and memory cost). We should
        //       only need access to the current (and next?) line.
        const lines = try p.parseLines(input);
        defer lines.deinit();

        var iter = LinesIter.init(lines);

        if (iter.peekNext() == null) return ValueTree{ .arena = arena, .root = null };

        return ValueTree{ .arena = arena, .root = try p.readValue(&iter) };
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

            std.debug.print("Line {}: {}\n", .{ lineno, text });

            // TODO: Check leading space is entirely made up of space characters.
            const stripped = std.mem.trimLeft(u8, text, &[_]u8{ ' ', '\t' });
            depth = text.len - stripped.len;
            if (stripped.len == 0) {
                kind = .Blank;
                depth = null;
            } else if (stripped[0] == '#') {
                kind = .Comment;
            } else if (stripped[0] == '-') { // TODO: Handle expected space
                kind = .List;
                value = stripped[2..];
            } else if (stripped[0] == '>') { // TODO: Handle expected space
                kind = .String;
                value = stripped[2..];
            } else if (false) { // TODO: Handle objects
                kind = .Object;
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

    fn readValue(p: Self, lines: *LinesIter) !Value {
        // Call read<type>() with the iterator set up with the first line of the
        // type queued up as the next line.
        return switch (lines.peekNext().?.kind) {
            .String => .{ .String = try p.readString(lines) },
            .List => .{ .List = try p.readList(lines) },
            .Object => .{ .Object = try p.readObject(lines) },
            .Unrecognised => return error.UnrecognisedLine,
            .Blank, .Comment => unreachable,
        };
    }

    fn readString(p: Self, lines: *LinesIter) ![]const u8 {
        // TODO
        return error.NotImplemented;
    }

    fn readList(p: Self, lines: *LinesIter) !Array {
        var array = Array.init(p.allocator);

        assert(lines.peekNext().?.kind == .List);
        const depth = lines.peekNext().?.depth.?;

        while (lines.peekNext() != null) {
            const line = lines.next().?;
            if (line.kind != .List) return error.InvalidListItem;
            if (line.depth.? > depth) return error.InvalidListIndentation;
            if (line.depth.? < depth) break;
            // TODO: Check whether string should be copied.
            try array.append(.{ .String = line.value.? });
        }
        return array;
    }

    fn readObject(p: Self, lines: *LinesIter) !Map {
        // TODO
        return error.NotImplemented;
    }
};

test "basic list parse" {
    var p = Parser.init(testing.allocator, .{});
    defer p.deinit();

    const s =
        \\ - foo
        \\ - bar
    ;

    var tree = try p.parse(s);
    defer tree.deinit();

    var root: Value = tree.root.?;
    var array: Array = root.List;

    var foo: []const u8 = array.items[0].String;
    var bar: []const u8 = array.items[1].String;

    testing.expectEqualStrings("foo", foo);
    testing.expectEqualStrings("bar", bar);
}

test "basic string parse" {
    var p = Parser.init(testing.allocator, .{});
    defer p.deinit();

    const s =
        \\ > this is a
        \\ > multiline
        \\ > string
    ;

    var tree = try p.parse(s);
    defer tree.deinit();

    var root = tree.root;
}

// test "basic object parse" {
//     var p = Parser.init(testing.allocator, .{});
//     defer p.deinit();
//
//     const s =
//         \\ foo: 1
//         \\ bar: False
//     ;
//
//     var tree = try p.parse(s);
//     defer tree.deinit();
//
//     var root = tree.root;

//     // const foo = root.Object.get("foo").?;
//     // const bar = root.Object.get("bar").?;
//     // testing.expectEqualSlices(foo, "1");
//     // testing.expectEqualSlices(bar, "False");
// }

// test "full parse" {
//     var p = Parser.init(testing.allocator);
//     defer p.deinit();
//
//     const s =
//         \\ # Contact information for our officers
//         \\
//         \\ president:
//         \\     name: Katheryn McDaniel
//         \\     address:
//         \\         > 138 Almond Street
//         \\         > Topeka, Kansas 20697
//         \\     phone:
//         \\         cell: 1-210-555-5297
//         \\         home: 1-210-555-8470
//         \\     email: KateMcD@aol.com
//         \\     additional roles:
//         \\         - board member
//         \\
//         \\ vice president:
//         \\     name: Margaret Hodge
//         \\     address:
//         \\         > 2586 Marigold Lane
//         \\         > Topeka, Kansas 20682
//         \\     phone: 1-470-555-0398
//         \\     email: margaret.hodge@ku.edu
//         \\     additional roles:
//         \\         - new membership task force
//         \\         - accounting task force
//         \\
//         \\ treasurer:
//         \\     name: Fumiko Purvis
//         \\         # Fumiko's term is ending at the end of the year.
//         \\         # She will be replaced by Merrill Eldridge.
//         \\     address:
//         \\         > 3636 Buffalo Ave
//         \\         > Topeka, Kansas 20692
//         \\     phone: 1-268-555-0280
//         \\     email: fumiko.purvis@hotmail.com
//         \\     additional roles:
//         \\         - accounting task force
//         ;
//
//     var tree = try p.parse(s, .{});
//     defer tree.deinit();
//
//     var root = tree.root;
//
//     const president = root.?.Object.get("president").?;
//
//     const name = president.Object.get("name").?;
//     testing.expectEqualSlices(name, "Katheryn McDaniel");
// }
