const std = @import("std");

const builtins = &[_][]const u8{
    "cd",
    "echo",
    "exit",
    "type",
};

const Cmd = enum {
    // cd,
    echo,
    exit,
    type,

    fn fromString(str: []const u8) ?Cmd {
        return std.meta.stringToEnum(Cmd, str);
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var writer = std.Io.File.stdout().writer(io, &.{});
    const stdout = &writer.interface;

    var buf: [1024]u8 = undefined;
    var reader = std.Io.File.stdin().reader(io, &buf);
    const stdin = &reader.interface;

    while (true) {
        try stdout.writeAll("$ ");

        const line = try stdin.takeDelimiterExclusive('\n');
        stdin.toss(1); // advance and discard the new line

        const cmd_str, const args = blk: {
            if (std.mem.cutScalar(u8, line, ' ')) |pair| {
                break :blk pair;
            } else {
                break :blk .{ line, "" };
            }
        };

        const cmd = Cmd.fromString(cmd_str) orelse {
            try stdout.print("{s}: command not found\n", .{line});
            try stdout.flush();
            continue;
        };

        switch (cmd) {
            .exit => break,
            .echo => {
                try stdout.print("{s}\n", .{args});
            },
            .type => {
                if (Cmd.fromString(args)) |_| {
                    try stdout.print("{s} is a shell builtin\n", .{args});
                } else {
                    try stdout.print("{s}: not found\n", .{args});
                }
            },
        }

        try stdout.flush();
    }
}
