const std = @import("std");
const Io = std.Io;

const data = @import("data.zig");
const pager = @import("pager.zig");
const render = @import("render.zig");
const search = @import("search.zig");

// The build passes `.version` from build.zig.zon.
const version: []const u8 = @import("build_options").version;

const usage_text = "usage: seks <app-name> | --list | --help | --version\n";

const help_text = usage_text ++
    \\
    \\Show every keyboard shortcut of an app.
    \\
    \\options:
    \\  --list         list the apps
    \\  -h, --help     show this help
    \\  -V, --version  show the version
    \\
;

const exit_failure = 1;
const exit_usage = 2;

const Option = enum { list, help, version };

/// Returns the option that `arg` names, or null when it names none.
fn parseOption(arg: []const u8) ?Option {
    const names = [_]struct { name: []const u8, option: Option }{
        .{ .name = "--list", .option = .list },
        .{ .name = "--help", .option = .help },
        .{ .name = "-h", .option = .help },
        .{ .name = "--version", .option = .version },
        .{ .name = "-V", .option = .version },
    };
    for (names) |entry| {
        if (std.mem.eql(u8, arg, entry.name)) return entry.option;
    }
    return null;
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) failUsage(io, "", .{});

    // Only the first argument can be an option. All other arguments are
    // part of the app name.
    const first_arg = args[1];
    if (parseOption(first_arg)) |option| {
        if (args.len > 2) failUsage(io, "seks: {s} takes no argument\n", .{first_arg});
        return switch (option) {
            .list => printList(io, try data.loadBundled(arena)),
            .help => print(io, .stdout(), help_text, .{}),
            .version => print(io, .stdout(), "seks {s}\n", .{version}),
        };
    }
    if (std.mem.startsWith(u8, first_arg, "-")) {
        failUsage(io, "seks: unknown option: {s}\n", .{first_arg});
    }

    const app_name = try joinWords(arena, args[1..]);
    if (app_name.len == 0) failUsage(io, "", .{});

    const apps = try data.loadBundled(arena);
    const app = search.findApp(apps, app_name) orelse {
        print(io, .stderr(), "seks: unknown app: {s}\nRun `seks --list` to see the apps.\n", .{app_name});
        std.process.exit(exit_failure);
    };

    const style = stdoutStyle(init);

    // The pager needs a terminal on both ends: stdout to draw the pages,
    // stdin to read the keys. A pipe on either end gets the plain text.
    const stdout_is_terminal = Io.File.stdout().isTty(io) catch false;
    const stdin_is_terminal = Io.File.stdin().isTty(io) catch false;
    if (stdout_is_terminal and stdin_is_terminal and terminalMovesCursor(init)) {
        // The pager restores the terminal before it returns, also on an
        // error. Print the text then, so the user still gets the bindings.
        if (pager.show(io, app, style)) |_| return else |_| {}
    }

    printApp(io, app, style);
}

/// Returns the words of `args` with one space between two words.
///
/// `seks visual studio code` then needs no quotes. An argument can hold
/// several words, and tabs or more than one space between them.
fn joinWords(arena: std.mem.Allocator, args: []const [:0]const u8) ![]const u8 {
    var words: std.ArrayList([]const u8) = .empty;
    for (args) |arg| {
        var parts = std.mem.tokenizeAny(u8, arg, &std.ascii.whitespace);
        while (parts.next()) |part| try words.append(arena, part);
    }
    return std.mem.join(arena, " ", words.items);
}

/// Returns true when the terminal can move the cursor, which the pager
/// needs. A terminal with no `TERM` or with `TERM=dumb` cannot, for example
/// the shell buffer of an editor.
fn terminalMovesCursor(init: std.process.Init) bool {
    const term = init.environ_map.get("TERM") orelse return false;
    return term.len > 0 and !std.mem.eql(u8, term, "dumb");
}

/// Returns `.ansi` when stdout is a terminal that takes escape codes and the
/// `NO_COLOR` variable is not set. Returns `.plain` for a pipe or a file.
fn stdoutStyle(init: std.process.Init) render.Style {
    const no_color = if (init.environ_map.get("NO_COLOR")) |value| value.len > 0 else false;
    const mode = Io.Terminal.Mode.detect(init.io, .stdout(), no_color, false) catch return .plain;
    return switch (mode) {
        .escape_codes => .ansi,
        else => .plain,
    };
}

/// Prints one line per app to stdout: the name, a tab, the full name. The
/// shell completions read this format.
///
/// The apps are in name order, because the build merges the data files in
/// file name order.
fn printList(io: Io, apps: []const data.App) void {
    var buffer: [4096]u8 = undefined;
    var file_writer = Io.File.stdout().writer(io, &buffer);
    const writer = &file_writer.interface;

    for (apps) |app| {
        writer.print("{s}\t{s}\n", .{ app.name, app.full_name }) catch std.process.exit(exit_failure);
    }
    writer.flush() catch std.process.exit(exit_failure);
}

/// Renders `app` to stdout. Exits with `exit_failure` when the write fails.
fn printApp(io: Io, app: data.App, style: render.Style) void {
    var buffer: [4096]u8 = undefined;
    var file_writer = Io.File.stdout().writer(io, &buffer);
    const writer = &file_writer.interface;

    render.render(writer, app, style) catch std.process.exit(exit_failure);
    writer.flush() catch std.process.exit(exit_failure);
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
    _ = @import("check.zig");
    _ = data;
    _ = pager;
    _ = @import("pages.zig");
    _ = render;
    _ = search;
}

test "parseOption" {
    try std.testing.expectEqual(.list, parseOption("--list").?);
    try std.testing.expectEqual(.help, parseOption("--help").?);
    try std.testing.expectEqual(.help, parseOption("-h").?);
    try std.testing.expectEqual(.version, parseOption("--version").?);
    try std.testing.expectEqual(.version, parseOption("-V").?);

    try std.testing.expectEqual(null, parseOption("--LIST"));
    try std.testing.expectEqual(null, parseOption("-x"));
    try std.testing.expectEqual(null, parseOption("nvim"));
}

test "joinWords gives one space between two words" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings("visual studio code", try joinWords(arena, &.{ "visual", "studio", "code" }));
    try std.testing.expectEqualStrings("visual studio code", try joinWords(arena, &.{" visual  studio\tcode "}));
    try std.testing.expectEqualStrings("nvim", try joinWords(arena, &.{ "", "nvim\t", " " }));
    try std.testing.expectEqualStrings("", try joinWords(arena, &.{ "", " \t" }));
}
