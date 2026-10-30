const std = @import("std");
const Pori = @import("Pori");
const gtk = Pori.gtk;
const gdk = Pori.gdk;
const ui = @import("helpers/ui.zig");
const format = @import("helpers/format.zig");
const options = @import("helpers/options.zig");
const blockops = @import("services/blockops.zig");

pub const MountChoice = struct {
    mount_point: []const u8,
    description: []const u8,
    options: []const u8,
};

fn newDialog(parent: *gtk.Window, title: []const u8, width: c_int, height: c_int) *gtk.Window {
    const win = gtk.Window.new();
    win.setTransientFor(parent);
    win.setModal(1);
    win.setResizable(1);
    win.setTitle(ui.z(title));
    win.setDefaultSize(width, height);
    return win;
}

fn scrollCap(parent: *gtk.Window) c_int {
    const fallback: c_int = 560;
    const surface = ui.as(gtk.Native, parent).getSurface() orelse return fallback;
    const monitor = gdk.Surface.getDisplay(surface).getMonitorAtSurface(surface) orelse return fallback;
    var rect: gdk.Rectangle = undefined;
    monitor.getGeometry(&rect);
    return @max(240, rect.f_height - 200);
}

const ConfirmCtx = struct {
    window: *gtk.Window,
    cb: *const fn (?*anyopaque, bool) void,
    ud: ?*anyopaque,
};

pub const Confirm = struct {
    title: []const u8,
    body: []const u8,
    confirm_label: []const u8,
    danger: bool = false,
};

pub fn showConfirm(parent: *gtk.Window, spec: Confirm, cb: *const fn (?*anyopaque, bool) void, ud: ?*anyopaque) void {
    const win = newDialog(parent, spec.title, 480, -1);

    const box = gtk.Box.new(.vertical, 12);
    const b_w = ui.widget(box);
    b_w.setMarginTop(20);
    b_w.setMarginBottom(20);
    b_w.setMarginStart(20);
    b_w.setMarginEnd(20);

    const heading = gtk.Label.new(ui.z(spec.title));
    ui.widget(heading).addCssClass(ui.z("title-4"));
    heading.setXalign(0);
    gtk.Box.append(box, ui.widget(heading));

    const message = gtk.Label.new(ui.z(spec.body));
    message.setWrap(1);
    message.setXalign(0);
    gtk.Box.append(box, ui.widget(message));

    const ctx = std.heap.page_allocator.create(ConfirmCtx) catch return;
    ctx.* = .{ .window = win, .cb = cb, .ud = ud };

    const button_box = gtk.Box.new(.horizontal, 8);
    ui.widget(button_box).setHalign(.end);
    ui.widget(button_box).setMarginTop(8);

    const cancel = gtk.Button.newWithLabel(ui.z("Cancel"));
    _ = gtk.Button.signals.clicked.connect(cancel, *ConfirmCtx, &onConfirmCancel, ctx, .{});
    const proceed = gtk.Button.newWithLabel(ui.z(spec.confirm_label));
    if (spec.danger) ui.widget(proceed).addCssClass(ui.z("destructive-action"));
    _ = gtk.Button.signals.clicked.connect(proceed, *ConfirmCtx, &onConfirmProceed, ctx, .{});

    gtk.Box.append(button_box, ui.widget(cancel));
    gtk.Box.append(button_box, ui.widget(proceed));
    gtk.Box.append(box, ui.widget(button_box));

    win.setChild(ui.widget(box));
    _ = gtk.Window.signals.close_request.connect(win, *ConfirmCtx, &onConfirmCloseRequest, ctx, .{});
    win.present();
}

pub fn showNtfsWarning(parent: *gtk.Window, cb: *const fn (?*anyopaque, bool) void, ud: ?*anyopaque) void {
    showConfirm(parent, .{
        .title = "⚠ NTFS Compatibility Warning",
        .body = "Linux does not have full native support for NTFS. " ++
            "While mounting is possible you may experience issues.\n\n" ++
            "Especially if trying to mount an NTFS drive and play games off Steam " ++
            "it is recommended to back up important data and reformat the drive to a format like ext4.",
        .confirm_label = "Proceed Anyway",
        .danger = true,
    }, cb, ud);
}

fn onConfirmCancel(btn: *gtk.Button, ctx: *ConfirmCtx) callconv(.c) void {
    _ = btn;
    const win = ctx.window;
    fireConfirm(ctx, false);
    win.destroy();
}

fn onConfirmProceed(btn: *gtk.Button, ctx: *ConfirmCtx) callconv(.c) void {
    _ = btn;
    const win = ctx.window;
    fireConfirm(ctx, true);
    win.destroy();
}

fn onConfirmCloseRequest(win: *gtk.Window, ctx: *ConfirmCtx) callconv(.c) c_int {
    _ = win;
    fireConfirm(ctx, false);
    return 0;
}

fn fireConfirm(ctx: *ConfirmCtx, proceed: bool) void {
    const cb = ctx.cb;
    const ud = ctx.ud;
    std.heap.page_allocator.destroy(ctx);
    cb(ud, proceed);
}

pub const Mode = enum { create, edit };

pub const DeviceInfo = struct {
    name: []const u8,
    fs_type: []const u8,
    uuid: []const u8,
    default_mount_point: []const u8,
};

pub const EditInfo = struct {
    unit_name: []const u8,
    where: []const u8,
    description: []const u8,
    fs_type: []const u8,
    current_options: []const u8,
};

const CheckOpt = struct {
    check: *gtk.CheckButton,
    option: []const u8,
};

const OptionsCtx = struct {
    window: *gtk.Window,
    mount_entry: *gtk.Entry,
    desc_entry: *gtk.Entry,
    extra_entry: *gtk.Entry,
    checks: []const CheckOpt,
    cb: *const fn (?*anyopaque, ?MountChoice) void,
    ud: ?*anyopaque,
};

pub fn showMountOptions(
    parent: *gtk.Window,
    mode: Mode,
    device: ?DeviceInfo,
    edit: ?EditInfo,
    cb: *const fn (?*anyopaque, ?MountChoice) void,
    ud: ?*anyopaque,
) void {
    const fs_type = if (mode == .create) (device orelse return).fs_type else (edit orelse return).fs_type;

    const win = newDialog(
        parent,
        if (mode == .create) "Mount Disk" else "Edit Mount",
        520,
        -1,
    );

    const content = gtk.Box.new(.vertical, 10);
    const c_w = ui.widget(content);
    c_w.setMarginTop(16);
    c_w.setMarginBottom(4);
    c_w.setMarginStart(20);
    c_w.setMarginEnd(20);

    if (mode == .create) {
        const d = device orelse unreachable;
        const heading = gtk.Label.new(ui.zFmt("Mount {s}", .{d.name}));
        ui.widget(heading).addCssClass(ui.z("title-4"));
        heading.setXalign(0);
        gtk.Box.append(content, ui.widget(heading));

        const info = gtk.Box.new(.vertical, 4);
        ui.cardField(info, "Device", d.name, false);
        ui.cardField(info, "Type", d.fs_type, false);
        ui.cardField(info, "UUID", d.uuid, false);
        gtk.Box.append(content, ui.widget(info));
    } else {
        const e = edit orelse unreachable;
        const heading = gtk.Label.new(ui.zFmt("Edit {s}", .{e.unit_name}));
        ui.widget(heading).addCssClass(ui.z("title-4"));
        heading.setXalign(0);
        gtk.Box.append(content, ui.widget(heading));
    }

    gtk.Box.append(content, ui.widget(gtk.Separator.new(.horizontal)));

    appendFieldLabel(content, "Mount point");
    const mount_entry = gtk.Entry.new();
    ui.widget(mount_entry).setHexpand(1);
    if (mode == .create) {
        const d = device orelse unreachable;
        gtk.Editable.setText(ui.editable(mount_entry), ui.z(d.default_mount_point));
    } else {
        const e = edit orelse unreachable;
        gtk.Editable.setText(ui.editable(mount_entry), ui.z(e.where));
    }
    gtk.Box.append(content, ui.widget(mount_entry));

    appendFieldLabel(content, "Description (optional)");
    const desc_entry = gtk.Entry.new();
    ui.widget(desc_entry).setHexpand(1);
    desc_entry.setPlaceholderText(ui.z("e.g. Games drive, Backup disk"));
    if (mode == .edit) {
        const e = edit orelse unreachable;
        gtk.Editable.setText(ui.editable(desc_entry), ui.z(e.description));
    }
    gtk.Box.append(content, ui.widget(desc_entry));

    const recommended = options.optionsForFs(fs_type);
    var check_list: std.ArrayList(CheckOpt) = .empty;
    if (recommended.len > 0) {
        appendFieldLabel(content, "Recommended mount options");

        const opts_box = gtk.Box.new(.vertical, 2);
        for (recommended) |opt| {
            const resolved = options.resolveOption(std.heap.page_allocator, opt.option) catch opt.option;
            const check = gtk.CheckButton.new();
            const label = gtk.Label.new(ui.zFmt("<b>{s}</b>: {s}", .{ opt.option, opt.description }));
            label.setUseMarkup(1);
            label.setWrap(1);
            label.setXalign(0);
            check.setChild(ui.widget(label));

            const active: c_int = if (mode == .edit)
                @intFromBool(optionsContain((edit orelse unreachable).current_options, resolved))
            else
                1;
            check.setActive(active);

            gtk.Box.append(opts_box, ui.widget(check));
            check_list.append(std.heap.page_allocator, .{ .check = check, .option = resolved }) catch {};
        }
        gtk.Box.append(content, ui.widget(opts_box));
    }

    appendFieldLabel(content, "Additional options (optional)");
    const extra_entry = gtk.Entry.new();
    ui.widget(extra_entry).setHexpand(1);
    extra_entry.setPlaceholderText(ui.z("e.g. nofail"));
    if (mode == .edit) {
        const e = edit orelse unreachable;
        var additional: std.ArrayList(u8) = .empty;
        var it = std.mem.splitScalar(u8, e.current_options, ',');
        var first = true;
        while (it.next()) |raw| {
            const o = std.mem.trim(u8, raw, " ");
            if (o.len == 0) continue;
            if (optionsContainSlice(recommended, o)) continue;
            if (!first) additional.append(std.heap.page_allocator, ',') catch {};
            additional.appendSlice(std.heap.page_allocator, o) catch {};
            first = false;
        }
        gtk.Editable.setText(ui.editable(extra_entry), ui.z(additional.items));
    }
    gtk.Box.append(content, ui.widget(extra_entry));

    const ctx = std.heap.page_allocator.create(OptionsCtx) catch return;
    ctx.* = .{
        .window = win,
        .mount_entry = mount_entry,
        .desc_entry = desc_entry,
        .extra_entry = extra_entry,
        .checks = check_list.items,
        .cb = cb,
        .ud = ud,
    };

    const button_box = gtk.Box.new(.horizontal, 8);
    ui.widget(button_box).setHalign(.end);
    ui.widget(button_box).setMarginTop(8);
    ui.widget(button_box).setMarginBottom(16);
    ui.widget(button_box).setMarginStart(20);
    ui.widget(button_box).setMarginEnd(20);

    const cancel = gtk.Button.newWithLabel(ui.z("Cancel"));
    _ = gtk.Button.signals.clicked.connect(cancel, *OptionsCtx, &onOptionsCancel, ctx, .{});
    const confirm = gtk.Button.newWithLabel(ui.z(if (mode == .create) "Mount" else "Save"));
    ui.widget(confirm).addCssClass(ui.z("suggested-action"));
    _ = gtk.Button.signals.clicked.connect(confirm, *OptionsCtx, &onOptionsConfirm, ctx, .{});

    gtk.Box.append(button_box, ui.widget(cancel));
    gtk.Box.append(button_box, ui.widget(confirm));

    const cap = scrollCap(parent);
    const scrolled = gtk.ScrolledWindow.new();
    ui.widget(scrolled).setHexpand(1);
    ui.widget(scrolled).setVexpand(1);
    ui.widget(scrolled).setSizeRequest(-1, @min(360, cap));
    scrolled.setPolicy(.never, .automatic);
    scrolled.setMaxContentHeight(cap);
    scrolled.setChild(ui.widget(content));

    const outer = gtk.Box.new(.vertical, 0);
    gtk.Box.append(outer, ui.widget(scrolled));
    gtk.Box.append(outer, ui.widget(button_box));

    win.setChild(ui.widget(outer));
    _ = gtk.Window.signals.close_request.connect(win, *OptionsCtx, &onOptionsCloseRequest, ctx, .{});
    win.present();
    _ = ui.widget(mount_entry).grabFocus();
}

fn appendFieldLabel(box: *gtk.Box, text: []const u8) void {
    const label = gtk.Label.new(ui.z(text));
    label.setXalign(0);
    ui.widget(label).addCssClass(ui.z("dim-label"));
    gtk.Box.append(box, ui.widget(label));
}

fn optionsContain(comma_list: []const u8, needle: []const u8) bool {
    var it = std.mem.splitScalar(u8, comma_list, ',');
    while (it.next()) |raw| {
        if (std.mem.eql(u8, std.mem.trim(u8, raw, " "), needle)) return true;
    }
    return false;
}

fn optionsContainSlice(list: []const options.MountOption, needle: []const u8) bool {
    for (list) |opt| {
        if (std.mem.eql(u8, opt.option, needle)) return true;
    }
    return false;
}

fn onOptionsCancel(btn: *gtk.Button, ctx: *OptionsCtx) callconv(.c) void {
    _ = btn;
    const win = ctx.window;
    closeOptions(ctx, null);
    win.destroy();
}

fn onOptionsCloseRequest(win: *gtk.Window, ctx: *OptionsCtx) callconv(.c) c_int {
    _ = win;
    closeOptions(ctx, null);
    return 0;
}

fn onOptionsConfirm(btn: *gtk.Button, ctx: *OptionsCtx) callconv(.c) void {
    _ = btn;
    const alloc = std.heap.page_allocator;

    const mount_point = std.mem.sliceTo(gtk.Editable.getText(ui.editable(ctx.mount_entry)), 0);
    const description = std.mem.sliceTo(gtk.Editable.getText(ui.editable(ctx.desc_entry)), 0);
    const extra = std.mem.sliceTo(gtk.Editable.getText(ui.editable(ctx.extra_entry)), 0);

    var opts: std.ArrayList(u8) = .empty;
    for (ctx.checks) |check_opt| {
        if (check_opt.check.getActive() == 0) continue;
        if (opts.items.len > 0) opts.append(alloc, ',') catch {};
        opts.appendSlice(alloc, check_opt.option) catch {};
    }
    const trimmed_extra = std.mem.trim(u8, extra, " ");
    if (trimmed_extra.len > 0) {
        if (opts.items.len > 0) opts.append(alloc, ',') catch {};
        opts.appendSlice(alloc, trimmed_extra) catch {};
    }

    const choice = MountChoice{
        .mount_point = alloc.dupe(u8, mount_point) catch "",
        .description = alloc.dupe(u8, description) catch "",
        .options = opts.items,
    };

    const win = ctx.window;
    closeOptions(ctx, choice);
    win.destroy();
}

fn closeOptions(ctx: *OptionsCtx, choice: ?MountChoice) void {
    const cb = ctx.cb;
    const ud = ctx.ud;
    std.heap.page_allocator.destroy(ctx);
    cb(ud, choice);
}

const Shell = struct {
    win: *gtk.Window,
    content: *gtk.Box,
    buttons: *gtk.Box,
};

fn destructiveShell(
    parent: *gtk.Window,
    title: []const u8,
    heading: []const u8,
    warning: []const u8,
    width: c_int,
) Shell {
    const win = newDialog(parent, title, width, -1);

    const content = gtk.Box.new(.vertical, 10);
    const c_w = ui.widget(content);
    c_w.setMarginTop(16);
    c_w.setMarginBottom(4);
    c_w.setMarginStart(20);
    c_w.setMarginEnd(20);

    const h = gtk.Label.new(ui.z(heading));
    ui.widget(h).addCssClass(ui.z("title-4"));
    h.setXalign(0);
    h.setWrap(1);
    gtk.Box.append(content, ui.widget(h));

    const w = gtk.Label.new(ui.z(warning));
    ui.widget(w).addCssClass(ui.z("warning-text"));
    w.setWrap(1);
    w.setXalign(0);
    gtk.Box.append(content, ui.widget(w));

    const buttons = gtk.Box.new(.horizontal, 8);
    const b_w = ui.widget(buttons);
    b_w.setHalign(.end);
    b_w.setMarginTop(8);
    b_w.setMarginBottom(16);
    b_w.setMarginStart(20);
    b_w.setMarginEnd(20);

    const cap = scrollCap(parent);
    const scrolled = gtk.ScrolledWindow.new();
    ui.widget(scrolled).setHexpand(1);
    ui.widget(scrolled).setVexpand(1);
    ui.widget(scrolled).setSizeRequest(-1, @min(360, cap));
    scrolled.setPolicy(.never, .automatic);
    scrolled.setMaxContentHeight(cap);
    scrolled.setChild(ui.widget(content));

    const outer = gtk.Box.new(.vertical, 0);
    gtk.Box.append(outer, ui.widget(scrolled));
    gtk.Box.append(outer, ui.widget(buttons));
    win.setChild(ui.widget(outer));

    return .{ .win = win, .content = content, .buttons = buttons };
}

const ConfirmByName = struct {
    entry: *gtk.Entry,
    error_label: *gtk.Label,
};

fn appendConfirmByName(box: *gtk.Box, expected: []const u8) ConfirmByName {
    gtk.Box.append(box, ui.widget(gtk.Separator.new(.horizontal)));
    appendFieldLabel(box, ui.zFmt("Type {s} to confirm", .{expected}));

    const entry = gtk.Entry.new();
    ui.widget(entry).setHexpand(1);
    entry.setPlaceholderText(ui.z(expected));
    gtk.Box.append(box, ui.widget(entry));

    const error_label = gtk.Label.new(ui.z(""));
    ui.widget(error_label).addCssClass(ui.z("error-label"));
    error_label.setXalign(0);
    error_label.setWrap(1);
    gtk.Box.append(box, ui.widget(error_label));

    return .{ .entry = entry, .error_label = error_label };
}

fn appendError(box: *gtk.Box) *gtk.Label {
    const error_label = gtk.Label.new(ui.z(""));
    ui.widget(error_label).addCssClass(ui.z("error-label"));
    error_label.setXalign(0);
    error_label.setWrap(1);
    gtk.Box.append(box, ui.widget(error_label));
    return error_label;
}

fn showError(label: *gtk.Label, text: []const u8) void {
    label.setLabel(ui.z(text));
    ui.widget(label).setVisible(1);
}

fn extraWarningSuffix(extra: []const u8) []const u8 {
    if (extra.len == 0) return "";
    return ui.zFmt("\n\n{s}", .{extra});
}

fn fsDropdown(filesystems: []const []const u8, current: []const u8) *gtk.DropDown {
    const alloc = std.heap.page_allocator;
    const items = alloc.alloc(?[*:0]const u8, filesystems.len + 1) catch unreachable;
    for (filesystems, 0..) |fs, i| items[i] = ui.z(fs);
    items[filesystems.len] = null;

    const dropdown = gtk.DropDown.newFromStrings(@ptrCast(items.ptr));
    dropdown.setSelected(defaultFsIndex(filesystems, current));
    return dropdown;
}

fn defaultFsIndex(filesystems: []const []const u8, current: []const u8) c_uint {
    for (filesystems, 0..) |fs, i| {
        if (std.ascii.eqlIgnoreCase(fs, current)) return @intCast(i);
    }
    for (filesystems, 0..) |fs, i| {
        if (std.ascii.eqlIgnoreCase(fs, "ext4")) return @intCast(i);
    }
    return 0;
}

fn chosenFs(filesystems: []const []const u8, dropdown: *gtk.DropDown) []const u8 {
    const index: usize = dropdown.getSelected();
    if (index >= filesystems.len) return "ext4";
    return filesystems[index];
}

fn entryText(entry: *gtk.Entry) []const u8 {
    return std.mem.sliceTo(gtk.Editable.getText(ui.editable(entry)), 0);
}

const mib_f: f64 = 1024 * 1024;

fn mibOf(bytes: u64) f64 {
    return @floatFromInt(bytes / blockops.mib);
}

const SliderCtx = struct {
    entry: *gtk.Entry,
};

fn newScale(entry: *gtk.Entry) *gtk.Scale {
    const scale = gtk.Scale.newWithRange(.horizontal, 1, 1024, 1);
    const range = ui.as(gtk.Range, scale);
    range.setRoundDigits(0);
    range.setIncrements(1, 1024);
    scale.setDrawValue(0);

    const ctx = std.heap.page_allocator.create(SliderCtx) catch return scale;
    ctx.* = .{ .entry = entry };
    _ = gtk.Range.signals.value_changed.connect(range, *SliderCtx, &onSliderChanged, ctx, .{});

    ui.widget(scale).setHexpand(1);
    ui.widget(scale).setMarginBottom(4);
    return scale;
}

fn onSliderChanged(range: *gtk.Range, ctx: *SliderCtx) callconv(.c) void {
    var buf: [16]u8 = undefined;
    const bytes: u64 = @intFromFloat(range.getValue() * mib_f);
    gtk.Editable.setText(ui.editable(ctx.entry), ui.z(format.humanSize(&buf, bytes)));
}

fn setSpan(scale: *gtk.Scale, entry: *gtk.Entry, max_mib: f64, value_mib: f64, marks: bool) void {
    const range = ui.as(gtk.Range, scale);
    range.setRange(1, @max(max_mib, value_mib));
    scale.clearMarks();
    if (marks and max_mib > 4) {
        scale.addMark(max_mib / 4, .bottom, null);
        scale.addMark(max_mib / 2, .bottom, null);
        scale.addMark(max_mib * 3 / 4, .bottom, null);
    }
    range.setValue(value_mib);

    ui.widget(scale).setVisible(@intFromBool(max_mib >= 2));

    var buf: [16]u8 = undefined;
    const bytes: u64 = @intFromFloat(value_mib * mib_f);
    gtk.Editable.setText(ui.editable(entry), ui.z(format.humanSize(&buf, bytes)));
}

const RegionPick = struct {
    scale: *gtk.Scale,
    entry: *gtk.Entry,
    region: RegionChoice,
    chosen: *RegionChoice,
};

fn onRegionToggled(btn: *gtk.CheckButton, pick: *RegionPick) callconv(.c) void {
    if (btn.getActive() == 0) return;
    pick.chosen.* = pick.region;
    setSpan(pick.scale, pick.entry, mibOf(pick.region.size), mibOf(pick.region.size), true);
}

pub const FormatInfo = struct {
    name: []const u8,
    dev: []const u8,
    size_text: []const u8,
    contents: []const u8,
    whole_disk: bool,
    extra_warning: []const u8 = "",
};

pub const FormatChoice = struct {
    fs_type: []const u8,
    label: []const u8,
    erase: bool,
};

const FormatCtx = struct {
    window: *gtk.Window,
    expected: [:0]const u8,
    filesystems: []const []const u8,
    dropdown: *gtk.DropDown,
    label_entry: *gtk.Entry,
    confirm: ConfirmByName,
    erase_check: ?*gtk.CheckButton,
    cb: *const fn (?*anyopaque, ?FormatChoice) void,
    ud: ?*anyopaque,
};

pub fn showFormat(
    parent: *gtk.Window,
    info: FormatInfo,
    filesystems: []const []const u8,
    cb: *const fn (?*anyopaque, ?FormatChoice) void,
    ud: ?*anyopaque,
) void {
    const shell = destructiveShell(
        parent,
        ui.zFmt("Format {s}", .{info.name}),
        ui.zFmt("Format {s}", .{info.name}),
        ui.zFmt(
            "Everything on {s} ({s}) will be permanently destroyed.\n\n" ++
                "This cannot be undone and the data cannot be recovered.{s}",
            .{ info.dev, info.size_text, extraWarningSuffix(info.extra_warning) },
        ),
        520,
    );

    const fields = gtk.Box.new(.vertical, 4);
    ui.cardField(fields, "Device", info.dev, true);
    ui.cardField(fields, "Size", info.size_text, false);
    ui.cardField(fields, "Contents", info.contents, false);
    gtk.Box.append(shell.content, ui.widget(fields));

    gtk.Box.append(shell.content, ui.widget(gtk.Separator.new(.horizontal)));

    appendFieldLabel(shell.content, "Filesystem");
    const dropdown = fsDropdown(filesystems, info.contents);
    ui.widget(dropdown).setHalign(.start);
    gtk.Box.append(shell.content, ui.widget(dropdown));

    appendFieldLabel(shell.content, "Label (optional)");
    const label_entry = gtk.Entry.new();
    ui.widget(label_entry).setHexpand(1);
    label_entry.setPlaceholderText(ui.z("e.g. Games, Backup"));
    gtk.Box.append(shell.content, ui.widget(label_entry));

    var erase_check: ?*gtk.CheckButton = null;
    if (info.whole_disk) {
        const check = gtk.CheckButton.newWithLabel(ui.z("Overwrite the whole disk first"));
        ui.widget(check).setHalign(.start);
        ui.widget(check).setTooltipText(ui.z("Slow: writes to every sector, and nothing is recoverable afterwards"));
        gtk.Box.append(shell.content, ui.widget(check));
        erase_check = check;
    }

    const confirm = appendConfirmByName(shell.content, info.name);

    const ctx = std.heap.page_allocator.create(FormatCtx) catch return;
    ctx.* = .{
        .window = shell.win,
        .expected = ui.z(info.name),
        .filesystems = filesystems,
        .dropdown = dropdown,
        .label_entry = label_entry,
        .confirm = confirm,
        .erase_check = erase_check,
        .cb = cb,
        .ud = ud,
    };

    const cancel = gtk.Button.newWithLabel(ui.z("Cancel"));
    _ = gtk.Button.signals.clicked.connect(cancel, *FormatCtx, &onFormatCancel, ctx, .{});
    const proceed = gtk.Button.newWithLabel(ui.z("Format"));
    ui.widget(proceed).addCssClass(ui.z("destructive-action"));
    _ = gtk.Button.signals.clicked.connect(proceed, *FormatCtx, &onFormatConfirm, ctx, .{});
    gtk.Box.append(shell.buttons, ui.widget(cancel));
    gtk.Box.append(shell.buttons, ui.widget(proceed));

    _ = gtk.Window.signals.close_request.connect(shell.win, *FormatCtx, &onFormatCloseRequest, ctx, .{});
    shell.win.present();
    _ = ui.widget(confirm.entry).grabFocus();
}

fn onFormatCancel(btn: *gtk.Button, ctx: *FormatCtx) callconv(.c) void {
    _ = btn;
    const win = ctx.window;
    closeFormat(ctx, null);
    win.destroy();
}

fn onFormatCloseRequest(win: *gtk.Window, ctx: *FormatCtx) callconv(.c) c_int {
    _ = win;
    closeFormat(ctx, null);
    return 0;
}

fn onFormatConfirm(btn: *gtk.Button, ctx: *FormatCtx) callconv(.c) void {
    _ = btn;
    if (!blockops.confirmMatches(entryText(ctx.confirm.entry), ctx.expected)) {
        showError(ctx.confirm.error_label, ui.zFmt("Type {s} exactly. Nothing happens until you do.", .{ctx.expected}));
        return;
    }

    const alloc = std.heap.page_allocator;
    const choice = FormatChoice{
        .fs_type = alloc.dupe(u8, chosenFs(ctx.filesystems, ctx.dropdown)) catch "",
        .label = alloc.dupe(u8, entryText(ctx.label_entry)) catch "",
        .erase = if (ctx.erase_check) |c| c.getActive() != 0 else false,
    };

    const win = ctx.window;
    closeFormat(ctx, choice);
    win.destroy();
}

fn closeFormat(ctx: *FormatCtx, choice: ?FormatChoice) void {
    const cb = ctx.cb;
    const ud = ctx.ud;
    std.heap.page_allocator.destroy(ctx);
    cb(ud, choice);
}

pub const RegionChoice = struct {
    label: []const u8,
    size_text: []const u8,
    offset: u64,
    size: u64,
};

pub const PartitionInfo = struct {
    disk_title: []const u8,
    disk_name: []const u8,
};

pub const PartitionChoice = struct {
    offset: u64,
    size: u64,
    name: []const u8,
    fs_type: []const u8,
    label: []const u8,
};

const PartitionCtx = struct {
    window: *gtk.Window,
    chosen: *RegionChoice,
    filesystems: []const []const u8,
    dropdown: *gtk.DropDown,
    size_entry: *gtk.Entry,
    name_entry: *gtk.Entry,
    label_entry: *gtk.Entry,
    error_label: *gtk.Label,
    cb: *const fn (?*anyopaque, ?PartitionChoice) void,
    ud: ?*anyopaque,
};

pub fn showNewPartition(
    parent: *gtk.Window,
    info: PartitionInfo,
    regions: []const RegionChoice,
    filesystems: []const []const u8,
    cb: *const fn (?*anyopaque, ?PartitionChoice) void,
    ud: ?*anyopaque,
) void {
    const shell = destructiveShell(
        parent,
        ui.zFmt("New partition on {s}", .{info.disk_name}),
        ui.zFmt("New partition on {s}", .{info.disk_title}),
        "The new partition goes into whichever gap you pick below. " ++
            "The partitions already on the disk are left alone.",
        520,
    );

    const owned = std.heap.page_allocator.dupe(RegionChoice, regions) catch regions;

    const fields = gtk.Box.new(.vertical, 4);
    ui.cardField(fields, "Disk", info.disk_name, true);
    gtk.Box.append(shell.content, ui.widget(fields));

    gtk.Box.append(shell.content, ui.widget(gtk.Separator.new(.horizontal)));

    const chosen = std.heap.page_allocator.create(RegionChoice) catch return;
    chosen.* = biggestRegion(owned) orelse owned[0];

    const size_entry = gtk.Entry.new();
    ui.widget(size_entry).setHexpand(1);
    const scale = newScale(size_entry);
    setSpan(scale, size_entry, mibOf(chosen.size), mibOf(chosen.size), true);

    appendFieldLabel(shell.content, "Where");
    const where_box = gtk.Box.new(.vertical, 2);
    var group: ?*gtk.CheckButton = null;
    for (owned) |r| {
        const radio = gtk.CheckButton.newWithLabel(ui.z(r.label));
        if (group) |g| radio.setGroup(g) else group = radio;
        radio.setActive(@intFromBool(r.offset == chosen.offset));
        ui.widget(radio).setHalign(.start);
        gtk.Box.append(where_box, ui.widget(radio));

        const pick = std.heap.page_allocator.create(RegionPick) catch continue;
        pick.* = .{ .scale = scale, .entry = size_entry, .region = r, .chosen = chosen };
        _ = gtk.CheckButton.signals.toggled.connect(radio, *RegionPick, &onRegionToggled, pick, .{});
    }
    gtk.Box.append(shell.content, ui.widget(where_box));

    appendFieldLabel(shell.content, "Size");
    gtk.Box.append(shell.content, ui.widget(size_entry));
    gtk.Box.append(shell.content, ui.widget(scale));

    const help = gtk.Label.new(ui.z("Drag to the size you want, or type one, e.g. 500M, 20G, 50%"));
    ui.widget(help).addCssClass(ui.z("dim-label"));
    help.setXalign(0);
    gtk.Box.append(shell.content, ui.widget(help));

    appendFieldLabel(shell.content, "Partition name (optional)");
    const name_entry = gtk.Entry.new();
    ui.widget(name_entry).setHexpand(1);
    gtk.Box.append(shell.content, ui.widget(name_entry));

    appendFieldLabel(shell.content, "Filesystem");
    const dropdown = fsDropdown(filesystems, "");
    ui.widget(dropdown).setHalign(.start);
    gtk.Box.append(shell.content, ui.widget(dropdown));

    appendFieldLabel(shell.content, "Label (optional)");
    const label_entry = gtk.Entry.new();
    ui.widget(label_entry).setHexpand(1);
    gtk.Box.append(shell.content, ui.widget(label_entry));

    const error_label = appendError(shell.content);

    const ctx = std.heap.page_allocator.create(PartitionCtx) catch return;
    ctx.* = .{
        .window = shell.win,
        .chosen = chosen,
        .filesystems = filesystems,
        .dropdown = dropdown,
        .size_entry = size_entry,
        .name_entry = name_entry,
        .label_entry = label_entry,
        .error_label = error_label,
        .cb = cb,
        .ud = ud,
    };

    const cancel = gtk.Button.newWithLabel(ui.z("Cancel"));
    _ = gtk.Button.signals.clicked.connect(cancel, *PartitionCtx, &onPartitionCancel, ctx, .{});
    const proceed = gtk.Button.newWithLabel(ui.z("Create partition"));
    ui.widget(proceed).addCssClass(ui.z("suggested-action"));
    _ = gtk.Button.signals.clicked.connect(proceed, *PartitionCtx, &onPartitionConfirm, ctx, .{});
    gtk.Box.append(shell.buttons, ui.widget(cancel));
    gtk.Box.append(shell.buttons, ui.widget(proceed));

    _ = gtk.Window.signals.close_request.connect(shell.win, *PartitionCtx, &onPartitionCloseRequest, ctx, .{});
    shell.win.present();
    _ = ui.widget(size_entry).grabFocus();
}

fn biggestRegion(regions: []const RegionChoice) ?RegionChoice {
    var best: ?RegionChoice = null;
    for (regions) |r| {
        if (best == null or r.size > best.?.size) best = r;
    }
    return best;
}

fn onPartitionCancel(btn: *gtk.Button, ctx: *PartitionCtx) callconv(.c) void {
    _ = btn;
    const win = ctx.window;
    closePartition(ctx, null);
    win.destroy();
}

fn onPartitionCloseRequest(win: *gtk.Window, ctx: *PartitionCtx) callconv(.c) c_int {
    _ = win;
    closePartition(ctx, null);
    return 0;
}

fn onPartitionConfirm(btn: *gtk.Button, ctx: *PartitionCtx) callconv(.c) void {
    _ = btn;
    const alloc = std.heap.page_allocator;

    const region = ctx.chosen.*;

    const size = blockops.parseSize(entryText(ctx.size_entry), region.size) orelse {
        showError(ctx.error_label, ui.zFmt(
            "Enter a size like 500M, 20G or 50%, up to {s}",
            .{region.size_text},
        ));
        return;
    };
    const aligned = blockops.alignDown(size, blockops.mib);
    if (aligned < blockops.mib) {
        showError(ctx.error_label, "A partition has to be at least 1M");
        return;
    }

    const choice = PartitionChoice{
        .offset = region.offset,
        .size = aligned,
        .name = alloc.dupe(u8, entryText(ctx.name_entry)) catch "",
        .fs_type = alloc.dupe(u8, chosenFs(ctx.filesystems, ctx.dropdown)) catch "",
        .label = alloc.dupe(u8, entryText(ctx.label_entry)) catch "",
    };

    const win = ctx.window;
    closePartition(ctx, choice);
    win.destroy();
}

fn closePartition(ctx: *PartitionCtx, choice: ?PartitionChoice) void {
    const cb = ctx.cb;
    const ud = ctx.ud;
    const chosen = ctx.chosen;
    std.heap.page_allocator.destroy(ctx);
    std.heap.page_allocator.destroy(chosen);
    cb(ud, choice);
}

pub const ResizeInfo = struct {
    name: []const u8,
    dev: []const u8,
    current_text: []const u8,
    max_text: []const u8,
    window: blockops.ResizeWindow,
};

pub const ResizeChoice = struct {
    size: u64,
};

const ResizeCtx = struct {
    window: *gtk.Window,
    expected: [:0]const u8,
    info: ResizeInfo,
    size_entry: *gtk.Entry,
    confirm: ConfirmByName,
    cb: *const fn (?*anyopaque, ?ResizeChoice) void,
    ud: ?*anyopaque,
};

pub fn showResize(
    parent: *gtk.Window,
    info: ResizeInfo,
    cb: *const fn (?*anyopaque, ?ResizeChoice) void,
    ud: ?*anyopaque,
) void {
    const shell = destructiveShell(
        parent,
        ui.zFmt("Resize {s}", .{info.name}),
        ui.zFmt("Resize {s}", .{info.name}),
        "Resizing rewrites the partition table and the filesystem inside it. " ++
            "Shrinking only goes as far as the filesystem has room to give up, " ++
            "and a resize interrupted part-way can leave the partition unusable.",
        520,
    );

    const grow = blockops.canGrow(info.window);

    const fields = gtk.Box.new(.vertical, 4);
    ui.cardField(fields, "Device", info.dev, true);
    ui.cardField(fields, "Size now", info.current_text, false);
    ui.cardField(fields, "Can grow to", if (grow) info.max_text else "no room after it", false);
    gtk.Box.append(shell.content, ui.widget(fields));

    gtk.Box.append(shell.content, ui.widget(gtk.Separator.new(.horizontal)));

    appendFieldLabel(shell.content, "New size");
    const size_entry = gtk.Entry.new();
    ui.widget(size_entry).setHexpand(1);
    gtk.Box.append(shell.content, ui.widget(size_entry));

    const scale = newScale(size_entry);
    gtk.Box.append(shell.content, ui.widget(scale));
    setSpan(scale, size_entry, mibOf(info.window.max_size), mibOf(info.window.size), grow);

    const help = gtk.Label.new(if (grow)
        ui.zFmt(
            "Up to {s}. The partition grows or shrinks at its end; it cannot be moved.",
            .{info.max_text},
        )
    else
        ui.z("There is no free space after this partition, so it can only be made smaller. " ++
            "Space in front of it is out of reach: a partition changes at its end only, and " ++
            "moving one means copying all of its data. Create a new partition in the gap instead."));
    ui.widget(help).addCssClass(ui.z(if (grow) "dim-label" else "warning-text"));
    help.setXalign(0);
    help.setWrap(1);
    gtk.Box.append(shell.content, ui.widget(help));

    const confirm = appendConfirmByName(shell.content, info.name);

    const ctx = std.heap.page_allocator.create(ResizeCtx) catch return;
    ctx.* = .{
        .window = shell.win,
        .expected = ui.z(info.name),
        .info = info,
        .size_entry = size_entry,
        .confirm = confirm,
        .cb = cb,
        .ud = ud,
    };

    const cancel = gtk.Button.newWithLabel(ui.z("Cancel"));
    _ = gtk.Button.signals.clicked.connect(cancel, *ResizeCtx, &onResizeCancel, ctx, .{});
    const proceed = gtk.Button.newWithLabel(ui.z("Resize"));
    ui.widget(proceed).addCssClass(ui.z("destructive-action"));
    _ = gtk.Button.signals.clicked.connect(proceed, *ResizeCtx, &onResizeConfirm, ctx, .{});
    gtk.Box.append(shell.buttons, ui.widget(cancel));
    gtk.Box.append(shell.buttons, ui.widget(proceed));

    _ = gtk.Window.signals.close_request.connect(shell.win, *ResizeCtx, &onResizeCloseRequest, ctx, .{});
    shell.win.present();
    _ = ui.widget(size_entry).grabFocus();
}

fn onResizeCancel(btn: *gtk.Button, ctx: *ResizeCtx) callconv(.c) void {
    _ = btn;
    const win = ctx.window;
    closeResize(ctx, null);
    win.destroy();
}

fn onResizeCloseRequest(win: *gtk.Window, ctx: *ResizeCtx) callconv(.c) c_int {
    _ = win;
    closeResize(ctx, null);
    return 0;
}

fn onResizeConfirm(btn: *gtk.Button, ctx: *ResizeCtx) callconv(.c) void {
    _ = btn;
    if (!blockops.confirmMatches(entryText(ctx.confirm.entry), ctx.expected)) {
        showError(ctx.confirm.error_label, ui.zFmt("Type {s} exactly. Nothing happens until you do.", .{ctx.expected}));
        return;
    }

    const max = ctx.info.window.max_size;
    const size = blockops.parseSize(entryText(ctx.size_entry), max) orelse {
        showError(ctx.confirm.error_label, ui.zFmt("Enter a size like 500M or 20G, up to {s}", .{ctx.info.max_text}));
        return;
    };
    const aligned = blockops.alignDown(size, blockops.mib);
    if (aligned < blockops.mib) {
        showError(ctx.confirm.error_label, "A partition has to be at least 1M");
        return;
    }
    if (aligned == ctx.info.window.size) {
        showError(ctx.confirm.error_label, "That is already its size");
        return;
    }

    const win = ctx.window;
    closeResize(ctx, .{ .size = aligned });
    win.destroy();
}

fn closeResize(ctx: *ResizeCtx, choice: ?ResizeChoice) void {
    const cb = ctx.cb;
    const ud = ctx.ud;
    std.heap.page_allocator.destroy(ctx);
    cb(ud, choice);
}

pub const TableInfo = struct {
    disk_title: []const u8,
    disk_name: []const u8,
    size_text: []const u8,
    partition_count: usize,
    contents: []const u8,
};

const TableCtx = struct {
    window: *gtk.Window,
    expected: [:0]const u8,
    gpt: *gtk.CheckButton,
    confirm: ConfirmByName,
    cb: *const fn (?*anyopaque, ?[]const u8) void,
    ud: ?*anyopaque,
};

pub fn showPartitionTable(
    parent: *gtk.Window,
    info: TableInfo,
    cb: *const fn (?*anyopaque, ?[]const u8) void,
    ud: ?*anyopaque,
) void {
    const shell = destructiveShell(
        parent,
        ui.zFmt("Partition table on {s}", .{info.disk_name}),
        ui.zFmt("Create a partition table on {s}", .{info.disk_name}),
        ui.zFmt(
            "The disk's current layout ({s}) will be discarded and everything on {s} " ++
                "becomes unreachable.\n\nThis cannot be undone.",
            .{ info.contents, info.size_text },
        ),
        520,
    );

    const fields = gtk.Box.new(.vertical, 4);
    ui.cardField(fields, "Disk", info.disk_name, true);
    ui.cardField(fields, "Size", info.size_text, false);
    if (info.partition_count > 0) {
        ui.cardField(fields, "Partitions", ui.zFmt("{d} will be deleted", .{info.partition_count}), false);
    }
    gtk.Box.append(shell.content, ui.widget(fields));

    gtk.Box.append(shell.content, ui.widget(gtk.Separator.new(.horizontal)));
    appendFieldLabel(shell.content, "Table type");

    const gpt = gtk.CheckButton.newWithLabel(ui.z("GPT: modern, no size or count limits"));
    gpt.setActive(1);
    ui.widget(gpt).setHalign(.start);
    gtk.Box.append(shell.content, ui.widget(gpt));

    const mbr = gtk.CheckButton.newWithLabel(ui.z("MBR: for very old hardware and 32-bit systems"));
    mbr.setGroup(gpt);
    ui.widget(mbr).setHalign(.start);
    gtk.Box.append(shell.content, ui.widget(mbr));

    const confirm = appendConfirmByName(shell.content, info.disk_name);

    const ctx = std.heap.page_allocator.create(TableCtx) catch return;
    ctx.* = .{
        .window = shell.win,
        .expected = ui.z(info.disk_name),
        .gpt = gpt,
        .confirm = confirm,
        .cb = cb,
        .ud = ud,
    };

    const cancel = gtk.Button.newWithLabel(ui.z("Cancel"));
    _ = gtk.Button.signals.clicked.connect(cancel, *TableCtx, &onTableCancel, ctx, .{});
    const proceed = gtk.Button.newWithLabel(ui.z("Create table"));
    ui.widget(proceed).addCssClass(ui.z("destructive-action"));
    _ = gtk.Button.signals.clicked.connect(proceed, *TableCtx, &onTableConfirm, ctx, .{});
    gtk.Box.append(shell.buttons, ui.widget(cancel));
    gtk.Box.append(shell.buttons, ui.widget(proceed));

    _ = gtk.Window.signals.close_request.connect(shell.win, *TableCtx, &onTableCloseRequest, ctx, .{});
    shell.win.present();
    _ = ui.widget(confirm.entry).grabFocus();
}

fn onTableCancel(btn: *gtk.Button, ctx: *TableCtx) callconv(.c) void {
    _ = btn;
    const win = ctx.window;
    closeTable(ctx, null);
    win.destroy();
}

fn onTableCloseRequest(win: *gtk.Window, ctx: *TableCtx) callconv(.c) c_int {
    _ = win;
    closeTable(ctx, null);
    return 0;
}

fn onTableConfirm(btn: *gtk.Button, ctx: *TableCtx) callconv(.c) void {
    _ = btn;
    if (!blockops.confirmMatches(entryText(ctx.confirm.entry), ctx.expected)) {
        showError(ctx.confirm.error_label, ui.zFmt("Type {s} exactly. Nothing happens until you do.", .{ctx.expected}));
        return;
    }

    const table_type: []const u8 = if (ctx.gpt.getActive() != 0) "gpt" else "dos";
    const win = ctx.window;
    closeTable(ctx, table_type);
    win.destroy();
}

fn closeTable(ctx: *TableCtx, table_type: ?[]const u8) void {
    const cb = ctx.cb;
    const ud = ctx.ud;
    std.heap.page_allocator.destroy(ctx);
    cb(ud, table_type);
}

test "defaultFsIndex prefers the current filesystem, then ext4, then the first" {
    const list = [_][]const u8{ "btrfs", "ext4", "vfat" };
    try std.testing.expectEqual(@as(c_uint, 0), defaultFsIndex(&list, "btrfs"));
    try std.testing.expectEqual(@as(c_uint, 2), defaultFsIndex(&list, "VFAT"));
    try std.testing.expectEqual(@as(c_uint, 1), defaultFsIndex(&list, "zfs"));
    try std.testing.expectEqual(@as(c_uint, 0), defaultFsIndex(&.{}, "ext4"));
}
