const std = @import("std");

pub fn parser(buffer: []u8) Parser {
    return .{
        .buffer = buffer,
    };
}

const Parser = struct {
    buffer: []u8,

    start: usize = 0,
    end: usize = 0,

    pub fn parse(self: *Parser, alloc: std.mem.Allocator, cmd_line: []const u8) ![][]const u8 {
        // cursor into the cmd_line
        var seek: usize = 0;

        var argv: std.ArrayList([]const u8) = .empty;

        self.start = 0;
        self.end = 0;

        while (seek != cmd_line.len) {
            // skip whitespaces
            while (true) : (seek += 1) {
                switch (cmd_line[seek]) {
                    ' ', '\t' => continue,
                    else => break,
                }
            }

            var is_inside_quote = false;
            while (true) : (seek += 1) {
                const ch = if (seek != cmd_line.len) cmd_line[seek] else break;
                switch (ch) {
                    '\'' => {
                        is_inside_quote = !is_inside_quote;
                    },
                    '\\' => {
                        // handle escaped
                    },
                    ' ', '\t', '\n' => {
                        if (!is_inside_quote) {
                            // token end?
                            try argv.append(alloc, self.buffer[self.start..self.end]);
                            self.end += 1;
                            self.start = self.end;
                            break;
                        }
                        self.buffer[self.end] = ' ';
                        self.end += 1;
                    },
                    else => {
                        self.buffer[self.end] = ch;
                        self.end += 1;
                    },
                }
            }

            if (self.end - self.start > 0) {
                try argv.append(alloc, self.buffer[self.start..self.end]);
                self.end += 1;
                self.start = self.end;
            }
        }

        // for (argv.items) |arg| {
        //     std.debug.print("|{s}|\n", .{arg});
        // }

        return try argv.toOwnedSlice(alloc);
    }
};

test parser {
    try testParser("echo hello world", &.{ "echo", "hello", "world" });
    try testParser("echo hello    world", &.{ "echo", "hello", "world" });

    try testParser("echo 'hello world'", &.{ "echo", "hello world" });
    try testParser("echo 'hello    world'", &.{ "echo", "hello    world" });

    // adjacent quoted strings are concatenated
    try testParser("echo 'hello''world'", &.{ "echo", "helloworld" });

    // empty quotes are ignored
    try testParser("echo hello''world", &.{ "echo", "helloworld" });
}

fn testParser(
    cmd_line: []const u8,
    expected_args: []const []const u8,
) !void {
    var buffer: [1024]u8 = undefined;
    var cmd_parser = parser(&buffer);

    const result = try cmd_parser.parse(std.testing.allocator, cmd_line);
    defer std.testing.allocator.free(result);

    for (expected_args, result) |exp, got| {
        try std.testing.expectEqualStrings(exp, got);
    }
}
