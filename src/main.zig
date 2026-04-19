const std = @import("std");

const builtins = &[_][]const u8{
    "cd",
    "echo",
    "exit",
    "type",
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

        const cmd, const args = blk: {
            if (std.mem.cutScalar(u8, line, ' ')) |pair| {
                break :blk pair;
            } else {
                break :blk .{ line, "" };
            }
        };

        if (std.mem.eql(u8, cmd, "exit")) {
            break;
        } else if (std.mem.eql(u8, cmd, "echo")) {
            try stdout.print("{s}\n", .{args});
        } else if (std.mem.eql(u8, cmd, "type")) {
            for (builtins) |c| {
                if (std.mem.eql(u8, c, args)) {
                    try stdout.print("{s} is a shell builtin\n", .{args});
                    break;
                }
            } else {
                try stdout.print("{s}: not found\n", .{args});
            }
        } else {
            try stdout.print("{s}: command not found\n", .{line});
        }
        try stdout.flush();
    }
}
