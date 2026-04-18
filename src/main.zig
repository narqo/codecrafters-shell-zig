const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var writer = std.Io.File.stdout().writer(io, &.{});
    const stdout = &writer.interface;

    var buf: [1024]u8 = undefined;
    var reader = std.Io.File.stdin().reader(io, &buf);
    const stdin = &reader.interface;

    while (true) {
        try stdout.writeAll("$ ");

        const line = try stdin.takeDelimiterInclusive('\n');
        const cmd = std.mem.trimEnd(u8, line, "\n");
        if (std.mem.eql(u8, cmd, "exit")) {
            break;
        }
        try stdout.print("{s}: command not found\n", .{cmd});
        try stdout.flush();
    }
}
