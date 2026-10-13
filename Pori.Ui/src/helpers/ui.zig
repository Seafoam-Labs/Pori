const std = @import("std");
const Pori = @import("Pori");
const gtk = Pori.gtk;
const glib = Pori.glib;
const gobject = Pori.gobject;

pub fn as(comptime T: type, x: anytype) *T {
    return gobject.ext.as(T, x);
}

pub fn widget(x: anytype) *gtk.Widget {
    return as(gtk.Widget, x);
}

pub fn editable(x: anytype) *gtk.Editable {
    return as(gtk.Editable, x);
}

var scratch_arena: ?*std.heap.ArenaAllocator = null;

fn scratchAlloc() std.mem.Allocator {
    if (scratch_arena == null) {
        const a = std.heap.page_allocator.create(std.heap.ArenaAllocator) catch unreachable;
        a.* = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        scratch_arena = a;
    }
    return scratch_arena.?.allocator();
}

pub fn z(s: []const u8) [:0]const u8 {
    return scratchAlloc().dupeZ(u8, s) catch "";
}

pub fn zFmt(comptime fmt_str: []const u8, args: anytype) [:0]const u8 {
    const alloc = scratchAlloc();
    const s = std.fmt.allocPrint(alloc, fmt_str, args) catch "";
    return alloc.dupeZ(u8, s) catch "";
}

pub fn idle(comptime T: type, comptime f: fn (*T) void, data: *T) void {
    const S = struct {
        fn callback(ud: ?*anyopaque) callconv(.c) c_int {
            f(@ptrCast(@alignCast(ud.?)));
            return 0;
        }
    };
    _ = glib.idleAdd(&S.callback, data);
}

pub fn spawnJob(comptime T: type, comptime f: fn (*T) void, data: *T) !void {
    const S = struct {
        fn entry(d: *T) void {
            f(d);
        }
    };
    _ = try std.Thread.spawn(.{}, S.entry, .{data});
}

pub fn selectedFirst(flow: *gtk.FlowBox) ?*glib.List {
    const first = flow.getSelectedChildren();
    if (@intFromPtr(first) == 0) return null;
    return first;
}

pub fn cardField(box: *gtk.Box, name: []const u8, value: []const u8, bold: bool) void {
    const row = gtk.Box.new(.horizontal, 4);

    const name_label = gtk.Label.new(z(name));
    name_label.setXalign(0);
    widget(name_label).addCssClass(z("dim-label"));
    name_label.as(gtk.Widget).setSizeRequest(84, -1);

    const value_label = gtk.Label.new(z(value));
    value_label.setXalign(0);
    value_label.as(gtk.Widget).setHexpand(1);
    value_label.setEllipsize(.end);
    value_label.as(gtk.Widget).setTooltipText(z(value));
    if (bold) widget(value_label).addCssClass(z("heading"));

    gtk.Box.append(row, widget(name_label));
    gtk.Box.append(row, widget(value_label));
    gtk.Box.append(box, widget(row));
}

pub fn pageHeader(title: []const u8, status_label: *gtk.Label) *gtk.Box {
    const header = gtk.Box.new(.horizontal, 6);
    const w = widget(header);
    w.setMarginStart(10);
    w.setMarginEnd(10);
    w.setMarginTop(8);
    w.setMarginBottom(4);

    const title_label = gtk.Label.new(z(title));
    title_label.setXalign(0);
    title_label.as(gtk.Widget).setHexpand(1);
    widget(title_label).addCssClass(z("heading"));
    gtk.Box.append(header, widget(title_label));

    status_label.setXalign(1);
    status_label.setEllipsize(.end);
    status_label.as(gtk.Widget).setHexpand(1);
    gtk.Box.append(header, widget(status_label));

    return header;
}

pub fn refreshButton() *gtk.Button {
    const btn = gtk.Button.newFromIconName(z("view-refresh-symbolic"));
    btn.as(gtk.Widget).setTooltipText(z("Refresh"));
    return btn;
}

pub fn statusLabel() *gtk.Label {
    const label = gtk.Label.new(z(""));
    widget(label).addCssClass(z("dim-label"));
    return label;
}

pub fn setStatus(label: *gtk.Label, css_class: [:0]const u8, text: []const u8) void {
    widget(label).removeCssClass(z("dim-label"));
    widget(label).removeCssClass(z("error-label"));
    widget(label).removeCssClass(z("success-label"));
    widget(label).addCssClass(css_class);
    label.setLabel(z(text));
}

pub fn scrolled(child: *gtk.Widget) *gtk.ScrolledWindow {
    const sw = gtk.ScrolledWindow.new();
    const w = widget(sw);
    w.setHexpand(1);
    w.setVexpand(1);
    sw.setPolicy(.automatic, .automatic);
    sw.setChild(child);
    return sw;
}

pub fn clearBox(box: *gtk.Box) void {
    const w = widget(box);
    while (w.getFirstChild()) |child| box.remove(child);
}

pub fn button(label: []const u8, css_class: ?[]const u8) *gtk.Button {
    const btn = gtk.Button.newWithLabel(z(label));
    if (css_class) |c| widget(btn).addCssClass(z(c));
    return btn;
}

pub fn badge(text: []const u8, css_class: []const u8) *gtk.Label {
    const label = gtk.Label.new(z(text));
    widget(label).addCssClass(z(css_class));
    label.setXalign(0);
    return label;
}

pub fn sectionLabel(text: []const u8) *gtk.Label {
    const label = gtk.Label.new(z(text));
    widget(label).addCssClass(z("pori-section"));
    label.setXalign(0);
    return label;
}

pub const RowDot = enum { mounted, idle, none };

pub const Guide = enum { none, mid, last };

pub const RowStyle = struct {
    dot: RowDot = .none,
    indent: bool = false,
    icon: ?[]const u8 = null,
    guide: Guide = .none,
};

pub fn styledRow(title: []const u8, subtitle: []const u8, style: RowStyle) *gtk.Widget {
    const outer = gtk.Box.new(.horizontal, 6);
    const o_w = widget(outer);
    o_w.setMarginTop(6);
    o_w.setMarginBottom(6);
    o_w.setMarginStart(if (style.indent) 4 else 8);
    o_w.setMarginEnd(8);

    if (style.guide != .none) {
        const guide = gtk.Box.new(.vertical, 0);
        widget(guide).setSizeRequest(16, -1);

        const top = gtk.Box.new(.vertical, 0);
        widget(top).setVexpand(1);
        widget(top).addCssClass(z("pori-guide"));

        const elbow = gtk.Box.new(.vertical, 0);
        widget(elbow).setSizeRequest(16, 1);
        widget(elbow).addCssClass(z("pori-guide-elbow"));

        const bottom = gtk.Box.new(.vertical, 0);
        widget(bottom).setVexpand(1);
        if (style.guide == .mid) widget(bottom).addCssClass(z("pori-guide"));

        gtk.Box.append(guide, widget(top));
        gtk.Box.append(guide, widget(elbow));
        gtk.Box.append(guide, widget(bottom));
        gtk.Box.append(outer, widget(guide));
    }

    if (style.icon) |name| {
        const img = gtk.Image.newFromIconName(z(name));
        widget(img).setValign(.center);
        widget(img).addCssClass(z("dim-label"));
        gtk.Box.append(outer, widget(img));
    }

    if (style.dot != .none) {
        const d = gtk.Label.new(z(""));
        widget(d).addCssClass(z("row-dot"));
        widget(d).addCssClass(z(if (style.dot == .mounted) "row-dot-mounted" else "row-dot-idle"));
        widget(d).setValign(.center);
        gtk.Box.append(outer, widget(d));
    }

    const box = gtk.Box.new(.vertical, 2);
    const b_w = widget(box);
    b_w.setHexpand(1);

    const name = gtk.Label.new(z(title));
    widget(name).addCssClass(z("heading"));
    name.setXalign(0);
    name.setEllipsize(.end);
    gtk.Box.append(box, widget(name));

    const sub = gtk.Label.new(z(subtitle));
    widget(sub).addCssClass(z("dim-label"));
    sub.setXalign(0);
    sub.setEllipsize(.end);
    gtk.Box.append(box, widget(sub));

    gtk.Box.append(outer, b_w);
    return o_w;
}

pub fn listRow(title: []const u8, subtitle: []const u8, dot: RowDot) *gtk.Widget {
    return styledRow(title, subtitle, .{ .dot = dot });
}
