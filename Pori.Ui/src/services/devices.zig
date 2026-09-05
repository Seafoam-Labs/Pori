const std = @import("std");
const Pori = @import("Pori");
const gio = Pori.gio;
const glib = Pori.glib;
const dbus = @import("../helpers/dbus.zig");
const format = @import("../helpers/format.zig");

pub const Device = struct {
    name: []const u8,

    dev: []const u8,
    fs_type: []const u8,
    fs_version: []const u8,
    label: []const u8,
    uuid: []const u8,
    size: u64,
    read_only: bool,
    mount_points: []const []const u8,

    pub fn mounted(self: Device) bool {
        return self.mount_points.len > 0;
    }
};

const udisks_name = "org.freedesktop.UDisks2";
const udisks_root = "/org/freedesktop/UDisks2";
const object_manager_iface = "org.freedesktop.DBus.ObjectManager";
const block_iface = "org.freedesktop.UDisks2.Block";
const fs_iface = "org.freedesktop.UDisks2.Filesystem";

pub fn list(arena: std.mem.Allocator) dbus.CallError![]Device {
    const conn = try dbus.systemBus();

    const res = dbus.call(
        conn,
        udisks_name,
        udisks_root,
        object_manager_iface,
        "GetManagedObjects",
        null,
    ) orelse return error.CallFailed;
    defer res.unref();

    const objects = res.getChildValue(0);
    defer objects.unref();

    var out: std.ArrayList(Device) = .empty;
    const object_count = objects.nChildren();
    var i: usize = 0;
    while (i < object_count) : (i += 1) {
        const obj_entry = objects.getChildValue(i);
        defer obj_entry.unref();

        const ifaces = obj_entry.getChildValue(1);
        defer ifaces.unref();

        var device = Device{
            .name = "",
            .dev = "",
            .fs_type = "",
            .fs_version = "",
            .label = "",
            .uuid = "",
            .size = 0,
            .read_only = false,
            .mount_points = &.{},
        };
        var has_block = false;
        var has_filesystem = false;

        const iface_count = ifaces.nChildren();
        var j: usize = 0;
        while (j < iface_count) : (j += 1) {
            const iface_entry = ifaces.getChildValue(j);
            defer iface_entry.unref();

            const iface_name_v = iface_entry.getChildValue(0);
            defer iface_name_v.unref();
            const iface_name = std.mem.sliceTo(iface_name_v.getString(null), 0);

            if (!std.mem.eql(u8, iface_name, block_iface) and
                !std.mem.eql(u8, iface_name, fs_iface)) continue;

            const props = iface_entry.getChildValue(1);
            defer props.unref();

            if (std.mem.eql(u8, iface_name, block_iface)) {
                has_block = true;
                device.dev = dbus.dictByteString(arena, props, "Device") orelse "";
                device.fs_type = dbus.dictString(arena, props, "IdType") orelse "";
                device.fs_version = dbus.dictString(arena, props, "IdVersion") orelse "";
                device.label = dbus.dictString(arena, props, "IdLabel") orelse "";
                device.uuid = dbus.dictString(arena, props, "IdUUID") orelse "";
                device.size = dbus.dictU64(props, "Size");
                device.read_only = dbus.dictBool(props, "ReadOnly");
            } else {
                has_filesystem = true;
                if (dbus.dictLookup(props, "MountPoints")) |mp_v| {
                    defer mp_v.unref();
                    device.mount_points = dbus.byteStringArray(arena, mp_v) orelse &.{};
                }
            }
        }

        if (!has_block or !has_filesystem) continue;
        if (device.fs_type.len == 0 or device.uuid.len == 0) continue;
        if (std.mem.eql(u8, device.fs_type, "swap")) continue;
        const basename = std.fs.path.basename(device.dev);
        if (std.mem.startsWith(u8, basename, "loop") or
            std.mem.startsWith(u8, basename, "zram") or
            std.mem.startsWith(u8, basename, "ram")) continue;

        device.name = basename;
        try out.append(arena, device);
    }

    std.mem.sort(Device, out.items, {}, deviceLessThan);
    return out.items;
}

fn deviceLessThan(_: void, a: Device, b: Device) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

pub fn usage(device: Device) ?format.FsUsage {
    if (device.mount_points.len == 0) return null;
    return format.fsUsage(device.mount_points[0]);
}
