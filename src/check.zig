//! Checks the rules of the binding data that the parser cannot check.
//!
//! The build runs the check on every data file, so a broken file stops
//! `zig build`. No part of it is in the binary.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const data = @import("data.zig");
const Platform = data.Platform;

/// Where `validate` found a problem. Filled only when `validate` fails.
pub const Problem = struct {
    /// The name of the app. It is also the file name without `.json`.
    app: []const u8 = "",
    group_id: ?u32 = null,
    binding_id: ?u32 = null,
    /// The text that broke the rule, when the rule is about one text.
    text: ?[]const u8 = null,

    /// Writes the place and the text, for example
    /// `, group 2, binding 9: "Cmd+Return"`. Writes nothing for a problem of
    /// the app itself with no text.
    pub fn format(problem: Problem, writer: *Io.Writer) Io.Writer.Error!void {
        if (problem.group_id) |id| try writer.print(", group {d}", .{id});
        if (problem.binding_id) |id| try writer.print(", binding {d}", .{id});
        // The text can hold the control characters that the check found.
        // Escape it, so they do not reach the terminal.
        if (problem.text) |text| try writer.print(": \"{f}\"", .{std.zig.fmtString(text)});
    }
};

pub const Error = error{
    InvalidName,
    DuplicateName,
    DuplicateGroupId,
    DuplicateBindingId,
    DuplicateTitle,
    DuplicateNote,
    EmptyField,
    InvalidText,
    InvalidKeys,
} || Allocator.Error;

/// Other spellings of the keys in `data.key_names`. The check rejects them
/// and so keeps one spelling per key.
const KeyAlias = struct { alias: []const u8, name: []const u8 };
const key_aliases = [_]KeyAlias{
    .{ .alias = "Return", .name = "Enter" },
    .{ .alias = "Escape", .name = "Esc" },
    .{ .alias = "Spacebar", .name = "Space" },
    .{ .alias = "Bksp", .name = "Backspace" },
    .{ .alias = "Del", .name = "Delete" },
    .{ .alias = "Ins", .name = "Insert" },
    .{ .alias = "PgUp", .name = "PageUp" },
    .{ .alias = "PgDn", .name = "PageDown" },
    .{ .alias = "PgDown", .name = "PageDown" },
    .{ .alias = "ArrowUp", .name = "Up" },
    .{ .alias = "ArrowDown", .name = "Down" },
    .{ .alias = "ArrowLeft", .name = "Left" },
    .{ .alias = "ArrowRight", .name = "Right" },
    .{ .alias = "↑", .name = "Up" },
    .{ .alias = "↓", .name = "Down" },
    .{ .alias = "←", .name = "Left" },
    .{ .alias = "→", .name = "Right" },
    // The first half of a name written as two words, such as `Page Up` or
    // `Left Arrow`.
    .{ .alias = "Page", .name = "PageUp" },
    .{ .alias = "Arrow", .name = "Up" },
};

/// Words that people write for a modifier, on any platform. A step that
/// starts with one of them and a `+` is a key combination, so a wrong word
/// such as `command+n` is found and not taken for literal text.
const modifier_words = [_][]const u8{
    "Cmd",   "Command", "Opt",   "Option", "Alt",     "Ctrl", "Control",
    "Shift", "Fn",      "Super", "Win",    "Windows", "Meta",
};

/// Checks the rules for the apps of `platform`. Dead entries count, so call
/// it on the result of `data.parseRaw`.
///
/// `arena` holds the lookup sets. Nothing is freed one by one. On failure,
/// `problem` holds the place of the first broken rule.
pub fn validate(
    arena: Allocator,
    apps: []const data.App,
    platform: Platform,
    problem: *Problem,
) Error!void {
    var names: std.StringHashMap(void) = .init(arena);

    for (apps) |app| {
        problem.* = .{ .app = app.name, .text = app.name };
        if (!isValidName(app.name, .no_spaces)) return error.InvalidName;
        if ((try names.getOrPut(app.name)).found_existing) return error.DuplicateName;
        for (app.aliases) |alias| {
            problem.text = alias;
            if (!isValidName(alias, .spaces_allowed)) return error.InvalidName;
            if ((try names.getOrPut(alias)).found_existing) return error.DuplicateName;
        }
        try checkText(app.full_name, problem);
        if (app.note) |note| try checkText(note, problem);
        if (app.source) |source| try checkText(source, problem);

        var group_ids: std.AutoHashMap(u32, void) = .init(arena);
        var binding_ids: std.AutoHashMap(u32, void) = .init(arena);
        var titles: std.StringHashMap(void) = .init(arena);
        var notes: std.StringHashMap(void) = .init(arena);
        for (app.binding_groups) |group| {
            problem.* = .{ .app = app.name, .group_id = group.id };
            if ((try group_ids.getOrPut(group.id)).found_existing) return error.DuplicateGroupId;
            try checkText(group.title, problem);
            if (group.note) |note| try checkText(note, problem);

            // Two groups that show need different titles, or the user
            // cannot tell them apart. A note that two groups share is a
            // fact of the app, and belongs in the note of the app. A dead
            // group does not show, so it does not count.
            if (!group.dead) {
                problem.text = group.title;
                if ((try titles.getOrPut(group.title)).found_existing) return error.DuplicateTitle;
                if (group.note) |note| {
                    problem.text = note;
                    if ((try notes.getOrPut(note)).found_existing) return error.DuplicateNote;
                }
                problem.text = null;
            }
            // A group with no binding would be dropped in silence. A group
            // that is removed says so with `dead`.
            if (group.bindings.len == 0 and !group.dead) return error.EmptyField;

            for (group.bindings) |binding| {
                problem.* = .{ .app = app.name, .group_id = group.id, .binding_id = binding.id };
                if ((try binding_ids.getOrPut(binding.id)).found_existing) return error.DuplicateBindingId;
                try checkText(binding.effect, problem);
                if (binding.keys.len == 0) return error.EmptyField;
                for (binding.keys, 0..) |alternative, index| {
                    try checkText(alternative, problem);
                    problem.text = alternative;
                    if (!isValidKeys(alternative, platform)) return error.InvalidKeys;
                    // The same alternative twice shows as `a OR a`.
                    for (binding.keys[0..index]) |earlier| {
                        if (std.mem.eql(u8, earlier, alternative)) return error.InvalidKeys;
                    }
                    problem.text = null;
                }
            }
        }
    }
}

/// Fails when `text` is empty or is not clean. Stores `text` in `problem`.
fn checkText(text: []const u8, problem: *Problem) Error!void {
    problem.text = text;
    if (text.len == 0) return error.EmptyField;
    if (!isCleanText(text)) return error.InvalidText;
    problem.text = null;
}

/// Returns true when `text` is safe to write to a terminal and has no
/// space at either end.
///
/// The data comes from contributors. A control character in it could move
/// the cursor, set the window title or write the clipboard of the user. An
/// invisible or a direction-changing character could hide what a line says.
fn isCleanText(text: []const u8) bool {
    if (text.len == 0) return true;
    if (text[0] == ' ' or text[text.len - 1] == ' ') return false;

    const view = std.unicode.Utf8View.init(text) catch return false;
    var code_points = view.iterator();
    while (code_points.nextCodepoint()) |code_point| {
        switch (code_point) {
            // C0 controls, DEL and C1 controls. This includes tab, line
            // feed and escape.
            0x00...0x1f, 0x7f...0x9f => return false,
            // No-break space. It looks like a space but joins two words.
            0xa0 => return false,
            // Zero-width characters and direction marks.
            0x200b...0x200f, 0x2060...0x2064, 0xfeff, 0x061c => return false,
            // Line and paragraph separators.
            0x2028, 0x2029 => return false,
            // Direction embeddings, overrides and isolates.
            0x202a...0x202e, 0x2066...0x2069 => return false,
            else => {},
        }
    }
    return true;
}

/// Returns true when `alternative` follows the key notation:
///
/// - No space at either end and no two spaces in a row.
/// - Every modifier is spelled as in `platform.modifiers()`.
/// - Every named key is spelled as in `data.key_names`.
///
/// A step is a part between spaces. A step is a key combination when its
/// first `+` follows a capitalised word, or a word for a modifier in any
/// case. Any other step with a `+` is literal text, such as the vim command
/// `"+p`, and passes. In a key combination, every part before the last `+`
/// must be a modifier, no modifier appears twice, and the last part is a
/// key, not a modifier and not empty. Write the plus key as `Plus`.
fn isValidKeys(alternative: []const u8, platform: Platform) bool {
    var previous_step: []const u8 = "";
    var steps = std.mem.splitScalar(u8, alternative, ' ');
    while (steps.next()) |step| {
        defer previous_step = step;
        // An empty step means a space at one end, or two spaces in a row.
        if (step.len == 0) return false;
        // `Cmd + N` has spaces around the `+`. It must be `Cmd+N`.
        if (std.mem.eql(u8, step, "+") and isModifierWord(previous_step)) return false;

        const first_plus = std.mem.indexOfScalar(u8, step, '+') orelse {
            if (!isValidKeyName(step, .alone)) return false;
            continue;
        };
        const first_part = step[0..first_plus];
        const is_combination = isModifierWord(first_part) or
            (first_part.len >= 2 and std.ascii.isUpper(first_part[0]));
        if (!is_combination) continue;

        const last_plus = std.mem.lastIndexOfScalar(u8, step, '+').?;
        const modifiers = step[0..last_plus];
        const key = step[last_plus + 1 ..];

        var seen: usize = 0;
        var parts = std.mem.splitScalar(u8, modifiers, '+');
        while (parts.next()) |part| {
            const index = modifierIndex(part, platform) orelse return false;
            const bit = @as(usize, 1) << @intCast(index);
            if (seen & bit != 0) return false;
            seen |= bit;
        }

        if (key.len == 0) return false;
        if (isModifierInAnyCase(key, platform)) return false;
        if (!isValidKeyName(key, .in_combination)) return false;
    }
    return true;
}

/// Returns false when `key` is a named key in a spelling other than the one
/// in `data.key_names`: another case, or an alias such as `Return` for
/// `Enter`. Returns true for the fixed spelling and for every key with no
/// name in the list.
///
/// A lowercase word that stands `.alone` passes. It can be literal text,
/// such as `left` in a command. After a modifier it can only be a key.
fn isValidKeyName(key: []const u8, place: enum { alone, in_combination }) bool {
    if (isFunctionKeyInAnyCase(key)) {
        // `F1` to `F24`, with a capital `F` and no zero in front.
        const number = std.fmt.parseInt(u8, key[1..], 10) catch return false;
        return key[0] == 'F' and key[1] != '0' and number >= 1 and number <= 24;
    }

    const name = fixedKeyName(key) orelse return true;
    if (std.mem.eql(u8, key, name)) return true;
    return place == .alone and isLowercaseWord(key);
}

/// Returns the fixed spelling of `key` when it is a named key in any case
/// or an alias of one. Returns null for every other key.
fn fixedKeyName(key: []const u8) ?[]const u8 {
    for (data.key_names) |name| {
        if (std.ascii.eqlIgnoreCase(key, name)) return name;
    }
    for (key_aliases) |entry| {
        if (std.ascii.eqlIgnoreCase(key, entry.alias)) return entry.name;
    }
    return null;
}

/// Returns true for `F` and one or two digits, and for the same with a
/// lowercase `f`.
fn isFunctionKeyInAnyCase(key: []const u8) bool {
    if (key.len < 2 or key.len > 3) return false;
    if (key[0] != 'F' and key[0] != 'f') return false;
    for (key[1..]) |char| {
        if (!std.ascii.isDigit(char)) return false;
    }
    return true;
}

fn isLowercaseWord(text: []const u8) bool {
    for (text) |char| {
        if (!std.ascii.isLower(char)) return false;
    }
    return true;
}

/// Returns the position of `part` in `platform.modifiers()`, or null when it
/// is not a modifier in the fixed spelling.
fn modifierIndex(part: []const u8, platform: Platform) ?usize {
    for (platform.modifiers(), 0..) |modifier, index| {
        if (std.mem.eql(u8, part, modifier)) return index;
    }
    return null;
}

/// Returns true when `part` is a word for a modifier, in any case and for
/// any platform.
fn isModifierWord(part: []const u8) bool {
    for (modifier_words) |word| {
        if (std.ascii.eqlIgnoreCase(part, word)) return true;
    }
    return false;
}

fn isModifierInAnyCase(part: []const u8, platform: Platform) bool {
    for (platform.modifiers()) |modifier| {
        if (std.ascii.eqlIgnoreCase(part, modifier)) return true;
    }
    return false;
}

/// Returns true when `name` can be an app name or an alias.
///
/// A name is made of the characters `a` to `z`, `0` to `9`, `.`, `_` and
/// `-`, and does not start with `-`. With `.spaces_allowed` it can be
/// several such words with one space between two words.
///
/// The set is small on purpose. The shell completions pass the names to the
/// shell, and a character such as `$` or a backtick would be run as a
/// command there. A name that starts with `-` could never be called,
/// because `seks` reads it as an option.
fn isValidName(name: []const u8, spaces: enum { no_spaces, spaces_allowed }) bool {
    if (name.len == 0 or name[0] == '-') return false;

    var words = std.mem.splitScalar(u8, name, ' ');
    var count: usize = 0;
    while (words.next()) |word| : (count += 1) {
        // An empty word means a space at one end, or two spaces in a row.
        if (word.len == 0) return false;
        for (word) |char| {
            const allowed = std.ascii.isLower(char) or std.ascii.isDigit(char) or
                char == '.' or char == '_' or char == '-';
            if (!allowed) return false;
        }
    }
    return spaces == .spaces_allowed or count == 1;
}

const testing = std.testing;

/// Parses `json` and returns the error and the problem of `validate`.
fn expectProblem(expected: Error, json: []const u8) !Problem {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var problem: Problem = .{};
    const raw = try data.parseRaw(arena, json);
    try testing.expectError(expected, validate(arena, raw, .macos, &problem));
    // The texts of the problem point into the arena. Drop them.
    problem.app = "";
    problem.text = null;
    return problem;
}

test "bundled data of every platform follows the rules" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const files = [_]struct { platform: Platform, json: []const u8 }{
        .{ .platform = .macos, .json = @embedFile("macos.json") },
        .{ .platform = .linux, .json = @embedFile("linux.json") },
    };
    for (files) |file| {
        const raw = data.parseRaw(arena, file.json) catch |err| {
            std.debug.print("data/{t}: {t}\n", .{ file.platform, err });
            return err;
        };
        var problem: Problem = .{};
        validate(arena, raw, file.platform, &problem) catch |err| {
            std.debug.print("data/{t}/{s}.json: {t}{f}\n", .{ file.platform, problem.app, err, problem });
            return err;
        };
    }
}

test "validate counts dead entries when it checks ids" {
    // Binding 1 is dead in the first group and reused in the second group.
    const problem = try expectProblem(error.DuplicateBindingId,
        \\[ { "name": "app", "full_name": "App", "binding_groups": [
        \\  { "id": 1, "title": "One", "bindings": [
        \\    { "id": 1, "keys": ["a"], "effect": "First", "dead": true } ] },
        \\  { "id": 2, "title": "Two", "bindings": [
        \\    { "id": 1, "keys": ["b"], "effect": "Second" } ] }
        \\] } ]
    );
    try testing.expectEqual(2, problem.group_id.?);
    try testing.expectEqual(1, problem.binding_id.?);
}

test "validate rejects an alias that another app uses" {
    _ = try expectProblem(error.DuplicateName,
        \\[
        \\  { "name": "one", "full_name": "One", "binding_groups": [] },
        \\  { "name": "two", "aliases": ["one"], "full_name": "Two", "binding_groups": [] }
        \\]
    );
}

test "validate rejects a broken name, a reused group id and an empty field" {
    _ = try expectProblem(error.InvalidName,
        \\[ { "name": "Two Words", "full_name": "App", "binding_groups": [] } ]
    );
    _ = try expectProblem(error.InvalidName,
        \\[ { "name": "app", "aliases": ["$(id)"], "full_name": "App", "binding_groups": [] } ]
    );
    _ = try expectProblem(error.DuplicateGroupId,
        \\[ { "name": "app", "full_name": "App", "binding_groups": [
        \\  { "id": 1, "title": "One", "dead": true, "bindings": [] },
        \\  { "id": 1, "title": "Two", "bindings": [] }
        \\] } ]
    );
    _ = try expectProblem(error.EmptyField,
        \\[ { "name": "app", "full_name": "App", "binding_groups": [
        \\  { "id": 1, "title": "One", "bindings": [
        \\    { "id": 1, "keys": [], "effect": "No keys" } ] }
        \\] } ]
    );
    _ = try expectProblem(error.EmptyField,
        \\[ { "name": "app", "full_name": "App", "binding_groups": [
        \\  { "id": 1, "title": "One", "note": "", "bindings": [] }
        \\] } ]
    );
    _ = try expectProblem(error.InvalidKeys,
        \\[ { "name": "app", "full_name": "App", "binding_groups": [
        \\  { "id": 1, "title": "One", "bindings": [
        \\    { "id": 1, "keys": ["Cmd+N", "Command+N"], "effect": "Long spelling" } ] }
        \\] } ]
    );
}

test "validate rejects a control character in every text field" {
    // `\u001b` is the escape character. It starts a terminal command.
    const cases = [_][]const u8{
        \\[ { "name": "app", "full_name": "App\u001b[31m", "binding_groups": [] } ]
        ,
        \\[ { "name": "app", "full_name": "App", "note": "Note\u001b]0;title\u0007", "binding_groups": [] } ]
        ,
        \\[ { "name": "app", "full_name": "App", "source": "https://x\n$(id)", "binding_groups": [] } ]
        ,
        \\[ { "name": "app", "full_name": "App", "binding_groups": [
        \\  { "id": 1, "title": "One\ttab", "bindings": [] } ] } ]
        ,
        \\[ { "name": "app", "full_name": "App", "binding_groups": [
        \\  { "id": 1, "title": "One", "note": "Note‮", "bindings": [] } ] } ]
        ,
        \\[ { "name": "app", "full_name": "App", "binding_groups": [
        \\  { "id": 1, "title": "One", "bindings": [
        \\    { "id": 1, "keys": ["a\u001b[2J"], "effect": "Clear" } ] } ] } ]
        ,
        \\[ { "name": "app", "full_name": "App", "binding_groups": [
        \\  { "id": 1, "title": "One", "bindings": [
        \\    { "id": 1, "keys": ["a"], "effect": "Line\nbreak" } ] } ] } ]
        ,
        \\[ { "name": "app", "full_name": "App", "binding_groups": [
        \\  { "id": 1, "title": "One", "bindings": [
        \\    { "id": 1, "keys": ["a"], "effect": " Space at the start" } ] } ] } ]
    };
    for (cases) |json| _ = try expectProblem(error.InvalidText, json);
}

test "Problem formats the place and escapes the text" {
    var buffer: [128]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);

    const problem: Problem = .{ .app = "app", .group_id = 2, .binding_id = 9, .text = "a\x1b[2J" };
    try writer.print("{f}", .{problem});
    try testing.expectEqualStrings(", group 2, binding 9: \"a\\x1b[2J\"", writer.buffered());
}

test "isCleanText" {
    try testing.expect(isCleanText("Move left"));
    try testing.expect(isCleanText("Größe ändern → ←"));
    try testing.expect(isCleanText("Ctrl+B d ··· Detach"));

    try testing.expect(!isCleanText("a\x1bb"));
    try testing.expect(!isCleanText("a\tb"));
    try testing.expect(!isCleanText("a\nb"));
    try testing.expect(!isCleanText("a\x7fb"));
    try testing.expect(!isCleanText("a\u{9b}b"));
    try testing.expect(!isCleanText("a\u{a0}b"));
    try testing.expect(!isCleanText("a\u{200b}b"));
    try testing.expect(!isCleanText("a\u{202e}b"));
    try testing.expect(!isCleanText(" a"));
    try testing.expect(!isCleanText("a "));
    // Not valid UTF-8.
    try testing.expect(!isCleanText("a\xffb"));
}

test "isValidKeys accepts the fixed modifier spellings and literal text" {
    try testing.expect(isValidKeys("Space", .macos));
    try testing.expect(isValidKeys("Cmd+N", .macos));
    try testing.expect(isValidKeys("Ctrl+Opt+Shift+Cmd+N", .macos));
    try testing.expect(isValidKeys("Fn+Delete", .macos));
    try testing.expect(isValidKeys("Cmd+Plus", .macos));
    try testing.expect(isValidKeys("Cmd+K Cmd+S", .macos));
    try testing.expect(isValidKeys("Ctrl+Alt+T", .linux));
    try testing.expect(isValidKeys("Super+L", .linux));

    // Sequences and commands with no key combination.
    try testing.expect(isValidKeys("Prefix %", .macos));
    try testing.expect(isValidKeys("g g", .macos));
    try testing.expect(isValidKeys(":wq", .macos));

    // A `+` that is literal text, not a join.
    try testing.expect(isValidKeys("\"+p", .macos));
    try testing.expect(isValidKeys("g+", .macos));
    try testing.expect(isValidKeys("Ctrl+w +", .macos));
    try testing.expect(isValidKeys(":set path+=src", .macos));
}

test "isValidKeys rejects every other modifier spelling" {
    try testing.expect(!isValidKeys("Command+N", .macos));
    try testing.expect(!isValidKeys("Option+N", .macos));
    try testing.expect(!isValidKeys("Cmd+Shfit+N", .macos));
    try testing.expect(!isValidKeys("cmd+N", .macos));
    try testing.expect(!isValidKeys("CMD+N", .macos));
    try testing.expect(!isValidKeys("Cmd+K Command+S", .macos));

    // A modifier of the other platform.
    try testing.expect(!isValidKeys("Alt+N", .macos));
    try testing.expect(!isValidKeys("Cmd+N", .linux));

    // The plus key must be written as `Plus`.
    try testing.expect(!isValidKeys("Cmd++", .macos));
    try testing.expect(!isValidKeys("Cmd+", .macos));

    // Keys pressed in order need a space, not a `+`.
    try testing.expect(!isValidKeys("Prefix+c", .macos));
}

test "isValidKeys rejects a combination with no key or with a modifier twice" {
    // The last part must be a key.
    try testing.expect(!isValidKeys("Cmd+Shift+Cmd", .macos));
    try testing.expect(!isValidKeys("Ctrl+Shift+Ctrl", .linux));
    try testing.expect(!isValidKeys("Cmd+Shift", .macos));
    try testing.expect(!isValidKeys("Cmd+shift", .macos));

    try testing.expect(!isValidKeys("Cmd+Cmd+N", .macos));
    try testing.expect(!isValidKeys("Ctrl+Shift+Ctrl+N", .linux));
}

test "isValidKeys rejects a modifier word in lowercase and a spaced plus" {
    try testing.expect(!isValidKeys("command+n", .macos));
    try testing.expect(!isValidKeys("option+n", .macos));
    try testing.expect(!isValidKeys("control+c", .macos));
    try testing.expect(!isValidKeys("alt+n", .macos));
    try testing.expect(!isValidKeys("win+l", .linux));
    try testing.expect(!isValidKeys("meta+x", .linux));

    try testing.expect(!isValidKeys("Cmd + N", .macos));
    try testing.expect(!isValidKeys("ctrl + c", .linux));

    // A plus with no modifier before it is the plus key of the app.
    try testing.expect(isValidKeys("Ctrl+w +", .macos));
    try testing.expect(isValidKeys("g +", .macos));
}

test "isValidKeys rejects a name written as two words and a wrong function key" {
    try testing.expect(!isValidKeys("Ctrl+Page Up", .linux));
    try testing.expect(!isValidKeys("Left Arrow", .macos));

    try testing.expect(isValidKeys("F1", .macos));
    try testing.expect(isValidKeys("F24", .macos));
    try testing.expect(!isValidKeys("F0", .macos));
    try testing.expect(!isValidKeys("F00", .macos));
    try testing.expect(!isValidKeys("F05", .macos));
    try testing.expect(!isValidKeys("F25", .macos));
    try testing.expect(!isValidKeys("Shift+F99", .macos));
}

test "validate rejects the same alternative twice and a live group with no binding" {
    _ = try expectProblem(error.InvalidKeys,
        \\[ { "name": "app", "full_name": "App", "binding_groups": [
        \\  { "id": 1, "title": "One", "bindings": [
        \\    { "id": 1, "keys": ["Cmd+N", "Cmd+N"], "effect": "Twice" } ] }
        \\] } ]
    );
    _ = try expectProblem(error.EmptyField,
        \\[ { "name": "app", "full_name": "App", "binding_groups": [
        \\  { "id": 1, "title": "One", "bindings": [] }
        \\] } ]
    );
}

test "validate rejects a title or a note that two live groups share" {
    _ = try expectProblem(error.DuplicateTitle,
        \\[ { "name": "app", "full_name": "App", "binding_groups": [
        \\  { "id": 1, "title": "Same", "bindings": [ { "id": 1, "keys": ["a"], "effect": "A" } ] },
        \\  { "id": 2, "title": "Same", "bindings": [ { "id": 2, "keys": ["b"], "effect": "B" } ] }
        \\] } ]
    );
    _ = try expectProblem(error.DuplicateNote,
        \\[ { "name": "app", "full_name": "App", "binding_groups": [
        \\  { "id": 1, "title": "One", "note": "Same", "bindings": [ { "id": 1, "keys": ["a"], "effect": "A" } ] },
        \\  { "id": 2, "title": "Two", "note": "Same", "bindings": [ { "id": 2, "keys": ["b"], "effect": "B" } ] }
        \\] } ]
    );
}

test "validate accepts the title and the note of a dead group again" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const json =
        \\[ { "name": "app", "full_name": "App", "binding_groups": [
        \\  { "id": 1, "title": "Same", "note": "Note", "dead": true, "bindings": [] },
        \\  { "id": 2, "title": "Same", "note": "Note", "bindings": [ { "id": 1, "keys": ["a"], "effect": "A" } ] }
        \\] } ]
    ;
    var problem: Problem = .{};
    try validate(arena, try data.parseRaw(arena, json), .macos, &problem);
}

test "isValidKeys rejects a space at either end and two spaces in a row" {
    try testing.expect(!isValidKeys(" g g", .macos));
    try testing.expect(!isValidKeys("g g ", .macos));
    try testing.expect(!isValidKeys("g  g", .macos));
}

test "isValidKeys accepts the fixed key names and keys with no fixed name" {
    try testing.expect(isValidKeys("Enter", .macos));
    try testing.expect(isValidKeys("Esc", .macos));
    try testing.expect(isValidKeys("Ctrl+Enter", .macos));
    try testing.expect(isValidKeys("Cmd+Shift+PageDown", .macos));
    try testing.expect(isValidKeys("F5", .macos));
    try testing.expect(isValidKeys("Shift+F12", .macos));
    try testing.expect(isValidKeys("Prefix Up", .macos));

    // A key that is not in the list has no fixed spelling.
    try testing.expect(isValidKeys("Cmd+Click", .macos));
    try testing.expect(isValidKeys("VolumeUp", .macos));

    // A lowercase word with no modifier can be literal text.
    try testing.expect(isValidKeys("focus left", .linux));
    try testing.expect(isValidKeys(":tab split", .macos));
}

test "isValidKeys rejects every other spelling of a named key" {
    // An alias.
    try testing.expect(!isValidKeys("Return", .macos));
    try testing.expect(!isValidKeys("Escape", .macos));
    try testing.expect(!isValidKeys("Cmd+Return", .macos));
    try testing.expect(!isValidKeys("Cmd+Del", .macos));
    try testing.expect(!isValidKeys("Ctrl+PgUp", .macos));
    try testing.expect(!isValidKeys("Spacebar", .macos));
    try testing.expect(!isValidKeys("Prefix ←", .macos));

    // Another case.
    try testing.expect(!isValidKeys("ESC", .macos));
    try testing.expect(!isValidKeys("Pageup", .macos));
    try testing.expect(!isValidKeys("Ctrl+enter", .macos));
    try testing.expect(!isValidKeys("Ctrl+plus", .macos));
    try testing.expect(!isValidKeys("f5", .macos));
    try testing.expect(!isValidKeys("Ctrl+f5", .macos));
}

test "isValidName" {
    try testing.expect(isValidName("vim", .no_spaces));
    try testing.expect(isValidName("i3", .no_spaces));
    try testing.expect(isValidName("vs-code_2.0", .no_spaces));
    try testing.expect(isValidName("visual studio code", .spaces_allowed));

    try testing.expect(!isValidName("", .no_spaces));
    try testing.expect(!isValidName("Vim", .no_spaces));
    try testing.expect(!isValidName("two words", .no_spaces));
    try testing.expect(!isValidName(" files", .spaces_allowed));
    try testing.expect(!isValidName("files ", .spaces_allowed));
    try testing.expect(!isValidName("two  spaces", .spaces_allowed));

    // A name that the shell would run or that `seks` reads as an option.
    try testing.expect(!isValidName("$(id)", .no_spaces));
    try testing.expect(!isValidName("a`id`", .no_spaces));
    try testing.expect(!isValidName("a;b", .no_spaces));
    try testing.expect(!isValidName("a\tb", .spaces_allowed));
    try testing.expect(!isValidName("-list", .no_spaces));
    try testing.expect(!isValidName("größe", .no_spaces));
}
