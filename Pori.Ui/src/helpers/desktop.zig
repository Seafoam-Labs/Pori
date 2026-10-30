const std = @import("std");
const env = @import("env.zig");

pub const Desktop = enum { gnome, other };

fn containsLower(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    for (0..haystack.len - needle.len + 1) |i| {
        for (needle, 0..) |nc, j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(nc)) break;
        } else return true;
    }
    return false;
}

pub fn detect() Desktop {
    const xdg = env.get("XDG_CURRENT_DESKTOP") orelse "";
    const session = env.get("DESKTOP_SESSION") orelse "";

    if (containsLower(xdg, "gnome") or containsLower(session, "gnome")) return .gnome;
    return .other;
}
