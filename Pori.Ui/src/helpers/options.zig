const std = @import("std");

pub const MountOption = struct {
    option: []const u8,
    description: []const u8,
};

const fs_options: []const struct { fs: []const u8, options: []const MountOption } = &.{
    .{
        .fs = "btrfs",
        .options = &.{
            .{ .option = "defaults", .description = "Use default mount options" },
            .{ .option = "compress=zstd:3", .description = "Reduces file sizes and increases lifespan of flash-based media" },
            .{ .option = "noatime", .description = "Improves performance and reduces writes to the drive" },
            .{ .option = "autodefrag", .description = "Keeps data ordered closely on the platter (beneficial for HDDs)" },
            .{ .option = "discard", .description = "Frees unused blocks on SSDs for better write performance" },
            .{ .option = "noacl", .description = "Reduces metadata overhead by disabling extended permissions" },
            .{ .option = "ssd_spread", .description = "Optimizes allocation for low-end SSDs" },
            .{ .option = "nosuid", .description = "Security" },
            .{ .option = "nodev", .description = "Security" },
            .{ .option = "x-gvfs-show", .description = "Shows the mount in the file manager and sidebar" },
        },
    },
    .{
        .fs = "ext4",
        .options = &.{
            .{ .option = "defaults", .description = "Use default mount options" },
            .{ .option = "noatime", .description = "Improves performance and reduces writes to the drive" },
            .{ .option = "errors=remount-ro", .description = "Remounts the filesystem as read-only in case of errors" },
            .{ .option = "discard", .description = "Frees unused blocks on SSDs for better write performance" },
            .{ .option = "nosuid", .description = "Security" },
            .{ .option = "nodev", .description = "Security" },
            .{ .option = "x-gvfs-show", .description = "Shows the mount in the file manager and sidebar" },
        },
    },
    .{
        .fs = "exfat",
        .options = &.{
            .{ .option = "defaults", .description = "Use default mount options" },
            .{ .option = "uid=$UID", .description = "Mount with your user permissions" },
            .{ .option = "gid=$GID", .description = "Mount with your user group permissions" },
            .{ .option = "sync", .description = "Forces all write operations to be flushed immediately" },
            .{ .option = "x-gvfs-show", .description = "Shows the mount in the file manager and sidebar" },
        },
    },
    .{
        .fs = "udf",
        .options = &.{
            .{ .option = "defaults", .description = "Use default mount options" },
            .{ .option = "unhide", .description = "Show otherwise hidden files" },
            .{ .option = "uid=$UID", .description = "Mount with your user permissions" },
            .{ .option = "gid=$GID", .description = "Mount with your user group permissions" },
            .{ .option = "noatime", .description = "Improves performance and reduces writes to the drive" },
            .{ .option = "nosuid", .description = "Security" },
            .{ .option = "nodev", .description = "Security" },
            .{ .option = "x-gvfs-show", .description = "Shows the mount in the file manager and sidebar" },
        },
    },
    .{
        .fs = "ntfs",
        .options = &.{
            .{ .option = "defaults", .description = "Use default mount options" },
            .{ .option = "windows_names", .description = "Only allow Windows-compliant file names" },
            .{ .option = "uid=$UID", .description = "Mount with your user permissions" },
            .{ .option = "gid=$GID", .description = "Mount with your user group permissions" },
            .{ .option = "nosuid", .description = "Prevents execution of set-user/group-ID programs (security)" },
            .{ .option = "nodev", .description = "Prevents interpretation of block/character devices (security)" },
            .{ .option = "umask=022", .description = "Sets standard file/directory permissions (rw-r--r-- / rwxr-xr-x)" },
            .{ .option = "x-gvfs-show", .description = "Shows the mount in the file manager and sidebar" },
        },
    },
    .{
        .fs = "zfs",
        .options = &.{
            .{ .option = "defaults", .description = "Use default mount options" },
            .{ .option = "x-gvfs-show", .description = "Shows the mount in the file manager and sidebar" },
        },
    },
};

pub fn optionsForFs(fs_type: []const u8) []const MountOption {
    for (fs_options) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.fs, fs_type)) return entry.options;
    }
    return &.{};
}

pub fn resolveOption(arena: std.mem.Allocator, option: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;

    var id_buf: [16]u8 = undefined;
    var rest = option;
    while (rest.len > 0) {
        if (std.mem.startsWith(u8, rest, "$UID")) {
            const id = std.fmt.bufPrint(&id_buf, "{d}", .{std.c.getuid()}) catch unreachable;
            try buf.appendSlice(arena, id);
            rest = rest[4..];
        } else if (std.mem.startsWith(u8, rest, "$GID")) {
            const id = std.fmt.bufPrint(&id_buf, "{d}", .{std.c.getgid()}) catch unreachable;
            try buf.appendSlice(arena, id);
            rest = rest[4..];
        } else {
            try buf.append(arena, rest[0]);
            rest = rest[1..];
        }
    }
    return buf.items;
}

test "btrfs has ten options" {
    try std.testing.expectEqual(@as(usize, 10), optionsForFs("btrfs").len);
}

test "lookup is case insensitive" {
    try std.testing.expectEqual(@as(usize, 7), optionsForFs("EXT4").len);
}

test "unknown filesystem has no options" {
    try std.testing.expectEqual(@as(usize, 0), optionsForFs("reiserfs").len);
}

test "resolveOption substitutes uid and gid" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const uid = try resolveOption(arena_alloc, "uid=$UID");
    var expected_uid: [24]u8 = undefined;
    const expected_uid_str = std.fmt.bufPrint(&expected_uid, "uid={d}", .{std.c.getuid()}) catch unreachable;
    try std.testing.expectEqualStrings(expected_uid_str, uid);

    const plain = try resolveOption(arena_alloc, "noatime");
    try std.testing.expectEqualStrings("noatime", plain);
}
