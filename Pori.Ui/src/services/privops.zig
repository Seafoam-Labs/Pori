const std = @import("std");
const unitname = @import("../helpers/unitname.zig");
const sysutil = @import("../helpers/sysutil.zig");
const env = @import("../helpers/env.zig");

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

fn chownLine(arena: std.mem.Allocator, path: []const u8, home: ?[]const u8, uid: u32, gid: u32) ![]const u8 {
    const h = home orelse return "";
    if (path.len <= h.len + 1) return "";
    if (!std.mem.startsWith(u8, path, h)) return "";
    if (path[h.len] != '/') return "";
    return std.fmt.allocPrint(arena, "chown {d}:{d} {s}", .{ uid, gid, try shQuote(arena, path) });
}

fn buildChownLine(arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    return chownLine(arena, path, env.get("HOME"), std.c.getuid(), std.c.getgid());
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

    const path = if (std.mem.startsWith(u8, mount_point, "/")) mount_point else try std.fmt.allocPrint(arena, "/{s}", .{mount_point});
    const script = try std.fmt.allocPrint(arena,
        \\set -e
        \\cp {s} '/etc/systemd/system/{s}'
        \\chmod 644 '/etc/systemd/system/{s}'
        \\systemctl daemon-reload
        \\systemctl enable --now '{s}'
        \\{s}
    , .{ try shQuote(arena, tmp), unit, unit, unit, try buildChownLine(arena, path) });

    return runPrivileged(arena, &.{ "/usr/bin/sh", "-c", script });
}

fn buildEditContent(arena: std.mem.Allocator, description: []const u8, mount_point: []const u8, fs_type: []const u8, options: []const u8) ![]const u8 {
    const path = if (std.mem.startsWith(u8, mount_point, "/")) mount_point else try std.fmt.allocPrint(arena, "/{s}", .{mount_point});
    return std.fmt.allocPrint(arena,
        \\[Unit]
        \\Description={s}
        \\
        \\[Mount]
        \\Where={s}
        \\Type={s}
        \\Options={s}
        \\
        \\[Install]
        \\WantedBy=multi-user.target
        \\
    , .{ description, path, fs_type, options });
}

pub fn editMountUnit(arena: std.mem.Allocator, old_unit: []const u8, description: []const u8, mount_point: []const u8, fs_type: []const u8, options: []const u8) !OpResult {
    const new_unit = try unitname.fromMountPoint(arena, mount_point);
    const content = try buildEditContent(arena, description, mount_point, fs_type, options);

    const tmp = try writeTempFile(arena, content);
    defer sysutil.deleteFile(tmp);
    const spliced = try std.fmt.allocPrint(arena, "{s}.new", .{tmp});
    defer sysutil.deleteFile(spliced);

    const old_path = try shQuote(arena, try std.fmt.allocPrint(arena, "/etc/systemd/system/{s}", .{old_unit}));

    const splice = try std.fmt.allocPrint(arena,
        \\if ! grep -q '^What=' {s}; then echo 'unit file has no What directive' >&2; exit 3; fi
        \\sed -n '1,/^\[Mount\]$/p' {s} > {s}
        \\sed -n '/^What=/p' {s} | head -n 1 >> {s}
        \\sed -n '/^\[Mount\]$/,$p' {s} | tail -n +2 >> {s}
    , .{ old_path, try shQuote(arena, tmp), try shQuote(arena, spliced), old_path, try shQuote(arena, spliced), try shQuote(arena, tmp), try shQuote(arena, spliced) });

    const path = if (std.mem.startsWith(u8, mount_point, "/")) mount_point else try std.fmt.allocPrint(arena, "/{s}", .{mount_point});
    const chown = try buildChownLine(arena, path);

    var script: []const u8 = undefined;
    if (std.mem.eql(u8, old_unit, new_unit)) {
        script = try std.fmt.allocPrint(arena,
            \\set -e
            \\{s}
            \\cp {s} {s}
            \\chmod 644 {s}
            \\systemctl daemon-reload
            \\if systemctl is-active --quiet '{s}'; then systemctl restart '{s}'; else systemctl enable --now '{s}'; fi
            \\{s}
        , .{ splice, try shQuote(arena, spliced), old_path, old_path, new_unit, new_unit, new_unit, chown });
    } else {
        script = try std.fmt.allocPrint(arena,
            \\set -e
            \\{s}
            \\systemctl disable --now '{s}' || true
            \\rm -f {s}
            \\cp {s} '/etc/systemd/system/{s}'
            \\chmod 644 '/etc/systemd/system/{s}'
            \\systemctl daemon-reload
            \\systemctl enable --now '{s}'
            \\{s}
        , .{ splice, old_unit, old_path, try shQuote(arena, spliced), new_unit, new_unit, new_unit, chown });
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

test "chown line only fires inside the caller's home" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const inside = try chownLine(a, "/home/caro/mnt/games", "/home/caro", 1000, 1001);
    try std.testing.expectEqualStrings("chown 1000:1001 '/home/caro/mnt/games'", inside);

    try std.testing.expectEqualStrings("", try chownLine(a, "/mnt/games", "/home/caro", 1000, 1001));
    try std.testing.expectEqualStrings("", try chownLine(a, "/home/carol/mnt", "/home/caro", 1000, 1001));
    try std.testing.expectEqualStrings("", try chownLine(a, "/home/caro", "/home/caro", 1000, 1001));
    try std.testing.expectEqualStrings("", try chownLine(a, "/home/caro/mnt", null, 1000, 1001));
}

test "unit content layout matches systemd expectations" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const content = try buildUnitContent(arena.allocator(), "Games", "abcd-1234", "mnt/games", "btrfs", "defaults,noatime");
    try std.testing.expect(std.mem.indexOf(u8, content, "What=/dev/disk/by-uuid/abcd-1234") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "Where=/mnt/games") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "WantedBy=multi-user.target") != null);
}

test "edit content leaves What to the privileged splice" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const content = try buildEditContent(arena.allocator(), "Games", "mnt/games", "btrfs", "defaults,noatime");
    try std.testing.expect(std.mem.indexOf(u8, content, "What=") == null);
    try std.testing.expect(std.mem.indexOf(u8, content, "Where=/mnt/games") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "[Mount]") != null);
}
