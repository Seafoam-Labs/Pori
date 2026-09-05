const std = @import("std");
const Pori = @import("Pori");
const gtk = Pori.gtk;
const ui = @import("helpers/ui.zig");
const options = @import("helpers/options.zig");

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

const WarningCtx = struct {
    window: *gtk.Window,
    cb: *const fn (?*anyopaque, bool) void,
    ud: ?*anyopaque,
};

pub fn showNtfsWarning(parent: *gtk.Window, cb: *const fn (?*anyopaque, bool) void, ud: ?*anyopaque) void {
    const win = newDialog(parent, "NTFS Compatibility Warning", 480, -1);

    const box = gtk.Box.new(.vertical, 12);
    const b_w = ui.widget(box);
    b_w.setMarginTop(20);
    b_w.setMarginBottom(20);
    b_w.setMarginStart(20);
    b_w.setMarginEnd(20);

    const title = gtk.Label.new(ui.z("⚠ NTFS Compatibility Warning"));
    ui.widget(title).addCssClass(ui.z("title-4"));
    gtk.Box.append(box, ui.widget(title));

    const message = gtk.Label.new(ui.z(
        "Linux does not have full native support for NTFS. " ++
            "While mounting is possible you may experience issues.\n\n" ++
            "Especially if trying to mount an NTFS drive and play games off Steam " ++
            "it is recommended to back up important data and reformat the drive to a format like ext4.",
    ));
    message.setWrap(1);
    message.setXalign(0);
    gtk.Box.append(box, ui.widget(message));

    const ctx = std.heap.page_allocator.create(WarningCtx) catch return;
    ctx.* = .{ .window = win, .cb = cb, .ud = ud };

    const button_box = gtk.Box.new(.horizontal, 8);
    ui.widget(button_box).setHalign(.end);
    ui.widget(button_box).setMarginTop(8);

    const cancel = gtk.Button.newWithLabel(ui.z("Cancel"));
    _ = gtk.Button.signals.clicked.connect(cancel, *WarningCtx, &onWarningCancel, ctx, .{});
    const proceed = gtk.Button.newWithLabel(ui.z("Proceed Anyway"));
    ui.widget(proceed).addCssClass(ui.z("destructive-action"));
    _ = gtk.Button.signals.clicked.connect(proceed, *WarningCtx, &onWarningProceed, ctx, .{});

    gtk.Box.append(button_box, ui.widget(cancel));
    gtk.Box.append(button_box, ui.widget(proceed));
    gtk.Box.append(box, ui.widget(button_box));

    win.setChild(ui.widget(box));
    _ = gtk.Window.signals.close_request.connect(win, *WarningCtx, &onWarningCloseRequest, ctx, .{});
    win.present();
}

fn onWarningCancel(btn: *gtk.Button, ctx: *WarningCtx) callconv(.c) void {
    _ = btn;
    const win = ctx.window;
    fireWarning(ctx, false);
    win.destroy();
}

fn onWarningProceed(btn: *gtk.Button, ctx: *WarningCtx) callconv(.c) void {
    _ = btn;
    const win = ctx.window;
    fireWarning(ctx, true);
    win.destroy();
}

fn onWarningCloseRequest(win: *gtk.Window, ctx: *WarningCtx) callconv(.c) c_int {
    _ = win;
    fireWarning(ctx, false);
    return 0; // GTK destroys the window
}

fn fireWarning(ctx: *WarningCtx, proceed: bool) void {
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
        640,
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
            const label = gtk.Label.new(ui.zFmt("<b>{s}</b> — {s}", .{ opt.option, opt.description }));
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

    const scrolled = gtk.ScrolledWindow.new();
    ui.widget(scrolled).setHexpand(1);
    ui.widget(scrolled).setVexpand(1);
    scrolled.setPolicy(.never, .automatic);
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
