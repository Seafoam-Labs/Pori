const std = @import("std");

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;

pub fn exists(path: []const u8) bool {
    var buf: [4096]u8 = undefined;
    if (path.len >= buf.len - 1) return false;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return access(buf[0..path.len :0].ptr, 0) == 0;
}

pub fn get(key: []const u8) ?[]const u8 {
    var buf: [128]u8 = undefined;
    if (key.len >= buf.len - 1) return null;
    @memcpy(buf[0..key.len], key);
    buf[key.len] = 0;
    const v = getenv(buf[0..key.len :0].ptr) orelse return null;
    return std.mem.sliceTo(v, 0);
}

pub fn has(key: []const u8) bool {
    const v = get(key) orelse return false;
    return v.len > 0;
}

pub fn set(key: []const u8, value: []const u8, overwrite: bool) void {
    var key_buf: [128]u8 = undefined;
    var val_buf: [1024]u8 = undefined;
    if (key.len >= key_buf.len - 1 or value.len >= val_buf.len - 1) return;
    @memcpy(key_buf[0..key.len], key);
    key_buf[key.len] = 0;
    @memcpy(val_buf[0..value.len], value);
    val_buf[value.len] = 0;
    _ = setenv(key_buf[0..key.len :0].ptr, val_buf[0..value.len :0].ptr, @intFromBool(overwrite));
}
