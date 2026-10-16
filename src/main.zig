const std = @import("std");

const c = @import("webview_api");

pub fn main() !void {
    const w = c.webview_create(0, null);
    if (w == null) return error.WebviewCreateFailed;

    _ = c.webview_set_title(w, "modsync");
    _ = c.webview_set_size(w, 520, 640, c.WEBVIEW_HINT_NONE);
    _ = c.webview_navigate(w, "data:text/html,<h1>modsync</h1>");
    _ = c.webview_run(w);
    _ = c.webview_destroy(w);
}

test {
    _ = @import("config.zig");
}
