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
    alloc: Allocator,
    io: std.Io,

    cwd: std.Io.Dir,
    environ: *std.process.Environ.Map,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var writer = std.Io.File.stdout().writer(io, &.{});
    const stdout = &writer.interface;

    var buf: [1024]u8 = undefined;
    var reader = std.Io.File.stdin().reader(io, &buf);
    const stdin = &reader.interface;

    while (true) {
        var arena = std.heap.ArenaAllocator.init(init.gpa);
        defer arena.deinit();

        const alloc = arena.allocator();

        const ctx = Context{
            .alloc = alloc,
            .io = io,
            .environ = init.environ_map,
            .cwd = std.Io.Dir.cwd(),
        };

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

    const path_env = ctx.environ.get("PATH") orelse "";

    if (Cmd.fromString(cmd_str)) |cmd| {
        switch (cmd) {
            .exit => return,
            .echo => {
                try stdout.print("{s}\n", .{args});
            },
            .type => {
                if (Cmd.fromString(args)) |_| {
                    try stdout.print("{s} is a shell builtin\n", .{args});
                } else if (findExecutable(ctx.alloc, ctx.io, ctx.cwd, path_env, args)) |exe_path| {
                    try stdout.print("{s} is {s}\n", .{ args, exe_path });
                } else |err| switch (err) {
                    FindExecutableError.NotFound => try stdout.print("{s}: not found\n", .{args}),
                    else => return err,
                }
            },
            .cd => try execCd(ctx, stdout, args),
            .pwd => try execPwd(ctx, stdout, args),
        }
    } else if (findExecutable(ctx.alloc, ctx.io, ctx.cwd, path_env, cmd_str)) |exe_path| {
        var args_list: std.ArrayList([]const u8) = .empty;
        defer args_list.deinit(ctx.alloc);

        try args_list.append(ctx.alloc, exe_path);

        var it = try std.process.Args.IteratorGeneral(.{}).init(ctx.alloc, args);
        defer it.deinit();
        while (it.next()) |arg| {
            try args_list.append(ctx.alloc, arg);
        }

        var child = try std.process.spawn(ctx.io, .{
            .argv = args_list.items,
        });
        defer child.kill(ctx.io);

        const term = try child.wait(ctx.io);
        _ = term;
    } else |err| switch (err) {
        FindExecutableError.NotFound => try stdout.print("{s}: command not found\n", .{line}),
        else => return err,
    }
}

fn execCd(ctx: Context, stdout: *std.Io.Writer, args: []const u8) !void {
    const path = try expandPath(ctx.alloc, ctx.environ, args);
    std.process.setCurrentPath(ctx.io, path) catch |err| switch (err) {
        std.process.SetCurrentPathError.FileNotFound => try stdout.print("cd {s}: No such file or directory\n", .{args}),
        else => return err,
    };
}

fn execPwd(ctx: Context, stdout: *std.Io.Writer, _: []const u8) !void {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try std.process.currentPath(ctx.io, &buf);
    try stdout.print("{s}\n", .{buf[0..n]});
}

const FindExecutableError = error{NotFound};

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
    return FindExecutableError.NotFound;
}

fn expandPath(alloc: std.mem.Allocator, environ: *std.process.Environ.Map, path: []const u8) ![]u8 {
    if (path.len == 0 or path[0] != '~') {
        return alloc.dupe(u8, path);
    }

    var user_home: ?[]const u8 = null;
    var path_tail = path[1..];
    if (path_tail.len == 0 or path_tail[0] == '/') {
        user_home = environ.get("HOME");
    }

    if (user_home == null) {
        var user, path_tail = blk: {
            if (std.mem.findScalar(u8, path_tail, '/')) |pos| {
                break :blk .{ path_tail[0..pos], path_tail[pos + 1 ..] };
            } else {
                break :blk .{ path_tail, "" };
            }
        };
        if (user.len == 0) {
            user = environ.get("USER") orelse return error.UserNotFound;
        }
        const userZ = try alloc.dupeSentinel(u8, user, 0);
        defer alloc.free(userZ);
        const pw = std.c.getpwnam(userZ) orelse return error.UserNotFound;
        user_home = if (pw.dir) |dir| std.mem.span(dir) else null;
    }

    return std.fs.path.join(alloc, &[_][]const u8{ user_home orelse unreachable, path_tail });
}

test "expandPath" {
    const testing = std.testing;

    const gpa = testing.allocator;

    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();

    try environ.put("HOME", "/home/user");

    {
        const expanded = try expandPath(gpa, &environ, "~");
        defer gpa.free(expanded);
        try testing.expectEqualStrings("/home/user", expanded);
    }
    {
        const expanded = try expandPath(gpa, &environ, "~/");
        defer gpa.free(expanded);
        try testing.expectEqualStrings("/home/user/", expanded);
    }
    // TODO
    // {
    //     var empty_environ = std.process.Environ.Map.init(gpa);
    //     defer empty_environ.deinit();

    //     const test_user_home = try testing.environ.getAlloc(gpa, "HOME");
    //     defer gpa.free(test_user_home);
    //     try testing.expect(test_user_home.len > 0);

    //     const expanded = try expandPath(gpa, &empty_environ, "~/");
    //     defer gpa.free(expanded);
    //     try testing.expectEqualStrings(test_user_home, expanded);
    // }
}
