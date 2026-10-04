const std = @import("std");
const Io = std.Io;

// Keep in sync with `.version` in build.zig.zon.
const version = "0.0.0";

const usage_text = "usage: seks <app-name> | --help | --version\n";

// TODO: add the list of supported apps once the JSON data loads.
const help_text = usage_text ++
    \\
    \\Show every keyboard shortcut of an app.
    \\
    \\options:
    \\  --help     show this help
    \\  --version  show the version
    \\
;

const exit_failure = 1;
const exit_usage = 2;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) failUsage(io, "", .{});

    // Only the first argument can be an option. All other arguments are
    // part of the app name.
    const first_arg = args[1];
    if (std.mem.eql(u8, first_arg, "--help")) {
        return print(io, .stdout(), help_text, .{});
    }
    if (std.mem.eql(u8, first_arg, "--version")) {
        return print(io, .stdout(), "seks {s}\n", .{version});
    }
    if (std.mem.startsWith(u8, first_arg, "-")) {
        failUsage(io, "seks: unknown option: {s}\n", .{first_arg});
    }

    // Join the arguments, so `seks visual studio code` needs no quotes.
    const joined = try std.mem.join(arena, " ", args[1..]);
    const app_name = std.mem.trim(u8, joined, " ");
    if (app_name.len == 0) failUsage(io, "", .{});

    // TODO: look up `app_name` and show its shortcuts.
}

/// Prints a formatted message to `file`. Exits with `exit_failure` when the
/// write fails, for example on a closed pipe.
fn print(io: Io, file: Io.File, comptime fmt: []const u8, args: anytype) void {
    var buffer: [1024]u8 = undefined;
    var file_writer = file.writer(io, &buffer);
    const writer = &file_writer.interface;

    writer.print(fmt, args) catch std.process.exit(exit_failure);
    writer.flush() catch std.process.exit(exit_failure);
}

/// Prints a formatted message and the usage line to stderr, then exits with
/// `exit_usage`.
fn failUsage(io: Io, comptime fmt: []const u8, args: anytype) noreturn {
    print(io, .stderr(), fmt ++ usage_text, args);
    std.process.exit(exit_usage);
}
