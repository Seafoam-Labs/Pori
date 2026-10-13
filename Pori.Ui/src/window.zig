const std = @import("std");
const Pori = @import("Pori");
const gtk = Pori.gtk;
const ui = @import("helpers/ui.zig");
const drives_page = @import("pages/drives.zig");

pub const MainWindow = struct {
    window: *gtk.ApplicationWindow,
    drives: *drives_page.DrivesPage,

    pub fn build(alloc: std.mem.Allocator, app: *gtk.Application) !*MainWindow {
        const self = try alloc.create(MainWindow);

        const window = gtk.ApplicationWindow.new(app);
        const win = ui.as(gtk.Window, window);
        win.setTitle(ui.z("Pori"));
        win.setDefaultSize(1020, 800);
        win.setIconName(ui.z("pori"));

        self.* = .{
            .window = window,
            .drives = undefined,
        };

        self.drives = try drives_page.DrivesPage.build(alloc, win);
        win.setChild(self.drives.widget());

        return self;
    }

    pub fn present(self: *MainWindow) void {
        ui.as(gtk.Window, self.window).present();
    }
};
