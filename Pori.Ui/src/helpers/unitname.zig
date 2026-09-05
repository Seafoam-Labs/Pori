const std = @import("std");

fn isSafe(c: u8) bool {
    return switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', ':', '_', '.' => true,
        else => false,
    };
}

pub fn fromMountPoint(arena: std.mem.Allocator, mount_point: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, mount_point, "/");
    var out: std.ArrayList(u8) = .empty;

    if (trimmed.len == 0) {
        try out.append(arena, '-');
    }

    var escape_buf: [4]u8 = undefined;
    var after_sep = true;
    for (trimmed) |c| {
        if (c == '/') {
            try out.append(arena, '-');
            after_sep = true;
        } else if (isSafe(c) and !(after_sep and c == '.')) {
            try out.append(arena, c);
            after_sep = false;
        } else {
            const escaped = std.fmt.bufPrint(&escape_buf, "\\x{x:0>2}", .{c}) catch unreachable;
            try out.appendSlice(arena, escaped);
            after_sep = false;
        }
    }

    try out.appendSlice(arena, ".mount");
    return out.items;
}

test "simple path" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const got = try fromMountPoint(arena.allocator(), "/home/caroline/mnt/sda1");
    try std.testing.expectEqualStrings("home-caroline-mnt-sda1.mount", got);
}

test "spaces are escaped" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const got = try fromMountPoint(arena.allocator(), "/mnt/New Volume");
    try std.testing.expectEqualStrings("mnt-New\\x20Volume.mount", got);
}

test "dashes are escaped" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const got = try fromMountPoint(arena.allocator(), "/mnt/my-drive/");
    try std.testing.expectEqualStrings("mnt-my\\x2ddrive.mount", got);
}

test "leading dot is escaped" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const got = try fromMountPoint(arena.allocator(), "/mnt/.hidden");
    try std.testing.expectEqualStrings("mnt-\\x2ehidden.mount", got);
}

test "root path becomes dash" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const got = try fromMountPoint(arena.allocator(), "/");
    try std.testing.expectEqualStrings("-.mount", got);
}

test "no leading slash" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const got = try fromMountPoint(arena.allocator(), "mnt/games");
    try std.testing.expectEqualStrings("mnt-games.mount", got);
}
