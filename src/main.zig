const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var file_writer = std.Io.File.stdout().writer(io, &.{});
    try file_writer.interface.writeAll("$ ");
}
