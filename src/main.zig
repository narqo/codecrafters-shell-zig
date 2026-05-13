const std = @import("std");

const args = @import("args.zig");

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

    var stdin_reader_buf: [1024]u8 = undefined;
    var reader = std.Io.File.stdin().reader(io, &stdin_reader_buf);
    const stdin = &reader.interface;

    var args_buf: [1024]u8 = undefined;
    var args_parser = args.parser(&args_buf);

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

        try stdout.writeAll("$ ");
        defer stdout.flush() catch unreachable; // runtime panic on failure

        const raw_cmd_line = try stdin.takeDelimiterExclusive('\n');
        stdin.toss(1); // advance and discard the new line

        if (raw_cmd_line.len == 0) continue;

        const parsed_args = try args_parser.parse(alloc, raw_cmd_line);
        defer alloc.free(parsed_args);

        const cmd_str = parsed_args[0];
        const argv = if (parsed_args.len > 1) parsed_args[1..] else &.{};

        if (Cmd.fromString(cmd_str)) |cmd| {
            switch (cmd) {
                .exit => return,

                .cd => try execCd(ctx, stdout, argv),
                .echo => try execEcho(ctx, stdout, argv),
                .pwd => try execPwd(ctx, stdout, argv),
                .type => try execType(ctx, stdout, argv),
            }
            continue;
        }

        const path_env = ctx.environ.get("PATH") orelse "";

        if (findExecutable(ctx.alloc, ctx.io, ctx.cwd, path_env, cmd_str)) |exe_path| {
            var args_list: std.ArrayList([]const u8) = .empty;
            defer args_list.deinit(ctx.alloc);

            try args_list.append(ctx.alloc, exe_path);
            try args_list.appendSlice(ctx.alloc, argv);

            var child = try std.process.spawn(ctx.io, .{
                .argv = args_list.items,
            });
            defer child.kill(ctx.io);

            const term = try child.wait(ctx.io);
            _ = term;
        } else |err| switch (err) {
            FindExecutableError.NotFound => try stdout.print("{s}: command not found\n", .{raw_cmd_line}),
            else => return err,
        }
    }
}

fn execEcho(ctx: Context, stdout: *std.Io.Writer, argv: []const []const u8) !void {
    const s = try std.mem.join(ctx.alloc, " ", argv);
    try stdout.print("{s}\n", .{s});
}

fn execType(ctx: Context, stdout: *std.Io.Writer, argv: []const []const u8) !void {
    const path_env = ctx.environ.get("PATH") orelse "";

    const cmd_name = try std.mem.join(ctx.alloc, " ", argv);
    if (Cmd.fromString(cmd_name)) |_| {
        try stdout.print("{s} is a shell builtin\n", .{cmd_name});
    } else if (findExecutable(ctx.alloc, ctx.io, ctx.cwd, path_env, cmd_name)) |exe_path| {
        try stdout.print("{s} is {s}\n", .{ cmd_name, exe_path });
    } else |err| switch (err) {
        FindExecutableError.NotFound => try stdout.print("{s}: not found\n", .{cmd_name}),
        else => return err,
    }
}

fn execCd(ctx: Context, stdout: *std.Io.Writer, argv: []const []const u8) !void {
    if (argv.len != 1) {
        try stdout.print("Too many args for cd command\n", .{});
        return;
    }

    const target_path = argv[0];
    const path = try expandPath(ctx.alloc, ctx.environ, target_path);
    std.process.setCurrentPath(ctx.io, path) catch |err| switch (err) {
        std.process.SetCurrentPathError.FileNotFound => try stdout.print("cd {s}: No such file or directory\n", .{target_path}),
        else => return err,
    };
}

fn execPwd(ctx: Context, stdout: *std.Io.Writer, _: []const []const u8) !void {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try std.process.currentPath(ctx.io, &buf);
    try stdout.print("{s}\n", .{buf[0..n]});
}

const FindExecutableError = error{NotFound};

fn findExecutable(alloc: std.mem.Allocator, io: std.Io, cwd: std.Io.Dir, path_env: []const u8, cmd_name: []const u8) ![]const u8 {
    var paths_iter = std.mem.splitScalar(u8, path_env, std.fs.path.delimiter);
    while (paths_iter.next()) |path_str| {
        if (path_str.len == 0) continue;

        const exe_path = try std.fs.path.join(alloc, &[_][]const u8{ path_str, cmd_name });
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
