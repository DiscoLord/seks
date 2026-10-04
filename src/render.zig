//! Turns one app into the text that the user reads.
const std = @import("std");
const Io = std.Io;
const data = @import("data.zig");

pub const Style = enum {
    /// Text only. For a pipe or a file.
    plain,
    /// Text with ANSI escape codes for bold. For a terminal.
    ansi,
};

const indent = "  ";
const column_gap = "  ";
const alternative_separator = "OR";

/// The keys column does not grow past this width. A binding with wider keys
/// keeps its own width and does not move the effects of the other bindings.
const max_keys_width = 32;

const bold_on = "\x1b[1m";
const bold_off = "\x1b[0m";

/// Writes `app` to `writer`: the name, the note, then each group as a title
/// with one line per binding. The effects of all bindings start in the same
/// column.
///
/// Does no terminal work, so the same text goes to a pager, a pipe or a
/// test.
pub fn render(writer: *Io.Writer, app: data.App, style: Style) Io.Writer.Error!void {
    try writeBold(writer, app.full_name, style);
    try writer.writeByte('\n');
    if (app.note) |note| try writer.print("{s}\n", .{note});

    const column_width = keysColumnWidth(app);
    for (app.binding_groups) |group| {
        try writer.writeByte('\n');
        try writeBold(writer, group.title, style);
        try writer.writeByte('\n');

        for (group.bindings) |binding| {
            try writer.writeAll(indent);
            for (binding.keys, 0..) |alternative, index| {
                if (index > 0) {
                    try writer.writeByte(' ');
                    try writeBold(writer, alternative_separator, style);
                    try writer.writeByte(' ');
                }
                try writer.writeAll(alternative);
            }
            // Pad by the visible width. The bold codes take bytes but no
            // columns, so the byte count of the written text is wrong here.
            try writer.splatByteAll(' ', column_width -| keysWidth(binding.keys));
            try writer.writeAll(column_gap);
            try writer.print("{s}\n", .{binding.effect});
        }
    }
}

fn writeBold(writer: *Io.Writer, text: []const u8, style: Style) Io.Writer.Error!void {
    switch (style) {
        .plain => try writer.writeAll(text),
        .ansi => try writer.print(bold_on ++ "{s}" ++ bold_off, .{text}),
    }
}

/// Returns the width of the keys column: the widest keys text of `app` that
/// is not over `max_keys_width`.
fn keysColumnWidth(app: data.App) usize {
    var widest: usize = 0;
    for (app.binding_groups) |group| {
        for (group.bindings) |binding| {
            const width = keysWidth(binding.keys);
            if (width <= max_keys_width) widest = @max(widest, width);
        }
    }
    return widest;
}

/// Returns the columns that the alternatives take when written with the
/// separator between them.
fn keysWidth(keys: []const []const u8) usize {
    var width: usize = 0;
    for (keys, 0..) |alternative, index| {
        if (index > 0) width += alternative_separator.len + 2;
        width += textWidth(alternative);
    }
    return width;
}

/// Returns the columns that `text` takes in a terminal.
///
/// Counts code points, so `←` is one column. This is wrong for characters
/// that take two columns, such as CJK text and most emoji.
fn textWidth(text: []const u8) usize {
    return std.unicode.utf8CountCodepoints(text) catch text.len;
}

const testing = std.testing;

const test_app: data.App = .{
    .name = "tmux",
    .full_name = "tmux",
    .note = "Prefix is Ctrl+b by default",
    .binding_groups = &.{
        .{ .id = 1, .title = "Panes", .bindings = &.{
            .{ .id = 1, .keys = &.{"Prefix %"}, .effect = "Split left and right" },
            .{ .id = 2, .keys = &.{ "Prefix x", "Ctrl+d" }, .effect = "Close the pane" },
        } },
        .{ .id = 2, .title = "Windows", .bindings = &.{
            .{ .id = 3, .keys = &.{"Prefix c"}, .effect = "Create a window" },
        } },
    },
};

fn renderToBuffer(buffer: []u8, app: data.App, style: Style) ![]const u8 {
    var writer: Io.Writer = .fixed(buffer);
    try render(&writer, app, style);
    return writer.buffered();
}

/// Returns `text` without ANSI escape codes. A code runs from ESC to `m`.
fn stripCodes(buffer: []u8, text: []const u8) []const u8 {
    var len: usize = 0;
    var in_code = false;
    for (text) |char| {
        if (in_code) {
            if (char == 'm') in_code = false;
        } else if (char == '\x1b') {
            in_code = true;
        } else {
            buffer[len] = char;
            len += 1;
        }
    }
    return buffer[0..len];
}

test "render aligns the effects across all groups" {
    var buffer: [1024]u8 = undefined;
    const expected =
        \\tmux
        \\Prefix is Ctrl+b by default
        \\
        \\Panes
        \\  Prefix %            Split left and right
        \\  Prefix x OR Ctrl+d  Close the pane
        \\
        \\Windows
        \\  Prefix c            Create a window
        \\
    ;
    try testing.expectEqualStrings(expected, try renderToBuffer(&buffer, test_app, .plain));
}

test "render with ansi makes the name, the titles and OR bold" {
    var buffer: [1024]u8 = undefined;
    const text = try renderToBuffer(&buffer, test_app, .ansi);

    try testing.expect(std.mem.startsWith(u8, text, "\x1b[1mtmux\x1b[0m\n"));
    try testing.expect(std.mem.indexOf(u8, text, "\x1b[1mPanes\x1b[0m\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Prefix x \x1b[1mOR\x1b[0m Ctrl+d  Close") != null);
}

test "render with ansi keeps the layout of plain" {
    var plain_buffer: [1024]u8 = undefined;
    var ansi_buffer: [1024]u8 = undefined;
    var stripped_buffer: [1024]u8 = undefined;

    const plain = try renderToBuffer(&plain_buffer, test_app, .plain);
    const ansi = try renderToBuffer(&ansi_buffer, test_app, .ansi);
    try testing.expectEqualStrings(plain, stripCodes(&stripped_buffer, ansi));
}

test "render does not widen the column for keys over the limit" {
    var buffer: [1024]u8 = undefined;
    const app: data.App = .{
        .name = "vim",
        .full_name = "Vim",
        .binding_groups = &.{
            .{ .id = 1, .title = "Edit", .bindings = &.{
                .{ .id = 1, .keys = &.{"u"}, .effect = "Undo" },
                .{ .id = 2, .keys = &.{":%s/old text/new text/gc and more"}, .effect = "Replace" },
            } },
        },
    };
    const expected =
        \\Vim
        \\
        \\Edit
        \\  u  Undo
        \\  :%s/old text/new text/gc and more  Replace
        \\
    ;
    try testing.expectEqualStrings(expected, try renderToBuffer(&buffer, app, .plain));
}

test "render counts a non-ASCII key as one column" {
    var buffer: [1024]u8 = undefined;
    const app: data.App = .{
        .name = "app",
        .full_name = "App",
        .binding_groups = &.{
            .{ .id = 1, .title = "Move", .bindings = &.{
                .{ .id = 1, .keys = &.{"←"}, .effect = "Left" },
                .{ .id = 2, .keys = &.{"gg"}, .effect = "Top" },
            } },
        },
    };
    const expected =
        \\App
        \\
        \\Move
        \\  ←   Left
        \\  gg  Top
        \\
    ;
    try testing.expectEqualStrings(expected, try renderToBuffer(&buffer, app, .plain));
}

test "render writes the name only for an app with no groups" {
    var buffer: [1024]u8 = undefined;
    const app: data.App = .{ .name = "app", .full_name = "App", .binding_groups = &.{} };
    try testing.expectEqualStrings("App\n", try renderToBuffer(&buffer, app, .plain));
}
