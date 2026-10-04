const std = @import("std");
const Io = std.Io;

const data = @import("data.zig");
const search = @import("search.zig");

// The build passes `.version` from build.zig.zon.
const version: []const u8 = @import("build_options").version;

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

    const apps = try data.loadBundled(arena);
    const app = search.findApp(apps, app_name) orelse {
        print(io, .stderr(), "seks: unknown app: {s}\n", .{app_name});
        std.process.exit(exit_failure);
    };

    printApp(io, app);
}

/// Prints `app` to stdout in a plain form: the name, then each group with
/// one line per binding.
///
/// TODO: replace with the renderer and the pager.
fn printApp(io: Io, app: data.App) void {
    var buffer: [4096]u8 = undefined;
    var file_writer = Io.File.stdout().writer(io, &buffer);
    const writer = &file_writer.interface;

    writeApp(writer, app) catch std.process.exit(exit_failure);
    writer.flush() catch std.process.exit(exit_failure);
}

fn writeApp(writer: *Io.Writer, app: data.App) Io.Writer.Error!void {
    try writer.print("{s}\n", .{app.full_name});
    if (app.note) |note| try writer.print("{s}\n", .{note});

    for (app.binding_groups) |group| {
        try writer.print("\n{s}\n", .{group.title});
        for (group.bindings) |binding| {
            try writer.writeAll("  ");
            for (binding.keys, 0..) |alternative, index| {
                if (index > 0) try writer.writeAll(" OR ");
                try writer.writeAll(alternative);
            }
            try writer.print("  {s}\n", .{binding.effect});
        }
    }
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

// Zig runs the tests of a file only when something references the file.
test {
    _ = data;
    _ = search;
}
