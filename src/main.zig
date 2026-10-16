const std = @import("std");
const dvui = @import("dvui");

pub const dvui_app: dvui.App = .{
    .config = .{
        .options = .{
            .size = .{ .w = 520.0, .h = 640.0 },
            .min_size = .{ .w = 320.0, .h = 400.0 },
            .title = "modsync",
        },
    },
    .frameFn = appFrame,
};

pub const main = dvui.App.main;
pub const panic = dvui.App.panic;
pub const std_options: std.Options = .{ .logFn = dvui.App.logFn };

fn appFrame() !dvui.App.Result {
    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .style = .window });
    defer scroll.deinit();

    dvui.label(@src(), "modsync (dvui spike)", .{}, .{ .font = .theme(.title) });
    _ = dvui.separator(@src(), .{ .expand = .horizontal });

    if (dvui.button(@src(), "Click me", .{}, .{})) {
        std.debug.print("clicked\n", .{});
    }

    return .ok;
}
