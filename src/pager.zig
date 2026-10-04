//! Shows an app as pages on the terminal and reads the keys that turn them.
const std = @import("std");
const Io = std.Io;
const posix = std.posix;

const data = @import("data.zig");
const pages = @import("pages.zig");
const render = @import("render.zig");

/// The size of the terminal, in character cells.
const Size = struct {
    columns: usize,
    rows: usize,

    const fallback: Size = .{ .columns = 80, .rows = 24 };
};

const Command = enum { next, back, first, last, quit };

// Switch to the alternate screen, hide the cursor, and stop the terminal
// from wrapping a long line. A line that is too wide is then cut, and it
// cannot push the rows below it down.
const enter_screen = "\x1b[?1049h\x1b[?25l\x1b[?7l";
const leave_screen = "\x1b[?7h\x1b[?25h\x1b[?1049l";
const clear_to_line_end = "\x1b[K";

// The empty columns on the left and on the right of every row, so the text
// does not touch the side of the screen.
const margin = "  ";

const help_many_pages = "Space next   b back   q quit";
const help_one_page = "q quit";

// How long to wait for a key before the size of the terminal is read again.
const resize_poll_ms = 200;

/// Shows `app` page by page and returns when the user quits.
///
/// Takes over the terminal: stdin gives single keys, stdout shows the
/// alternate screen. Both are restored on every way out, also on an error.
/// Never exits the process, so the restore always runs.
pub fn show(io: Io, app: data.App, style: render.Style) !void {
    const stdin = Io.File.stdin();

    const original = try posix.tcgetattr(stdin.handle);
    var raw = original;
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.lflag.IEXTEN = false;
    // With ISIG off, Ctrl+C arrives as a byte and quits like `q`. No signal
    // can then end the process while the terminal is in raw mode.
    raw.lflag.ISIG = false;
    raw.iflag.IXON = false;
    raw.iflag.ICRNL = false;
    raw.cc[@backingInt(posix.V.MIN)] = 1;
    raw.cc[@backingInt(posix.V.TIME)] = 0;
    // Never `.FLUSH`: it throws away the keys that are typed but not read.
    // A key pressed right after Enter must still turn the page, and keys
    // typed after `q` belong to the shell.
    try posix.tcsetattr(stdin.handle, .NOW, raw);
    defer posix.tcsetattr(stdin.handle, .DRAIN, original) catch {};

    var buffer: [16 * 1024]u8 = undefined;
    var file_writer = Io.File.stdout().writerStreaming(io, &buffer);
    const writer = &file_writer.interface;

    try writer.writeAll(enter_screen);
    defer {
        writer.writeAll(leave_screen) catch {};
        writer.flush() catch {};
    }

    // Each new layout replaces the one before it, so its memory is reset.
    var layout_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer layout_arena.deinit();

    var size = terminalSize(io);
    var layout = try pages.layout(layout_arena.allocator(), app, style, bodyWidth(size), bodyHeight(app, size));
    var page_index: usize = 0;
    var needs_draw = true;

    while (true) {
        if (needs_draw) {
            try draw(writer, app, layout, page_index, size, style);
            try writer.flush();
            needs_draw = false;
        }

        var key_buffer: [64]u8 = undefined;
        var keys = try readKeys(stdin.handle, &key_buffer) orelse {
            // No key. Lay the pages out again when the terminal has a new
            // size.
            const new_size = terminalSize(io);
            if (new_size.columns == size.columns and new_size.rows == size.rows) continue;
            size = new_size;
            _ = layout_arena.reset(.retain_capacity);
            layout = try pages.layout(layout_arena.allocator(), app, style, bodyWidth(size), bodyHeight(app, size));
            page_index = @min(page_index, layout.len - 1);
            needs_draw = true;
            continue;
        };

        // Stdin is closed. Nothing can turn the pages now.
        if (keys.len == 0) return;

        // One read can hold several keys, for example when a key repeats.
        while (keys.len > 0) {
            const key = keys[0..keyLength(keys)];
            keys = keys[key.len..];
            switch (parseKey(key) orelse continue) {
                .next => page_index = @min(page_index + 1, layout.len - 1),
                .back => page_index -|= 1,
                .first => page_index = 0,
                .last => page_index = layout.len - 1,
                .quit => return,
            }
            needs_draw = true;
        }
    }
}

/// Returns the rows of the header: the name, the note when there is one,
/// and one empty row.
fn headerHeight(app: data.App) usize {
    return if (app.note == null) 2 else 3;
}

/// Returns the rows left for the columns: all rows without the header, one
/// empty row and the help row.
fn bodyHeight(app: data.App, size: Size) usize {
    return @max(1, size.rows -| (headerHeight(app) + 2));
}

/// Returns the columns left for the text: all columns without the two
/// margins.
fn bodyWidth(size: Size) usize {
    return size.columns -| 2 * margin.len;
}

fn terminalSize(io: Io) Size {
    var winsize: posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
    const result = io.operate(.{ .device_io_control = .{
        .file = Io.File.stdout(),
        .code = posix.T.IOCGWINSZ,
        .arg = &winsize,
    } }) catch return .fallback;
    if (result.device_io_control < 0 or winsize.col == 0 or winsize.row == 0) return .fallback;
    return .{ .columns = winsize.col, .rows = winsize.row };
}

/// Draws one page. Writes every row of the screen, so no text of the page
/// before stays visible.
fn draw(
    writer: *Io.Writer,
    app: data.App,
    layout: []const pages.Page,
    page_index: usize,
    size: Size,
    style: render.Style,
) Io.Writer.Error!void {
    var row: usize = 1;

    // The name on the left, the page number on the right.
    try moveTo(writer, row);
    try render.writeStyled(writer, app.full_name, .bold, style);
    var counter_buffer: [32]u8 = undefined;
    const counter = std.fmt.bufPrint(&counter_buffer, "page {d}/{d}", .{ page_index + 1, layout.len }) catch "";
    const name_width = render.textWidth(app.full_name);
    if (name_width + 2 + counter.len <= bodyWidth(size)) {
        try writer.splatByteAll(' ', bodyWidth(size) - name_width - counter.len);
        try writer.writeAll(counter);
    }
    row += 1;

    if (app.note) |note| {
        try moveTo(writer, row);
        try render.writeStyled(writer, note, .italic, style);
        row += 1;
    }

    try moveTo(writer, row);
    row += 1;

    const columns = layout[page_index].columns;
    const body_height = bodyHeight(app, size);
    for (0..body_height) |line_index| {
        try moveTo(writer, row);
        for (columns, 0..) |column, column_index| {
            const line: pages.Line = if (line_index < column.lines.len) column.lines[line_index] else .{};
            try writer.writeAll(line.text);
            // The last column needs no padding. The row is already clear.
            if (column_index + 1 < columns.len) {
                try writer.splatByteAll(' ', column.width - line.width + pages.column_gap);
            }
        }
        row += 1;
    }

    // Clear the rows between the body and the help row.
    while (row < size.rows) : (row += 1) {
        try moveTo(writer, row);
    }

    try moveTo(writer, size.rows);
    try writer.writeAll(if (layout.len > 1) help_many_pages else help_one_page);
}

/// Clears `row` and moves the cursor to its first column after the left
/// margin. Rows start at 1.
///
/// The clear must come before the text, not after. With line wrap off, the
/// cursor stays on the last column after a character is written there, and
/// a clear from the cursor would erase that character.
fn moveTo(writer: *Io.Writer, row: usize) Io.Writer.Error!void {
    try writer.print("\x1b[{d};1H" ++ clear_to_line_end ++ margin, .{row});
}

/// Waits for keys for at most `resize_poll_ms`. Returns the bytes that came,
/// or null when none came. An empty result means that stdin is closed.
fn readKeys(stdin: posix.fd_t, buffer: []u8) !?[]const u8 {
    var fds = [_]posix.pollfd{.{ .fd = stdin, .events = posix.POLL.IN, .revents = 0 }};
    if (try posix.poll(&fds, resize_poll_ms) == 0) return null;
    return buffer[0..try posix.read(stdin, buffer)];
}

const escape = '\x1b';

/// Returns the length of the first key press in `bytes`. `bytes` must not
/// be empty.
///
/// An arrow or a navigation key is ESC, then `[` or `O`, then bytes up to
/// the first one from `@` to `~`. Every other key is one byte.
fn keyLength(bytes: []const u8) usize {
    const is_sequence = bytes.len >= 3 and bytes[0] == escape and (bytes[1] == '[' or bytes[1] == 'O');
    if (!is_sequence) return 1;
    for (bytes[2..], 2..) |byte, index| {
        if (byte >= '@' and byte <= '~') return index + 1;
    }
    return bytes.len;
}

/// Returns the command for the bytes of one key press, or null when the key
/// has none.
fn parseKey(bytes: []const u8) ?Command {
    const ctrl_c = '\x03';
    const ctrl_d = '\x04';
    const backspace = '\x7f';

    if (bytes.len == 1) {
        return switch (bytes[0]) {
            ' ', 'n', 'j', 'l', 'f', '\r', '\n' => .next,
            'b', 'p', 'k', 'h', backspace => .back,
            'g' => .first,
            'G' => .last,
            'q', escape, ctrl_c, ctrl_d => .quit,
            else => null,
        };
    }

    // An arrow or a navigation key: ESC, then `[` or `O`, then the key.
    if (bytes.len >= 3 and bytes[0] == escape and (bytes[1] == '[' or bytes[1] == 'O')) {
        const sequence = bytes[2..];
        const next = [_][]const u8{ "C", "B", "6~" };
        const back = [_][]const u8{ "D", "A", "5~" };
        const first = [_][]const u8{ "H", "1~" };
        const last = [_][]const u8{ "F", "4~" };
        for (next) |key| if (std.mem.eql(u8, sequence, key)) return .next;
        for (back) |key| if (std.mem.eql(u8, sequence, key)) return .back;
        for (first) |key| if (std.mem.eql(u8, sequence, key)) return .first;
        for (last) |key| if (std.mem.eql(u8, sequence, key)) return .last;
    }
    return null;
}

const testing = std.testing;

test "parseKey maps the single keys" {
    try testing.expectEqual(.next, parseKey(" ").?);
    try testing.expectEqual(.next, parseKey("j").?);
    try testing.expectEqual(.next, parseKey("\r").?);
    try testing.expectEqual(.back, parseKey("b").?);
    try testing.expectEqual(.back, parseKey("k").?);
    try testing.expectEqual(.first, parseKey("g").?);
    try testing.expectEqual(.last, parseKey("G").?);
    try testing.expectEqual(.quit, parseKey("q").?);
    try testing.expectEqual(.quit, parseKey("\x1b").?);
    try testing.expectEqual(.quit, parseKey("\x03").?);
    try testing.expectEqual(.quit, parseKey("\x04").?);
    try testing.expectEqual(null, parseKey("x"));
}

test "parseKey maps the arrows and the page keys" {
    try testing.expectEqual(.next, parseKey("\x1b[C").?);
    try testing.expectEqual(.next, parseKey("\x1b[B").?);
    try testing.expectEqual(.next, parseKey("\x1bOC").?);
    try testing.expectEqual(.next, parseKey("\x1b[6~").?);
    try testing.expectEqual(.back, parseKey("\x1b[D").?);
    try testing.expectEqual(.back, parseKey("\x1b[A").?);
    try testing.expectEqual(.back, parseKey("\x1b[5~").?);
    try testing.expectEqual(.first, parseKey("\x1b[H").?);
    try testing.expectEqual(.last, parseKey("\x1b[F").?);
    try testing.expectEqual(null, parseKey("\x1b[Z"));
}

test "keyLength splits a read that holds several keys" {
    try testing.expectEqual(1, keyLength(" q"));
    try testing.expectEqual(3, keyLength("\x1b[C\x1b[C"));
    try testing.expectEqual(4, keyLength("\x1b[6~q"));
    try testing.expectEqual(1, keyLength("\x1b"));
    try testing.expectEqual(1, keyLength("\x1bq"));
}

test "bodyHeight leaves room for the header and the help row" {
    const with_note: data.App = .{ .name = "a", .full_name = "A", .note = "Note", .binding_groups = &.{} };
    const no_note: data.App = .{ .name = "a", .full_name = "A", .binding_groups = &.{} };

    try testing.expectEqual(19, bodyHeight(with_note, .{ .columns = 80, .rows = 24 }));
    try testing.expectEqual(20, bodyHeight(no_note, .{ .columns = 80, .rows = 24 }));
    try testing.expectEqual(1, bodyHeight(with_note, .{ .columns = 80, .rows = 2 }));
}

test "draw composes the columns of a page side by side" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    const app: data.App = .{
        .name = "app",
        .full_name = "App",
        .binding_groups = &.{
            .{ .id = 1, .title = "One", .bindings = &.{
                .{ .id = 1, .keys = &.{"a"}, .effect = "First" },
                .{ .id = 2, .keys = &.{"b"}, .effect = "Second" },
            } },
            .{ .id = 2, .title = "Two", .bindings = &.{
                .{ .id = 3, .keys = &.{"c"}, .effect = "Third" },
                .{ .id = 4, .keys = &.{"d"}, .effect = "Fourth" },
            } },
        },
    };
    const size: Size = .{ .columns = 40, .rows = 7 };
    const layout = try pages.layout(arena_state.allocator(), app, .plain, bodyWidth(size), bodyHeight(app, size));

    var buffer: [1024]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);
    try draw(&writer, app, layout, 0, size, .plain);

    // Every row starts after a margin of 2. The name is padded so that the
    // page number ends at column 38, a margin of 2 before the right side.
    const expected = std.fmt.comptimePrint("\x1b[1;1H\x1b[K  {s: <28}page 1/1", .{"App"}) ++
        "\x1b[2;1H\x1b[K  " ++
        // The first column is 14 wide, then a gap of 4.
        "\x1b[3;1H\x1b[K  One               Two" ++
        "\x1b[4;1H\x1b[K    a     First       c     Third" ++
        "\x1b[5;1H\x1b[K    b     Second      d     Fourth" ++
        "\x1b[6;1H\x1b[K  " ++
        "\x1b[7;1H\x1b[K  q quit";
    try testing.expectEqualStrings(expected, writer.buffered());
}
