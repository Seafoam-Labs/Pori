const std = @import("std");
const Pori = @import("Pori");
const gtk = Pori.gtk;
const glib = Pori.glib;
const ui = @import("../helpers/ui.zig");
const units = @import("../services/units.zig");
const privops = @import("../services/privops.zig");

pub const UnmountPage = struct {
    root: *gtk.Box,
    flow: *gtk.FlowBox,
    unmount_button: *gtk.Button,
    refresh_btn: *gtk.Button,
    status: *gtk.Label,

    arena: std.heap.ArenaAllocator,
    list: []const units.MountUnit,
    selected: ?*const units.MountUnit,
    busy: bool,

    pub fn build(alloc: std.mem.Allocator) !*UnmountPage {
        const self = try alloc.create(UnmountPage);

        const root = gtk.Box.new(.vertical, 0);

        const status = ui.statusLabel();
        const header = ui.pageHeader("Unmount", status);

        const unmount_button = gtk.Button.newWithLabel(ui.z("Remove Mount"));
        ui.widget(unmount_button).addCssClass(ui.z("destructive-action"));
        ui.widget(unmount_button).setSensitive(0);
        ui.widget(unmount_button).setTooltipText(ui.z("Stop the mount and remove its unit file"));

        const refresh_btn = ui.refreshButton();

        gtk.Box.append(header, ui.widget(unmount_button));
        gtk.Box.append(header, ui.widget(refresh_btn));
        gtk.Box.append(root, ui.widget(header));

        const flow = gtk.FlowBox.new();
        flow.setSelectionMode(.single);
        flow.setHomogeneous(1);
        flow.setMinChildrenPerLine(1);
        flow.setMaxChildrenPerLine(3);
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
            .unmount_button = unmount_button,
            .refresh_btn = refresh_btn,
            .status = status,
            .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
            .list = &.{},
            .selected = null,
            .busy = false,
        };

        _ = gtk.Button.signals.clicked.connect(unmount_button, *UnmountPage, &onUnmountClicked, self, .{});
        _ = gtk.Button.signals.clicked.connect(refresh_btn, *UnmountPage, &onRefresh, self, .{});
        _ = gtk.FlowBox.signals.selected_children_changed.connect(flow, *UnmountPage, &onSelectionChanged, self, .{});

        self.refresh();
        return self;
    }

    pub fn refresh(self: *UnmountPage) void {
        self.arena.deinit();
        self.arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        const alloc = self.arena.allocator();

        const names = units.listEtcMountUnits(alloc) catch &.{};

        var found: std.ArrayList(units.MountUnit) = .empty;
        for (names) |name| {
            if (units.unitInfo(alloc, name) catch null) |unit| {
                found.append(alloc, unit) catch {};
            }
        }

        self.list = found.items;
        self.selected = null;
        self.populate();
        ui.setStatus(self.status, ui.z("dim-label"), ui.zFmt("{d} mount unit(s)", .{self.list.len}));
    }

    fn populate(self: *UnmountPage) void {
        self.flow.removeAll();
        for (self.list) |*u| {
            self.flow.append(createCard(u));
        }
        self.updateUnmountButton();
    }

    fn createCard(u: *const units.MountUnit) *gtk.Widget {
        const frame = gtk.Frame.new(null);
        const f_w = ui.widget(frame);
        f_w.addCssClass(ui.z("card"));
        f_w.addCssClass(ui.z("pori-card"));
        f_w.setSizeRequest(280, -1);

        const box = gtk.Box.new(.vertical, 4);
        const b_w = ui.widget(box);
        b_w.setMarginTop(10);
        b_w.setMarginBottom(10);
        b_w.setMarginStart(10);
        b_w.setMarginEnd(10);

        const title = gtk.Label.new(ui.z(u.name));
        ui.widget(title).addCssClass(ui.z("heading"));
        title.setXalign(0);
        title.setEllipsize(.end);
        gtk.Box.append(box, ui.widget(title));

        if (u.description.len > 0) ui.cardField(box, "Description", u.description, false);
        if (u.where.len > 0) ui.cardField(box, "Mount Point", u.where, false);
        if (u.what.len > 0) ui.cardField(box, "Device", u.what, false);

        const state = gtk.Label.new(ui.zFmt("{s} ({s})", .{ u.active_state, u.sub_state }));
        ui.widget(state).addCssClass(if (std.mem.eql(u8, u.active_state, "active")) ui.z("success-label") else ui.z("dim-label"));
        state.setXalign(0);
        ui.widget(state).setMarginTop(4);
        gtk.Box.append(box, ui.widget(state));

        frame.setChild(b_w);
        return f_w;
    }

    fn onSelectionChanged(flow: *gtk.FlowBox, self: *UnmountPage) callconv(.c) void {
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
        self.updateUnmountButton();
    }

    fn updateUnmountButton(self: *UnmountPage) void {
        const enabled = self.selected != null and !self.busy;
        ui.widget(self.unmount_button).setSensitive(@intFromBool(enabled));
    }

    fn onRefresh(btn: *gtk.Button, self: *UnmountPage) callconv(.c) void {
        _ = btn;
        self.refresh();
    }

    fn onUnmountClicked(btn: *gtk.Button, self: *UnmountPage) callconv(.c) void {
        _ = btn;
        const u = self.selected orelse return;
        if (self.busy) return;

        const job = std.heap.page_allocator.create(UnmountJob) catch return;
        job.* = .{
            .page = self,
            // Dup the arena-backed name: the arena resets on refresh.
            .unit = std.heap.page_allocator.dupe(u8, u.name) catch u.name,
        };

        self.setBusy(true);
        ui.spawnJob(UnmountJob, runUnmountJob, job) catch {
            std.heap.page_allocator.destroy(job);
            self.setBusy(false);
        };
    }

    fn setBusy(self: *UnmountPage, busy: bool) void {
        self.busy = busy;
        self.updateUnmountButton();
        ui.widget(self.refresh_btn).setSensitive(@intFromBool(!busy));
    }

    pub fn widget(self: *UnmountPage) *gtk.Widget {
        return ui.widget(self.root);
    }
};

const UnmountJob = struct {
    page: *UnmountPage,
    unit: []const u8,
    result: ?privops.OpResult = null,
};

fn runUnmountJob(job: *UnmountJob) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    job.result = privops.deleteMountUnit(arena.allocator(), job.unit) catch
        privops.OpResult{ .ok = false, .cancelled = false, .output = "", .err = "failed to start operation", .exit_code = -1 };

    ui.idle(UnmountJob, finishUnmountJob, job);
}

fn finishUnmountJob(job: *UnmountJob) void {
    const page = job.page;
    const res = job.result.?;

    if (res.ok) {
        page.refresh();
        ui.setStatus(page.status, ui.z("success-label"), ui.zFmt("Removed {s}", .{job.unit}));
    } else if (res.cancelled) {
        ui.setStatus(page.status, ui.z("dim-label"), ui.z("Authentication cancelled"));
    } else {
        ui.setStatus(page.status, ui.z("error-label"), ui.zFmt("Remove failed: {s}", .{firstLine(res.err)}));
    }

    page.setBusy(false);
    std.heap.page_allocator.free(job.unit);
    std.heap.page_allocator.destroy(job);
}

fn firstLine(s: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, s, '\n')) |i| return s[0..i];
    return s;
}
