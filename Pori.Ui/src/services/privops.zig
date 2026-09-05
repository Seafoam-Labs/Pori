const std = @import("std");
const unitname = @import("../helpers/unitname.zig");
const sysutil = @import("../helpers/sysutil.zig");

pub const OpResult = struct {
    ok: bool,

    cancelled: bool,
    output: []const u8,
    err: []const u8,
    exit_code: i32,
};

fn fromExec(res: sysutil.ExecResult) OpResult {
    return .{
        .ok = res.exit_code == 0,
        .cancelled = res.exit_code == 126,
        .output = res.output,
        .err = res.err,
        .exit_code = res.exit_code,
    };
}

pub fn runPrivileged(arena: std.mem.Allocator, argv: []const []const u8) !OpResult {
    var full = try arena.alloc([]const u8, argv.len + 1);
    full[0] = "/usr/bin/pkexec";
    @memcpy(full[1..], argv);
    return fromExec(try sysutil.runCommand(arena, full));
}

fn buildUnitContent(arena: std.mem.Allocator, description: []const u8, uuid: []const u8, mount_point: []const u8, fs_type: []const u8, options: []const u8) ![]const u8 {
    const path = if (std.mem.startsWith(u8, mount_point, "/")) mount_point else try std.fmt.allocPrint(arena, "/{s}", .{mount_point});
    return std.fmt.allocPrint(arena,
        \\[Unit]
        \\Description={s}
        \\
        \\[Mount]
        \\What=/dev/disk/by-uuid/{s}
        \\Where={s}
        \\Type={s}
        \\Options={s}
        \\
        \\[Install]
        \\WantedBy=multi-user.target
        \\
    , .{ description, uuid, path, fs_type, options });
}

var temp_counter: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

fn writeTempFile(arena: std.mem.Allocator, content: []const u8) ![]const u8 {
    const n = temp_counter.fetchAdd(1, .monotonic);
    const name = try std.fmt.allocPrint(arena, "/tmp/pori-{d}-{d}.mount.tmp", .{ std.os.linux.getpid(), n });
    sysutil.writeFile(name, content) catch return error.TempFileFailed;
    return name;
}

fn shQuote(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(arena, '\'');
    for (s) |c| {
        if (c == '\'') {
            try out.appendSlice(arena, "'\\''");
        } else {
            try out.append(arena, c);
        }
    }
    try out.append(arena, '\'');
    return out.items;
}

pub fn createMountUnit(arena: std.mem.Allocator, description: []const u8, uuid: []const u8, mount_point: []const u8, fs_type: []const u8, options: []const u8) !OpResult {
    const unit = try unitname.fromMountPoint(arena, mount_point);
    const content = try buildUnitContent(arena, description, uuid, mount_point, fs_type, options);

    const tmp = try writeTempFile(arena, content);
    defer sysutil.deleteFile(tmp);

    const script = try std.fmt.allocPrint(arena,
        \\set -e
        \\cp {s} '/etc/systemd/system/{s}'
        \\systemctl daemon-reload
        \\systemctl enable --now '{s}'
    , .{ try shQuote(arena, tmp), unit, unit });

    return runPrivileged(arena, &.{ "/usr/bin/sh", "-c", script });
}

fn readWhatLine(arena: std.mem.Allocator, unit: []const u8) !?[]const u8 {
    const path = try std.fmt.allocPrint(arena, "/etc/systemd/system/{s}", .{unit});
    const content = sysutil.readFileAlloc(arena, path) orelse return null;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "What=")) {
            return trimmed;
        }
    }
    return null;
}

pub fn editMountUnit(arena: std.mem.Allocator, old_unit: []const u8, description: []const u8, mount_point: []const u8, fs_type: []const u8, options: []const u8) !OpResult {
    const new_unit = try unitname.fromMountPoint(arena, mount_point);
    const what_line = (try readWhatLine(arena, old_unit)) orelse
        return .{ .ok = false, .cancelled = false, .output = "", .err = "Failed to find 'What' directive in unit file.", .exit_code = -1 };

    const path = if (std.mem.startsWith(u8, mount_point, "/")) mount_point else try std.fmt.allocPrint(arena, "/{s}", .{mount_point});
    const content = try std.fmt.allocPrint(arena,
        \\[Unit]
        \\Description={s}
        \\
        \\[Mount]
        \\{s}
        \\Where={s}
        \\Type={s}
        \\Options={s}
        \\
        \\[Install]
        \\WantedBy=multi-user.target
        \\
    , .{ description, what_line, path, fs_type, options });

    const tmp = try writeTempFile(arena, content);
    defer sysutil.deleteFile(tmp);

    var script: []const u8 = undefined;
    if (std.mem.eql(u8, old_unit, new_unit)) {
        script = try std.fmt.allocPrint(arena,
            \\set -e
            \\cp {s} '/etc/systemd/system/{s}'
            \\systemctl daemon-reload
            \\if systemctl is-active --quiet '{s}'; then systemctl restart '{s}'; else systemctl enable --now '{s}'; fi
        , .{ try shQuote(arena, tmp), new_unit, new_unit, new_unit, new_unit });
    } else {
        script = try std.fmt.allocPrint(arena,
            \\set -e
            \\systemctl disable --now '{s}' || true
            \\rm -f '/etc/systemd/system/{s}'
            \\cp {s} '/etc/systemd/system/{s}'
            \\systemctl daemon-reload
            \\systemctl enable --now '{s}'
        , .{ old_unit, old_unit, try shQuote(arena, tmp), new_unit, new_unit });
    }

    return runPrivileged(arena, &.{ "/usr/bin/sh", "-c", script });
}

pub fn deleteMountUnit(arena: std.mem.Allocator, unit: []const u8) !OpResult {
    const script = try std.fmt.allocPrint(arena,
        \\set -e
        \\systemctl disable --now '{s}' || true
        \\rm -f '/etc/systemd/system/{s}'
        \\systemctl daemon-reload
    , .{ unit, unit });
    return runPrivileged(arena, &.{ "/usr/bin/sh", "-c", script });
}

test "shQuote escapes single quotes" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const quoted = try shQuote(arena.allocator(), "it's a trap");
    try std.testing.expectEqualStrings("'it'\\''s a trap'", quoted);
}

test "unit content layout matches systemd expectations" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const content = try buildUnitContent(arena.allocator(), "Games", "abcd-1234", "mnt/games", "btrfs", "defaults,noatime");
    try std.testing.expect(std.mem.indexOf(u8, content, "What=/dev/disk/by-uuid/abcd-1234") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "Where=/mnt/games") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "WantedBy=multi-user.target") != null);
}
