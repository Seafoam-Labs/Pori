const std = @import("std");
const env = @import("env.zig");

pub const Desktop = enum { gnome, other };

fn containsLower(haystack: []const u8, needle: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(haystack, needle) != null;
}

pub fn detect() Desktop {
    const xdg = env.get("XDG_CURRENT_DESKTOP") orelse "";
    const session = env.get("DESKTOP_SESSION") orelse "";

    if (containsLower(xdg, "gnome") or containsLower(session, "gnome")) return .gnome;
    return .other;
}
