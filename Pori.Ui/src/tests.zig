const std = @import("std");

test {
    _ = @import("helpers/dbus.zig");
    _ = @import("helpers/format.zig");
    _ = @import("helpers/options.zig");
    _ = @import("helpers/unitname.zig");
    _ = @import("services/blockops.zig");
    _ = @import("services/devices.zig");
    _ = @import("services/privops.zig");
    _ = @import("services/units.zig");
    _ = @import("services/watch.zig");
    _ = @import("actions.zig");
    _ = @import("dialogs.zig");
    _ = @import("pages/drives.zig");
}
