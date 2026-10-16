const std = @import("std");

const config = @import("config.zig");
const App = @import("app.zig").App;

pub fn main() !void {
    const alloc = std.heap.smp_allocator;

    // Load the saved config, or fall back to the platform defaults. The
    // default repos slice aliases a global seed — App.init deep-clones, so it
    // is never mutated or freed here (and a loaded copy is freed below).
    const loaded: ?config.Config = try config.load(alloc);
    defer if (loaded) |cfg| config.freeConfig(alloc, cfg);
    const cfg = loaded orelse config.Config{
        .minecraftDir = config.defaultMinecraftDir(),
        .githubToken = null,
        .repos = config.defaultRepos(),
    };

    var app = try App.init(alloc, cfg);
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
