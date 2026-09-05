const std = @import("std");
const Pori = @import("Pori");
const gio = Pori.gio;
const glib = Pori.glib;
const dbus = @import("../helpers/dbus.zig");
const sysutil = @import("../helpers/sysutil.zig");

pub const MountUnit = struct {
    name: []const u8,
    description: []const u8,
    load_state: []const u8,
    active_state: []const u8,
    sub_state: []const u8,
    what: []const u8,
    where: []const u8,
    options: []const u8,
    fs_type: []const u8,
    unit_file_state: []const u8,

    pub fn statusText(self: MountUnit) []const u8 {
        if (self.active_state.len == 0) return "unknown";
        return self.active_state;
    }
};

const systemd_name = "org.freedesktop.systemd1";
const manager_path = "/org/freedesktop/systemd1";
const manager_iface = "org.freedesktop.systemd1.Manager";
const unit_iface = "org.freedesktop.systemd1.Unit";
const mount_iface = "org.freedesktop.systemd1.Mount";
const props_iface = "org.freedesktop.DBus.Properties";
const unit_dir = "/etc/systemd/system";

pub fn listLoadedMountUnits(arena: std.mem.Allocator) dbus.CallError![]MountUnit {
    const conn = try dbus.systemBus();

    const res = dbus.call(conn, systemd_name, manager_path, manager_iface, "ListUnits", null) orelse
        return error.CallFailed;
    defer res.unref();

    const units = res.getChildValue(0);
    defer units.unref();

    var out: std.ArrayList(MountUnit) = .empty;
    const count = units.nChildren();
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const tuple = units.getChildValue(i);
        defer tuple.unref();

        const name_v = tuple.getChildValue(0);
        defer name_v.unref();
        const name = std.mem.sliceTo(name_v.getString(null), 0);
        if (!std.mem.endsWith(u8, name, ".mount")) continue;

        var unit = MountUnit{
            .name = arena.dupe(u8, name) catch continue,
            .description = "",
            .load_state = "",
            .active_state = "",
            .sub_state = "",
            .what = "",
            .where = "",
            .options = "",
            .fs_type = "",
            .unit_file_state = "",
        };

        const desc_v = tuple.getChildValue(1);
        defer desc_v.unref();
        unit.description = arena.dupe(u8, std.mem.sliceTo(desc_v.getString(null), 0)) catch "";

        const load_v = tuple.getChildValue(2);
        defer load_v.unref();
        unit.load_state = arena.dupe(u8, std.mem.sliceTo(load_v.getString(null), 0)) catch "";

        const active_v = tuple.getChildValue(3);
        defer active_v.unref();
        unit.active_state = arena.dupe(u8, std.mem.sliceTo(active_v.getString(null), 0)) catch "";

        const sub_v = tuple.getChildValue(4);
        defer sub_v.unref();
        unit.sub_state = arena.dupe(u8, std.mem.sliceTo(sub_v.getString(null), 0)) catch "";

        const path_v = tuple.getChildValue(6);
        defer path_v.unref();
        const object_path = std.mem.sliceTo(path_v.getString(null), 0);

        fillMountProps(arena, conn, object_path, &unit);
        try out.append(arena, unit);
    }

    std.mem.sort(MountUnit, out.items, {}, unitLessThan);
    return out.items;
}

fn unitLessThan(_: void, a: MountUnit, b: MountUnit) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

pub fn getUnit(arena: std.mem.Allocator, name: []const u8) dbus.CallError!?MountUnit {
    const conn = try dbus.systemBus();

    var name_z: [256]u8 = undefined;
    if (name.len >= name_z.len - 1) return null;
    @memcpy(name_z[0..name.len], name);
    name_z[name.len] = 0;

    const res = dbus.call(
        conn,
        systemd_name,
        manager_path,
        manager_iface,
        "GetUnit",
        dbus.stringTuple(name_z[0..name.len :0].ptr),
    ) orelse return null;
    defer res.unref();

    const path_v = res.getChildValue(0);
    defer path_v.unref();
    const object_path = std.mem.sliceTo(path_v.getString(null), 0);

    var unit = MountUnit{
        .name = arena.dupe(u8, name) catch return null,
        .description = "",
        .load_state = "",
        .active_state = "",
        .sub_state = "",
        .what = "",
        .where = "",
        .options = "",
        .fs_type = "",
        .unit_file_state = "",
    };
    fillUnitProps(arena, conn, object_path, &unit);
    fillMountProps(arena, conn, object_path, &unit);
    return unit;
}

fn getAllDict(conn: *gio.DBusConnection, object_path: []const u8, iface: []const u8) ?*glib.Variant {
    var path_z: [512]u8 = undefined;
    var iface_z: [128]u8 = undefined;
    if (object_path.len >= path_z.len - 1 or iface.len >= iface_z.len - 1) return null;
    @memcpy(path_z[0..object_path.len], object_path);
    path_z[object_path.len] = 0;
    @memcpy(iface_z[0..iface.len], iface);
    iface_z[iface.len] = 0;

    var children = [_]*glib.Variant{glib.Variant.newString(iface_z[0..iface.len :0].ptr)};

    const params = glib.Variant.newTuple(&children, children.len);

    const res = dbus.call(
        conn,
        systemd_name,
        path_z[0..object_path.len :0].ptr,
        props_iface,
        "GetAll",
        params,
    ) orelse return null;

    const dict = res.getChildValue(0);
    res.unref();
    return dict;
}

fn fillUnitProps(arena: std.mem.Allocator, conn: *gio.DBusConnection, object_path: []const u8, unit: *MountUnit) void {
    const dict = getAllDict(conn, object_path, unit_iface) orelse return;
    defer dict.unref();
    unit.description = dbus.dictString(arena, dict, "Description") orelse unit.description;
    unit.load_state = dbus.dictString(arena, dict, "LoadState") orelse unit.load_state;
    unit.active_state = dbus.dictString(arena, dict, "ActiveState") orelse unit.active_state;
    unit.sub_state = dbus.dictString(arena, dict, "SubState") orelse unit.sub_state;
}

fn fillMountProps(arena: std.mem.Allocator, conn: *gio.DBusConnection, object_path: []const u8, unit: *MountUnit) void {
    const dict = getAllDict(conn, object_path, mount_iface) orelse return;
    defer dict.unref();
    unit.what = dbus.dictString(arena, dict, "What") orelse unit.what;
    unit.where = dbus.dictString(arena, dict, "Where") orelse unit.where;
    unit.options = dbus.dictString(arena, dict, "Options") orelse unit.options;
    unit.fs_type = dbus.dictString(arena, dict, "Type") orelse unit.fs_type;
}

pub fn listEtcMountUnits(arena: std.mem.Allocator) ![][]const u8 {
    const entries = try sysutil.listDir(arena, unit_dir);
    var out: std.ArrayList([]const u8) = .empty;
    for (entries) |name| {
        if (!std.mem.endsWith(u8, name, ".mount")) continue;
        try out.append(arena, name);
    }
    std.mem.sort([]const u8, out.items, {}, sliceLessThan);
    return out.items;
}

fn sliceLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

pub fn parseUnitFile(arena: std.mem.Allocator, name: []const u8, content: []const u8) !MountUnit {
    var unit = MountUnit{
        .name = try arena.dupe(u8, name),
        .description = "",
        .load_state = "not-loaded",
        .active_state = "inactive",
        .sub_state = "dead",
        .what = "",
        .where = "",
        .options = "",
        .fs_type = "",
        .unit_file_state = "",
    };

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#' or line[0] == '[' or line[0] == ';') continue;
        if (std.mem.startsWith(u8, line, "Description=")) {
            unit.description = try arena.dupe(u8, std.mem.trim(u8, line["Description=".len..], " "));
        } else if (std.mem.startsWith(u8, line, "What=")) {
            unit.what = try arena.dupe(u8, std.mem.trim(u8, line["What=".len..], " "));
        } else if (std.mem.startsWith(u8, line, "Where=")) {
            unit.where = try arena.dupe(u8, std.mem.trim(u8, line["Where=".len..], " "));
        } else if (std.mem.startsWith(u8, line, "Type=")) {
            unit.fs_type = try arena.dupe(u8, std.mem.trim(u8, line["Type=".len..], " "));
        } else if (std.mem.startsWith(u8, line, "Options=")) {
            unit.options = try arena.dupe(u8, std.mem.trim(u8, line["Options=".len..], " "));
        }
    }
    return unit;
}

pub fn unitInfo(arena: std.mem.Allocator, name: []const u8) !?MountUnit {
    if (try getUnit(arena, name)) |live| return live;

    const path = try std.fmt.allocPrint(arena, "/etc/systemd/system/{s}", .{name});
    const content = sysutil.readFileAlloc(arena, path) orelse return null;
    return try parseUnitFile(arena, name, content);
}

pub fn unitFilePath(arena: std.mem.Allocator, unit_name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ unit_dir, unit_name });
}
