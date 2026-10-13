const std = @import("std");
const Pori = @import("Pori");
const gio = Pori.gio;
const glib = Pori.glib;

pub const CallError = error{ ConnectionFailed, CallFailed, OutOfMemory };

var system_conn: ?*gio.DBusConnection = null;

pub fn systemBus() CallError!*gio.DBusConnection {
    if (system_conn) |conn| return conn;
    var err: ?*glib.Error = null;
    const conn = gio.busGetSync(.system, null, &err) orelse {
        if (err) |e| {
            logError("connecting to system bus", e);
        }
        return error.ConnectionFailed;
    };
    system_conn = conn;
    return conn;
}

fn logError(context: []const u8, err: *glib.Error) void {
    const message = err.f_message orelse "<no message>";
    std.log.err("D-Bus error while {s}: {s}", .{ context, std.mem.sliceTo(message, 0) });
    err.free();
}

pub fn call(
    conn: *gio.DBusConnection,
    dest: [*:0]const u8,
    path: [*:0]const u8,
    iface: [*:0]const u8,
    method: [*:0]const u8,
    params: ?*glib.Variant,
) ?*glib.Variant {
    var err: ?*glib.Error = null;
    const res = conn.callSync(dest, path, iface, method, params, null, .{}, -1, null, &err);
    if (err) |e| {
        logError("calling method", e);
        return null;
    }
    return res;
}

pub fn stringTuple(s: [*:0]const u8) *glib.Variant {
    var children = [_]*glib.Variant{glib.Variant.newString(s)};
    return glib.Variant.newTuple(&children, children.len);
}

pub const Reply = struct {
    result: ?*glib.Variant,
    message: []const u8,
};

pub fn callAuth(
    arena: std.mem.Allocator,
    conn: *gio.DBusConnection,
    dest: [*:0]const u8,
    path: [*:0]const u8,
    iface: [*:0]const u8,
    method: [*:0]const u8,
    params: ?*glib.Variant,
) Reply {
    var err: ?*glib.Error = null;
    const res = conn.callSync(
        dest,
        path,
        iface,
        method,
        params,
        null,
        .{ .allow_interactive_authorization = true },
        -1,
        null,
        &err,
    );
    if (err) |e| {
        const raw = std.mem.sliceTo(e.f_message orelse "operation failed", 0);
        const tail = stripDbusPrefix(raw);
        const message = arena.dupe(u8, tail) catch "operation failed";
        e.free();
        return .{ .result = null, .message = message };
    }
    if (res == null) return .{ .result = null, .message = "no reply from UDisks2" };
    return .{ .result = res, .message = "" };
}

pub fn stripDbusPrefix(msg: []const u8) []const u8 {
    const prefix = "GDBus.Error:";
    if (!std.mem.startsWith(u8, msg, prefix)) return msg;
    const rest = msg[prefix.len..];
    const colon = std.mem.indexOfScalar(u8, rest, ':') orelse return rest;
    return std.mem.trim(u8, rest[colon + 1 ..], " ");
}

pub fn firstString(res: *glib.Variant) []const u8 {
    if (res.nChildren() == 0) return "";
    const child = res.getChildValue(0);
    defer child.unref();
    return variantString(child);
}

pub fn optionsArray(entries: []const *glib.Variant) *glib.Variant {
    const entry_type = glib.VariantType.new("{sv}");
    defer entry_type.free();
    const array = glib.Variant.newArray(entry_type, entries.ptr, entries.len);

    if (@intFromPtr(array) == 0) return glib.Variant.newArray(entry_type, null, 0);
    return array;
}

pub fn optionEntry(key: [*:0]const u8, value: *glib.Variant) *glib.Variant {
    return glib.Variant.newDictEntry(glib.Variant.newString(key), glib.Variant.newVariant(value));
}

test "optionEntry wraps values so optionsArray builds a real a{sv}" {
    const opts = optionsArray(&.{
        optionEntry("erase", glib.Variant.newBoolean(1)),
        optionEntry("label", glib.Variant.newString("Games")),
    });
    try std.testing.expect(@intFromPtr(opts) != 0);
    try std.testing.expectEqualStrings("a{sv}", std.mem.sliceTo(opts.getTypeString(), 0));
    try std.testing.expectEqual(@as(usize, 2), opts.nChildren());

    const empty = optionsArray(&.{});
    try std.testing.expect(@intFromPtr(empty) != 0);
    try std.testing.expectEqualStrings("a{sv}", std.mem.sliceTo(empty.getTypeString(), 0));
    try std.testing.expectEqual(@as(usize, 0), empty.nChildren());
}

test "stripDbusPrefix drops the domain and keeps the sentence" {
    try std.testing.expectEqualStrings(
        "Device is mounted",
        stripDbusPrefix("GDBus.Error:org.freedesktop.UDisks2.Error.Failed: Device is mounted"),
    );
    try std.testing.expectEqualStrings(
        "Not authorized",
        stripDbusPrefix("GDBus.Error:org.freedesktop.PolicyKit1.Error.NotAuthorized: Not authorized"),
    );
    try std.testing.expectEqualStrings("plain text", stripDbusPrefix("plain text"));
    try std.testing.expectEqualStrings("weird", stripDbusPrefix("GDBus.Error:weird"));
}

pub fn dictLookup(dict: *glib.Variant, key: []const u8) ?*glib.Variant {
    const n = dict.nChildren();
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const entry = dict.getChildValue(i);
        defer entry.unref();
        const entry_key_v = entry.getChildValue(0);
        defer entry_key_v.unref();
        const entry_key = std.mem.sliceTo(entry_key_v.getString(null), 0);
        if (!std.mem.eql(u8, entry_key, key)) continue;

        const boxed = entry.getChildValue(1);
        defer boxed.unref();
        return boxed.getVariant();
    }
    return null;
}

pub fn variantString(v: *glib.Variant) []const u8 {
    return std.mem.sliceTo(v.getString(null), 0);
}

pub fn dictString(arena: std.mem.Allocator, dict: *glib.Variant, key: []const u8) ?[]const u8 {
    const v = dictLookup(dict, key) orelse return null;
    defer v.unref();
    return arena.dupe(u8, variantString(v)) catch null;
}

pub fn dictByteString(arena: std.mem.Allocator, dict: *glib.Variant, key: []const u8) ?[]const u8 {
    const v = dictLookup(dict, key) orelse return null;
    defer v.unref();
    return byteString(arena, v);
}

pub fn dictBool(dict: *glib.Variant, key: []const u8) bool {
    const v = dictLookup(dict, key) orelse return false;
    defer v.unref();
    return v.getBoolean() != 0;
}

pub fn dictU64(dict: *glib.Variant, key: []const u8) u64 {
    const v = dictLookup(dict, key) orelse return 0;
    defer v.unref();
    return v.getUint64();
}

pub fn dictU32(dict: *glib.Variant, key: []const u8) u32 {
    const v = dictLookup(dict, key) orelse return 0;
    defer v.unref();
    return v.getUint32();
}

pub fn byteString(arena: std.mem.Allocator, v: *glib.Variant) ?[]const u8 {
    const data: [*]const u8 = @ptrCast(v.getData() orelse return null);
    const len = v.nChildren();
    var end: usize = 0;
    while (end < len and data[end] != 0) end += 1;
    return arena.dupe(u8, data[0..end]) catch null;
}

pub fn byteStringArray(arena: std.mem.Allocator, v: *glib.Variant) ?[][]const u8 {
    const n = v.nChildren();
    var out: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const child = v.getChildValue(i);
        defer child.unref();
        if (byteString(arena, child)) |s| {
            out.append(arena, s) catch return null;
        }
    }
    return out.items;
}
