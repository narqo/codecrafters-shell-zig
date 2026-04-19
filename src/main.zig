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
    const alloc = init.gpa;

    const cwd = std.Io.Dir.cwd();

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
                var found = false;
                if (Cmd.fromString(args)) |_| {
                    found = true;
                    try stdout.print("{s} is a shell builtin\n", .{args});
                } else if (init.environ_map.get("PATH")) |path_env| {
                    var paths_iter = std.mem.splitScalar(u8, path_env, std.fs.path.delimiter);
                    while (paths_iter.next()) |path_str| {
                        if (path_str.len == 0) continue;

                        const exe_path = try std.fs.path.join(alloc, &[_][]const u8{ path_str, args });
                        defer alloc.free(exe_path);

                        const exe_stat = cwd.statFile(io, exe_path, .{}) catch continue; // ignore any errors and move on
                        if ((exe_stat.permissions.toMode() & std.posix.X_OK) != 0) {
                            found = true;
                            try stdout.print("{s} is {s}\n", .{ args, exe_path });
                            break;
                        }
                    }
                }
                if (!found) {
                    try stdout.print("{s}: not found\n", .{args});
                }
            },
        }

        try stdout.flush();
    }
}
