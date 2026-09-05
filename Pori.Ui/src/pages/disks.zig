const std = @import("std");
const Pori = @import("Pori");
const gtk = Pori.gtk;
const glib = Pori.glib;
const ui = @import("../helpers/ui.zig");
const env = @import("../helpers/env.zig");
const devices = @import("../services/devices.zig");
const format = @import("../helpers/format.zig");
const dialogs = @import("../dialogs.zig");
const privops = @import("../services/privops.zig");

pub const DisksPage = struct {
    root: *gtk.Box,
    flow: *gtk.FlowBox,
    parent: *gtk.Window,
    mount_button: *gtk.Button,
    refresh_btn: *gtk.Button,
    status: *gtk.Label,

    arena: std.heap.ArenaAllocator,
    list: []const devices.Device,
    selected: ?*const devices.Device,
    busy: bool,

    pub fn build(alloc: std.mem.Allocator, parent: *gtk.Window) !*DisksPage {
        const self = try alloc.create(DisksPage);

        const root = gtk.Box.new(.vertical, 0);

        const status = ui.statusLabel();
        const header = ui.pageHeader("Disks", status);

        const mount_button = gtk.Button.newWithLabel(ui.z("Mount Disk"));
        ui.widget(mount_button).addCssClass(ui.z("suggested-action"));
        ui.widget(mount_button).setSensitive(0);
        ui.widget(mount_button).setTooltipText(ui.z("Create a mount unit for the selected disk"));

        const refresh_btn = ui.refreshButton();

        gtk.Box.append(header, ui.widget(mount_button));
        gtk.Box.append(header, ui.widget(refresh_btn));
        gtk.Box.append(root, ui.widget(header));

        const flow = gtk.FlowBox.new();
        flow.setSelectionMode(.single);
        flow.setHomogeneous(1);
        flow.setMinChildrenPerLine(1);
        flow.setMaxChildrenPerLine(4);
        const flow_w = ui.widget(flow);
        flow_w.setMarginStart(10);
        flow_w.setMarginEnd(10);
        flow_w.setMarginTop(6);
        flow_w.setMarginBottom(10);
        flow.setColumnSpacing(8);
        flow.setRowSpacing(8);

        gtk.Box.append(root, ui.widget(ui.scrolled(ui.widget(flow))));

        self.* = .{
            .root = root,
            .flow = flow,
            .parent = parent,
            .mount_button = mount_button,
            .refresh_btn = refresh_btn,
            .status = status,
            .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
            .list = &.{},
            .selected = null,
            .busy = false,
        };

        _ = gtk.Button.signals.clicked.connect(mount_button, *DisksPage, &onMountClicked, self, .{});
        _ = gtk.Button.signals.clicked.connect(refresh_btn, *DisksPage, &onRefresh, self, .{});
        _ = gtk.FlowBox.signals.selected_children_changed.connect(flow, *DisksPage, &onSelectionChanged, self, .{});

        self.refresh();
        return self;
    }

    pub fn refresh(self: *DisksPage) void {
        // Drop the previous snapshot; `list` and everything it points into
        // live in this arena.
        self.arena.deinit();
        self.arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

        self.list = devices.list(self.arena.allocator()) catch &.{};
        self.selected = null;
        self.populate();
        ui.setStatus(self.status, ui.z("dim-label"), ui.zFmt("{d} device(s)", .{self.list.len}));
    }

    fn populate(self: *DisksPage) void {
        self.flow.removeAll();
        for (self.list) |*d| {
            self.flow.append(createCard(d));
        }
        self.updateMountButton();
    }

    fn createCard(d: *const devices.Device) *gtk.Widget {
        const frame = gtk.Frame.new(null);
        const f_w = ui.widget(frame);
        f_w.addCssClass(ui.z("card"));
        f_w.addCssClass(ui.z("pori-card"));
        f_w.setSizeRequest(230, -1);

        const box = gtk.Box.new(.vertical, 4);
        const b_w = ui.widget(box);
        b_w.setMarginTop(10);
        b_w.setMarginBottom(10);
        b_w.setMarginStart(10);
        b_w.setMarginEnd(10);

        ui.cardField(box, "Name", d.name, true);
        ui.cardField(box, "Type", d.fs_type, false);
        if (d.fs_version.len > 0) ui.cardField(box, "Version", d.fs_version, false);
        if (d.label.len > 0) ui.cardField(box, "Label", d.label, false);
        ui.cardField(box, "UUID", d.uuid, false);

        var size_buf: [16]u8 = undefined;
        ui.cardField(box, "Size", format.humanSize(&size_buf, d.size), false);

        if (d.mounted()) {
            if (devices.usage(d.*)) |usage| {
                var avail_buf: [16]u8 = undefined;
                ui.cardField(box, "Available", format.humanSize(&avail_buf, usage.avail_bytes), false);
                ui.cardField(box, "Use%", ui.zFmt("{d}%", .{usage.used_percent}), false);

                const bar = gtk.LevelBar.new();
                bar.setMinValue(0);
                bar.setMaxValue(100);
                bar.setValue(@floatFromInt(usage.used_percent));
                bar.addOffsetValue(ui.z("low"), 33);
                bar.addOffsetValue(ui.z("high"), 66);
                bar.addOffsetValue(ui.z("full"), 100);
                ui.widget(bar).setMarginTop(2);
                ui.widget(bar).setMarginBottom(4);
                gtk.Box.append(box, ui.widget(bar));
            }

            const badge = gtk.Label.new(ui.zFmt("Mounted at {s}", .{d.mount_points[0]}));
            ui.widget(badge).addCssClass(ui.z("mount-badge"));
            badge.setXalign(0);
            ui.widget(badge).setMarginTop(4);
            gtk.Box.append(box, ui.widget(badge));
        }

        frame.setChild(b_w);
        return f_w;
    }

    fn onSelectionChanged(flow: *gtk.FlowBox, self: *DisksPage) callconv(.c) void {
        self.selected = null;
        if (ui.selectedFirst(flow)) |first| {
            var node: ?*glib.List = first;
            while (node) |n| : (node = n.f_next) {
                const child: *gtk.FlowBoxChild = @ptrCast(@alignCast(n.f_data.?));
                const idx = child.getIndex();
                if (idx >= 0 and @as(usize, @intCast(idx)) < self.list.len) {
                    self.selected = &self.list[@as(usize, @intCast(idx))];
                }
            }
        }
        self.updateMountButton();
    }

    fn updateMountButton(self: *DisksPage) void {
        const enabled = if (self.selected) |d| !d.mounted() and !self.busy else false;
        ui.widget(self.mount_button).setSensitive(@intFromBool(enabled));
    }

    fn onRefresh(btn: *gtk.Button, self: *DisksPage) callconv(.c) void {
        _ = btn;
        self.refresh();
    }

    fn onMountClicked(btn: *gtk.Button, self: *DisksPage) callconv(.c) void {
        _ = btn;
        const d = self.selected orelse return;
        if (d.mounted() or self.busy) return;

        const ctx = std.heap.page_allocator.create(MountCtx) catch return;
        ctx.* = .{ .page = self, .device = d };

        if (std.ascii.eqlIgnoreCase(d.fs_type, "ntfs")) {
            dialogs.showNtfsWarning(self.parent, &onNtfsAnswer, ctx);
        } else {
            startOptions(ctx);
        }
    }

    fn onNtfsAnswer(ud: ?*anyopaque, proceed: bool) void {
        const ctx: *MountCtx = @ptrCast(@alignCast(ud.?));
        if (!proceed) {
            std.heap.page_allocator.destroy(ctx);
            return;
        }
        startOptions(ctx);
    }

    fn startOptions(ctx: *MountCtx) void {
        const d = ctx.device;
        const home = env.get("HOME") orelse "/root";

        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        const default_mp = std.fmt.allocPrint(arena.allocator(), "{s}/mnt/{s}", .{ home, d.name }) catch d.name;

        const info = dialogs.DeviceInfo{
            .name = d.name,
            .fs_type = d.fs_type,
            .uuid = d.uuid,
            .default_mount_point = default_mp,
        };
        dialogs.showMountOptions(ctx.page.parent, .create, info, null, &onOptionsChosen, ctx);
        arena.deinit();
    }

    fn onOptionsChosen(ud: ?*anyopaque, choice: ?dialogs.MountChoice) void {
        const ctx: *MountCtx = @ptrCast(@alignCast(ud.?));
        const c = choice orelse {
            std.heap.page_allocator.destroy(ctx);
            return;
        };

        const job = std.heap.page_allocator.create(MountJob) catch {
            std.heap.page_allocator.destroy(ctx);
            return;
        };
        job.* = .{
            .page = ctx.page,
            .device = ctx.device,
            .description = c.description,
            .mount_point = c.mount_point,
            .options = c.options,
        };
        std.heap.page_allocator.destroy(ctx);

        ctxDone(job.page, true);
        ui.spawnJob(MountJob, runMountJob, job) catch {
            std.heap.page_allocator.destroy(job);
            ctxDone(job.page, false);
        };
    }

    pub fn widget(self: *DisksPage) *gtk.Widget {
        return ui.widget(self.root);
    }
};

fn ctxDone(page: *DisksPage, busy: bool) void {
    page.busy = busy;
    page.updateMountButton();
    ui.widget(page.refresh_btn).setSensitive(@intFromBool(!busy));
}

const MountCtx = struct {
    page: *DisksPage,
    device: *const devices.Device,
};

const MountJob = struct {
    page: *DisksPage,
    device: *const devices.Device,
    description: []const u8,
    mount_point: []const u8,
    options: []const u8,
    result: ?privops.OpResult = null,
};

fn runMountJob(job: *MountJob) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    job.result = privops.createMountUnit(
        arena.allocator(),
        job.description,
        job.device.uuid,
        job.mount_point,
        job.device.fs_type,
        job.options,
    ) catch privops.OpResult{ .ok = false, .cancelled = false, .output = "", .err = "failed to start operation", .exit_code = -1 };

    ui.idle(MountJob, finishMountJob, job);
}

fn finishMountJob(job: *MountJob) void {
    const page = job.page;
    const res = job.result.?;

    if (res.ok) {
        ui.setStatus(page.status, ui.z("success-label"), ui.zFmt("Mounted {s} at {s}", .{ job.device.name, job.mount_point }));
        page.refresh();
    } else if (res.cancelled) {
        ui.setStatus(page.status, ui.z("dim-label"), ui.z("Authentication cancelled"));
    } else {
        ui.setStatus(page.status, ui.z("error-label"), ui.zFmt("Mount failed: {s}", .{firstLine(res.err)}));
    }

    ctxDone(page, false);
    std.heap.page_allocator.destroy(job);
}

fn firstLine(s: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, s, '\n')) |i| return s[0..i];
    return s;
}
