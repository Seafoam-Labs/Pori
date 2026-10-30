const std = @import("std");

// glibc's struct statvfs on 64-bit; only the f_frsize..f_bavail fields are read.
const Statvfs = extern struct {
    f_bsize: c_ulong,
    f_frsize: c_ulong,
    f_blocks: c_ulong,
    f_bfree: c_ulong,
    f_bavail: c_ulong,
    f_files: c_ulong,
    f_ffree: c_ulong,
    f_favail: c_ulong,
    f_fsid: [8]u8,
    f_flag: c_ulong,
    f_namemax: c_ulong,
    __f_spare: [6]c_int,
};

extern "c" fn statvfs(path: [*:0]const u8, buf: *Statvfs) c_int;

pub fn humanSize(buf: []u8, bytes: u64) []const u8 {
    const units = "KMGTPE";
    var value: f64 = @floatFromInt(bytes);
    var unit: u8 = 'B';
    for (units) |u| {
        if (value < 1024.0) break;
        value /= 1024.0;
        unit = u;
    }
    if (unit == 'B') {
        return std.fmt.bufPrint(buf, "{d}B", .{bytes}) catch "0B";
    }
    if (value >= 10.0) {
        return std.fmt.bufPrint(buf, "{d:.0}{c}", .{ value, unit }) catch "?";
    }
    return std.fmt.bufPrint(buf, "{d:.1}{c}", .{ value, unit }) catch "?";
}

pub const FsUsage = struct {
    avail_bytes: u64,
    total_bytes: u64,
    used_percent: u8,
};

pub fn fsUsage(path: []const u8) ?FsUsage {
    var path_buf: [4096]u8 = undefined;
    if (path.len >= path_buf.len - 1) return null;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;

    var st: Statvfs = undefined;
    if (statvfs(path_buf[0..path.len :0].ptr, &st) != 0) return null;

    const block: u64 = @intCast(st.f_frsize);
    const total = st.f_blocks * block;
    const free = st.f_bfree * block;
    const avail = st.f_bavail * block;
    const used_percent: u8 = if (total == 0) 0 else @intCast(@min(100, (total - free) * 100 / total));

    return .{
        .avail_bytes = avail,
        .total_bytes = total,
        .used_percent = used_percent,
    };
}

test "humanSize formats like lsblk" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("100B", humanSize(&buf, 100));
    try std.testing.expectEqualStrings("95M", humanSize(&buf, 95 * 1024 * 1024));
    try std.testing.expectEqualStrings("224G", humanSize(&buf, 223 * 1024 * 1024 * 1024 + 512 * 1024 * 1024));
    try std.testing.expectEqualStrings("3.2T", humanSize(&buf, @as(u64, 32) * 1024 * 1024 * 1024 * 1024 / 10));
}

test "fsUsage works on the root filesystem" {
    const usage = fsUsage("/") orelse return error.TestUnexpectedResult;
    try std.testing.expect(usage.total_bytes > 0);
    try std.testing.expect(usage.used_percent <= 100);
}
