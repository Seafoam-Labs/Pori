const std = @import("std");
const Pori = @import("Pori");
const gio = Pori.gio;
const glib = Pori.glib;
const dbus = @import("../helpers/dbus.zig");
const format = @import("../helpers/format.zig");

pub const Device = struct {
    name: []const u8,

    path: []const u8,
    dev: []const u8,
    fs_type: []const u8,
    fs_version: []const u8,
    label: []const u8,
    uuid: []const u8,
    size: u64,
    read_only: bool,
    mount_points: []const []const u8,

    parent: []const u8,
    parent_size: u64,
    table_type: []const u8,
    partition_number: u32,
    partition_count: usize,

    pub fn mounted(self: Device) bool {
        return self.mount_points.len > 0;
    }

    pub fn isPartition(self: Device) bool {
        return self.parent.len > 0;
    }

    pub fn groupKey(self: Device) []const u8 {
        if (self.parent.len > 0) return self.parent;
        return self.name;
    }
};

pub const DiskPartition = struct {
    path: []const u8,
    name: []const u8,
    number: u32,
    offset: u64,
    size: u64,
    fs_type: []const u8,
    label: []const u8,
    mount_points: []const []const u8,

    pub fn mounted(self: DiskPartition) bool {
        return self.mount_points.len > 0;
    }

    pub fn title(self: DiskPartition) []const u8 {
        if (self.label.len > 0) return self.label;
        return self.name;
    }
};

pub const Disk = struct {
    path: []const u8,
    name: []const u8,
    dev: []const u8,
    model: []const u8,
    vendor: []const u8,
    serial: []const u8,
    size: u64,
    read_only: bool,
    table_type: []const u8,

    fs_type: []const u8,
    label: []const u8,
    mount_points: []const []const u8,

    partitions: []const DiskPartition,

    pub fn hasTable(self: Disk) bool {
        return self.table_type.len > 0;
    }

    pub fn mounted(self: Disk) bool {
        return self.mount_points.len > 0;
    }

    pub fn title(self: Disk) []const u8 {
        if (self.model.len > 0) return self.model;
        if (self.label.len > 0) return self.label;
        return self.name;
    }
};

pub const Snapshot = struct {
    disks: []const Disk,
    devices: []const Device,
};

const BlockInfo = struct {
    name: []const u8,
    size: u64,
    table_type: []const u8,
    partition_count: usize,
};

const udisks_name = "org.freedesktop.UDisks2";
const udisks_root = "/org/freedesktop/UDisks2";
const object_manager_iface = "org.freedesktop.DBus.ObjectManager";
const block_iface = "org.freedesktop.UDisks2.Block";
const drive_iface = "org.freedesktop.UDisks2.Drive";
const fs_iface = "org.freedesktop.UDisks2.Filesystem";
const partition_iface = "org.freedesktop.UDisks2.Partition";
const partition_table_iface = "org.freedesktop.UDisks2.PartitionTable";

const Raw = struct {
    path: []const u8 = "",
    dev: []const u8 = "",
    fs_type: []const u8 = "",
    fs_version: []const u8 = "",
    label: []const u8 = "",
    uuid: []const u8 = "",
    size: u64 = 0,
    read_only: bool = false,
    mount_points: []const []const u8 = &.{},
    has_block: bool = false,
    has_filesystem: bool = false,
    is_partition: bool = false,
    is_drive: bool = false,
    drive_path: []const u8 = "",
    model: []const u8 = "",
    vendor: []const u8 = "",
    serial: []const u8 = "",
    table_path: []const u8 = "",
    partition_number: u32 = 0,
    partition_offset: u64 = 0,
    partition_size: u64 = 0,
    table_type: []const u8 = "",
    partition_count: usize = 0,
};

fn parseObject(arena: std.mem.Allocator, obj_entry: *glib.Variant) Raw {
    var raw: Raw = .{};

    const path_v = obj_entry.getChildValue(0);
    defer path_v.unref();
    raw.path = arena.dupe(u8, std.mem.sliceTo(path_v.getString(null), 0)) catch "";

    const ifaces = obj_entry.getChildValue(1);
    defer ifaces.unref();

    const iface_count = ifaces.nChildren();
    var j: usize = 0;
    while (j < iface_count) : (j += 1) {
        const iface_entry = ifaces.getChildValue(j);
        defer iface_entry.unref();

        const iface_name_v = iface_entry.getChildValue(0);
        defer iface_name_v.unref();
        const iface_name = std.mem.sliceTo(iface_name_v.getString(null), 0);

        const props = iface_entry.getChildValue(1);
        defer props.unref();

        if (std.mem.eql(u8, iface_name, block_iface)) {
            raw.has_block = true;
            raw.dev = dbus.dictByteString(arena, props, "Device") orelse "";
            raw.fs_type = dbus.dictString(arena, props, "IdType") orelse "";
            raw.fs_version = dbus.dictString(arena, props, "IdVersion") orelse "";
            raw.label = dbus.dictString(arena, props, "IdLabel") orelse "";
            raw.uuid = dbus.dictString(arena, props, "IdUUID") orelse "";
            raw.size = dbus.dictU64(props, "Size");
            raw.read_only = dbus.dictBool(props, "ReadOnly");
            raw.drive_path = dbus.dictString(arena, props, "Drive") orelse "";
        } else if (std.mem.eql(u8, iface_name, drive_iface)) {
            raw.is_drive = true;
            raw.model = dbus.dictString(arena, props, "Model") orelse "";
            raw.vendor = dbus.dictString(arena, props, "Vendor") orelse "";
            raw.serial = dbus.dictString(arena, props, "Serial") orelse "";
        } else if (std.mem.eql(u8, iface_name, fs_iface)) {
            raw.has_filesystem = true;
            if (dbus.dictLookup(props, "MountPoints")) |mp_v| {
                defer mp_v.unref();
                raw.mount_points = dbus.byteStringArray(arena, mp_v) orelse &.{};
            }
        } else if (std.mem.eql(u8, iface_name, partition_iface)) {
            raw.is_partition = true;
            raw.table_path = dbus.dictString(arena, props, "Table") orelse "";
            raw.partition_number = dbus.dictU32(props, "Number");
            raw.partition_offset = dbus.dictU64(props, "Offset");
            raw.partition_size = dbus.dictU64(props, "Size");
        } else if (std.mem.eql(u8, iface_name, partition_table_iface)) {
            raw.table_type = dbus.dictString(arena, props, "Type") orelse "";
            if (dbus.dictLookup(props, "Partitions")) |parts| {
                defer parts.unref();
                raw.partition_count = parts.nChildren();
            }
        }
    }

    return raw;
}

fn isVirtual(basename: []const u8) bool {
    return std.mem.startsWith(u8, basename, "loop") or
        std.mem.startsWith(u8, basename, "zram") or
        std.mem.startsWith(u8, basename, "ram") or
        std.mem.startsWith(u8, basename, "dm-") or
        std.mem.startsWith(u8, basename, "sr") or
        std.mem.startsWith(u8, basename, "md");
}

pub fn snapshot(arena: std.mem.Allocator) dbus.CallError!Snapshot {
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

    var raws: std.ArrayList(Raw) = .empty;
    const object_count = objects.nChildren();
    var i: usize = 0;
    while (i < object_count) : (i += 1) {
        const obj_entry = objects.getChildValue(i);
        defer obj_entry.unref();
        raws.append(arena, parseObject(arena, obj_entry)) catch {};
    }

    var blocks = std.StringHashMap(BlockInfo).init(arena);
    for (raws.items) |raw| {
        if (!raw.has_block) continue;
        blocks.put(raw.path, .{
            .name = std.fs.path.basename(raw.dev),
            .size = raw.size,
            .table_type = raw.table_type,
            .partition_count = raw.partition_count,
        }) catch {};
    }

    const disks = try collectDisks(arena, raws.items);
    const devices = try collectDevices(arena, raws.items, blocks, disks);
    return .{ .disks = disks, .devices = devices };
}

const DriveInfo = struct {
    model: []const u8,
    vendor: []const u8,
    serial: []const u8,
};

fn driveInfos(arena: std.mem.Allocator, raws: []const Raw) std.StringHashMap(DriveInfo) {
    var drives = std.StringHashMap(DriveInfo).init(arena);
    for (raws) |raw| {
        if (!raw.is_drive) continue;
        drives.put(raw.path, .{ .model = raw.model, .vendor = raw.vendor, .serial = raw.serial }) catch {};
    }
    return drives;
}

fn collectDisks(arena: std.mem.Allocator, raws: []const Raw) ![]const Disk {
    const drives = driveInfos(arena, raws);
    var out: std.ArrayList(Disk) = .empty;

    for (raws) |raw| {
        if (!raw.has_block or raw.is_partition) continue;
        if (raw.size == 0) continue;
        const basename = std.fs.path.basename(raw.dev);
        if (isVirtual(basename)) continue;

        var partitions: std.ArrayList(DiskPartition) = .empty;
        for (raws) |p| {
            if (!p.is_partition) continue;
            if (!std.mem.eql(u8, p.table_path, raw.path)) continue;
            const part_dev = std.fs.path.basename(p.dev);
            const size = if (p.partition_size != 0) p.partition_size else p.size;
            partitions.append(arena, .{
                .path = p.path,
                .name = part_dev,
                .number = p.partition_number,
                .offset = p.partition_offset,
                .size = size,
                .fs_type = p.fs_type,
                .label = p.label,
                .mount_points = p.mount_points,
            }) catch {};
        }
        std.mem.sort(DiskPartition, partitions.items, {}, partitionLessThan);

        const info = if (raw.drive_path.len > 0) drives.get(raw.drive_path) else null;
        out.append(arena, .{
            .path = raw.path,
            .name = basename,
            .dev = raw.dev,
            .model = if (info) |d| d.model else "",
            .vendor = if (info) |d| d.vendor else "",
            .serial = if (info) |d| d.serial else "",
            .size = raw.size,
            .read_only = raw.read_only,
            .table_type = raw.table_type,
            .fs_type = raw.fs_type,
            .label = raw.label,
            .mount_points = raw.mount_points,
            .partitions = partitions.items,
        }) catch {};
    }

    std.mem.sort(Disk, out.items, {}, diskLessThan);
    return out.items;
}

fn collectDevices(
    arena: std.mem.Allocator,
    raws: []const Raw,
    blocks: std.StringHashMap(BlockInfo),
    disks: []const Disk,
) ![]const Device {
    var out: std.ArrayList(Device) = .empty;

    for (raws) |raw| {
        if (!raw.has_block or !raw.has_filesystem) continue;
        if (raw.fs_type.len == 0 or raw.uuid.len == 0) continue;
        if (std.mem.eql(u8, raw.fs_type, "swap")) continue;
        const basename = std.fs.path.basename(raw.dev);
        if (std.mem.startsWith(u8, basename, "loop") or
            std.mem.startsWith(u8, basename, "zram") or
            std.mem.startsWith(u8, basename, "ram")) continue;

        var device = Device{
            .name = basename,
            .path = raw.path,
            .dev = raw.dev,
            .fs_type = raw.fs_type,
            .fs_version = raw.fs_version,
            .label = raw.label,
            .uuid = raw.uuid,
            .size = raw.size,
            .read_only = raw.read_only,
            .mount_points = raw.mount_points,
            .parent = "",
            .parent_size = 0,
            .table_type = "",
            .partition_number = 0,
            .partition_count = 0,
        };

        if (raw.table_path.len > 0 and !std.mem.eql(u8, raw.table_path, "/")) {
            if (blocks.get(raw.table_path)) |info| {
                device.parent = info.name;
                device.parent_size = info.size;
                device.table_type = info.table_type;
                device.partition_number = raw.partition_number;
                device.partition_count = info.partition_count;
            }
        } else {
            for (disks) |disk| {
                if (std.mem.eql(u8, disk.name, basename)) {
                    device.parent_size = disk.size;
                    break;
                }
            }
        }

        try out.append(arena, device);
    }

    std.mem.sort(Device, out.items, {}, deviceLessThan);
    return out.items;
}

fn partitionLessThan(_: void, a: DiskPartition, b: DiskPartition) bool {
    if (a.number != b.number) return a.number < b.number;
    return a.offset < b.offset;
}

fn diskLessThan(_: void, a: Disk, b: Disk) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

fn deviceLessThan(_: void, a: Device, b: Device) bool {
    const ka = a.groupKey();
    const kb = b.groupKey();
    if (!std.mem.eql(u8, ka, kb)) return std.mem.lessThan(u8, ka, kb);
    if (a.partition_number != b.partition_number) return a.partition_number < b.partition_number;
    return std.mem.lessThan(u8, a.name, b.name);
}

pub fn usage(device: Device) ?format.FsUsage {
    if (device.mount_points.len == 0) return null;
    return format.fsUsage(device.mount_points[0]);
}

test "isVirtual keeps physical disks and drops synthetic block devices" {
    try std.testing.expect(!isVirtual("sda"));
    try std.testing.expect(!isVirtual("nvme0n1"));
    try std.testing.expect(isVirtual("loop0"));
    try std.testing.expect(isVirtual("zram0"));
    try std.testing.expect(isVirtual("dm-0"));
    try std.testing.expect(isVirtual("sr0"));
}

test "collectDisks takes the model from the separate drive object" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const raws = [_]Raw{
        .{
            .path = "/org/freedesktop/UDisks2/block_devices/nvme0n1",
            .dev = "/dev/nvme0n1",
            .size = 100 * mib_test,
            .has_block = true,
            .drive_path = "/org/freedesktop/UDisks2/drives/Some_SSD_123",
            .table_type = "gpt",
        },
        .{
            .path = "/org/freedesktop/UDisks2/drives/Some_SSD_123",
            .is_drive = true,
            .model = "Some SSD",
            .serial = "123",
        },
        .{
            .path = "/org/freedesktop/UDisks2/block_devices/nvme0n1p2",
            .dev = "/dev/nvme0n1p2",
            .size = 90 * mib_test,
            .has_block = true,
            .is_partition = true,
            .table_path = "/org/freedesktop/UDisks2/block_devices/nvme0n1",
            .partition_number = 2,
            .partition_offset = mib_test,
            .partition_size = 90 * mib_test,
        },
    };

    const disks = try collectDisks(arena.allocator(), &raws);
    try std.testing.expectEqual(@as(usize, 1), disks.len);
    try std.testing.expectEqualStrings("nvme0n1", disks[0].name);
    try std.testing.expectEqualStrings("Some SSD", disks[0].model);
    try std.testing.expectEqualStrings("123", disks[0].serial);
    try std.testing.expectEqual(@as(usize, 1), disks[0].partitions.len);
    try std.testing.expectEqualStrings("nvme0n1p2", disks[0].partitions[0].name);
}

test "collectDisks still lists a disk when UDisks2 reports no drive object" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const raws = [_]Raw{.{
        .path = "/org/freedesktop/UDisks2/block_devices/sdb",
        .dev = "/dev/sdb",
        .size = 100 * mib_test,
        .has_block = true,
        .table_type = "gpt",
    }};

    const disks = try collectDisks(arena.allocator(), &raws);
    try std.testing.expectEqual(@as(usize, 1), disks.len);
    try std.testing.expectEqualStrings("sdb", disks[0].name);
    try std.testing.expectEqualStrings("", disks[0].model);
}

const mib_test: u64 = 1024 * 1024;
