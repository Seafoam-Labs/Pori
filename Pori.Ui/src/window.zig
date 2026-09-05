//! Main window shell: overlay + sidebar navigation + stack of pages.
//! Port of MainWindow.cs / MainWindow.ui, built in code instead of GtkBuilder.
const std = @import("std");
const Pori = @import("Pori");
const gtk = Pori.gtk;
const gio = Pori.gio;
const gobject = Pori.gobject;
const ui = @import("helpers/ui.zig");
const disks_page = @import("pages/disks.zig");
const edit_page = @import("pages/edit.zig");
const unmount_page = @import("pages/unmount.zig");

pub const version = "0.1.0";

pub const MainWindow = struct {
    window: *gtk.ApplicationWindow,
    overlay: *gtk.Overlay,
    stack: *gtk.Stack,
    disks: *disks_page.DisksPage,
    edit: *edit_page.EditPage,
    unmount: *unmount_page.UnmountPage,
    nav_disks: *gtk.ToggleButton,
    nav_edit: *gtk.ToggleButton,
    nav_unmount: *gtk.ToggleButton,

    pub fn build(alloc: std.mem.Allocator, app: *gtk.Application) !*MainWindow {
        const self = try alloc.create(MainWindow);

        const window = gtk.ApplicationWindow.new(app);
        const win = ui.as(gtk.Window, window);
        win.setTitle(ui.z("Pori"));
        win.setDefaultSize(1020, 800);
        win.setIconName(ui.z("pori"));

        const overlay = gtk.Overlay.new();

        const outer = gtk.Box.new(.horizontal, 0);

        const sidebar = gtk.Box.new(.vertical, 0);
        const s_w = ui.widget(sidebar);
        s_w.setSizeRequest(56, -1);
        s_w.addCssClass(ui.z("pori-sidebar"));

        const nav_disks = navButton("drive-harddisk-symbolic", "Mount disks");
        const nav_edit = navButton("emblem-system-symbolic", "Edit mounts");
        const nav_unmount = navButton("media-eject-symbolic", "Remove mounts");
        nav_disks.setActive(1);

        const spacer = gtk.Box.new(.vertical, 0);
        ui.widget(spacer).setVexpand(1);

        const version_label = gtk.Label.new(ui.z("v" ++ version));
        const v_w = ui.widget(version_label);
        v_w.setOpacity(0.5);
        v_w.setMarginBottom(10);

        gtk.Box.append(sidebar, ui.widget(nav_disks));
        gtk.Box.append(sidebar, ui.widget(nav_edit));
        gtk.Box.append(sidebar, ui.widget(nav_unmount));
        gtk.Box.append(sidebar, ui.widget(spacer));
        gtk.Box.append(sidebar, v_w);

        self.* = .{
            .window = window,
            .overlay = overlay,
            .stack = undefined,
            .disks = undefined,
            .edit = undefined,
            .unmount = undefined,
            .nav_disks = nav_disks,
            .nav_edit = nav_edit,
            .nav_unmount = nav_unmount,
        };

        const stack = gtk.Stack.new();
        stack.setTransitionType(.crossfade);
        ui.widget(stack).setHexpand(1);
        ui.widget(stack).setVexpand(1);
        self.stack = stack;

        self.disks = try disks_page.DisksPage.build(alloc, win);
        self.edit = try edit_page.EditPage.build(alloc, win);
        self.unmount = try unmount_page.UnmountPage.build(alloc);

        _ = gtk.Stack.addTitled(stack, self.disks.widget(), ui.z("disks"), ui.z("Disks"));
        _ = gtk.Stack.addTitled(stack, self.edit.widget(), ui.z("edit"), ui.z("Edit"));
        _ = gtk.Stack.addTitled(stack, self.unmount.widget(), ui.z("unmount"), ui.z("Unmount"));

        gtk.Box.append(outer, s_w);
        gtk.Box.append(outer, ui.widget(stack));

        overlay.setChild(ui.widget(outer));
        win.setChild(ui.widget(overlay));

        _ = gtk.ToggleButton.signals.toggled.connect(nav_disks, *MainWindow, &onNavDisks, self, .{});
        _ = gtk.ToggleButton.signals.toggled.connect(nav_edit, *MainWindow, &onNavEdit, self, .{});
        _ = gtk.ToggleButton.signals.toggled.connect(nav_unmount, *MainWindow, &onNavUnmount, self, .{});

        return self;
    }

    fn navButton(icon: [:0]const u8, tooltip: [:0]const u8) *gtk.ToggleButton {
        const btn = gtk.ToggleButton.new();
        const b_w = ui.widget(btn);
        b_w.setMarginStart(10);
        b_w.setMarginEnd(10);
        b_w.setMarginTop(6);
        b_w.setTooltipText(tooltip);
        ui.as(gtk.Button, btn).setIconName(icon);
        return btn;
    }

    fn selectNav(self: *MainWindow, active: *gtk.ToggleButton) void {
        if (active != self.nav_disks) self.nav_disks.setActive(0);
        if (active != self.nav_edit) self.nav_edit.setActive(0);
        if (active != self.nav_unmount) self.nav_unmount.setActive(0);
        if (active.getActive() == 0) active.setActive(1);
    }

    fn onNavDisks(btn: *gtk.ToggleButton, self: *MainWindow) callconv(.c) void {
        if (btn.getActive() == 0) return;
        self.selectNav(btn);
        self.stack.setVisibleChildName(ui.z("disks"));
        self.disks.refresh();
    }

    fn onNavEdit(btn: *gtk.ToggleButton, self: *MainWindow) callconv(.c) void {
        if (btn.getActive() == 0) return;
        self.selectNav(btn);
        self.stack.setVisibleChildName(ui.z("edit"));
        self.edit.refresh();
    }

    fn onNavUnmount(btn: *gtk.ToggleButton, self: *MainWindow) callconv(.c) void {
        if (btn.getActive() == 0) return;
        self.selectNav(btn);
        self.stack.setVisibleChildName(ui.z("unmount"));
        self.unmount.refresh();
    }

    pub fn present(self: *MainWindow) void {
        ui.as(gtk.Window, self.window).present();
    }
};
