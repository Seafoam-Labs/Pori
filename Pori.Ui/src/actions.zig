const std = @import("std");
const Pori = @import("Pori");
const gtk = Pori.gtk;
const ui = @import("helpers/ui.zig");
const env = @import("helpers/env.zig");
const format = @import("helpers/format.zig");
const dialogs = @import("dialogs.zig");
const devices = @import("services/devices.zig");
const units = @import("services/units.zig");
const privops = @import("services/privops.zig");
const blockops = @import("services/blockops.zig");

pub const Outcome = struct {
    ok: bool,
    cancelled: bool,
    message: []const u8,
};

pub const Reporter = struct {
    setBusy: *const fn (ud: ?*anyopaque, busy: bool) void,
    report: *const fn (ud: ?*anyopaque, outcome: Outcome) void,
    ud: ?*anyopaque,
};

pub fn mount(parent: *gtk.Window, dev: *const devices.Device, reporter: Reporter) void {
    const flow = std.heap.page_allocator.create(MountFlow) catch return;
    flow.* = .{ .parent = parent, .reporter = reporter, .dev = dev };

    if (std.ascii.eqlIgnoreCase(dev.fs_type, "ntfs")) {
        dialogs.showNtfsWarning(parent, &onNtfsAnswer, flow);
    } else {
        beginMount(flow);
    }
}

pub fn edit(parent: *gtk.Window, unit: *const units.MountUnit, reporter: Reporter) void {
    const flow = std.heap.page_allocator.create(EditFlow) catch return;
    const alloc = std.heap.page_allocator;
    flow.* = .{
        .reporter = reporter,
        .unit_name = alloc.dupe(u8, unit.name) catch unit.name,
        .fs_type = alloc.dupe(u8, unit.fs_type) catch unit.fs_type,
    };

    dialogs.showMountOptions(parent, .edit, null, .{
        .unit_name = unit.name,
        .where = unit.where,
        .description = unit.description,
        .fs_type = unit.fs_type,
        .current_options = unit.options,
    }, &onEditChosen, flow);
}

pub fn remove(parent: *gtk.Window, unit_name: []const u8, reporter: Reporter) void {
    const flow = std.heap.page_allocator.create(RemoveFlow) catch return;
    flow.* = .{
        .reporter = reporter,
        .unit_name = std.heap.page_allocator.dupe(u8, unit_name) catch unit_name,
    };

    dialogs.showConfirm(parent, .{
        .title = "Remove mount unit",
        .body = ui.zFmt(
            "{s} will be stopped and deleted from /etc/systemd/system/.\n\n" ++
                "The drive itself is not modified and can be mounted again at any time.",
            .{unit_name},
        ),
        .confirm_label = "Remove",
        .danger = true,
    }, &onRemoveAnswer, flow);
}

const MountFlow = struct {
    parent: *gtk.Window,
    reporter: Reporter,
    dev: *const devices.Device,
};

const EditFlow = struct {
    reporter: Reporter,
    unit_name: []const u8,
    fs_type: []const u8,
};

const RemoveFlow = struct {
    reporter: Reporter,
    unit_name: []const u8,
};

fn onNtfsAnswer(ud: ?*anyopaque, proceed: bool) void {
    const flow: *MountFlow = @ptrCast(@alignCast(ud.?));
    if (!proceed) {
        std.heap.page_allocator.destroy(flow);
        return;
    }
    beginMount(flow);
}

fn beginMount(flow: *MountFlow) void {
    const d = flow.dev;
    const home = env.get("HOME") orelse "/root";

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const default_mp = std.fmt.allocPrint(arena.allocator(), "{s}/mnt/{s}", .{ home, d.name }) catch d.name;

    dialogs.showMountOptions(flow.parent, .create, .{
        .name = d.name,
        .fs_type = d.fs_type,
        .uuid = d.uuid,
        .default_mount_point = default_mp,
    }, null, &onMountChosen, flow);
    arena.deinit();
}

fn onMountChosen(ud: ?*anyopaque, choice: ?dialogs.MountChoice) void {
    const flow: *MountFlow = @ptrCast(@alignCast(ud.?));
    const c = choice orelse {
        std.heap.page_allocator.destroy(flow);
        return;
    };

    const alloc = std.heap.page_allocator;
    const d = flow.dev;
    const reporter = flow.reporter;
    const req = Request{ .create = .{
        .device_name = alloc.dupe(u8, d.name) catch d.name,
        .uuid = alloc.dupe(u8, d.uuid) catch d.uuid,
        .fs_type = alloc.dupe(u8, d.fs_type) catch d.fs_type,
        .description = c.description,
        .mount_point = c.mount_point,
        .options = c.options,
    } };
    std.heap.page_allocator.destroy(flow);
    submit(reporter, req);
}

fn onEditChosen(ud: ?*anyopaque, choice: ?dialogs.MountChoice) void {
    const flow: *EditFlow = @ptrCast(@alignCast(ud.?));
    const c = choice orelse {
        freeOwned(flow.unit_name);
        freeOwned(flow.fs_type);
        std.heap.page_allocator.destroy(flow);
        return;
    };

    const reporter = flow.reporter;
    const req = Request{ .edit = .{
        .old_unit = flow.unit_name,
        .fs_type = flow.fs_type,
        .description = c.description,
        .mount_point = c.mount_point,
        .options = c.options,
    } };
    std.heap.page_allocator.destroy(flow);
    submit(reporter, req);
}

fn onRemoveAnswer(ud: ?*anyopaque, proceed: bool) void {
    const flow: *RemoveFlow = @ptrCast(@alignCast(ud.?));
    if (!proceed) {
        freeOwned(flow.unit_name);
        std.heap.page_allocator.destroy(flow);
        return;
    }

    const reporter = flow.reporter;
    const req = Request{ .remove = .{ .unit = flow.unit_name } };
    std.heap.page_allocator.destroy(flow);
    submit(reporter, req);
}

const Create = struct {
    device_name: []const u8,
    uuid: []const u8,
    fs_type: []const u8,
    description: []const u8,
    mount_point: []const u8,
    options: []const u8,
};

const Edit = struct {
    old_unit: []const u8,
    fs_type: []const u8,
    description: []const u8,
    mount_point: []const u8,
    options: []const u8,
};

const Request = union(enum) {
    create: Create,
    edit: Edit,
    remove: struct { unit: []const u8 },
};

const Op = struct {
    reporter: Reporter,
    req: Request,
    result: ?privops.OpResult = null,
};

fn submit(reporter: Reporter, req: Request) void {
    const op = std.heap.page_allocator.create(Op) catch {
        freeRequest(req);
        return;
    };
    op.* = .{ .reporter = reporter, .req = req };

    reporter.setBusy(reporter.ud, true);
    ui.spawnJob(Op, runOp, op) catch {
        std.heap.page_allocator.destroy(op);
        freeRequest(req);
        reporter.setBusy(reporter.ud, false);
    };
}

fn runOp(op: *Op) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const failed = privops.OpResult{
        .ok = false,
        .cancelled = false,
        .output = "",
        .err = "failed to start operation",
        .exit_code = -1,
    };

    op.result = switch (op.req) {
        .create => |c| privops.createMountUnit(alloc, c.description, c.uuid, c.mount_point, c.fs_type, c.options) catch failed,
        .edit => |e| privops.editMountUnit(alloc, e.old_unit, e.description, e.mount_point, e.fs_type, e.options) catch failed,
        .remove => |r| privops.deleteMountUnit(alloc, r.unit) catch failed,
    };

    // finishOp runs on the UI thread after this arena is gone, so the result
    // strings must outlive it; finishOp frees them via freeOwned.
    if (op.result) |*r| {
        r.output = std.heap.page_allocator.dupe(u8, r.output) catch "";
        r.err = std.heap.page_allocator.dupe(u8, r.err) catch "";
    }

    ui.idle(Op, finishOp, op);
}

fn finishOp(op: *Op) void {
    const res = op.result.?;
    const outcome: Outcome = if (res.cancelled)
        .{ .ok = false, .cancelled = true, .message = "Authentication cancelled" }
    else if (!res.ok)
        .{
            .ok = false,
            .cancelled = false,
            .message = ui.zFmt("{s} failed: {s}", .{ verb(op.req), firstLine(res.err) }),
        }
    else switch (op.req) {
        .create => |c| .{ .ok = true, .cancelled = false, .message = ui.zFmt("Mounted {s} at {s}", .{ c.device_name, c.mount_point }) },
        .edit => |e| .{ .ok = true, .cancelled = false, .message = ui.zFmt("Saved {s}", .{e.mount_point}) },
        .remove => |r| .{ .ok = true, .cancelled = false, .message = ui.zFmt("Removed {s}", .{r.unit}) },
    };

    op.reporter.setBusy(op.reporter.ud, false);
    op.reporter.report(op.reporter.ud, outcome);

    freeOwned(res.output);
    freeOwned(res.err);
    freeRequest(op.req);
    std.heap.page_allocator.destroy(op);
}

fn verb(req: Request) []const u8 {
    return switch (req) {
        .create => "Mount",
        .edit => "Edit",
        .remove => "Remove",
    };
}

fn freeRequest(req: Request) void {
    switch (req) {
        .create => |c| {
            freeOwned(c.device_name);
            freeOwned(c.uuid);
            freeOwned(c.fs_type);
            freeOwned(c.description);
            freeOwned(c.mount_point);
            freeOwned(c.options);
        },
        .edit => |e| {
            freeOwned(e.old_unit);
            freeOwned(e.fs_type);
            freeOwned(e.description);
            freeOwned(e.mount_point);
            freeOwned(e.options);
        },
        .remove => |r| freeOwned(r.unit),
    }
}

fn freeOwned(s: []const u8) void {
    if (s.len == 0) return;
    std.heap.page_allocator.free(s);
}

fn firstLine(s: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, s, '\n')) |i| return s[0..i];
    return s;
}

test "firstLine keeps only the first line of multi-line stderr" {
    try std.testing.expectEqualStrings("boom", firstLine("boom\nat line 2\n"));
    try std.testing.expectEqualStrings("boom", firstLine("boom"));
}

var cached_filesystems: ?[]const []const u8 = null;

fn filesystems() []const []const u8 {
    if (cached_filesystems) |fs| return fs;
    const list = blockops.supportedFilesystems(std.heap.page_allocator);
    cached_filesystems = list;
    return list;
}

pub const FormatTarget = struct {
    path: []const u8,
    name: []const u8,
    dev: []const u8,
    size_text: []const u8,
    contents: []const u8,
    whole_disk: bool,
    extra_warning: []const u8 = "",
};

pub fn formatDevice(parent: *gtk.Window, target: FormatTarget, reporter: Reporter) void {
    const alloc = std.heap.page_allocator;
    const flow = alloc.create(FormatFlow) catch return;
    flow.* = .{
        .reporter = reporter,
        .path = alloc.dupe(u8, target.path) catch target.path,
        .name = alloc.dupe(u8, target.name) catch target.name,
        .whole_disk = target.whole_disk,
    };

    dialogs.showFormat(parent, .{
        .name = target.name,
        .dev = target.dev,
        .size_text = target.size_text,
        .contents = target.contents,
        .whole_disk = target.whole_disk,
        .extra_warning = target.extra_warning,
    }, filesystems(), &onFormatChosen, flow);
}

pub const TableTarget = struct {
    path: []const u8,
    name: []const u8,
    title: []const u8,
    size_text: []const u8,
    contents: []const u8,
    partition_count: usize,
};

pub fn createPartitionTable(parent: *gtk.Window, target: TableTarget, reporter: Reporter) void {
    const alloc = std.heap.page_allocator;
    const flow = alloc.create(TableFlow) catch return;
    flow.* = .{
        .reporter = reporter,
        .path = alloc.dupe(u8, target.path) catch target.path,
        .name = alloc.dupe(u8, target.name) catch target.name,
    };

    dialogs.showPartitionTable(parent, .{
        .disk_title = target.title,
        .disk_name = target.name,
        .size_text = target.size_text,
        .partition_count = target.partition_count,
        .contents = target.contents,
    }, &onTableChosen, flow);
}

pub const PartitionTarget = struct {
    disk_path: []const u8,
    disk_name: []const u8,
    disk_title: []const u8,
    regions: []const dialogs.RegionChoice,
};

pub fn createPartition(parent: *gtk.Window, target: PartitionTarget, reporter: Reporter) void {
    const alloc = std.heap.page_allocator;
    const flow = alloc.create(PartitionFlow) catch return;
    flow.* = .{
        .reporter = reporter,
        .disk_path = alloc.dupe(u8, target.disk_path) catch target.disk_path,
        .disk_name = alloc.dupe(u8, target.disk_name) catch target.disk_name,
    };

    dialogs.showNewPartition(parent, .{
        .disk_title = target.disk_title,
        .disk_name = target.disk_name,
    }, target.regions, filesystems(), &onPartitionChosen, flow);
}

pub const ResizeTarget = struct {
    path: []const u8,
    name: []const u8,
    dev: []const u8,
    window: blockops.ResizeWindow,
};

pub fn resizePartition(parent: *gtk.Window, target: ResizeTarget, reporter: Reporter) void {
    const alloc = std.heap.page_allocator;
    const flow = alloc.create(ResizeFlow) catch return;
    flow.* = .{
        .reporter = reporter,
        .path = alloc.dupe(u8, target.path) catch target.path,
        .name = alloc.dupe(u8, target.name) catch target.name,
    };

    var current_buf: [16]u8 = undefined;
    var max_buf: [16]u8 = undefined;
    dialogs.showResize(parent, .{
        .name = target.name,
        .dev = target.dev,
        .current_text = ui.z(format.humanSize(&current_buf, target.window.size)),
        .max_text = ui.z(format.humanSize(&max_buf, target.window.max_size)),
        .window = target.window,
    }, &onResizeChosen, flow);
}

pub fn deletePartition(parent: *gtk.Window, path: []const u8, name: []const u8, reporter: Reporter) void {
    const alloc = std.heap.page_allocator;
    const flow = alloc.create(DeleteFlow) catch return;
    flow.* = .{
        .reporter = reporter,
        .path = alloc.dupe(u8, path) catch path,
        .name = alloc.dupe(u8, name) catch name,
    };

    dialogs.showConfirm(parent, .{
        .title = "Delete partition",
        .body = ui.zFmt(
            "The {s} partition will be removed from the partition table.\n\n" ++
                "Its contents become unreachable, and the space is left unallocated " ++
                "until you create a new partition there.",
            .{name},
        ),
        .confirm_label = "Delete",
        .danger = true,
    }, &onDeleteAnswer, flow);
}

const FormatFlow = struct {
    reporter: Reporter,
    path: []const u8,
    name: []const u8,
    whole_disk: bool,
};

const TableFlow = struct {
    reporter: Reporter,
    path: []const u8,
    name: []const u8,
};

const PartitionFlow = struct {
    reporter: Reporter,
    disk_path: []const u8,
    disk_name: []const u8,
};

const DeleteFlow = struct {
    reporter: Reporter,
    path: []const u8,
    name: []const u8,
};

const ResizeFlow = struct {
    reporter: Reporter,
    path: []const u8,
    name: []const u8,
};

fn onResizeChosen(ud: ?*anyopaque, choice: ?dialogs.ResizeChoice) void {
    const flow: *ResizeFlow = @ptrCast(@alignCast(ud.?));
    const c = choice orelse {
        freeOwned(flow.path);
        freeOwned(flow.name);
        std.heap.page_allocator.destroy(flow);
        return;
    };

    const reporter = flow.reporter;
    const req = BlockRequest{ .resize = .{ .path = flow.path, .name = flow.name, .size = c.size } };
    std.heap.page_allocator.destroy(flow);
    submitBlock(reporter, req);
}

fn onFormatChosen(ud: ?*anyopaque, choice: ?dialogs.FormatChoice) void {
    const flow: *FormatFlow = @ptrCast(@alignCast(ud.?));
    const c = choice orelse {
        freeOwned(flow.path);
        freeOwned(flow.name);
        std.heap.page_allocator.destroy(flow);
        return;
    };

    const reporter = flow.reporter;
    const req = BlockRequest{ .format = .{
        .path = flow.path,
        .name = flow.name,
        .fs_type = c.fs_type,
        .label = c.label,
        .erase = c.erase,
        .whole_disk = flow.whole_disk,
    } };
    std.heap.page_allocator.destroy(flow);
    submitBlock(reporter, req);
}

fn onTableChosen(ud: ?*anyopaque, table_type: ?[]const u8) void {
    const flow: *TableFlow = @ptrCast(@alignCast(ud.?));
    const chosen = table_type orelse {
        freeOwned(flow.path);
        freeOwned(flow.name);
        std.heap.page_allocator.destroy(flow);
        return;
    };

    const reporter = flow.reporter;
    const req = BlockRequest{ .create_table = .{
        .path = flow.path,
        .name = flow.name,
        .table_type = chosen,
    } };
    std.heap.page_allocator.destroy(flow);
    submitBlock(reporter, req);
}

fn onPartitionChosen(ud: ?*anyopaque, choice: ?dialogs.PartitionChoice) void {
    const flow: *PartitionFlow = @ptrCast(@alignCast(ud.?));
    const c = choice orelse {
        freeOwned(flow.disk_path);
        freeOwned(flow.disk_name);
        std.heap.page_allocator.destroy(flow);
        return;
    };

    const reporter = flow.reporter;
    const req = BlockRequest{ .create_partition = .{
        .disk_path = flow.disk_path,
        .disk_name = flow.disk_name,
        .offset = c.offset,
        .size = c.size,
        .part_name = c.name,
        .fs_type = c.fs_type,
        .label = c.label,
    } };
    std.heap.page_allocator.destroy(flow);
    submitBlock(reporter, req);
}

fn onDeleteAnswer(ud: ?*anyopaque, proceed: bool) void {
    const flow: *DeleteFlow = @ptrCast(@alignCast(ud.?));
    if (!proceed) {
        freeOwned(flow.path);
        freeOwned(flow.name);
        std.heap.page_allocator.destroy(flow);
        return;
    }

    const reporter = flow.reporter;
    const req = BlockRequest{ .delete_partition = .{ .path = flow.path, .name = flow.name } };
    std.heap.page_allocator.destroy(flow);
    submitBlock(reporter, req);
}

const BlockRequest = union(enum) {
    format: struct {
        path: []const u8,
        name: []const u8,
        fs_type: []const u8,
        label: []const u8,
        erase: bool,
        whole_disk: bool,
    },
    create_table: struct {
        path: []const u8,
        name: []const u8,
        table_type: []const u8,
    },
    create_partition: struct {
        disk_path: []const u8,
        disk_name: []const u8,
        offset: u64,
        size: u64,
        part_name: []const u8,
        fs_type: []const u8,
        label: []const u8,
    },
    delete_partition: struct {
        path: []const u8,
        name: []const u8,
    },
    resize: struct {
        path: []const u8,
        name: []const u8,
        size: u64,
    },
};

const BlockOutcome = struct {
    ok: bool,
    message: []const u8,
};

const BlockOp = struct {
    reporter: Reporter,
    req: BlockRequest,
    result: ?BlockOutcome = null,
};

fn submitBlock(reporter: Reporter, req: BlockRequest) void {
    const op = std.heap.page_allocator.create(BlockOp) catch {
        freeBlockRequest(req);
        return;
    };
    op.* = .{ .reporter = reporter, .req = req };

    reporter.setBusy(reporter.ud, true);
    ui.spawnJob(BlockOp, runBlockOp, op) catch {
        std.heap.page_allocator.destroy(op);
        freeBlockRequest(req);
        reporter.setBusy(reporter.ud, false);
    };
}

fn runBlockOp(op: *BlockOp) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const res = switch (op.req) {
        .format => |f| blockops.format(alloc, f.path, f.fs_type, f.label, f.erase, f.whole_disk),
        .create_table => |t| blockops.createPartitionTable(alloc, t.path, t.table_type),
        .create_partition => |p| blockops.createPartition(alloc, p.disk_path, p.offset, p.size, p.part_name, p.fs_type, p.label),
        .delete_partition => |d| blockops.deletePartition(alloc, d.path),
        .resize => |r| blockops.resizePartition(alloc, r.path, r.size),
    };

    if (res.reply) |r| r.unref();
    op.result = .{
        .ok = res.ok,
        .message = std.heap.page_allocator.dupe(u8, res.message) catch "operation failed",
    };

    ui.idle(BlockOp, finishBlockOp, op);
}

fn finishBlockOp(op: *BlockOp) void {
    const res = op.result.?;
    const outcome: Outcome = if (res.ok)
        .{ .ok = true, .cancelled = false, .message = blockSuccess(op.req) }
    else if (authCancelled(res.message))
        .{ .ok = false, .cancelled = true, .message = "Authentication cancelled" }
    else
        .{ .ok = false, .cancelled = false, .message = ui.zFmt("{s} failed: {s}", .{ blockVerb(op.req), res.message }) };

    op.reporter.setBusy(op.reporter.ud, false);
    op.reporter.report(op.reporter.ud, outcome);

    std.heap.page_allocator.free(res.message);
    freeBlockRequest(op.req);
    std.heap.page_allocator.destroy(op);
}

fn authCancelled(message: []const u8) bool {
    return std.mem.indexOf(u8, message, "Not authorized") != null or
        std.mem.indexOf(u8, message, "Authentication was canceled") != null or
        std.mem.indexOf(u8, message, "Authentication was cancelled") != null;
}

fn blockVerb(req: BlockRequest) []const u8 {
    return switch (req) {
        .format => "Format",
        .create_table => "Create partition table",
        .create_partition => "Create partition",
        .delete_partition => "Delete partition",
        .resize => "Resize",
    };
}

fn blockSuccess(req: BlockRequest) []const u8 {
    return switch (req) {
        .format => |f| ui.zFmt("Formatted {s} as {s}", .{ f.name, f.fs_type }),
        .create_table => |t| ui.zFmt("Created a {s} table on {s}", .{ tableWord(t.table_type), t.name }),
        .create_partition => |p| ui.zFmt("Created a partition on {s} as {s}", .{ p.disk_name, p.fs_type }),
        .delete_partition => |d| ui.zFmt("Deleted partition {s}", .{d.name}),
        .resize => |r| blk: {
            var buf: [16]u8 = undefined;
            break :blk ui.zFmt("Resized {s} to {s}", .{ r.name, format.humanSize(&buf, r.size) });
        },
    };
}

fn tableWord(table_type: []const u8) []const u8 {
    if (std.mem.eql(u8, table_type, "gpt")) return "GPT";
    if (std.mem.eql(u8, table_type, "dos")) return "MBR";
    return table_type;
}

fn freeBlockRequest(req: BlockRequest) void {
    switch (req) {
        .format => |f| {
            freeOwned(f.path);
            freeOwned(f.name);
            freeOwned(f.fs_type);
            freeOwned(f.label);
        },
        .create_table => |t| {
            freeOwned(t.path);
            freeOwned(t.name);
        },
        .create_partition => |p| {
            freeOwned(p.disk_path);
            freeOwned(p.disk_name);
            freeOwned(p.part_name);
            freeOwned(p.fs_type);
            freeOwned(p.label);
        },
        .delete_partition => |d| {
            freeOwned(d.path);
            freeOwned(d.name);
        },
        .resize => |r| {
            freeOwned(r.path);
            freeOwned(r.name);
        },
    }
}

test "authCancelled reads a dismissed polkit dialog as a cancellation" {
    try std.testing.expect(authCancelled("Not authorized to perform operation"));
    try std.testing.expect(authCancelled("Authentication was cancelled"));
    try std.testing.expect(!authCancelled("Device is mounted"));
    try std.testing.expect(!authCancelled(""));
}

test "tableWord spells out the two table types and passes others through" {
    try std.testing.expectEqualStrings("GPT", tableWord("gpt"));
    try std.testing.expectEqualStrings("MBR", tableWord("dos"));
    try std.testing.expectEqualStrings("pmbr", tableWord("pmbr"));
}
