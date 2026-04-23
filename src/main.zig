const std = @import("std");
const Allocator = std.mem.Allocator;

const builtins = &[_][]const u8{
    "cd",
    "echo",
    "exit",
    "pwd",
    "type",
};

const Cmd = enum {
    cd,
    echo,
    exit,
    pwd,
    type,

    fn fromString(str: []const u8) ?Cmd {
        return std.meta.stringToEnum(Cmd, str);
    }
};

const Context = struct {
    gpa: Allocator,
    io: std.Io,

    cwd: std.Io.Dir,
    environ_map: *std.process.Environ.Map,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var writer = std.Io.File.stdout().writer(io, &.{});
    const stdout = &writer.interface;

    var buf: [1024]u8 = undefined;
    var reader = std.Io.File.stdin().reader(io, &buf);
    const stdin = &reader.interface;

    const ctx = Context{
        .gpa = init.gpa,
        .io = io,
        .environ_map = init.environ_map,
        .cwd = std.Io.Dir.cwd(),
    };

    while (true) {
        try runLoop(ctx, stdin, stdout);
    }
}

fn runLoop(ctx: Context, stdin: *std.Io.Reader, stdout: *std.Io.Writer) !void {
    try stdout.writeAll("$ ");
    defer stdout.flush() catch unreachable; // runtime panic on failure

    const line = try stdin.takeDelimiterExclusive('\n');
    stdin.toss(1); // advance and discard the new line

    const cmd_str, const args = blk: {
        if (std.mem.cutScalar(u8, line, ' ')) |pair| {
            break :blk pair;
        } else {
            break :blk .{ line, "" };
        }
    };

    var arena = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena.deinit();

    const alloc = arena.allocator();

    const path_env = ctx.environ_map.get("PATH") orelse "";

    if (Cmd.fromString(cmd_str)) |cmd| {
        switch (cmd) {
            .exit => return,
            .echo => {
                try stdout.print("{s}\n", .{args});
            },
            .type => {
                if (Cmd.fromString(args)) |_| {
                    try stdout.print("{s} is a shell builtin\n", .{args});
                } else if (findExecutable(alloc, ctx.io, ctx.cwd, path_env, args)) |exe_path| {
                    try stdout.print("{s} is {s}\n", .{ args, exe_path });
                } else |err| switch (err) {
                    FindError.NotFound => try stdout.print("{s}: not found\n", .{args}),
                    else => return err,
                }
            },
            .cd => {
                std.process.setCurrentPath(ctx.io, args) catch |err| switch (err) {
                    std.process.SetCurrentPathError.FileNotFound => try stdout.print("cd {s}: No such file or directory\n", .{args}),
                    else => return err,
                };
            },
            .pwd => {
                var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
                const n = try std.process.currentPath(ctx.io, &buf);
                try stdout.print("{s}\n", .{buf[0..n]});
            },
        }
    } else if (findExecutable(alloc, ctx.io, ctx.cwd, path_env, cmd_str)) |exe_path| {
        var args_list: std.ArrayList([]const u8) = .empty;
        defer args_list.deinit(alloc);

        try args_list.append(alloc, exe_path);

        var it = try std.process.Args.IteratorGeneral(.{}).init(alloc, args);
        defer it.deinit();
        while (it.next()) |arg| {
            try args_list.append(alloc, arg);
        }

        var child = try std.process.spawn(ctx.io, .{
            .argv = args_list.items,
        });
        defer child.kill(ctx.io);

        const term = try child.wait(ctx.io);
        _ = term;
    } else |err| switch (err) {
        FindError.NotFound => try stdout.print("{s}: command not found\n", .{line}),
        else => return err,
    }
}

const FindError = error{NotFound};

fn findExecutable(alloc: std.mem.Allocator, io: std.Io, cwd: std.Io.Dir, path_env: []const u8, args: []const u8) ![]const u8 {
    var paths_iter = std.mem.splitScalar(u8, path_env, std.fs.path.delimiter);
    while (paths_iter.next()) |path_str| {
        if (path_str.len == 0) continue;

        const exe_path = try std.fs.path.join(alloc, &[_][]const u8{ path_str, args });
        defer alloc.free(exe_path);

        const exe_stat = cwd.statFile(io, exe_path, .{}) catch continue; // ignore any errors and move on
        if ((exe_stat.permissions.toMode() & std.posix.X_OK) != 0) {
            return alloc.dupe(u8, exe_path);
        }
    }
    return FindError.NotFound;
}
