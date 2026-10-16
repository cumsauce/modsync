const std = @import("std");

const config = @import("config.zig");
const App = @import("app.zig").App;

pub fn main() !void {
    const alloc = std.heap.smp_allocator;

    // Make the seed list discoverable/editable on first run.
    config.writeDefaultsIfAbsent();

    // Load the saved config, or build one from the seed repos
    // (`<config-dir>/defaults.json`, else the embedded list).
    const loaded: ?config.Config = try config.load(alloc);
    defer if (loaded) |cfg| config.freeConfig(alloc, cfg);

    var app = try App.initFromLoaded(alloc, loaded);
    defer app.deinit();
    try app.run();
}

test {
    _ = @import("net.zig");
    _ = @import("config.zig");
    _ = @import("github.zig");
    _ = @import("install.zig");
    _ = @import("app.zig");
    _ = @import("launcher.zig");
}
