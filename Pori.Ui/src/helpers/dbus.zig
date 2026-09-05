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
