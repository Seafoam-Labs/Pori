const std = @import("std");
const Pori = @import("Pori");
const gtk = Pori.gtk;
const glib = Pori.glib;
const ui = @import("../helpers/ui.zig");
const units = @import("../services/units.zig");
const dialogs = @import("../dialogs.zig");
const privops = @import("../services/privops.zig");

pub const EditPage = struct {
    root: *gtk.Box,
    flow: *gtk.FlowBox,
    parent: *gtk.Window,
    edit_button: *gtk.Button,
    refresh_btn: *gtk.Button,
    status: *gtk.Label,

    arena: std.heap.ArenaAllocator,
    list: []const units.MountUnit,
    selected: ?*const units.MountUnit,
    busy: bool,

    pub fn build(alloc: std.mem.Allocator, parent: *gtk.Window) !*EditPage {
        const self = try alloc.create(EditPage);

        const root = gtk.Box.new(.vertical, 0);

        const status = ui.statusLabel();
        const header = ui.pageHeader("Mount Units", status);

        const edit_button = gtk.Button.newWithLabel(ui.z("Edit Mount"));
        ui.widget(edit_button).addCssClass(ui.z("suggested-action"));
        ui.widget(edit_button).setSensitive(0);

        const refresh_btn = ui.refreshButton();

        gtk.Box.append(header, ui.widget(edit_button));
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
            .parent = parent,
            .edit_button = edit_button,
            .refresh_btn = refresh_btn,
            .status = status,
            .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
            .list = &.{},
            .selected = null,
            .busy = false,
        };

        _ = gtk.Button.signals.clicked.connect(edit_button, *EditPage, &onEditClicked, self, .{});
        _ = gtk.Button.signals.clicked.connect(refresh_btn, *EditPage, &onRefresh, self, .{});
        _ = gtk.FlowBox.signals.selected_children_changed.connect(flow, *EditPage, &onSelectionChanged, self, .{});

        self.refresh();
        return self;
    }

    pub fn refresh(self: *EditPage) void {
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

        if (names.len == 0) {
            ui.setStatus(self.status, ui.z("dim-label"), ui.z("No Pori mount units yet — mount a disk first"));
        } else {
            ui.setStatus(self.status, ui.z("dim-label"), ui.zFmt("{d} mount unit(s)", .{self.list.len}));
        }
    }

    fn populate(self: *EditPage) void {
        self.flow.removeAll();
        for (self.list) |*u| {
            self.flow.append(createCard(u));
        }
        self.updateEditButton();
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
        if (u.where.len > 0) ui.cardField(box, "Where", u.where, false);
        if (u.what.len > 0) ui.cardField(box, "What", u.what, false);
        if (u.fs_type.len > 0) ui.cardField(box, "Type", u.fs_type, false);
        if (u.options.len > 0) ui.cardField(box, "Options", u.options, false);

        const state = gtk.Label.new(ui.zFmt("{s} ({s})", .{ u.active_state, u.sub_state }));
        ui.widget(state).addCssClass(if (std.mem.eql(u8, u.active_state, "active")) ui.z("success-label") else ui.z("dim-label"));
        state.setXalign(0);
        ui.widget(state).setMarginTop(4);
        gtk.Box.append(box, ui.widget(state));

        frame.setChild(b_w);
        return f_w;
    }

    fn onSelectionChanged(flow: *gtk.FlowBox, self: *EditPage) callconv(.c) void {
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
        self.updateEditButton();
    }

    fn updateEditButton(self: *EditPage) void {
        const enabled = self.selected != null and !self.busy;
        ui.widget(self.edit_button).setSensitive(@intFromBool(enabled));
    }

    fn onRefresh(btn: *gtk.Button, self: *EditPage) callconv(.c) void {
        _ = btn;
        self.refresh();
    }

    fn onEditClicked(btn: *gtk.Button, self: *EditPage) callconv(.c) void {
        _ = btn;
        const u = self.selected orelse return;
        if (self.busy) return;

        const ctx = std.heap.page_allocator.create(EditCtx) catch return;
        ctx.* = .{ .page = self, .unit = u };

        const info = dialogs.EditInfo{
            .unit_name = u.name,
            .where = u.where,
            .description = u.description,
            .fs_type = u.fs_type,
            .current_options = u.options,
        };
        dialogs.showMountOptions(self.parent, .edit, null, info, &onOptionsChosen, ctx);
    }

    fn onOptionsChosen(ud: ?*anyopaque, choice: ?dialogs.MountChoice) void {
        const ctx: *EditCtx = @ptrCast(@alignCast(ud.?));
        const c = choice orelse {
            std.heap.page_allocator.destroy(ctx);
            return;
        };

        const job = std.heap.page_allocator.create(EditJob) catch {
            std.heap.page_allocator.destroy(ctx);
            return;
        };

        job.* = .{
            .page = ctx.page,
            .old_unit = std.heap.page_allocator.dupe(u8, ctx.unit.name) catch ctx.unit.name,
            .description = c.description,
            .mount_point = c.mount_point,
            .fs_type = std.heap.page_allocator.dupe(u8, ctx.unit.fs_type) catch ctx.unit.fs_type,
            .options = c.options,
        };
        std.heap.page_allocator.destroy(ctx);

        job.page.setBusy(true);
        ui.spawnJob(EditJob, runEditJob, job) catch {
            job.page.setBusy(false);
            std.heap.page_allocator.destroy(job);
        };
    }

    fn setBusy(self: *EditPage, busy: bool) void {
        self.busy = busy;
        self.updateEditButton();
        ui.widget(self.refresh_btn).setSensitive(@intFromBool(!busy));
    }

    pub fn widget(self: *EditPage) *gtk.Widget {
        return ui.widget(self.root);
    }
};

const EditCtx = struct {
    page: *EditPage,
    unit: *const units.MountUnit,
};

const EditJob = struct {
    page: *EditPage,
    old_unit: []const u8,
    description: []const u8,
    mount_point: []const u8,
    fs_type: []const u8,
    options: []const u8,
    result: ?privops.OpResult = null,
};

fn runEditJob(job: *EditJob) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    job.result = privops.editMountUnit(
        arena.allocator(),
        job.old_unit,
        job.description,
        job.mount_point,
        job.fs_type,
        job.options,
    ) catch privops.OpResult{ .ok = false, .cancelled = false, .output = "", .err = "failed to start operation", .exit_code = -1 };

    ui.idle(EditJob, finishEditJob, job);
}

fn finishEditJob(job: *EditJob) void {
    const page = job.page;
    const res = job.result.?;

    if (res.ok) {
        page.refresh();
        ui.setStatus(page.status, ui.z("success-label"), ui.zFmt("Saved {s}", .{job.mount_point}));
    } else if (res.cancelled) {
        ui.setStatus(page.status, ui.z("dim-label"), ui.z("Authentication cancelled"));
    } else {
        ui.setStatus(page.status, ui.z("error-label"), ui.zFmt("Edit failed: {s}", .{firstLine(res.err)}));
    }

    page.setBusy(false);
    std.heap.page_allocator.free(job.old_unit);
    std.heap.page_allocator.free(job.fs_type);
    std.heap.page_allocator.destroy(job);
}

fn firstLine(s: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, s, '\n')) |i| return s[0..i];
    return s;
}
