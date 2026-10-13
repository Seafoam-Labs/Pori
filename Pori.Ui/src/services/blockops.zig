const std = @import("std");
const Pori = @import("Pori");
const glib = Pori.glib;
const dbus = @import("../helpers/dbus.zig");
const devices = @import("devices.zig");

const udisks_name = "org.freedesktop.UDisks2";
const manager_path = "/org/freedesktop/UDisks2/Manager";
const manager_iface = "org.freedesktop.UDisks2.Manager";
const block_iface = "org.freedesktop.UDisks2.Block";
const table_iface = "org.freedesktop.UDisks2.PartitionTable";
const partition_iface = "org.freedesktop.UDisks2.Partition";

pub const Result = struct {
    ok: bool,
    message: []const u8,

    reply: ?*glib.Variant = null,
};

fn failed(message: []const u8) Result {
    return .{ .ok = false, .message = message };
}

pub fn supportedFilesystems(arena: std.mem.Allocator) []const []const u8 {
    const conn = dbus.systemBus() catch return &fallback_filesystems;

    var out: std.ArrayList([]const u8) = .empty;
    for (filesystem_candidates) |fs| {
        const z = arena.dupeZ(u8, fs) catch continue;
        const res = dbus.call(conn, udisks_name, manager_path, manager_iface, "CanFormat", dbus.stringTuple(z)) orelse continue;
        defer res.unref();

        const supported = res.getChildValue(0);
        defer supported.unref();
        if (supported.getBoolean() == 0) continue;
        out.append(arena, fs) catch {};
    }

    if (out.items.len == 0) return &fallback_filesystems;
    std.mem.sort([]const u8, out.items, {}, lessThanString);
    return out.items;
}

const filesystem_candidates = [_][]const u8{ "btrfs", "ext2", "ext3", "ext4", "exfat", "f2fs", "ntfs", "swap", "vfat", "xfs" };

const fallback_filesystems = [_][]const u8{ "btrfs", "ext4", "exfat", "f2fs", "ntfs", "swap", "vfat", "xfs" };

fn lessThanString(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

pub fn format(
    arena: std.mem.Allocator,
    path: []const u8,
    fs_type: []const u8,
    label: []const u8,
    erase: bool,
    whole_disk: bool,
) Result {
    var entries: std.ArrayList(*glib.Variant) = .empty;
    entries.append(arena, dbus.optionEntry("erase", glib.Variant.newBoolean(@as(c_int, @intFromBool(erase))))) catch return failed("out of memory");
    entries.append(arena, dbus.optionEntry("no-block", glib.Variant.newBoolean(0))) catch return failed("out of memory");
    if (label.len > 0) {
        const z = arena.dupeZ(u8, label) catch return failed("out of memory");
        entries.append(arena, dbus.optionEntry("label", glib.Variant.newString(z))) catch return failed("out of memory");
    }
    if (whole_disk) {
        entries.append(arena, dbus.optionEntry("update-partition-type", glib.Variant.newBoolean(1))) catch return failed("out of memory");
    }

    const path_z = arena.dupeZ(u8, path) catch return failed("out of memory");
    const fs_z = arena.dupeZ(u8, fs_type) catch return failed("out of memory");
    return call(arena, path_z, block_iface, "Format", tuple2(glib.Variant.newString(fs_z), dbus.optionsArray(entries.items)));
}

pub fn createPartitionTable(arena: std.mem.Allocator, path: []const u8, table_type: []const u8) Result {
    const path_z = arena.dupeZ(u8, path) catch return failed("out of memory");
    const z = arena.dupeZ(u8, table_type) catch return failed("out of memory");
    return call(arena, path_z, table_iface, "Create", tuple2(glib.Variant.newString(z), dbus.optionsArray(&.{})));
}

pub fn createPartition(
    arena: std.mem.Allocator,
    disk_path: []const u8,
    offset: u64,
    size: u64,
    name: []const u8,
    fs_type: []const u8,
    label: []const u8,
) Result {
    const path_z = arena.dupeZ(u8, disk_path) catch return failed("out of memory");
    const name_z = arena.dupeZ(u8, name) catch return failed("out of memory");
    var children = [_]*glib.Variant{
        glib.Variant.newUint64(offset),
        glib.Variant.newUint64(size),
        glib.Variant.newString(""),
        glib.Variant.newString(name_z),
        dbus.optionsArray(&.{}),
    };

    const created = call(arena, path_z, table_iface, "CreatePartition", glib.Variant.newTuple(&children, children.len));
    if (!created.ok) return created;

    const reply = created.reply orelse return failed("UDisks2 created no partition");
    defer reply.unref();
    const new_path = arena.dupe(u8, dbus.firstString(reply)) catch return failed("out of memory");
    if (new_path.len == 0) return failed("UDisks2 created no partition");

    const formatted = format(arena, new_path, fs_type, label, false, false);
    if (!formatted.ok) {
        return failed(std.fmt.allocPrint(
            arena,
            "Partition created, but formatting it failed: {s}",
            .{formatted.message},
        ) catch "Partition created, but formatting it failed");
    }
    return .{ .ok = true, .message = "" };
}

pub fn deletePartition(arena: std.mem.Allocator, path: []const u8) Result {
    const path_z = arena.dupeZ(u8, path) catch return failed("out of memory");
    return call(arena, path_z, partition_iface, "Delete", tuple1(dbus.optionsArray(&.{})));
}

pub fn resizePartition(arena: std.mem.Allocator, path: []const u8, size: u64) Result {
    const path_z = arena.dupeZ(u8, path) catch return failed("out of memory");
    var children = [_]*glib.Variant{
        glib.Variant.newUint64(size),
        dbus.optionsArray(&.{}),
    };
    return call(arena, path_z, partition_iface, "Resize", glib.Variant.newTuple(&children, children.len));
}

fn tuple1(a: *glib.Variant) *glib.Variant {
    var children = [_]*glib.Variant{a};
    return glib.Variant.newTuple(&children, children.len);
}

fn tuple2(a: *glib.Variant, b: *glib.Variant) *glib.Variant {
    var children = [_]*glib.Variant{ a, b };
    return glib.Variant.newTuple(&children, children.len);
}

fn call(
    arena: std.mem.Allocator,
    path: [*:0]const u8,
    iface: [*:0]const u8,
    method: [*:0]const u8,
    params: ?*glib.Variant,
) Result {
    const conn = dbus.systemBus() catch return failed("cannot reach the system bus");
    const reply = dbus.callAuth(arena, conn, udisks_name, path, iface, method, params);
    if (reply.result == null) return failed(reply.message);
    return .{ .ok = true, .message = "", .reply = reply.result };
}

pub const mib: u64 = 1024 * 1024;

pub fn alignUp(value: u64, alignment: u64) u64 {
    if (alignment == 0) return value;
    const rem = value % alignment;
    if (rem == 0) return value;
    return value + (alignment - rem);
}

pub fn alignDown(value: u64, alignment: u64) u64 {
    if (alignment == 0) return value;
    return value - (value % alignment);
}

pub const Region = struct {
    offset: u64,
    size: u64,
    before: []const u8,
    after: []const u8,
};

pub const min_region: u64 = 16 * mib;

fn usableEnd(disk: devices.Disk) u64 {
    if (std.ascii.eqlIgnoreCase(disk.table_type, "gpt")) return disk.size -| mib;
    return disk.size;
}

pub fn freeRegions(arena: std.mem.Allocator, disk: devices.Disk) ![]const Region {
    var order: std.ArrayList(devices.DiskPartition) = .empty;
    for (disk.partitions) |p| {
        if (p.size == 0) continue;
        order.append(arena, p) catch {};
    }
    std.mem.sort(devices.DiskPartition, order.items, {}, offsetLessThan);

    const end = usableEnd(disk);
    var out: std.ArrayList(Region) = .empty;
    var cursor: u64 = mib;
    var before: []const u8 = "";

    for (order.items) |p| {
        if (p.offset > cursor) {
            const size = alignDown(p.offset - cursor, mib);
            if (size >= min_region) {
                try out.append(arena, .{ .offset = cursor, .size = size, .before = before, .after = p.name });
            }
        }
        cursor = @max(cursor, alignUp(p.offset + p.size, mib));
        before = p.name;
    }

    if (end > cursor) {
        const size = alignDown(end - cursor, mib);
        if (size >= min_region) {
            try out.append(arena, .{ .offset = cursor, .size = size, .before = before, .after = "" });
        }
    }

    return out.items;
}

fn offsetLessThan(_: void, a: devices.DiskPartition, b: devices.DiskPartition) bool {
    return a.offset < b.offset;
}

pub fn largestRegion(regions: []const Region) ?Region {
    var best: ?Region = null;
    for (regions) |r| {
        if (best == null or r.size > best.?.size) best = r;
    }
    return best;
}

pub fn totalFree(regions: []const Region) u64 {
    var sum: u64 = 0;
    for (regions) |r| sum += r.size;
    return sum;
}

pub const ResizeWindow = struct {
    offset: u64,
    size: u64,
    max_size: u64,
};

pub fn resizeWindow(disk: devices.Disk, part_path: []const u8) ?ResizeWindow {
    var found: ?devices.DiskPartition = null;
    for (disk.partitions) |p| {
        if (std.mem.eql(u8, p.path, part_path)) found = p;
    }
    const part = found orelse return null;
    if (part.size == 0) return null;

    const part_end = part.offset + part.size;
    var next_start = @max(usableEnd(disk), part_end);
    for (disk.partitions) |p| {
        if (p.size == 0 or std.mem.eql(u8, p.path, part_path)) continue;
        if (p.offset < part_end or p.offset >= next_start) continue;
        next_start = p.offset;
    }

    const room = if (next_start > part.offset) next_start - part.offset else 0;
    return .{
        .offset = part.offset,
        .size = part.size,
        .max_size = @max(alignDown(room, mib), part.size),
    };
}

pub fn canGrow(window: ResizeWindow) bool {
    return window.max_size > window.size;
}

pub fn parseSize(text: []const u8, limit: u64) ?u64 {
    const s = std.mem.trim(u8, text, " \t");
    if (s.len == 0) return null;

    var end: usize = 0;
    while (end < s.len and (std.ascii.isDigit(s[end]) or s[end] == '.' or s[end] == ',')) end += 1;
    if (end == 0) return null;

    var number_buf: [32]u8 = undefined;
    if (end > number_buf.len) return null;
    const number_text = number_buf[0..end];
    @memcpy(number_text, s[0..end]);
    std.mem.replaceScalar(u8, number_text, ',', '.');

    const unit_text = std.mem.trim(u8, s[end..], " ");
    const limit_f: f64 = @floatFromInt(limit);

    if (std.mem.eql(u8, unit_text, "%")) {
        const pct = std.fmt.parseFloat(f64, number_text) catch return null;
        if (!(pct > 0) or pct > 100) return null;
        return @intFromFloat(limit_f * pct / 100.0);
    }

    const value = std.fmt.parseFloat(f64, number_text) catch return null;
    if (!(value >= 0)) return null;

    const factor: f64 = if (unit_text.len == 0) 1.0 else blk: {
        const f: f64 = switch (std.ascii.toUpper(unit_text[0])) {
            'B' => 1,
            'K' => 1024,
            'M' => 1024 * 1024,
            'G' => 1024 * 1024 * 1024,
            'T' => @as(f64, 1024) * 1024 * 1024 * 1024,
            else => return null,
        };
        for (unit_text[1..]) |ch| {
            if (!std.ascii.isAlphabetic(ch) and ch != ' ') return null;
        }
        break :blk f;
    };

    const bytes = value * factor;
    if (!(bytes <= limit_f)) return null;
    return @intFromFloat(bytes);
}

pub fn confirmMatches(typed: []const u8, expected: []const u8) bool {
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, typed, " \t"), expected);
}

fn testDisk(table_type: []const u8, size: u64, partitions: []const devices.DiskPartition) devices.Disk {
    return .{
        .path = "/org/freedesktop/UDisks2/block_devices/sdb",
        .name = "sdb",
        .dev = "/dev/sdb",
        .model = "Test disk",
        .vendor = "",
        .serial = "",
        .size = size,
        .read_only = false,
        .table_type = table_type,
        .fs_type = "",
        .label = "",
        .mount_points = &.{},
        .partitions = partitions,
    };
}

fn testPartition(name: []const u8, number: u32, offset: u64, size: u64) devices.DiskPartition {
    return .{
        .path = name,
        .name = name,
        .number = number,
        .offset = offset,
        .size = size,
        .fs_type = "",
        .label = "",
        .mount_points = &.{},
    };
}

test "alignUp rounds to the boundary and leaves aligned values alone" {
    try std.testing.expectEqual(@as(u64, mib), alignUp(1, mib));
    try std.testing.expectEqual(@as(u64, mib), alignUp(mib, mib));
    try std.testing.expectEqual(@as(u64, 2 * mib), alignUp(mib + 1, mib));
    try std.testing.expectEqual(@as(u64, 500), alignUp(500, 0));
    try std.testing.expectEqual(@as(u64, mib), alignDown(2 * mib - 1, mib));
    try std.testing.expectEqual(@as(u64, 2 * mib), alignDown(2 * mib, mib));
}

test "freeRegions gives an empty disk one region, minus the GPT backup tail" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const gpt = try freeRegions(arena.allocator(), testDisk("gpt", 100 * mib, &.{}));
    try std.testing.expectEqual(@as(usize, 1), gpt.len);
    try std.testing.expectEqual(mib, gpt[0].offset);
    try std.testing.expectEqual(98 * mib, gpt[0].size);
    try std.testing.expectEqualStrings("", gpt[0].before);
    try std.testing.expectEqualStrings("", gpt[0].after);

    const dos = try freeRegions(arena.allocator(), testDisk("dos", 100 * mib, &.{}));
    try std.testing.expectEqual(99 * mib, dos[0].size);
}

test "freeRegions finds a gap in the middle of the disk, not just at the end" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const parts = [_]devices.DiskPartition{
        testPartition("sdb1", 1, mib, 10 * mib),
        testPartition("sdb2", 2, 40 * mib, 30 * mib + 512),
    };
    const regions = try freeRegions(arena.allocator(), testDisk("gpt", 100 * mib, &parts));

    try std.testing.expectEqual(@as(usize, 2), regions.len);
    try std.testing.expectEqual(11 * mib, regions[0].offset);
    try std.testing.expectEqual(29 * mib, regions[0].size);
    try std.testing.expectEqualStrings("sdb1", regions[0].before);
    try std.testing.expectEqualStrings("sdb2", regions[0].after);
    try std.testing.expectEqual(71 * mib, regions[1].offset);
    try std.testing.expectEqual(28 * mib, regions[1].size);
    try std.testing.expectEqualStrings("", regions[1].after);

    try std.testing.expectEqual(29 * mib, largestRegion(regions).?.size);
    try std.testing.expectEqual(57 * mib, totalFree(regions));
}

test "freeRegions drops alignment slivers too small to hold a filesystem" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const parts = [_]devices.DiskPartition{
        testPartition("sdb1", 1, mib, 10 * mib),
        testPartition("sdb2", 2, 12 * mib, 10 * mib),
    };
    const regions = try freeRegions(arena.allocator(), testDisk("gpt", 100 * mib, &parts));
    try std.testing.expectEqual(@as(usize, 1), regions.len);
    try std.testing.expectEqual(22 * mib, regions[0].offset);
    try std.testing.expectEqual(77 * mib, regions[0].size);
}

test "freeRegions is empty when partitions fill the disk" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const parts = [_]devices.DiskPartition{testPartition("sdb1", 1, 0, 100 * mib)};
    const regions = try freeRegions(arena.allocator(), testDisk("gpt", 100 * mib, &parts));
    try std.testing.expectEqual(@as(usize, 0), regions.len);
    try std.testing.expectEqual(null, largestRegion(regions));
    try std.testing.expectEqual(@as(u64, 0), totalFree(regions));
}

test "resizeWindow caps growth at the next partition" {
    const parts = [_]devices.DiskPartition{
        testPartition("sdb1", 1, mib, 10 * mib),
        testPartition("sdb2", 2, 20 * mib, 30 * mib),
    };
    const disk = testDisk("gpt", 100 * mib, &parts);

    const first = resizeWindow(disk, "sdb1").?;
    try std.testing.expectEqual(mib, first.offset);
    try std.testing.expectEqual(10 * mib, first.size);
    try std.testing.expectEqual(19 * mib, first.max_size);

    const last = resizeWindow(disk, "sdb2").?;
    try std.testing.expectEqual(30 * mib, last.size);
    try std.testing.expectEqual(79 * mib, last.max_size);
}

test "resizeWindow is null for a partition that is not on the disk" {
    const parts = [_]devices.DiskPartition{testPartition("sdb1", 1, mib, 10 * mib)};
    try std.testing.expectEqual(null, resizeWindow(testDisk("gpt", 100 * mib, &parts), "sdc9"));
}

test "resizeWindow never sets a ceiling below the current size" {
    const disk_bytes: u64 = 1024209543168;
    const parts = [_]devices.DiskPartition{testPartition("nvme0n1p2", 2, 2149580800, 1022059928576)};
    const disk = testDisk("gpt", disk_bytes, &parts);

    const window = resizeWindow(disk, "nvme0n1p2").?;
    try std.testing.expectEqual(@as(u64, 2149580800), window.offset);
    try std.testing.expectEqual(@as(u64, 1022059928576), window.size);
    try std.testing.expect(window.max_size >= window.size);
    try std.testing.expect(!canGrow(window));

    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const regions = try freeRegions(arena.allocator(), disk);
    try std.testing.expectEqual(@as(usize, 1), regions.len);
    try std.testing.expectEqual(mib, regions[0].offset);
    try std.testing.expectEqual(2049 * mib, regions[0].size);
    try std.testing.expectEqualStrings("nvme0n1p2", regions[0].after);
}

test "canGrow is true when free space follows the partition" {
    const parts = [_]devices.DiskPartition{testPartition("sdb1", 1, mib, 10 * mib)};
    const window = resizeWindow(testDisk("gpt", 100 * mib, &parts), "sdb1").?;
    try std.testing.expect(canGrow(window));
    try std.testing.expectEqual(@as(u64, 98 * mib), window.max_size);
}

test "parseSize reads units, decimals, percentages and bare bytes" {
    const limit: u64 = 1024 * mib;
    try std.testing.expectEqual(@as(u64, 500 * mib), parseSize("500M", limit).?);
    try std.testing.expectEqual(@as(u64, 500 * mib), parseSize("  500 mb ", limit).?);
    try std.testing.expectEqual(@as(u64, 512 * mib), parseSize("0.5G", limit).?);
    try std.testing.expectEqual(@as(u64, 1536), parseSize("1.5K", limit).?);
    try std.testing.expectEqual(@as(u64, 4096), parseSize("4096", limit).?);
    try std.testing.expectEqual(@as(u64, limit / 4), parseSize("25%", limit).?);
    try std.testing.expectEqual(@as(u64, 10 * 1024 * 1024 * 1024), parseSize("10G", @as(u64, 20) * 1024 * 1024 * 1024).?);
}

test "parseSize rejects nonsense and sizes that do not fit" {
    const limit: u64 = 1024 * mib;
    try std.testing.expectEqual(null, parseSize("", limit));
    try std.testing.expectEqual(null, parseSize("abc", limit));
    try std.testing.expectEqual(null, parseSize("500Q", limit));
    try std.testing.expectEqual(null, parseSize("2000M", limit));
    try std.testing.expectEqual(null, parseSize("150%", limit));
    try std.testing.expectEqual(null, parseSize("-5M", limit));
}

test "confirmMatches ignores case and surrounding whitespace" {
    try std.testing.expect(confirmMatches("sdb1", "sdb1"));
    try std.testing.expect(confirmMatches("  SDB1 ", "sdb1"));
    try std.testing.expect(!confirmMatches("sdb", "sdb1"));
    try std.testing.expect(!confirmMatches("", "sdb1"));
}
