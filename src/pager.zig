//! Shows an app in the pager of the user.
const std = @import("std");
const Io = std.Io;
const Environ = std.process.Environ;

const data = @import("data.zig");
const render = @import("render.zig");

const default_command = "less";

// The shell exits with one of these when it cannot run the command.
const exit_not_executable = 126;
const exit_not_found = 127;

/// Shows `app` in the pager and waits until the user quits it.
///
/// The `PAGER` variable names the command. The default is `less`.
///
/// Returns false when no pager ran. The caller must then print the text
/// itself.
pub fn show(io: Io, environ_map: *Environ.Map, app: data.App, style: render.Style) bool {
    var child = spawn(io, environ_map) catch return false;

    // Ctrl+C goes to this process and to the pager. The pager handles it and
    // stays open. This process must stay too, or the shell takes the
    // terminal back while the pager still draws on it.
    ignoreInterrupt();

    const stdin = child.stdin.?;
    var buffer: [4096]u8 = undefined;
    var file_writer = stdin.writerStreaming(io, &buffer);
    const writer = &file_writer.interface;

    // A write fails when the user quits the pager before it reads all the
    // text. That is not an error.
    render.render(writer, app, style) catch {};
    writer.flush() catch {};

    // Close the pipe, so the pager sees the end of the text.
    stdin.close(io);
    child.stdin = null;

    const term = child.wait(io) catch return false;
    return switch (term) {
        .exited => |code| code != exit_not_executable and code != exit_not_found,
        else => true,
    };
}

/// Starts the pager with a pipe as its stdin.
fn spawn(io: Io, environ_map: *Environ.Map) !std.process.Child {
    var command: []const u8 = default_command;
    if (environ_map.get("PAGER")) |pager| {
        if (pager.len > 0) command = pager;
    }

    // `less` shows the bold codes as text unless it has the `R` option. Set
    // it only when the user has no `LESS` of their own.
    if (environ_map.get("LESS") == null) try environ_map.put("LESS", "R");

    // Run the command through the shell, so `PAGER` can hold arguments.
    return std.process.spawn(io, .{
        .argv = &.{ "/bin/sh", "-c", command },
        .stdin = .pipe,
        .environ_map = environ_map,
    });
}

fn ignoreInterrupt() void {
    std.posix.sigaction(.INT, &.{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    }, null);
}
