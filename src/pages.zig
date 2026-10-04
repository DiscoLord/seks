//! Splits one app into pages of columns for a screen of a given size.
//!
//! Does no terminal work. The pager draws the pages.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const data = @import("data.zig");
const render = @import("render.zig");

/// One line of a column, ready to draw.
pub const Line = struct {
    /// The text. It can hold escape codes.
    text: []const u8 = "",
    /// The columns that `text` takes on screen.
    width: usize = 0,
};

pub const Column = struct {
    lines: []const Line,
    /// The width of its widest line.
    width: usize,
};

pub const Page = struct {
    columns: []const Column,
};

/// The empty columns between two columns of a page.
pub const column_gap = 4;

/// A group note wraps to the width of its group, but never to less than
/// this. A narrow group would turn its note into a tall strip of text.
const min_note_width = 40;

const continued_suffix = " (continued)";

/// One group as lines.
const Block = struct {
    /// The title, then the note lines.
    head: []const Line,
    /// The title with `continued_suffix`. It starts each next part of a
    /// group that is taller than a column.
    continued_head: []const Line,
    bindings: []const Line,
    /// The width of the widest line.
    width: usize,
};

/// Splits `app` into pages for a screen with `width` columns and `height`
/// rows of body text.
///
/// A page holds one or more columns side by side. A column takes whole
/// groups, top to bottom, with one empty line between two groups. A group
/// breaks only when it is taller than `height`. Its next part then starts a
/// new column with the title repeated.
///
/// The first column of a page can be wider than `width`. The caller must
/// cut those lines.
///
/// `arena` owns the result. Nothing is freed one by one.
pub fn layout(
    arena: Allocator,
    app: data.App,
    style: render.Style,
    width: usize,
    height: usize,
) Allocator.Error![]const Page {
    var pages: std.ArrayList(Page) = .empty;
    var columns: std.ArrayList(Column) = .empty;
    var lines: std.ArrayList(Line) = .empty;
    // The width of the closed columns of the current page, gaps included.
    var used_width: usize = 0;

    for (app.binding_groups) |group| {
        const block = try buildBlock(arena, group, style);
        var head = block.head;
        var rest = block.bindings;

        // Each pass places the block, or one part of it, or closes a column
        // or a page to make room.
        while (true) {
            if (lines.items.len > 0) {
                const fits_height = lines.items.len + 1 + head.len + rest.len <= height;
                const column_width = @max(widestLine(lines.items), block.width);
                const fits_width = columns.items.len == 0 or used_width + column_width <= width;
                if (fits_height and fits_width) {
                    try lines.append(arena, .{});
                    try lines.appendSlice(arena, head);
                    try lines.appendSlice(arena, rest);
                    break;
                }
                used_width += try closeColumn(arena, &columns, &lines);
                continue;
            }

            // The column is empty. A column after the first must fit beside
            // the others.
            if (columns.items.len > 0 and used_width + block.width > width) {
                try closePage(arena, &pages, &columns);
                used_width = 0;
                continue;
            }

            if (head.len + rest.len <= height or rest.len == 0) {
                try lines.appendSlice(arena, head);
                try lines.appendSlice(arena, rest);
                break;
            }

            // The group is taller than a column. Place what fits, at least
            // one binding, and continue in the next column.
            //
            // The head must leave a row for that binding. A head as tall as
            // the column would push the binding below the last row, and the
            // pager never draws a row there. Keep the title only, or no
            // head at all on a screen of one row.
            if (head.len >= height) head = if (height >= 2) head[0..1] else &.{};
            const count = @min(rest.len, @max(1, height -| head.len));
            try lines.appendSlice(arena, head);
            try lines.appendSlice(arena, rest[0..count]);
            used_width += try closeColumn(arena, &columns, &lines);

            rest = rest[count..];
            if (rest.len == 0) break;
            // On a screen of one row, a repeated title would leave no room
            // for a binding, and the loop would never end.
            head = if (height >= 2) block.continued_head else &.{};
        }
    }

    if (lines.items.len > 0) _ = try closeColumn(arena, &columns, &lines);
    if (columns.items.len > 0 or pages.items.len == 0) try closePage(arena, &pages, &columns);
    return pages.items;
}

/// Moves `lines` into a new column of `columns`. Returns the width that the
/// column takes on the page, the gap after it included.
fn closeColumn(
    arena: Allocator,
    columns: *std.ArrayList(Column),
    lines: *std.ArrayList(Line),
) Allocator.Error!usize {
    const width = widestLine(lines.items);
    try columns.append(arena, .{ .lines = lines.items, .width = width });
    lines.* = .empty;
    return width + column_gap;
}

/// Moves `columns` into a new page of `pages`.
fn closePage(
    arena: Allocator,
    pages: *std.ArrayList(Page),
    columns: *std.ArrayList(Column),
) Allocator.Error!void {
    try pages.append(arena, .{ .columns = columns.items });
    columns.* = .empty;
}

fn widestLine(lines: []const Line) usize {
    var widest: usize = 0;
    for (lines) |line| widest = @max(widest, line.width);
    return widest;
}

fn buildBlock(arena: Allocator, group: data.BindingGroup, style: render.Style) Allocator.Error!Block {
    const keys_column_width = render.keysColumnWidth(group);

    var width = render.textWidth(group.title);
    const bindings = try arena.alloc(Line, group.bindings.len);
    for (group.bindings, bindings) |binding, *line| {
        var text: Io.Writer.Allocating = .init(arena);
        render.writeBinding(&text.writer, binding, keys_column_width, style) catch return error.OutOfMemory;
        line.* = .{ .text = text.written(), .width = render.bindingWidth(binding, keys_column_width) };
        width = @max(width, line.width);
    }

    var head: std.ArrayList(Line) = .empty;
    try head.append(arena, try styledLine(arena, group.title, .bold, style));
    if (group.note) |note| {
        // The note takes the width of the group, so it does not make the
        // column wider than its bindings need.
        const note_width = @max(width, min_note_width);
        for (try wrap(arena, note, note_width)) |part| {
            const line = try styledLine(arena, part, .italic, style);
            try head.append(arena, line);
            width = @max(width, line.width);
        }
    }

    const continued_title = try std.mem.concat(arena, u8, &.{ group.title, continued_suffix });
    const continued_head = try arena.alloc(Line, 1);
    continued_head[0] = try styledLine(arena, continued_title, .bold, style);

    return .{
        .head = head.items,
        .continued_head = continued_head,
        .bindings = bindings,
        .width = @max(width, continued_head[0].width),
    };
}

fn styledLine(
    arena: Allocator,
    text: []const u8,
    emphasis: render.Emphasis,
    style: render.Style,
) Allocator.Error!Line {
    var styled: Io.Writer.Allocating = .init(arena);
    render.writeStyled(&styled.writer, text, emphasis, style) catch return error.OutOfMemory;
    return .{ .text = styled.written(), .width = render.textWidth(text) };
}

/// Splits `text` into lines of at most `width` columns. Breaks at spaces
/// only, so a word wider than `width` stays whole on a line of its own.
fn wrap(arena: Allocator, text: []const u8, width: usize) Allocator.Error![]const []const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    var line_start: usize = 0;
    var line_end: usize = 0;

    var words = std.mem.tokenizeScalar(u8, text, ' ');
    while (words.next()) |word| {
        const word_start = words.index - word.len;
        const word_end = words.index;
        if (line_end == line_start) {
            // The first word of a line always goes on it.
            line_start = word_start;
        } else if (render.textWidth(text[line_start..word_end]) > width) {
            try lines.append(arena, text[line_start..line_end]);
            line_start = word_start;
        }
        line_end = word_end;
    }
    if (line_end > line_start) try lines.append(arena, text[line_start..line_end]);
    return lines.items;
}

const testing = std.testing;

fn testGroup(comptime id: u32, comptime title: []const u8, comptime count: usize) data.BindingGroup {
    comptime var bindings: [count]data.Binding = undefined;
    inline for (&bindings, 0..) |*binding, index| {
        binding.* = .{
            .id = id * 100 + index,
            .keys = &.{std.fmt.comptimePrint("k{d}", .{index})},
            .effect = std.fmt.comptimePrint("{s} effect {d}", .{ title, index }),
        };
    }
    const final = bindings;
    return .{ .id = id, .title = title, .bindings = &final };
}

const two_groups: data.App = .{
    .name = "app",
    .full_name = "App",
    .binding_groups = &.{ testGroup(1, "One", 3), testGroup(2, "Two", 2) },
};

fn expectLines(expected: []const []const u8, column: Column) !void {
    try testing.expectEqual(expected.len, column.lines.len);
    for (expected, column.lines) |text, line| {
        try testing.expectEqualStrings(text, line.text);
        try testing.expectEqual(render.textWidth(text), line.width);
    }
}

test "layout puts groups under each other when they fit" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    const result = try layout(arena_state.allocator(), two_groups, .plain, 80, 20);
    try testing.expectEqual(1, result.len);
    try testing.expectEqual(1, result[0].columns.len);
    try expectLines(&.{
        "One",
        "  k0     One effect 0",
        "  k1     One effect 1",
        "  k2     One effect 2",
        "",
        "Two",
        "  k0     Two effect 0",
        "  k1     Two effect 1",
    }, result[0].columns[0]);
    try testing.expectEqual("  k0     One effect 0".len, result[0].columns[0].width);
}

test "layout starts a new column for a group that does not fit below" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    // Group One takes 4 rows. Group Two needs 1 + 3 more, and 5 are free.
    const result = try layout(arena_state.allocator(), two_groups, .plain, 80, 5);
    try testing.expectEqual(1, result.len);
    try testing.expectEqual(2, result[0].columns.len);
    try expectLines(&.{ "One", "  k0     One effect 0", "  k1     One effect 1", "  k2     One effect 2" }, result[0].columns[0]);
    try expectLines(&.{ "Two", "  k0     Two effect 0", "  k1     Two effect 1" }, result[0].columns[1]);
}

test "layout starts a new page when the next column does not fit beside" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    // A column is 21 wide. Two columns and the gap need 46.
    const narrow = try layout(arena_state.allocator(), two_groups, .plain, 45, 5);
    try testing.expectEqual(2, narrow.len);
    try testing.expectEqual(1, narrow[0].columns.len);
    try testing.expectEqual(1, narrow[1].columns.len);
    try testing.expectEqualStrings("Two", narrow[1].columns[0].lines[0].text);

    const wide = try layout(arena_state.allocator(), two_groups, .plain, 46, 5);
    try testing.expectEqual(1, wide.len);
    try testing.expectEqual(2, wide[0].columns.len);
}

test "layout splits a group that is taller than a column and repeats its title" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    const app: data.App = .{
        .name = "app",
        .full_name = "App",
        .binding_groups = &.{testGroup(1, "Long", 5)},
    };
    const result = try layout(arena_state.allocator(), app, .plain, 200, 4);
    try testing.expectEqual(1, result.len);
    try testing.expectEqual(2, result[0].columns.len);
    try expectLines(&.{
        "Long",
        "  k0     Long effect 0",
        "  k1     Long effect 1",
        "  k2     Long effect 2",
    }, result[0].columns[0]);
    try expectLines(&.{
        "Long (continued)",
        "  k3     Long effect 3",
        "  k4     Long effect 4",
    }, result[0].columns[1]);
}

test "layout places every binding once, on a screen of any size" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const app: data.App = .{
        .name = "app",
        .full_name = "App",
        .binding_groups = &.{ testGroup(1, "One", 7), testGroup(2, "Two", 1), testGroup(3, "Three", 12) },
    };
    const sizes = [_][2]usize{ .{ 200, 50 }, .{ 80, 24 }, .{ 40, 10 }, .{ 20, 3 }, .{ 1, 1 }, .{ 0, 0 } };
    for (sizes) |size| {
        const result = try layout(arena, app, .plain, size[0], size[1]);
        var bindings: usize = 0;
        for (result) |page| {
            for (page.columns) |column| {
                for (column.lines) |line| {
                    if (std.mem.startsWith(u8, line.text, "  k")) bindings += 1;
                }
            }
        }
        try testing.expectEqual(20, bindings);
    }
}

test "layout keeps every column inside the height, so the pager draws every binding" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The note wraps to two lines, so the head of this group is three lines.
    var with_note = testGroup(1, "One", 7);
    with_note.note = "Press the prefix key, release it, then press the next key of the binding.";
    const app: data.App = .{
        .name = "app",
        .full_name = "App",
        .binding_groups = &.{ with_note, testGroup(2, "Two", 1), testGroup(3, "Three", 12) },
    };

    // A height of 3 or less leaves no room for a binding under the full
    // head. The head must then shrink, not push the binding out of sight.
    for (1..9) |height| {
        const result = try layout(arena, app, .plain, 80, height);
        var bindings: usize = 0;
        for (result) |page| {
            for (page.columns) |column| {
                try testing.expect(column.lines.len <= height);
                for (column.lines) |line| {
                    if (std.mem.startsWith(u8, line.text, "  k")) bindings += 1;
                }
            }
        }
        try testing.expectEqual(20, bindings);
    }
}

test "layout wraps a group note to the width of the group" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    const app: data.App = .{
        .name = "app",
        .full_name = "App",
        .binding_groups = &.{.{
            .id = 1,
            .title = "Movement",
            .note = "Prefix most motions with a count, for example 5 j moves down five lines.",
            .bindings = &.{.{ .id = 1, .keys = &.{"j"}, .effect = "Move down" }},
        }},
    };
    const result = try layout(arena_state.allocator(), app, .plain, 200, 20);
    try expectLines(&.{
        "Movement",
        "Prefix most motions with a count, for",
        "example 5 j moves down five lines.",
        "  j     Move down",
    }, result[0].columns[0]);
}

test "layout with ansi keeps the widths of plain" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const plain = try layout(arena, two_groups, .plain, 80, 20);
    const ansi = try layout(arena, two_groups, .ansi, 80, 20);
    try testing.expectEqualStrings("\x1b[1mOne\x1b[0m", ansi[0].columns[0].lines[0].text);
    for (plain[0].columns[0].lines, ansi[0].columns[0].lines) |plain_line, ansi_line| {
        try testing.expectEqual(plain_line.width, ansi_line.width);
    }
}

test "layout gives one empty page for an app with no groups" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    const app: data.App = .{ .name = "app", .full_name = "App", .binding_groups = &.{} };
    const result = try layout(arena_state.allocator(), app, .plain, 80, 20);
    try testing.expectEqual(1, result.len);
    try testing.expectEqual(0, result[0].columns.len);
}

test "wrap breaks at spaces and keeps a long word whole" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const lines = try wrap(arena, "one two three four", 9);
    try testing.expectEqual(3, lines.len);
    try testing.expectEqualStrings("one two", lines[0]);
    try testing.expectEqualStrings("three", lines[1]);
    try testing.expectEqualStrings("four", lines[2]);

    const long_word = try wrap(arena, "a verylongword b", 4);
    try testing.expectEqual(3, long_word.len);
    try testing.expectEqualStrings("verylongword", long_word[1]);

    try testing.expectEqual(0, (try wrap(arena, "", 10)).len);
}
