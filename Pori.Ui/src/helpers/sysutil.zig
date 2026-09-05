const std = @import("std");
const posix = std.posix;

extern "c" fn fork() c_int;
extern "c" fn waitpid(pid: c_int, status: *c_int, options: c_int) c_int;
extern "c" fn execv(path: [*:0]const u8, argv: [*]const ?[*:0]const u8) c_int;
extern "c" fn pipe(fds: *[2]c_int) c_int;
extern "c" fn dup2(old: c_int, new: c_int) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
extern "c" fn unlink(path: [*:0]const u8) c_int;
extern "c" fn open(path: [*:0]const u8, flags: c_int, mode: c_int) c_int;
extern "c" fn system(cmd: [*:0]const u8) c_int;

const O_RDONLY = 0o0;
const O_WRONLY = 0o1;
const O_CREAT = 0o100;
const O_TRUNC = 0o1000;

pub const ExecResult = struct {
    exit_code: i32,
    output: []const u8,
    err: []const u8,
};

pub fn runCommand(arena: std.mem.Allocator, argv: []const []const u8) !ExecResult {
    var path_buf: [posix.PATH_MAX:0]u8 = undefined;
    const prog = if (argv.len > 0 and argv[0].len < path_buf.len) blk: {
        @memcpy(path_buf[0..argv[0].len], argv[0]);
        path_buf[argv[0].len] = 0;
        break :blk path_buf[0..argv[0].len :0];
    } else return error.PathTooLong;

    var out_fds: [2]c_int = undefined;
    var err_fds: [2]c_int = undefined;
    if (pipe(&out_fds) != 0) return error.SpawnFailed;
    if (pipe(&err_fds) != 0) {
        _ = close(out_fds[0]);
        _ = close(out_fds[1]);
        return error.SpawnFailed;
    }

    const pid = fork();
    if (pid < 0) return error.SpawnFailed;
    if (pid == 0) {
        _ = dup2(out_fds[1], posix.STDOUT_FILENO);
        _ = dup2(err_fds[1], posix.STDERR_FILENO);
        _ = close(out_fds[0]);
        _ = close(out_fds[1]);
        _ = close(err_fds[0]);
        _ = close(err_fds[1]);

        const argv_c = arena.alloc(?[*:0]const u8, argv.len + 1) catch std.process.exit(127);
        for (argv, 0..) |arg, i| {
            argv_c[i] = arena.dupeZ(u8, arg) catch std.process.exit(127);
        }
        argv_c[argv.len] = null;
        _ = execv(prog.ptr, argv_c.ptr);
        std.process.exit(127);
    }

    _ = close(out_fds[1]);
    _ = close(err_fds[1]);

    var stdout: std.ArrayList(u8) = .empty;
    var stderr: std.ArrayList(u8) = .empty;

    var fds = [2]posix.pollfd{
        .{ .fd = out_fds[0], .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = err_fds[0], .events = posix.POLL.IN, .revents = 0 },
    };
    var open_count: usize = 2;
    var buf: [4096]u8 = undefined;
    while (open_count > 0) {
        _ = posix.poll(&fds, -1) catch break;
        for (&fds, 0..) |*pfd, idx| {
            if (pfd.fd < 0 or pfd.revents == 0) continue;
            const n = posix.read(pfd.fd, &buf) catch 0;
            if (n > 0) {
                const target = if (idx == 0) &stdout else &stderr;
                target.appendSlice(arena, buf[0..n]) catch {};
            } else {
                _ = close(pfd.fd);
                pfd.fd = -1;
                open_count -= 1;
            }
        }
    }
    _ = close(out_fds[0]);
    _ = close(err_fds[0]);

    var status: c_int = 0;
    _ = waitpid(pid, &status, 0);
    const exit_code: i32 = if (posix.W.IFEXITED(@bitCast(status)))
        @intCast(posix.W.EXITSTATUS(@bitCast(status)))
    else
        -1;

    return .{ .exit_code = exit_code, .output = stdout.items, .err = stderr.items };
}

pub fn readFileAlloc(arena: std.mem.Allocator, path: []const u8) ?[]const u8 {
    var path_z: [posix.PATH_MAX:0]u8 = undefined;
    if (path.len >= path_z.len) return null;
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;

    const fd = open(path_z[0..path.len :0].ptr, O_RDONLY, 0);
    if (fd < 0) return null;
    defer _ = close(fd);

    var out: std.ArrayList(u8) = .empty;
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = posix.read(fd, &buf) catch break;
        if (n == 0) break;
        out.appendSlice(arena, buf[0..n]) catch break;
        if (out.items.len > 1 << 20) break;
    }
    return out.items;
}

pub fn writeFile(path: []const u8, content: []const u8) !void {
    var path_z: [posix.PATH_MAX:0]u8 = undefined;
    if (path.len >= path_z.len) return error.NameTooLong;
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;

    const fd = open(path_z[0..path.len :0].ptr, O_WRONLY | O_CREAT | O_TRUNC, 0o600);
    if (fd < 0) return error.OpenFailed;
    defer _ = close(fd);

    var written: usize = 0;
    while (written < content.len) {
        const n = write(fd, content.ptr + written, content.len - written);
        if (n <= 0) return error.WriteFailed;
        written += @intCast(n);
    }
}

pub fn deleteFile(path: []const u8) void {
    var path_z: [posix.PATH_MAX:0]u8 = undefined;
    if (path.len >= path_z.len) return;
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;
    _ = unlink(path_z[0..path.len :0].ptr);
}

pub fn listDir(arena: std.mem.Allocator, path: []const u8) ![][]const u8 {
    var path_z: [posix.PATH_MAX:0]u8 = undefined;
    if (path.len >= path_z.len) return error.NameTooLong;
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;

    var out: std.ArrayList([]const u8) = .empty;
    const dir = std.c.opendir(path_z[0..path.len :0].ptr) orelse return out.items;
    defer _ = std.c.closedir(dir);
    while (true) {
        std.c._errno().* = 0;
        const entry = std.c.readdir(dir) orelse break;
        const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&entry.name)), 0);
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        if (entry.type != std.c.DT.REG and entry.type != std.c.DT.UNKNOWN) continue;
        try out.append(arena, try arena.dupe(u8, name));
    }
    return out.items;
}

test "writeFile and readFileAlloc round-trip" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const path = "/tmp/pori-sysutil-test.txt";
    try writeFile(path, "hello pori");
    defer deleteFile(path);
    const content = readFileAlloc(arena.allocator(), path) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("hello pori", content);
}

test "listDir finds files in a directory" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    // Build a temp directory with a couple of known files.
    const rc = system("rm -rf /tmp/pori-listdir-test && mkdir -p /tmp/pori-listdir-test && touch /tmp/pori-listdir-test/a.mount /tmp/pori-listdir-test/b.txt");
    try std.testing.expectEqual(@as(c_int, 0), rc);
    defer _ = system("rm -rf /tmp/pori-listdir-test");

    const entries = try listDir(arena.allocator(), "/tmp/pori-listdir-test");
    try std.testing.expectEqual(@as(usize, 2), entries.len);
}

test "runCommand captures output" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const res = try runCommand(arena.allocator(), &.{ "/usr/bin/echo", "hi" });
    try std.testing.expectEqual(@as(i32, 0), res.exit_code);
    try std.testing.expectEqualStrings("hi\n", res.output);
}
