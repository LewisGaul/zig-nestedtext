const std = @import("std");
const testing = std.testing;

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
    Array: Array,
    Object: Map,
};

pub const Parser = struct {
    allocator: *Allocator,
    state: State,
    // Stores parent nodes and un-combined Values.
    stack: Array,

    const State = enum {
        String,
        ArrayValue,
        ObjectKey,
        ObjectValue,
    };

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

    pub fn init(allocator: *Allocator) Self {
        return .{
            .allocator = allocator,
            .state = .String,
            .stack = Array.init(allocator),
        };
    }

    pub fn deinit(p: *Self) void {
        p.stack.deinit();
    }

    pub fn parse(p: *Self, input: []const u8, options: ParseOptions) !ValueTree {
        var arena = ArenaAllocator.init(p.allocator);
        errdefer arena.deinit();

        var idx: usize = 0;
        var lineno: usize = 0;
        std.debug.print("\n", .{});
        while (p.readline(input[idx..])) |line| {
            idx += line.len;
            lineno += 1;
            std.debug.print("Line {}: {}", .{ lineno, line });
        }
        std.debug.print("\n", .{});

        // TODO

        return ValueTree{
            .arena = arena,
            .root = null,
        };
    }

    /// Return a slice corresponding to the first line of the given input,
    /// including the terminating newline character(s). If there is no terminating
    /// newline the entire input slice is returned. Returns null if the input is
    /// empty.
    fn readline(p: *Self, input: []const u8) ?[]const u8 {
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
};

test "basic parse" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();

    const s =
        \\ foo: 1
        \\ bar: False
    ;

    var tree = try p.parse(s, .{});
    defer tree.deinit();

    var root = tree.root;

    // const foo = root.Object.get("foo").?;
    // const bar = root.Object.get("bar").?;
    // testing.expectEqualSlices(foo, "1");
    // testing.expectEqualSlices(bar, "False");
}

// test "full parse" {
//     var p = Parser.init(testing.allocator);
//     defer p.deinit();

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

//     var tree = try p.parse(s, .{});
//     defer tree.deinit();

//     var root = tree.root;

//     const president = root.?.Object.get("president").?;

//     const name = president.Object.get("name").?;
//     testing.expectEqualSlices(name, "Katheryn McDaniel");
// }
