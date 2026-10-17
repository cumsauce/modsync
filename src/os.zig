const std = @import("std");
const builtin = @import("builtin");

const Io = std.Io;

// ============================================================================
// Platform helpers: browser launch, clipboard, folder validation
// ============================================================================

/// Blocking I/O context for one-shot process launches and filesystem probes.
/// `global_single_threaded` needs no allocation and no deinit; every operation
/// used here is a plain blocking syscall, so it is safe on the GUI thread and
/// from worker threads alike.
fn io() Io {
    return std.Io.Threaded.global_single_threaded.io();
}

/// Open `url` in the user's default browser.
///
/// Spawns the platform launcher (`open`, `xdg-open`, `cmd /c start`) and waits
/// only for THAT launcher to exit. The launcher hands the URL off and returns
/// immediately, so the browser's lifetime never blocks the caller. Spawn
/// failures (including a missing launcher) are returned to the caller.
pub fn openUrl(url: []const u8) !void {
    switch (builtin.os.tag) {
        .macos => try runLauncher(&.{ "open", url }),
        .linux => try runLauncher(&.{ "xdg-open", url }),
        // Empty title argument: `start` would otherwise treat the first quoted
        // token (the URL) as the new window's title.
        .windows => try runLauncher(&.{ "cmd", "/c", "start", "", url }),
        else => return error.Unsupported,
    }
}

/// Copy `text` to the system clipboard.
///
/// Uses the stock platform CLI tool with stdin piped to the child (pbcopy on
/// macOS, xclip/wl-copy on Linux, clip on Windows), so no AppKit or X11
/// linking is required. Returns `error.ClipboardUnavailable` when the tool is
/// missing or fails to complete the copy.
pub fn copyToClipboard(text: []const u8) !void {
    switch (builtin.os.tag) {
        .macos => try copyVia(&.{"pbcopy"}, text),
        .linux => copyVia(&.{ "xclip", "-selection", "clipboard" }, text) catch |err| switch (err) {
            // Minimal Wayland images ship wl-clipboard instead of xclip.
            error.ClipboardUnavailable => try copyVia(&.{"wl-copy"}, text),
            else => return err,
        },
        .windows => try copyVia(&.{"clip"}, text),
        else => return error.Unsupported,
    }
}

/// True only when `path` exists, is a directory, and the current user may
/// write to it. Missing paths, non-directories, and permission failures are
/// reported as `false`; only genuine I/O failures are returned as errors.
pub fn validateFolderWritable(path: []const u8) !bool {
    const io_handle = io();
    const cwd = Io.Dir.cwd();

    // Opening as a directory proves existence and rejects regular files
    // (`error.NotDir`) without a separate stat.
    const dir = cwd.openDir(io_handle, path, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir, error.AccessDenied, error.PermissionDenied => return false,
        else => return err,
    };
    defer dir.close(io_handle);

    // Write access on the directory itself (W_OK), i.e. entries can be created.
    cwd.access(io_handle, path, .{ .write = true }) catch |err| switch (err) {
        error.FileNotFound, error.AccessDenied, error.PermissionDenied, error.ReadOnlyFileSystem => return false,
        else => return err,
    };
    return true;
}

// ============================================================================
// Internals
// ============================================================================

/// Spawn `argv` and reap the launcher process. Used for browser/file openers,
/// which exit as soon as the target is handed off.
fn runLauncher(argv: []const []const u8) !void {
    var child = try std.process.spawn(io(), .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    _ = try child.wait(io());
}

/// Spawn a clipboard tool, feed it `text` on stdin, and require a zero exit.
/// A missing tool maps to `error.ClipboardUnavailable`; other spawn errors
/// propagate unchanged.
fn copyVia(argv: []const []const u8, text: []const u8) !void {
    var child = std.process.spawn(io(), .{
        .argv = argv,
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch |err| switch (err) {
        error.FileNotFound => return error.ClipboardUnavailable,
        else => return err,
    };

    if (child.stdin) |stdin| {
        stdin.writeStreamingAll(io(), text) catch |err| {
            stdin.close(io());
            child.stdin = null;
            _ = child.wait(io()) catch {};
            return err;
        };
        stdin.close(io());
        child.stdin = null;
    }

    const term = try child.wait(io());
    if (!term.success()) return error.ClipboardUnavailable;
}

// ============================================================================
// Tests
// ============================================================================

test "validateFolderWritable: writable temp dir is true" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(path);

    try std.testing.expect(try validateFolderWritable(path));
}

test "validateFolderWritable: missing path is false" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "does-not-exist" });
    defer std.testing.allocator.free(path);

    try std.testing.expect(!try validateFolderWritable(path));
}

test "validateFolderWritable: regular file is false" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "mod.jar", .data = "not a directory" });

    const path = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "mod.jar" });
    defer std.testing.allocator.free(path);

    try std.testing.expect(!try validateFolderWritable(path));
}
