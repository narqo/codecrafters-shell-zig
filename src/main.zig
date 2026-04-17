const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var writer = std.Io.File.stdout().writer(io, &.{});
    const stdout = &writer.interface;

    try stdout.writeAll("$ ");

    var buf: [1024]u8 = undefined;
    var reader = std.Io.File.stdin().reader(io, &buf);
    const stdin = &reader.interface;

    const cmd = try stdin.takeDelimiterExclusive('\n');

    try stdout.print("{s}: command not found\n", .{cmd});
    try stdout.flush();
}
