const std = @import("std");
const Pori = @import("Pori");
const gtk = Pori.gtk;
const gdk = Pori.gdk;
const gio = Pori.gio;
const glib = Pori.glib;
const gobject = Pori.gobject;
const ui = @import("helpers/ui.zig");
const env = @import("helpers/env.zig");
const desktop = @import("helpers/desktop.zig");
const window = @import("window.zig");
const sysutil = @import("helpers/sysutil.zig");

test {
    _ = @import("helpers/unitname.zig");
    _ = @import("helpers/options.zig");
    _ = @import("helpers/format.zig");
    _ = @import("services/privops.zig");
    _ = @import("helpers/sysutil.zig");
}

const app_id = "com.pori.app";

var main_window: ?*window.MainWindow = null;

pub fn main() void {
    ensureSessionEnvironment();

    switch (desktop.detect()) {
        .gnome => applyGnomeDark(),
        .other => {},
    }

    const app = gtk.Application.new(app_id, .{ .handles_command_line = true });

    _ = gio.Application.signals.command_line.connect(app, ?*anyopaque, &onCommandLine, null, .{});
    _ = gio.Application.signals.activate.connect(app, ?*anyopaque, &onActivate, null, .{});

    const status = gio.Application.run(gobject.ext.as(gio.Application, app), 0, null);
    std.process.exit(@intCast(status));
}

fn onCommandLine(app: *gtk.Application, line: *gio.ApplicationCommandLine, _: ?*anyopaque) callconv(.c) c_int {
    _ = line;
    gobject.ext.as(gio.Application, app).activate();
    return 0;
}

fn onActivate(app: *gtk.Application, _: ?*anyopaque) callconv(.c) void {
    if (app.getActiveWindow()) |existing| {
        existing.present();
        return;
    }

    const display = gdk.Display.getDefault() orelse return;

    const css = gtk.CssProvider.new();
    css.loadFromString(@embedFile("style.css"));
    gtk.StyleContext.addProviderForDisplay(display, ui.as(gtk.StyleProvider, css), 600);

    main_window = window.MainWindow.build(std.heap.page_allocator, app) catch return;
    if (main_window) |w| w.present();
}

fn ensureSessionEnvironment() void {
    if (!env.has("DBUS_SESSION_BUS_ADDRESS")) {
        if (env.get("XDG_RUNTIME_DIR")) |rd| {
            var buf: [1024]u8 = undefined;
            const sock = std.fmt.bufPrint(&buf, "{s}/bus", .{rd}) catch return;
            if (env.exists(sock)) {
                var val: [1100]u8 = undefined;
                const v = std.fmt.bufPrint(&val, "unix:path={s}", .{sock}) catch return;
                env.set("DBUS_SESSION_BUS_ADDRESS", v, false);
            }
        }
    }

    const data_dirs = env.get("XDG_DATA_DIRS") orelse "";
    if (data_dirs.len == 0 or std.mem.indexOf(u8, data_dirs, "/usr/share") == null) {
        var buf: [1024]u8 = undefined;
        const joined = if (data_dirs.len > 0)
            std.fmt.bufPrint(&buf, "/usr/local/share:/usr/share:{s}", .{data_dirs})
        else
            std.fmt.bufPrint(&buf, "/usr/local/share:/usr/share", .{});
        const v = joined catch return;
        env.set("XDG_DATA_DIRS", v, true);
    }

    if (!env.has("XDG_CURRENT_DESKTOP")) {
        env.set("XDG_CURRENT_DESKTOP", switch (desktop.detect()) {
            .gnome => "GNOME",
            .other => "",
        }, false);
    }

    if (!env.has("GSETTINGS_BACKEND")) {
        env.set("GSETTINGS_BACKEND", "dconf", false);
    }
}

fn valueAfterEquals(line: []const u8) ?[]const u8 {
    const i = std.mem.indexOfScalar(u8, line, '=') orelse return null;
    return std.mem.trim(u8, std.mem.trim(u8, line[i + 1 ..], "\""), "' ");
}

fn applyGnomeDark() void {
    const source = gio.SettingsSchemaSource.getDefault() orelse return;
    const schema = gio.SettingsSchemaSource.lookup(source, ui.z("org.gnome.desktop.interface"), 1) orelse return;
    const settings = gio.Settings.newFull(schema, null, null);
    const scheme = std.mem.sliceTo(settings.getString(ui.z("color-scheme")), 0);
    const prefer_dark = std.ascii.eqlIgnoreCase(scheme, "prefer-dark");
    env.set("GTK_APPLICATION_PREFER_DARK_THEME", if (prefer_dark) "1" else "0", true);
}
