//! Turns one app into the text that the user reads.
const std = @import("std");
const Io = std.Io;
const data = @import("data.zig");

pub const Style = enum {
    /// Text only. For a pipe or a file.
    plain,
    /// Text with ANSI escape codes for bold, italic and dim. For a terminal.
    ansi,
};

pub const Emphasis = enum {
    bold,
    dim,
    italic,

    fn code(emphasis: Emphasis) []const u8 {
        return switch (emphasis) {
            .bold => "\x1b[1m",
            .dim => "\x1b[2m",
            .italic => "\x1b[3m",
        };
    }
};

const emphasis_off = "\x1b[0m";

const indent = "  ";
const alternative_separator = "OR";

/// The leader is the run of dots that leads the eye from the keys to the
/// effect. It has one space on each side. The widest keys of a group get a
/// leader of this many dots, and narrower keys get more.
const min_leader_dots = 3;
const leader_dot = "·";

/// The keys column does not grow past this width. A binding with wider keys
/// keeps its own width and does not move the effects of the other bindings.
const max_keys_width = 32;

/// Writes `app` to `writer` as one long column: the name, the note, then
/// each group as a title, its note and one line per binding. In a group, the
/// effects of all bindings start in the same column.
///
/// Does no terminal work, so the same text goes to a pipe, a file or a test.
pub fn render(writer: *Io.Writer, app: data.App, style: Style) Io.Writer.Error!void {
    try writeStyled(writer, app.full_name, .bold, style);
    try writer.writeByte('\n');
    if (app.note) |note| {
        try writeStyled(writer, note, .italic, style);
        try writer.writeByte('\n');
    }

    for (app.binding_groups) |group| {
        try writer.writeByte('\n');
        try writeStyled(writer, group.title, .bold, style);
        try writer.writeByte('\n');
        if (group.note) |note| {
            try writeStyled(writer, note, .italic, style);
            try writer.writeByte('\n');
        }

        const keys_column_width = keysColumnWidth(group);
        for (group.bindings) |binding| {
            try writeBinding(writer, binding, keys_column_width, style);
            try writer.writeByte('\n');
        }
    }
}

/// Writes `text` with `emphasis`. With `.plain`, writes the text only.
pub fn writeStyled(
    writer: *Io.Writer,
    text: []const u8,
    emphasis: Emphasis,
    style: Style,
) Io.Writer.Error!void {
    switch (style) {
        .plain => try writer.writeAll(text),
        .ansi => try writer.print("{s}{s}" ++ emphasis_off, .{ emphasis.code(), text }),
    }
}

/// Writes one binding with no line end: the keys, a leader that ends at the
/// same column for all bindings of the group, then the effect.
///
/// With `.ansi` the leader is dim dots. With `.plain` it is spaces of the
/// same width, so a pipe gets no dots and the layout is the same.
pub fn writeBinding(
    writer: *Io.Writer,
    binding: data.Binding,
    keys_column_width: usize,
    style: Style,
) Io.Writer.Error!void {
    try writeBindingStart(writer, binding, keys_column_width, style);
    try writer.writeAll(binding.effect);
}

/// Returns the columns that `writeBinding` takes for `binding`.
pub fn bindingWidth(binding: data.Binding, keys_column_width: usize) usize {
    return bindingStartWidth(binding, keys_column_width) + textWidth(binding.effect);
}

/// Writes the part of a binding before its effect: the indent, the keys and
/// the leader.
pub fn writeBindingStart(
    writer: *Io.Writer,
    binding: data.Binding,
    keys_column_width: usize,
    style: Style,
) Io.Writer.Error!void {
    try writeBindingKeys(writer, binding, style);
    // Size the leader by the visible width of the keys. The escape codes
    // take bytes but no columns, so the byte count of the written text is
    // wrong here.
    const dots = min_leader_dots + (keys_column_width -| keysWidth(binding.keys));
    try writer.writeByte(' ');
    switch (style) {
        .plain => try writer.splatByteAll(' ', dots),
        .ansi => {
            try writer.writeAll(Emphasis.dim.code());
            for (0..dots) |_| try writer.writeAll(leader_dot);
            try writer.writeAll(emphasis_off);
        },
    }
    try writer.writeByte(' ');
}

/// Returns the columns that `writeBindingStart` takes. The effect starts in
/// the column after it.
pub fn bindingStartWidth(binding: data.Binding, keys_column_width: usize) usize {
    return indent.len + @max(keys_column_width, keysWidth(binding.keys)) + 1 + min_leader_dots + 1;
}

/// Writes the indent and the keys of a binding, with no leader.
pub fn writeBindingKeys(writer: *Io.Writer, binding: data.Binding, style: Style) Io.Writer.Error!void {
    try writer.writeAll(indent);
    for (binding.keys, 0..) |alternative, index| {
        if (index > 0) {
            try writer.writeByte(' ');
            try writeStyled(writer, alternative_separator, .bold, style);
            try writer.writeByte(' ');
        }
        var pieces: DrawnPieces = .{ .text = alternative };
        while (pieces.next()) |piece| try writer.writeAll(piece);
    }
}

/// Returns the columns that `writeBindingKeys` takes.
pub fn bindingKeysWidth(binding: data.Binding) usize {
    return indent.len + keysWidth(binding.keys);
}

/// Returns the width of the keys column of `group`: its widest keys text
/// that is not over `max_keys_width`.
pub fn keysColumnWidth(group: data.BindingGroup) usize {
    var widest: usize = 0;
    for (group.bindings) |binding| {
        const width = keysWidth(binding.keys);
        if (width <= max_keys_width) widest = @max(widest, width);
    }
    return widest;
}

/// Returns the columns that the alternatives take when written with the
/// separator between them.
fn keysWidth(keys: []const []const u8) usize {
    var width: usize = 0;
    for (keys, 0..) |alternative, index| {
        if (index > 0) width += alternative_separator.len + 2;
        var pieces: DrawnPieces = .{ .text = alternative };
        while (pieces.next()) |piece| width += textWidth(piece);
    }
    return width;
}

/// Walks one alternative and returns the pieces to draw, in order.
///
/// A piece is a key, or one of the two delimiters: a space or a `+`. The
/// key `Plus` comes out as `+`, so `Cmd+Plus` is drawn as `Cmd++`. Every
/// other piece comes out as written.
const DrawnPieces = struct {
    text: []const u8,
    index: usize = 0,

    fn next(pieces: *DrawnPieces) ?[]const u8 {
        if (pieces.index == pieces.text.len) return null;
        const rest = pieces.text[pieces.index..];

        if (rest[0] == ' ' or rest[0] == '+') {
            pieces.index += 1;
            return rest[0..1];
        }

        const end = std.mem.indexOfAny(u8, rest, " +") orelse rest.len;
        pieces.index += end;
        const key = rest[0..end];
        return if (std.mem.eql(u8, key, data.plus_key)) "+" else key;
    }
};

/// Returns the columns that `text` takes in a terminal.
///
/// Counts code points, so `←` is one column. This is wrong for characters
/// that take two columns, such as CJK text and most emoji.
pub fn textWidth(text: []const u8) usize {
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

test "render aligns the effects inside each group" {
    var buffer: [1024]u8 = undefined;
    const expected =
        \\tmux
        \\Prefix is Ctrl+b by default
        \\
        \\Panes
        \\  Prefix %               Split left and right
        \\  Prefix x OR Ctrl+d     Close the pane
        \\
        \\Windows
        \\  Prefix c     Create a window
        \\
    ;
    try testing.expectEqualStrings(expected, try renderToBuffer(&buffer, test_app, .plain));
}

test "render with ansi draws the leader as dim dots, longer for narrower keys" {
    var buffer: [1024]u8 = undefined;
    const text = try renderToBuffer(&buffer, test_app, .ansi);

    try testing.expect(std.mem.indexOf(u8, text, "Ctrl+d \x1b[2m···\x1b[0m Close the pane\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Prefix % \x1b[2m·············\x1b[0m Split left") != null);
}

test "render with ansi makes the name, the titles and OR bold" {
    var buffer: [1024]u8 = undefined;
    const text = try renderToBuffer(&buffer, test_app, .ansi);

    try testing.expect(std.mem.startsWith(u8, text, "\x1b[1mtmux\x1b[0m\n"));
    try testing.expect(std.mem.indexOf(u8, text, "\x1b[1mPanes\x1b[0m\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Prefix x \x1b[1mOR\x1b[0m Ctrl+d ") != null);
}

test "render with ansi makes the notes italic" {
    var buffer: [1024]u8 = undefined;
    const app: data.App = .{
        .name = "tmux",
        .full_name = "tmux",
        .note = "App note",
        .binding_groups = &.{
            .{ .id = 1, .title = "Copy mode", .note = "Group note", .bindings = &.{} },
        },
    };
    const text = try renderToBuffer(&buffer, app, .ansi);

    try testing.expect(std.mem.indexOf(u8, text, "\x1b[3mApp note\x1b[0m\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\x1b[3mGroup note\x1b[0m\n") != null);
}

test "bindingWidth equals the width of the written binding" {
    var buffer: [1024]u8 = undefined;
    const bindings = [_]data.Binding{
        .{ .id = 1, .keys = &.{"u"}, .effect = "Undo" },
        .{ .id = 2, .keys = &.{ "Plus", "Ctrl+w Plus" }, .effect = "Grow" },
        .{ .id = 3, .keys = &.{":%s/old text/new text/gc and more"}, .effect = "Replace" },
    };
    for (bindings) |binding| {
        var writer: Io.Writer = .fixed(&buffer);
        try writeBinding(&writer, binding, 13, .plain);
        try testing.expectEqual(textWidth(writer.buffered()), bindingWidth(binding, 13));
    }
}

test "render with ansi keeps the layout of plain" {
    var plain_buffer: [1024]u8 = undefined;
    var ansi_buffer: [1024]u8 = undefined;
    var stripped_buffer: [1024]u8 = undefined;

    const plain = try renderToBuffer(&plain_buffer, test_app, .plain);
    const ansi = try renderToBuffer(&ansi_buffer, test_app, .ansi);
    const stripped = stripCodes(&stripped_buffer, ansi);

    // Without the codes, the two differ only in the leader: a dot in `ansi`
    // is a space in `plain`.
    var spaced_buffer: [1024]u8 = undefined;
    const dots = std.mem.replace(u8, stripped, leader_dot, " ", &spaced_buffer);
    const spaced = spaced_buffer[0 .. stripped.len - dots * (leader_dot.len - 1)];
    try testing.expect(dots > 0);
    try testing.expectEqualStrings(plain, spaced);
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
        \\  u     Undo
        \\  :%s/old text/new text/gc and more     Replace
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
        \\  ←      Left
        \\  gg     Top
        \\
    ;
    try testing.expectEqualStrings(expected, try renderToBuffer(&buffer, app, .plain));
}

test "render draws the Plus key as + and aligns by the drawn width" {
    var buffer: [1024]u8 = undefined;
    const app: data.App = .{
        .name = "app",
        .full_name = "App",
        .binding_groups = &.{
            .{ .id = 1, .title = "Zoom", .bindings = &.{
                .{ .id = 1, .keys = &.{"Cmd+Plus"}, .effect = "Zoom in" },
                .{ .id = 2, .keys = &.{"Cmd+Minus"}, .effect = "Zoom out" },
                .{ .id = 3, .keys = &.{ "Plus", "Ctrl+w Plus" }, .effect = "Grow" },
                .{ .id = 4, .keys = &.{":Plus"}, .effect = "Not the key name" },
                .{ .id = 5, .keys = &.{"\"+p"}, .effect = "A literal plus" },
            } },
        },
    };
    const expected =
        \\App
        \\
        \\Zoom
        \\  Cmd++             Zoom in
        \\  Cmd+Minus         Zoom out
        \\  + OR Ctrl+w +     Grow
        \\  :Plus             Not the key name
        \\  "+p               A literal plus
        \\
    ;
    try testing.expectEqualStrings(expected, try renderToBuffer(&buffer, app, .plain));
}

test "render writes the note of a group under its title" {
    var buffer: [1024]u8 = undefined;
    const app: data.App = .{
        .name = "tmux",
        .full_name = "tmux",
        .binding_groups = &.{
            .{ .id = 1, .title = "Copy mode", .note = "Enter with Prefix [", .bindings = &.{
                .{ .id = 1, .keys = &.{"Space"}, .effect = "Start the selection" },
            } },
            .{ .id = 2, .title = "Windows", .bindings = &.{
                .{ .id = 2, .keys = &.{"Prefix c"}, .effect = "Create a window" },
            } },
        },
    };
    const expected =
        \\tmux
        \\
        \\Copy mode
        \\Enter with Prefix [
        \\  Space     Start the selection
        \\
        \\Windows
        \\  Prefix c     Create a window
        \\
    ;
    try testing.expectEqualStrings(expected, try renderToBuffer(&buffer, app, .plain));
}

test "render writes the name only for an app with no groups" {
    var buffer: [1024]u8 = undefined;
    const app: data.App = .{ .name = "app", .full_name = "App", .binding_groups = &.{} };
    try testing.expectEqualStrings("App\n", try renderToBuffer(&buffer, app, .plain));
}
