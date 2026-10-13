const std = @import("std");
const Pori = @import("Pori");
const gtk = Pori.gtk;
const ui = @import("../helpers/ui.zig");
const format = @import("../helpers/format.zig");
const actions = @import("../actions.zig");
const dialogs = @import("../dialogs.zig");
const devices = @import("../services/devices.zig");
const units = @import("../services/units.zig");
const blockops = @import("../services/blockops.zig");
const watch = @import("../services/watch.zig");

pub const State = enum {
    mounted,
    managed,
    unmanaged,

    pub fn of(d: devices.Device, unit: ?*const units.MountUnit) State {
        if (d.mounted()) return .mounted;
        return if (unit != null) .managed else .unmanaged;
    }

    pub fn badgeText(self: State, d: devices.Device) []const u8 {
        return switch (self) {
            .mounted => ui.zFmt("Mounted at {s}", .{d.mount_points[0]}),
            .managed => ui.z("Not mounted (a Pori mount unit exists)"),
            .unmanaged => ui.z("Not mounted"),
        };
    }

    pub fn badgeClass(self: State) [:0]const u8 {
        return if (self == .mounted) ui.z("mount-badge") else ui.z("state-badge");
    }
};

const Entry = union(enum) {
    disk: usize,
    device: usize,
    unit: usize,
};

const Kind = enum { none, disk, device, unit };

const name_buf_len = 256;

pub const DrivesPage = struct {
    root: *gtk.Box,
    parent: *gtk.Window,
    list_box: *gtk.ListBox,
    detail_host: *gtk.Box,
    refresh_btn: *gtk.Button,
    spinner: *gtk.Spinner,
    status: *gtk.Label,

    arena: std.heap.ArenaAllocator,
    disks: []const devices.Disk,
    list: []const devices.Device,
    unit_list: []const units.MountUnit,
    row_map: []const ?Entry,
    selected: ?Entry,
    selected_kind: Kind,
    selected_name: [name_buf_len]u8,
    selected_name_len: usize,
    busy: bool,

    action_buttons: std.ArrayList(*gtk.Button),

    pub fn build(alloc: std.mem.Allocator, parent: *gtk.Window) !*DrivesPage {
        const self = try alloc.create(DrivesPage);

        const root = gtk.Box.new(.vertical, 0);

        const status = ui.statusLabel();
        const header = ui.pageHeader("Drives", status);
        const spinner = gtk.Spinner.new();
        ui.widget(spinner).setVisible(0);
        const refresh_btn = ui.refreshButton();
        gtk.Box.append(header, ui.widget(spinner));
        gtk.Box.append(header, ui.widget(refresh_btn));
        gtk.Box.append(root, ui.widget(header));

        const paned = gtk.Paned.new(.horizontal);

        const list_box = gtk.ListBox.new();
        list_box.setSelectionMode(.single);
        const list_w = ui.widget(list_box);
        list_w.addCssClass(ui.z("pori-list"));
        list_w.setHexpand(0);
        list_w.setSizeRequest(260, -1);

        const placeholder = gtk.Label.new(ui.z("No drives found"));
        ui.widget(placeholder).addCssClass(ui.z("dim-label"));
        placeholder.setWrap(1);
        list_box.setPlaceholder(ui.widget(placeholder));

        paned.setStartChild(ui.widget(ui.scrolled(list_w)));

        const detail_host = gtk.Box.new(.vertical, 0);
        ui.widget(detail_host).setHexpand(1);
        ui.widget(detail_host).setVexpand(1);
        paned.setEndChild(ui.widget(ui.scrolled(ui.widget(detail_host))));
        paned.setPosition(270);

        gtk.Box.append(root, ui.widget(paned));

        self.* = .{
            .root = root,
            .parent = parent,
            .list_box = list_box,
            .detail_host = detail_host,
            .refresh_btn = refresh_btn,
            .spinner = spinner,
            .status = status,
            .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
            .disks = &.{},
            .list = &.{},
            .unit_list = &.{},
            .row_map = &.{},
            .selected = null,
            .selected_kind = .none,
            .selected_name = undefined,
            .selected_name_len = 0,
            .busy = false,
            .action_buttons = .empty,
        };

        _ = gtk.Button.signals.clicked.connect(refresh_btn, *DrivesPage, &onRefresh, self, .{});
        _ = gtk.ListBox.signals.row_selected.connect(list_box, *DrivesPage, &onRowSelected, self, .{});

        self.refresh();

        watch_page = self;
        watch.start(&onWatchChange);
        return self;
    }

    pub fn widget(self: *DrivesPage) *gtk.Widget {
        return ui.widget(self.root);
    }

    pub fn refresh(self: *DrivesPage) void {
        self.arena.deinit();
        self.arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        const alloc = self.arena.allocator();

        const empty: devices.Snapshot = .{ .disks = &.{}, .devices = &.{} };
        const snap = devices.snapshot(alloc) catch empty;
        self.disks = snap.disks;
        self.list = snap.devices;
        self.unit_list = units.listManaged(alloc) catch &.{};

        self.list_box.removeAll();
        self.action_buttons.clearRetainingCapacity();

        var rows: std.ArrayList(?Entry) = .empty;
        const covered = alloc.alloc(bool, self.list.len) catch unreachable;
        @memset(covered, false);

        for (self.disks, 0..) |disk, i| {
            if (self.wholeDiskDevice(disk)) |di| {
                covered[di] = true;
                self.appendDeviceRow(&rows, alloc, di, .none);
                continue;
            }

            self.list_box.append(ui.styledRow(disk.title(), diskRowSubtitle(alloc, disk), .{
                .dot = if (diskMounted(disk)) .mounted else .idle,
                .icon = "drive-harddisk-symbolic",
            }));
            rows.append(alloc, .{ .disk = i }) catch {};

            var last_di: ?usize = null;
            for (self.list, 0..) |d, di| {
                if (std.mem.eql(u8, d.parent, disk.name)) last_di = di;
            }
            for (self.list, 0..) |d, di| {
                if (!std.mem.eql(u8, d.parent, disk.name)) continue;
                covered[di] = true;
                const guide: ui.Guide = if (last_di != null and last_di.? == di) .last else .mid;
                self.appendDeviceRow(&rows, alloc, di, guide);
            }
        }

        for (covered, 0..) |done, di| {
            if (done) continue;
            self.appendDeviceRow(&rows, alloc, di, .none);
        }

        var orphans: usize = 0;
        for (self.unit_list, 0..) |u, j| {
            if (self.deviceFor(u) != null) continue;
            if (orphans == 0) {
                self.list_box.append(ui.widget(sectionRow("Not connected")));
                rows.append(alloc, null) catch {};
            }
            orphans += 1;
            self.list_box.append(ui.listRow(u.name, unitRowSubtitle(u), if (u.isActive()) .mounted else .idle));
            rows.append(alloc, .{ .unit = j }) catch {};
        }
        self.row_map = rows.items;

        if (self.indexOfSelected()) |entry| {
            self.select(entry);
        } else if (self.firstSelectable()) |entry| {
            self.select(entry);
        } else {
            self.selected = null;
            self.selected_kind = .none;
            self.selected_name_len = 0;
            self.renderDetail();
        }

        const status_text = if (orphans == 0)
            ui.zFmt("{d} disk(s) · {d} filesystem(s)", .{ self.disks.len, self.list.len })
        else
            ui.zFmt("{d} disk(s) · {d} filesystem(s) · {d} not connected", .{ self.disks.len, self.list.len, orphans });
        ui.setStatus(self.status, ui.z("dim-label"), status_text);
    }

    fn appendDeviceRow(self: *DrivesPage, rows: *std.ArrayList(?Entry), alloc: std.mem.Allocator, di: usize, guide: ui.Guide) void {
        const d = self.list[di];
        self.list_box.append(ui.styledRow(rowTitle(d), rowSubtitle(d), .{
            .dot = if (d.mounted()) .mounted else .idle,
            .indent = d.isPartition(),
            .icon = if (d.isPartition()) null else "drive-harddisk-symbolic",
            .guide = guide,
        }));
        rows.append(alloc, .{ .device = di }) catch {};
    }

    fn wholeDiskDevice(self: *DrivesPage, disk: devices.Disk) ?usize {
        for (self.list, 0..) |d, i| {
            if (d.isPartition()) continue;
            if (std.mem.eql(u8, d.name, disk.name)) return i;
        }
        return null;
    }

    fn firstSelectable(self: *DrivesPage) ?Entry {
        for (self.row_map) |mapped| {
            if (mapped) |entry| return entry;
        }
        return null;
    }

    fn select(self: *DrivesPage, entry: Entry) void {
        for (self.row_map, 0..) |mapped, row_index| {
            const m = mapped orelse continue;
            const same = switch (entry) {
                .disk => |i| m == .disk and m.disk == i,
                .device => |i| m == .device and m.device == i,
                .unit => |j| m == .unit and m.unit == j,
            };
            if (!same) continue;
            if (self.list_box.getRowAtIndex(@intCast(row_index))) |row| {
                self.list_box.selectRow(row);
            }
            return;
        }
    }

    fn indexOfSelected(self: *DrivesPage) ?Entry {
        if (self.selected_name_len == 0) return null;
        const wanted = self.selected_name[0..self.selected_name_len];
        switch (self.selected_kind) {
            .none => return null,
            .disk => for (self.disks, 0..) |disk, i| {
                if (std.mem.eql(u8, disk.name, wanted)) return .{ .disk = i };
            },
            .device => for (self.list, 0..) |d, i| {
                if (std.mem.eql(u8, d.name, wanted)) return .{ .device = i };
            },
            .unit => for (self.unit_list, 0..) |u, j| {
                if (std.mem.eql(u8, u.name, wanted)) return .{ .unit = j };
            },
        }
        return null;
    }

    fn rememberSelection(self: *DrivesPage, name: []const u8, kind: Kind) void {
        const n = @min(name.len, name_buf_len);
        @memcpy(self.selected_name[0..n], name[0..n]);
        self.selected_name_len = n;
        self.selected_kind = kind;
    }

    fn selectedDisk(self: *DrivesPage) ?*const devices.Disk {
        const sel = self.selected orelse return null;
        if (sel != .disk) return null;
        if (sel.disk >= self.disks.len) return null;
        return &self.disks[sel.disk];
    }

    fn selectedDevice(self: *DrivesPage) ?*const devices.Device {
        const sel = self.selected orelse return null;
        if (sel != .device) return null;
        if (sel.device >= self.list.len) return null;
        return &self.list[sel.device];
    }

    fn selectedUnit(self: *DrivesPage) ?*const units.MountUnit {
        const sel = self.selected orelse return null;
        if (sel != .unit) return null;
        if (sel.unit >= self.unit_list.len) return null;
        return &self.unit_list[sel.unit];
    }

    fn unitFor(self: *DrivesPage, d: devices.Device) ?*const units.MountUnit {
        for (self.unit_list) |*u| {
            if (u.matchesDevice(d)) return u;
        }
        return null;
    }

    fn deviceFor(self: *DrivesPage, u: units.MountUnit) ?*const devices.Device {
        for (self.list) |*d| {
            if (u.matchesDevice(d.*)) return d;
        }
        return null;
    }

    fn selectedUnitOrNil(self: *DrivesPage) ?*const units.MountUnit {
        if (self.selectedUnit()) |u| return u;
        if (self.selectedDevice()) |d| return self.unitFor(d.*);
        return null;
    }

    fn renderDetail(self: *DrivesPage) void {
        ui.clearBox(self.detail_host);
        self.action_buttons.clearRetainingCapacity();

        const pane = gtk.Box.new(.vertical, 8);
        const p_w = ui.widget(pane);
        p_w.setMarginTop(16);
        p_w.setMarginBottom(16);
        p_w.setMarginStart(18);
        p_w.setMarginEnd(18);
        p_w.setVexpand(1);

        if (self.selectedDevice()) |d| {
            self.renderDevice(pane, d);
        } else if (self.selectedDisk()) |disk| {
            self.renderDisk(pane, disk);
        } else if (self.selectedUnit()) |u| {
            self.renderUnit(pane, u);
        } else {
            const hint = gtk.Label.new(ui.z("Select a drive to see what Pori can do with it"));
            ui.widget(hint).addCssClass(ui.z("dim-label"));
            hint.setWrap(1);
            p_w.setHalign(.center);
            p_w.setValign(.center);
            gtk.Box.append(pane, ui.widget(hint));
        }

        gtk.Box.append(self.detail_host, p_w);
    }

    fn renderDevice(self: *DrivesPage, pane: *gtk.Box, d: *const devices.Device) void {
        const unit = self.unitFor(d.*);
        const state = State.of(d.*, unit);

        const title = gtk.Label.new(ui.z(rowTitle(d.*)));
        ui.widget(title).addCssClass(ui.z("title-3"));
        title.setXalign(0);
        title.setEllipsize(.end);
        gtk.Box.append(pane, ui.widget(title));

        const sub = gtk.Label.new(ui.zFmt("{s} · {s} · {s}", .{
            if (d.isPartition()) ui.zFmt("partition {d}", .{d.partition_number}) else "whole disk",
            d.name,
            d.dev,
        }));
        ui.widget(sub).addCssClass(ui.z("dim-label"));
        sub.setXalign(0);
        sub.setEllipsize(.end);
        gtk.Box.append(pane, ui.widget(sub));

        const badge = ui.badge(state.badgeText(d.*), state.badgeClass());
        ui.widget(badge).setHalign(.start);
        gtk.Box.append(pane, ui.widget(badge));

        gtk.Box.append(pane, ui.widget(gtk.Separator.new(.horizontal)));

        const fields = gtk.Box.new(.vertical, 4);
        ui.cardField(fields, "Type", fsLabel(d.*), true);
        if (d.label.len > 0) ui.cardField(fields, "Label", d.label, false);
        ui.cardField(fields, "UUID", d.uuid, false);
        if (d.isPartition()) {
            ui.cardField(fields, "Drive", ui.zFmt("{s} · {s} · partition {d}", .{ d.parent, tableWord(d.table_type), d.partition_number }), false);
        }

        var size_buf: [16]u8 = undefined;
        ui.cardField(fields, "Size", format.humanSize(&size_buf, d.size), false);

        if (d.mounted()) {
            if (devices.usage(d.*)) |usage| {
                var avail_buf: [16]u8 = undefined;
                ui.cardField(fields, "Available", format.humanSize(&avail_buf, usage.avail_bytes), false);
                ui.cardField(fields, "Use%", ui.zFmt("{d}%", .{usage.used_percent}), false);

                const bar = gtk.LevelBar.new();
                bar.setMinValue(0);
                bar.setMaxValue(100);
                bar.setValue(@floatFromInt(usage.used_percent));
                bar.addOffsetValue(ui.z("low"), 33);
                bar.addOffsetValue(ui.z("high"), 66);
                bar.addOffsetValue(ui.z("full"), 100);
                ui.widget(bar).setMarginTop(2);
                ui.widget(bar).setMarginBottom(4);
                gtk.Box.append(fields, ui.widget(bar));
            }
        }
        if (d.read_only) ui.cardField(fields, "Access", "Read-only", false);
        gtk.Box.append(pane, ui.widget(fields));

        if (unit) |u| {
            gtk.Box.append(pane, ui.widget(gtk.Separator.new(.horizontal)));
            gtk.Box.append(pane, ui.widget(ui.sectionLabel("Managed mount")));
            gtk.Box.append(pane, unitFields(u));
        }

        gtk.Box.append(pane, spacer());
        gtk.Box.append(pane, ui.widget(gtk.Separator.new(.horizontal)));
        gtk.Box.append(pane, self.buildDeviceActions(d, state, unit != null));
    }

    fn renderDisk(self: *DrivesPage, pane: *gtk.Box, disk: *const devices.Disk) void {
        const title = gtk.Label.new(ui.z(disk.title()));
        ui.widget(title).addCssClass(ui.z("title-3"));
        title.setXalign(0);
        title.setEllipsize(.end);
        gtk.Box.append(pane, ui.widget(title));

        const sub = gtk.Label.new(ui.zFmt("disk · {s} · {s}", .{ disk.name, disk.dev }));
        ui.widget(sub).addCssClass(ui.z("dim-label"));
        sub.setXalign(0);
        sub.setEllipsize(.end);
        gtk.Box.append(pane, ui.widget(sub));

        const badge = ui.badge(tableSummary(disk.*), if (disk.hasTable()) ui.z("state-badge") else ui.z("warn-badge"));
        ui.widget(badge).setHalign(.start);
        gtk.Box.append(pane, ui.widget(badge));

        gtk.Box.append(pane, ui.widget(gtk.Separator.new(.horizontal)));

        const fields = gtk.Box.new(.vertical, 4);
        if (disk.model.len > 0) ui.cardField(fields, "Model", disk.model, true);
        if (disk.vendor.len > 0) ui.cardField(fields, "Vendor", disk.vendor, false);
        if (disk.serial.len > 0) ui.cardField(fields, "Serial", disk.serial, false);

        var size_buf: [16]u8 = undefined;
        ui.cardField(fields, "Size", format.humanSize(&size_buf, disk.size), false);
        ui.cardField(fields, "Table", if (disk.hasTable()) tableWord(disk.table_type) else "none", false);
        if (disk.fs_type.len > 0) ui.cardField(fields, "Contents", fsText(disk.fs_type, disk.label), false);
        if (disk.read_only) ui.cardField(fields, "Access", "Read-only", false);
        gtk.Box.append(pane, ui.widget(fields));

        const regions = self.diskRegions(disk.*);
        if (disk.hasTable()) {
            var free_buf: [16]u8 = undefined;
            gtk.Box.append(pane, ui.widget(gtk.Separator.new(.horizontal)));
            gtk.Box.append(pane, ui.widget(ui.sectionLabel("Layout")));
            const layout = gtk.Box.new(.vertical, 4);
            for (disk.partitions) |p| {
                var part_buf: [16]u8 = undefined;
                const size_text = format.humanSize(&part_buf, p.size);
                ui.cardField(layout, p.name, ui.zFmt("{s} · {s}", .{ size_text, fsText(p.fs_type, p.label) }), false);

                if (p.fs_type.len == 0 and !p.mounted() and !disk.read_only) {
                    const act = self.arena.allocator().create(LayoutAction) catch continue;
                    act.* = .{ .page = self, .path = p.path, .name = p.name };

                    const row = gtk.Box.new(.horizontal, 6);
                    ui.widget(row).setMarginStart(88);
                    ui.widget(row).setMarginBottom(2);

                    const fmt_btn = ui.button("Format", null);
                    ui.widget(fmt_btn).setTooltipText(ui.z("Put a filesystem on this empty partition"));
                    _ = gtk.Button.signals.clicked.connect(fmt_btn, *LayoutAction, &onLayoutFormat, act, .{});
                    gtk.Box.append(row, ui.widget(fmt_btn));

                    const del_btn = ui.button("Delete", "destructive-action");
                    ui.widget(del_btn).setTooltipText(ui.z("Remove this empty partition and leave its space unallocated"));
                    _ = gtk.Button.signals.clicked.connect(del_btn, *LayoutAction, &onLayoutDelete, act, .{});
                    gtk.Box.append(row, ui.widget(del_btn));

                    gtk.Box.append(layout, ui.widget(row));
                }
            }
            for (regions) |r| {
                var gap_buf: [16]u8 = undefined;
                ui.cardField(layout, "free", regionLabel(r, format.humanSize(&gap_buf, r.size)), false);
            }
            const total_free = blockops.totalFree(regions);
            if (total_free > 0) {
                ui.cardField(layout, "Free", format.humanSize(&free_buf, total_free), false);
            }
            gtk.Box.append(pane, ui.widget(layout));
        }

        gtk.Box.append(pane, spacer());
        gtk.Box.append(pane, ui.widget(gtk.Separator.new(.horizontal)));
        gtk.Box.append(pane, self.buildDiskActions(disk, regions));
    }

    fn renderUnit(self: *DrivesPage, pane: *gtk.Box, u: *const units.MountUnit) void {
        const connected = self.deviceFor(u.*) != null;

        const title = gtk.Label.new(ui.z(u.name));
        ui.widget(title).addCssClass(ui.z("title-3"));
        title.setXalign(0);
        title.setEllipsize(.end);
        gtk.Box.append(pane, ui.widget(title));

        const badge = ui.badge(unitBadgeText(u.*, connected), unitBadgeClass(u.*, connected));
        ui.widget(badge).setHalign(.start);
        gtk.Box.append(pane, ui.widget(badge));

        gtk.Box.append(pane, ui.widget(gtk.Separator.new(.horizontal)));
        gtk.Box.append(pane, unitFields(u));

        gtk.Box.append(pane, spacer());
        gtk.Box.append(pane, ui.widget(gtk.Separator.new(.horizontal)));
        gtk.Box.append(pane, self.buildUnitActions());
    }

    fn buildDeviceActions(self: *DrivesPage, d: *const devices.Device, state: State, has_unit: bool) *gtk.Widget {
        const bar = gtk.Box.new(.horizontal, 8);
        const b_w = ui.widget(bar);
        b_w.setMarginTop(4);

        if (state == .mounted and !has_unit) {
            const note = gtk.Label.new(ui.z("Mounted by fstab, not managed by Pori"));
            ui.widget(note).addCssClass(ui.z("dim-label"));
            note.setXalign(0);
            gtk.Box.append(bar, ui.widget(note));
        }

        if (state == .unmanaged) {
            const mount_button = ui.button("Mount", "suggested-action");
            ui.widget(mount_button).setTooltipText(ui.z("Create a systemd mount unit for this drive"));
            _ = gtk.Button.signals.clicked.connect(mount_button, *DrivesPage, &onMountClicked, self, .{});
            gtk.Box.append(bar, ui.widget(mount_button));
            self.trackAction(mount_button);
        }

        if (has_unit) {
            const edit_button = ui.button("Edit mount", null);
            _ = gtk.Button.signals.clicked.connect(edit_button, *DrivesPage, &onEditClicked, self, .{});
            gtk.Box.append(bar, ui.widget(edit_button));
            self.trackAction(edit_button);

            const remove_button = ui.button("Remove mount", "destructive-action");
            _ = gtk.Button.signals.clicked.connect(remove_button, *DrivesPage, &onRemoveClicked, self, .{});
            gtk.Box.append(bar, ui.widget(remove_button));
            self.trackAction(remove_button);
        }

        gtk.Box.append(bar, self.buildDestructiveActions(d));
        return b_w;
    }

    fn buildDiskActions(self: *DrivesPage, disk: *const devices.Disk, regions: []const blockops.Region) *gtk.Widget {
        const bar = gtk.Box.new(.horizontal, 8);
        const b_w = ui.widget(bar);
        b_w.setMarginTop(4);

        if (disk.read_only) {
            gtk.Box.append(bar, ui.widget(disabledNote("The disk is read-only")));
            return b_w;
        }

        if (!disk.hasTable()) {
            const table_button = ui.button("Create partition table", "suggested-action");
            ui.widget(table_button).setTooltipText(ui.z("Write a GPT or MBR table so the disk can hold partitions"));
            _ = gtk.Button.signals.clicked.connect(table_button, *DrivesPage, &onTableClicked, self, .{});
            gtk.Box.append(bar, ui.widget(table_button));
            self.trackAction(table_button);

            const format_button = ui.button("Format whole disk", "destructive-action");
            ui.widget(format_button).setTooltipText(ui.z("Put a filesystem directly on the disk, with no partition table"));
            _ = gtk.Button.signals.clicked.connect(format_button, *DrivesPage, &onFormatDiskClicked, self, .{});
            gtk.Box.append(bar, ui.widget(format_button));
            self.trackAction(format_button);

            return b_w;
        }

        if (regions.len == 0) {
            gtk.Box.append(bar, ui.widget(disabledNote("No free space left on this disk")));
            return b_w;
        }

        var free_buf: [16]u8 = undefined;
        const biggest = blockops.largestRegion(regions).?;
        const new_button = ui.button("New partition", "suggested-action");
        ui.widget(new_button).setTooltipText(ui.zFmt(
            "Create a partition in one of {d} gap(s); the largest is {s}",
            .{ regions.len, format.humanSize(&free_buf, biggest.size) },
        ));
        _ = gtk.Button.signals.clicked.connect(new_button, *DrivesPage, &onNewPartitionClicked, self, .{});
        gtk.Box.append(bar, ui.widget(new_button));
        self.trackAction(new_button);

        return b_w;
    }

    fn diskRegions(self: *DrivesPage, disk: devices.Disk) []const blockops.Region {
        if (!disk.hasTable()) return &.{};
        return blockops.freeRegions(self.arena.allocator(), disk) catch &.{};
    }

    fn regionChoices(self: *DrivesPage, regions: []const blockops.Region) []const dialogs.RegionChoice {
        const alloc = self.arena.allocator();
        const out = alloc.alloc(dialogs.RegionChoice, regions.len) catch return &.{};
        for (regions, 0..) |r, i| {
            var size_buf: [16]u8 = undefined;
            const size_text = ui.z(format.humanSize(&size_buf, r.size));
            out[i] = .{
                .label = regionLabel(r, size_text),
                .size_text = size_text,
                .offset = r.offset,
                .size = r.size,
            };
        }
        return out;
    }

    fn buildDestructiveActions(self: *DrivesPage, d: *const devices.Device) *gtk.Widget {
        const bar = gtk.Box.new(.horizontal, 8);
        const blocked_reason: ?[]const u8 = if (d.mounted())
            "Unmount the drive first"
        else if (d.read_only)
            "The drive is read-only"
        else
            null;

        const format_button = ui.button("Format", "destructive-action");
        if (blocked_reason) |why| {
            ui.widget(format_button).setSensitive(0);
            ui.widget(format_button).setTooltipText(ui.z(why));
        } else {
            ui.widget(format_button).setTooltipText(ui.z("Replace the filesystem on this drive. This destroys its contents."));
            _ = gtk.Button.signals.clicked.connect(format_button, *DrivesPage, &onFormatClicked, self, .{});
            self.trackAction(format_button);
        }
        gtk.Box.append(bar, ui.widget(format_button));

        if (!d.isPartition()) return ui.widget(bar);

        const resize_button = ui.button("Resize", null);
        const window = if (blocked_reason == null)
            if (self.diskForDevice(d)) |disk| blockops.resizeWindow(disk.*, d.path) else null
        else
            null;

        if (blocked_reason) |why| {
            ui.widget(resize_button).setSensitive(0);
            ui.widget(resize_button).setTooltipText(ui.z(why));
        } else if (window == null) {
            ui.widget(resize_button).setSensitive(0);
            ui.widget(resize_button).setTooltipText(ui.z("Pori cannot see this partition's disk layout"));
        } else if (window.?.max_size < blockops.mib) {
            ui.widget(resize_button).setSensitive(0);
            ui.widget(resize_button).setTooltipText(ui.z("No room to grow or shrink into"));
        } else {
            ui.widget(resize_button).setTooltipText(ui.z("Grow or shrink this partition at its end, filesystem included"));
            _ = gtk.Button.signals.clicked.connect(resize_button, *DrivesPage, &onResizeClicked, self, .{});
            self.trackAction(resize_button);
        }
        gtk.Box.append(bar, ui.widget(resize_button));

        const delete_button = ui.button("Delete partition", "destructive-action");
        if (blocked_reason) |why| {
            ui.widget(delete_button).setSensitive(0);
            ui.widget(delete_button).setTooltipText(ui.z(why));
        } else {
            ui.widget(delete_button).setTooltipText(ui.z("Remove this partition from the table and leave its space unallocated"));
            _ = gtk.Button.signals.clicked.connect(delete_button, *DrivesPage, &onDeletePartitionClicked, self, .{});
            self.trackAction(delete_button);
        }
        gtk.Box.append(bar, ui.widget(delete_button));

        return ui.widget(bar);
    }

    fn buildUnitActions(self: *DrivesPage) *gtk.Widget {
        const bar = gtk.Box.new(.horizontal, 8);
        const b_w = ui.widget(bar);
        b_w.setMarginTop(4);

        const edit_button = ui.button("Edit mount", "suggested-action");
        _ = gtk.Button.signals.clicked.connect(edit_button, *DrivesPage, &onEditClicked, self, .{});
        gtk.Box.append(bar, ui.widget(edit_button));
        self.trackAction(edit_button);

        const remove_button = ui.button("Remove mount", "destructive-action");
        _ = gtk.Button.signals.clicked.connect(remove_button, *DrivesPage, &onRemoveClicked, self, .{});
        gtk.Box.append(bar, ui.widget(remove_button));
        self.trackAction(remove_button);

        return b_w;
    }

    fn trackAction(self: *DrivesPage, btn: *gtk.Button) void {
        ui.widget(btn).setSensitive(@intFromBool(!self.busy));
        self.action_buttons.append(std.heap.page_allocator, btn) catch {};
    }

    fn updateActions(self: *DrivesPage) void {
        const sensitive = @intFromBool(!self.busy);
        for (self.action_buttons.items) |b| ui.widget(b).setSensitive(sensitive);
    }

    fn reporter(self: *DrivesPage) actions.Reporter {
        return .{ .setBusy = &onBusy, .report = &onOutcome, .ud = @ptrCast(self) };
    }

    fn onRowSelected(box: *gtk.ListBox, row: ?*gtk.ListBoxRow, self: *DrivesPage) callconv(.c) void {
        _ = box;
        self.selected = null;
        if (row) |r| {
            const idx = r.getIndex();
            if (idx >= 0 and @as(usize, @intCast(idx)) < self.row_map.len) {
                if (self.row_map[@as(usize, @intCast(idx))]) |entry| {
                    self.selected = entry;
                    switch (entry) {
                        .disk => |i| self.rememberSelection(self.disks[i].name, .disk),
                        .device => |i| self.rememberSelection(self.list[i].name, .device),
                        .unit => |j| self.rememberSelection(self.unit_list[j].name, .unit),
                    }
                }
            }
        }
        self.renderDetail();
    }

    fn onRefresh(btn: *gtk.Button, self: *DrivesPage) callconv(.c) void {
        _ = btn;
        if (self.busy) return;
        self.refresh();
    }

    fn onBusy(ud: ?*anyopaque, busy: bool) void {
        const self: *DrivesPage = @ptrCast(@alignCast(ud.?));
        self.busy = busy;
        self.updateActions();
        ui.widget(self.refresh_btn).setSensitive(@intFromBool(!busy));
        if (busy) self.spinner.start() else self.spinner.stop();
        ui.widget(self.spinner).setVisible(@intFromBool(busy));
    }

    fn onOutcome(ud: ?*anyopaque, outcome: actions.Outcome) void {
        const self: *DrivesPage = @ptrCast(@alignCast(ud.?));
        self.refresh();
        const class: [:0]const u8 = if (outcome.ok)
            ui.z("success-label")
        else if (outcome.cancelled)
            ui.z("dim-label")
        else
            ui.z("error-label");
        ui.setStatus(self.status, class, outcome.message);
    }

    fn onMountClicked(btn: *gtk.Button, self: *DrivesPage) callconv(.c) void {
        _ = btn;
        const d = self.selectedDevice() orelse return;
        if (self.busy or d.mounted() or self.unitFor(d.*) != null) return;
        actions.mount(self.parent, d, self.reporter());
    }

    fn onEditClicked(btn: *gtk.Button, self: *DrivesPage) callconv(.c) void {
        _ = btn;
        if (self.busy) return;
        const u = self.selectedUnitOrNil() orelse return;
        actions.edit(self.parent, u, self.reporter());
    }

    fn onRemoveClicked(btn: *gtk.Button, self: *DrivesPage) callconv(.c) void {
        _ = btn;
        if (self.busy) return;
        const u = self.selectedUnitOrNil() orelse return;
        actions.remove(self.parent, u.name, self.reporter());
    }

    fn onFormatClicked(btn: *gtk.Button, self: *DrivesPage) callconv(.c) void {
        _ = btn;
        if (self.busy) return;
        const d = self.selectedDevice() orelse return;
        if (d.mounted() or d.read_only) return;

        var size_buf: [16]u8 = undefined;
        actions.formatDevice(self.parent, .{
            .path = d.path,
            .name = d.name,
            .dev = d.dev,
            .size_text = format.humanSize(&size_buf, d.size),
            .contents = fsText(d.fs_type, d.label),
            .whole_disk = !d.isPartition(),
            .extra_warning = if (self.unitFor(d.*) != null)
                "A Pori mount unit points at this drive's UUID, which the new filesystem replaces. " ++
                    "Remove the mount unit afterwards so it does not fail at boot."
            else
                "",
        }, self.reporter());
    }

    fn onFormatDiskClicked(btn: *gtk.Button, self: *DrivesPage) callconv(.c) void {
        _ = btn;
        if (self.busy) return;
        const disk = self.selectedDisk() orelse return;
        if (disk.read_only or diskMounted(disk.*)) return;

        var size_buf: [16]u8 = undefined;
        actions.formatDevice(self.parent, .{
            .path = disk.path,
            .name = disk.name,
            .dev = disk.dev,
            .size_text = format.humanSize(&size_buf, disk.size),
            .contents = diskContents(disk.*),
            .whole_disk = true,
        }, self.reporter());
    }

    fn onTableClicked(btn: *gtk.Button, self: *DrivesPage) callconv(.c) void {
        _ = btn;
        if (self.busy) return;
        const disk = self.selectedDisk() orelse return;
        if (disk.read_only or diskMounted(disk.*) or disk.hasTable()) return;

        var size_buf: [16]u8 = undefined;
        actions.createPartitionTable(self.parent, .{
            .path = disk.path,
            .name = disk.name,
            .title = disk.title(),
            .size_text = format.humanSize(&size_buf, disk.size),
            .contents = diskContents(disk.*),
            .partition_count = disk.partitions.len,
        }, self.reporter());
    }

    fn onNewPartitionClicked(btn: *gtk.Button, self: *DrivesPage) callconv(.c) void {
        _ = btn;
        if (self.busy) return;
        const disk = self.selectedDisk() orelse return;
        if (disk.read_only or !disk.hasTable()) return;

        const regions = self.diskRegions(disk.*);
        if (regions.len == 0) return;

        actions.createPartition(self.parent, .{
            .disk_path = disk.path,
            .disk_name = disk.name,
            .disk_title = disk.title(),
            .regions = self.regionChoices(regions),
        }, self.reporter());
    }

    fn diskForDevice(self: *DrivesPage, d: *const devices.Device) ?*const devices.Disk {
        if (!d.isPartition()) return null;
        for (self.disks) |*disk| {
            if (std.mem.eql(u8, disk.name, d.parent)) return disk;
        }
        return null;
    }

    fn layoutPartition(self: *DrivesPage, path: []const u8) ?devices.DiskPartition {
        const disk = self.selectedDisk() orelse return null;
        for (disk.partitions) |p| {
            if (std.mem.eql(u8, p.path, path)) return p;
        }
        return null;
    }

    fn onResizeClicked(btn: *gtk.Button, self: *DrivesPage) callconv(.c) void {
        _ = btn;
        if (self.busy) return;
        const d = self.selectedDevice() orelse return;
        if (!d.isPartition() or d.mounted() or d.read_only) return;

        const disk = self.diskForDevice(d) orelse return;
        const window = blockops.resizeWindow(disk.*, d.path) orelse return;
        if (window.max_size < blockops.mib) return;

        actions.resizePartition(self.parent, .{
            .path = d.path,
            .name = d.name,
            .dev = d.dev,
            .window = window,
        }, self.reporter());
    }

    fn onDeletePartitionClicked(btn: *gtk.Button, self: *DrivesPage) callconv(.c) void {
        _ = btn;
        if (self.busy) return;
        const d = self.selectedDevice() orelse return;
        if (!d.isPartition() or d.mounted() or d.read_only) return;
        actions.deletePartition(self.parent, d.path, d.name, self.reporter());
    }
};

const LayoutAction = struct {
    page: *DrivesPage,
    path: []const u8,
    name: []const u8,
};

fn onLayoutFormat(btn: *gtk.Button, act: *LayoutAction) callconv(.c) void {
    _ = btn;
    const self = act.page;
    if (self.busy) return;
    const p = self.layoutPartition(act.path) orelse return;
    if (p.mounted() or p.fs_type.len > 0) return;

    var size_buf: [16]u8 = undefined;
    actions.formatDevice(self.parent, .{
        .path = p.path,
        .name = p.name,
        .dev = ui.zFmt("/dev/{s}", .{p.name}),
        .size_text = format.humanSize(&size_buf, p.size),
        .contents = "unformatted",
        .whole_disk = false,
    }, self.reporter());
}

fn onLayoutDelete(btn: *gtk.Button, act: *LayoutAction) callconv(.c) void {
    _ = btn;
    const self = act.page;
    if (self.busy) return;
    const p = self.layoutPartition(act.path) orelse return;
    if (p.mounted() or p.fs_type.len > 0) return;
    actions.deletePartition(self.parent, p.path, p.name, self.reporter());
}

var watch_page: ?*DrivesPage = null;

fn onWatchChange() void {
    const self = watch_page orelse return;
    if (self.busy) return;
    self.refresh();
}

fn unitFields(u: *const units.MountUnit) *gtk.Widget {
    const fields = gtk.Box.new(.vertical, 4);
    if (u.description.len > 0) ui.cardField(fields, "Description", u.description, true);
    if (u.what.len > 0) ui.cardField(fields, "Device", u.what, false);
    if (u.where.len > 0) ui.cardField(fields, "Mount point", u.where, false);
    if (u.fs_type.len > 0) ui.cardField(fields, "Type", u.fs_type, false);
    if (u.options.len > 0) ui.cardField(fields, "Options", u.options, false);
    ui.cardField(fields, "State", ui.zFmt("{s} ({s})", .{ u.active_state, u.sub_state }), false);
    return ui.widget(fields);
}

fn spacer() *gtk.Widget {
    const box = gtk.Box.new(.vertical, 0);
    ui.widget(box).setVexpand(1);
    return ui.widget(box);
}

fn disabledNote(text: []const u8) *gtk.Label {
    const note = gtk.Label.new(ui.z(text));
    ui.widget(note).addCssClass(ui.z("dim-label"));
    note.setXalign(0);
    return note;
}

fn sectionRow(text: []const u8) *gtk.ListBoxRow {
    const row = gtk.ListBoxRow.new();
    row.setSelectable(0);
    row.setActivatable(0);

    const box = gtk.Box.new(.vertical, 0);
    const b_w = ui.widget(box);
    b_w.setMarginTop(10);
    b_w.setMarginBottom(2);
    b_w.setMarginStart(8);
    b_w.setMarginEnd(8);

    const label = gtk.Label.new(ui.z(text));
    ui.widget(label).addCssClass(ui.z("pori-group"));
    label.setXalign(0);
    gtk.Box.append(box, ui.widget(label));

    row.setChild(b_w);
    return row;
}

fn tableWord(table_type: []const u8) []const u8 {
    if (std.mem.eql(u8, table_type, "gpt")) return "GPT table";
    if (std.mem.eql(u8, table_type, "dos")) return "MBR table";
    if (table_type.len == 0) return "no table";
    return ui.zFmt("{s} table", .{table_type});
}

fn tableSummary(disk: devices.Disk) []const u8 {
    if (disk.hasTable()) {
        return ui.zFmt("{s} · {d} partition(s)", .{ tableWord(disk.table_type), disk.partitions.len });
    }
    if (disk.fs_type.len > 0) return ui.zFmt("{s} filesystem, no partition table", .{disk.fs_type});
    return "No partition table, nothing allocated";
}

fn diskMounted(disk: devices.Disk) bool {
    if (disk.mounted()) return true;
    for (disk.partitions) |p| {
        if (p.mounted()) return true;
    }
    return false;
}

fn diskContents(disk: devices.Disk) []const u8 {
    if (disk.fs_type.len > 0) return fsText(disk.fs_type, disk.label);
    if (!disk.hasTable()) return "no filesystem";
    return ui.zFmt("{s} · {d} partition(s)", .{ tableWord(disk.table_type), disk.partitions.len });
}

fn regionLabel(r: blockops.Region, size_text: []const u8) []const u8 {
    if (r.before.len == 0 and r.after.len == 0) return ui.zFmt("{s} of free space", .{size_text});
    if (r.before.len == 0) return ui.zFmt("{s} before {s}", .{ size_text, r.after });
    if (r.after.len == 0) return ui.zFmt("{s} after {s}", .{ size_text, r.before });
    return ui.zFmt("{s} between {s} and {s}", .{ size_text, r.before, r.after });
}

fn fsText(fs_type: []const u8, label: []const u8) []const u8 {
    if (fs_type.len == 0) return "unformatted";
    if (label.len == 0) return fs_type;
    return ui.zFmt("{s} · {s}", .{ fs_type, label });
}

fn diskRowSubtitle(alloc: std.mem.Allocator, disk: devices.Disk) []const u8 {
    var size_buf: [16]u8 = undefined;
    const size = format.humanSize(&size_buf, disk.size);
    const base = ui.zFmt("disk · {s} · {s} · {s}", .{ disk.name, size, tableSummary(disk) });
    if (!disk.hasTable()) return base;
    const regions = blockops.freeRegions(alloc, disk) catch return base;
    const free = blockops.totalFree(regions);
    if (free == 0) return base;
    var free_buf: [16]u8 = undefined;
    return ui.zFmt("{s} · {s} free", .{ base, format.humanSize(&free_buf, free) });
}

fn rowTitle(d: devices.Device) []const u8 {
    if (d.label.len > 0) return d.label;
    return d.name;
}

fn rowSubtitle(d: devices.Device) []const u8 {
    var size_buf: [16]u8 = undefined;
    const size = format.humanSize(&size_buf, d.size);
    const kind: []const u8 = if (d.isPartition())
        ui.zFmt("partition {d}", .{d.partition_number})
    else
        "whole disk";
    if (d.mounted()) {
        return ui.zFmt("{s} · {s} · {s} · {s}", .{ kind, d.name, d.fs_type, d.mount_points[0] });
    }
    return ui.zFmt("{s} · {s} · {s} · {s}", .{ kind, d.name, d.fs_type, size });
}

fn unitRowSubtitle(u: units.MountUnit) []const u8 {
    if (u.where.len == 0) return ui.zFmt("mount unit · {s}", .{u.active_state});
    return ui.zFmt("mount unit · {s} · {s}", .{ u.where, u.active_state });
}

fn unitBadgeText(u: units.MountUnit, connected: bool) []const u8 {
    if (u.isActive()) {
        if (u.where.len > 0) return ui.zFmt("Active, mounted at {s}", .{u.where});
        return ui.z("Active");
    }
    if (!connected) return ui.z("Inactive, drive not connected");
    return ui.z("Inactive");
}

fn unitBadgeClass(u: units.MountUnit, connected: bool) [:0]const u8 {
    if (u.isActive()) return ui.z("mount-badge");
    if (!connected) return ui.z("warn-badge");
    return ui.z("state-badge");
}

fn fsLabel(d: devices.Device) []const u8 {
    if (d.fs_version.len == 0) return d.fs_type;
    return ui.zFmt("{s} {s}", .{ d.fs_type, d.fs_version });
}

fn testDisk(
    table_type: []const u8,
    fs_type: []const u8,
    partitions: []const devices.DiskPartition,
) devices.Disk {
    return .{
        .path = "/p",
        .name = "sdb",
        .dev = "/dev/sdb",
        .model = "Test disk",
        .vendor = "",
        .serial = "",
        .size = 1000,
        .read_only = false,
        .table_type = table_type,
        .fs_type = fs_type,
        .label = "",
        .mount_points = &.{},
        .partitions = partitions,
    };
}

test "tableSummary describes the three disk conditions" {
    try std.testing.expectEqualStrings(
        "GPT table · 0 partition(s)",
        tableSummary(testDisk("gpt", "", &.{})),
    );
    try std.testing.expectEqualStrings(
        "No partition table, nothing allocated",
        tableSummary(testDisk("", "", &.{})),
    );
    try std.testing.expectEqualStrings(
        "ext4 filesystem, no partition table",
        tableSummary(testDisk("", "ext4", &.{})),
    );
}

test "diskMounted follows any mounted partition" {
    const mounted_part = [_]devices.DiskPartition{
        .{ .path = "/p1", .name = "sdb1", .number = 1, .offset = 0, .size = 1, .fs_type = "", .label = "", .mount_points = &.{"/mnt/x"} },
    };
    try std.testing.expect(diskMounted(testDisk("gpt", "", &mounted_part)));
    try std.testing.expect(!diskMounted(testDisk("gpt", "", &.{})));
}
