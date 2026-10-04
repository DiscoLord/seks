//! The binding data: the structs that mirror the JSON, and the parser.
//!
//! The source is one JSON file per app in `data/<platform>/`. The build
//! merges the files of a platform into one JSON array, and this file embeds
//! that array.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

/// The shape of the JSON. Raise it only when the shape changes in a way that
/// breaks older builds.
pub const schema_version = 1;

/// The revision of the bundled data. The data ships inside the app, so this
/// is the app version.
pub const version: []const u8 = @import("build_options").version;

/// The name of the plus key in the data. A bare `+` joins keys held
/// together, so the key itself needs a name.
pub const plus_key = "Plus";

/// The only spelling of each named key in the data. A key that is not in
/// this list, such as a letter or `Click`, has no fixed spelling.
pub const key_names = [_][]const u8{
    "Enter",    "Esc",    "Tab",  "Space", "Backspace", "Delete", "Insert",
    "Up",       "Down",   "Left", "Right", "Home",      "End",    "PageUp",
    "PageDown", plus_key,
};

/// Other spellings of the keys in `key_names`. The data check rejects them
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
};

pub const Platform = enum {
    macos,
    linux,

    /// The platform this build runs on, and the platform of the bundled data.
    pub const native: Platform = switch (builtin.os.tag) {
        .macos => .macos,
        .linux => .linux,
        else => @compileError("seks supports macOS and Linux only"),
    };

    /// The only spellings a modifier key can have in the data.
    pub fn modifiers(platform: Platform) []const []const u8 {
        return switch (platform) {
            .macos => &.{ "Cmd", "Shift", "Opt", "Ctrl", "Fn" },
            .linux => &.{ "Ctrl", "Shift", "Alt", "Super" },
        };
    }
};

pub const App = struct {
    /// The default name to call the app by. Lowercase, no spaces. The build
    /// takes it from the file name.
    name: []const u8,
    /// Other names that find the app. Lowercase, spaces allowed.
    aliases: []const []const u8 = &.{},
    /// The name to show.
    full_name: []const u8,
    /// One short line to show under the name, such as the default prefix key.
    note: ?[]const u8 = null,
    /// The page the bindings come from.
    source: ?[]const u8 = null,
    binding_groups: []const BindingGroup,
};

pub const BindingGroup = struct {
    /// Unique among the groups of one app. Never changed, never reused.
    id: u32,
    title: []const u8,
    /// One short line to show under the title, such as how to enter the mode
    /// that the bindings work in.
    note: ?[]const u8 = null,
    /// A tombstone. It keeps the `id` taken after the group is removed.
    dead: bool = false,
    bindings: []const Binding,
};

pub const Binding = struct {
    /// Unique among all bindings of one app. Never changed, never reused.
    id: u32,
    /// The alternatives that trigger the effect. In one alternative, `+`
    /// joins keys held together and a space separates keys pressed in order.
    /// A modifier is spelled as in `Platform.modifiers`.
    keys: []const []const u8,
    effect: []const u8,
    /// A tombstone. It keeps the `id` taken after the binding is removed.
    dead: bool = false,
};

// The switch operand is comptime-known, so a build embeds one file only.
const bundled_json: []const u8 = switch (Platform.native) {
    .macos => @embedFile("macos.json"),
    .linux => @embedFile("linux.json"),
};

/// Parses the apps bundled into this build. Returns them without dead groups
/// and dead bindings.
///
/// `arena` owns the result. Nothing is freed one by one.
pub fn loadBundled(arena: Allocator) ![]const App {
    return parse(arena, bundled_json);
}

/// Parses a JSON array of apps. Returns the apps without dead groups and
/// dead bindings.
///
/// `arena` owns the result. Nothing is freed one by one. The result keeps
/// references into `json`, so `json` must live as long as the result.
pub fn parse(arena: Allocator, json: []const u8) ![]const App {
    const raw = try parseRaw(arena, json);
    return dropDead(arena, raw);
}

/// Parses a JSON array of apps and keeps the dead entries.
fn parseRaw(arena: Allocator, json: []const u8) ![]const App {
    // Unknown fields are ignored, so an added field does not break the parse.
    return std.json.parseFromSliceLeaky([]const App, arena, json, .{
        .ignore_unknown_fields = true,
    });
}

/// Returns a copy of `apps` without dead groups and dead bindings. A group
/// with no live binding is dropped too.
fn dropDead(arena: Allocator, apps: []const App) Allocator.Error![]const App {
    const live_apps = try arena.alloc(App, apps.len);
    for (apps, live_apps) |app, *live_app| {
        var groups: std.ArrayList(BindingGroup) = .empty;
        for (app.binding_groups) |group| {
            if (group.dead) continue;

            var bindings: std.ArrayList(Binding) = .empty;
            for (group.bindings) |binding| {
                if (!binding.dead) try bindings.append(arena, binding);
            }
            if (bindings.items.len == 0) continue;

            var live_group = group;
            live_group.bindings = bindings.items;
            try groups.append(arena, live_group);
        }
        live_app.* = app;
        live_app.binding_groups = groups.items;
    }
    return live_apps;
}

/// Where `validate` found a problem. Filled only when `validate` fails.
const Problem = struct {
    app: []const u8 = "",
    id: u32 = 0,
};

const ValidateError = error{
    InvalidName,
    DuplicateName,
    DuplicateGroupId,
    DuplicateBindingId,
    EmptyField,
    InvalidKeys,
} || Allocator.Error;

/// Checks the rules that the parser cannot check, for apps of `platform`.
/// Dead entries count, so call it on the result of `parseRaw`.
///
/// `arena` holds the lookup sets. Nothing is freed one by one. On failure,
/// `problem` holds the app of the first broken rule, and the id when the
/// rule is about a group or a binding.
fn validate(
    arena: Allocator,
    apps: []const App,
    platform: Platform,
    problem: *Problem,
) ValidateError!void {
    var names: std.StringHashMap(void) = .init(arena);

    for (apps) |app| {
        problem.* = .{ .app = app.name };

        if (!isValidName(app.name, .no_spaces)) return error.InvalidName;
        if ((try names.getOrPut(app.name)).found_existing) return error.DuplicateName;
        for (app.aliases) |alias| {
            if (!isValidName(alias, .spaces_allowed)) return error.InvalidName;
            if ((try names.getOrPut(alias)).found_existing) return error.DuplicateName;
        }
        if (app.full_name.len == 0) return error.EmptyField;
        if (app.note) |note| if (note.len == 0) return error.EmptyField;

        var group_ids: std.AutoHashMap(u32, void) = .init(arena);
        var binding_ids: std.AutoHashMap(u32, void) = .init(arena);
        for (app.binding_groups) |group| {
            problem.id = group.id;
            if ((try group_ids.getOrPut(group.id)).found_existing) return error.DuplicateGroupId;
            if (group.title.len == 0) return error.EmptyField;
            if (group.note) |note| if (note.len == 0) return error.EmptyField;

            for (group.bindings) |binding| {
                problem.id = binding.id;
                if ((try binding_ids.getOrPut(binding.id)).found_existing) return error.DuplicateBindingId;
                if (binding.effect.len == 0) return error.EmptyField;
                if (binding.keys.len == 0) return error.EmptyField;
                for (binding.keys) |alternative| {
                    if (alternative.len == 0) return error.EmptyField;
                    if (!isValidKeys(alternative, platform)) return error.InvalidKeys;
                }
            }
        }
    }
}

/// Returns true when every modifier in `alternative` is spelled as in
/// `platform.modifiers()` and every named key as in `key_names`.
///
/// A step is a part between spaces. A step is a key combination when its
/// first `+` follows a capitalised word, or a modifier in the wrong case.
/// Any other step with a `+` is literal text, such as the vim command
/// `"+p`, and passes. In a key combination, every part before the last `+`
/// must be a modifier, and the last part must not be empty. Write the plus
/// key as `Plus`.
fn isValidKeys(alternative: []const u8, platform: Platform) bool {
    var steps = std.mem.tokenizeScalar(u8, alternative, ' ');
    while (steps.next()) |step| {
        const first_plus = std.mem.indexOfScalar(u8, step, '+') orelse {
            if (!isValidKeyName(step, .alone)) return false;
            continue;
        };
        const first_part = step[0..first_plus];
        const is_combination = isModifierInAnyCase(first_part, platform) or
            (first_part.len >= 2 and std.ascii.isUpper(first_part[0]));
        if (!is_combination) continue;

        const last_plus = std.mem.lastIndexOfScalar(u8, step, '+').?;
        if (last_plus == step.len - 1) return false;

        var parts = std.mem.splitScalar(u8, step[0..last_plus], '+');
        while (parts.next()) |part| {
            if (!isModifier(part, platform)) return false;
        }
        if (!isValidKeyName(step[last_plus + 1 ..], .in_combination)) return false;
    }
    return true;
}

/// Returns false when `key` is a named key in a spelling other than the one
/// in `key_names`: another case, or an alias such as `Return` for `Enter`.
/// Returns true for the fixed spelling and for every key with no name in
/// the list.
///
/// A lowercase word that stands `.alone` passes. It can be literal text,
/// such as `left` in a command. After a modifier it can only be a key.
fn isValidKeyName(key: []const u8, place: enum { alone, in_combination }) bool {
    if (isFunctionKeyInAnyCase(key)) return key[0] == 'F';

    const name = fixedKeyName(key) orelse return true;
    if (std.mem.eql(u8, key, name)) return true;
    return place == .alone and isLowercaseWord(key);
}

/// Returns the fixed spelling of `key` when it is a named key in any case
/// or an alias of one. Returns null for every other key.
fn fixedKeyName(key: []const u8) ?[]const u8 {
    for (key_names) |name| {
        if (std.ascii.eqlIgnoreCase(key, name)) return name;
    }
    for (key_aliases) |entry| {
        if (std.ascii.eqlIgnoreCase(key, entry.alias)) return entry.name;
    }
    return null;
}

/// Returns true for `F1` to `F99` and for the same with a lowercase `f`.
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

fn isModifier(part: []const u8, platform: Platform) bool {
    for (platform.modifiers()) |modifier| {
        if (std.mem.eql(u8, part, modifier)) return true;
    }
    return false;
}

fn isModifierInAnyCase(part: []const u8, platform: Platform) bool {
    for (platform.modifiers()) |modifier| {
        if (std.ascii.eqlIgnoreCase(part, modifier)) return true;
    }
    return false;
}

/// Returns true when `name` is not empty, has no uppercase letter and has no
/// whitespace at either end. With `.no_spaces` it must hold no whitespace.
fn isValidName(name: []const u8, spaces: enum { no_spaces, spaces_allowed }) bool {
    if (name.len == 0) return false;
    if (std.mem.trim(u8, name, &std.ascii.whitespace).len != name.len) return false;
    for (name) |char| {
        if (std.ascii.isUpper(char)) return false;
        if (spaces == .no_spaces and std.ascii.isWhitespace(char)) return false;
    }
    return true;
}

const testing = std.testing;

const test_json =
    \\[
    \\  {
    \\    "name": "tmux",
    \\    "full_name": "tmux",
    \\    "note": "Prefix is Ctrl+b by default",
    \\    "future_field": true,
    \\    "binding_groups": [
    \\      {
    \\        "id": 1,
    \\        "title": "Panes",
    \\        "bindings": [
    \\          { "id": 1, "keys": ["Prefix %"], "effect": "Split left and right" },
    \\          { "id": 2, "keys": ["Prefix x"], "effect": "Close the pane", "dead": true }
    \\        ]
    \\      },
    \\      {
    \\        "id": 2,
    \\        "title": "Removed group",
    \\        "dead": true,
    \\        "bindings": [
    \\          { "id": 3, "keys": ["Prefix c"], "effect": "Create a window" }
    \\        ]
    \\      },
    \\      {
    \\        "id": 3,
    \\        "title": "Group with dead bindings only",
    \\        "bindings": [
    \\          { "id": 4, "keys": ["Prefix d"], "effect": "Detach", "dead": true }
    \\        ]
    \\      }
    \\    ]
    \\  }
    \\]
;

test "bundled data of every platform parses and follows the rules" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const files = [_]struct { platform: Platform, json: []const u8 }{
        .{ .platform = .macos, .json = @embedFile("macos.json") },
        .{ .platform = .linux, .json = @embedFile("linux.json") },
    };
    for (files) |file| {
        const raw = parseRaw(arena, file.json) catch |err| {
            std.debug.print("data/{t}: {t}\n", .{ file.platform, err });
            return err;
        };
        var problem: Problem = .{};
        validate(arena, raw, file.platform, &problem) catch |err| {
            std.debug.print("data/{t}/{s}.json: {t}, id {d}\n", .{ file.platform, problem.app, err, problem.id });
            return err;
        };
    }
}

test "loadBundled returns the apps of this platform" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    const apps = try loadBundled(arena_state.allocator());
    try testing.expect(apps.len > 0);
}

test "parse reads optional fields and ignores unknown fields" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    const apps = try parse(arena_state.allocator(), test_json);
    const app = apps[0];
    try testing.expectEqualStrings("tmux", app.name);
    try testing.expectEqual(0, app.aliases.len);
    try testing.expectEqualStrings("Prefix is Ctrl+b by default", app.note.?);
    try testing.expectEqual(null, app.source);
}

test "parse drops dead groups, dead bindings and groups left empty" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    const apps = try parse(arena_state.allocator(), test_json);
    const groups = apps[0].binding_groups;
    try testing.expectEqual(1, groups.len);
    try testing.expectEqual(1, groups[0].id);
    try testing.expectEqual(1, groups[0].bindings.len);
    try testing.expectEqual(1, groups[0].bindings[0].id);
}

test "validate counts dead entries when it checks ids" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Binding 1 is dead in the first group and reused in the second group.
    const json =
        \\[ { "name": "app", "full_name": "App", "binding_groups": [
        \\  { "id": 1, "title": "One", "bindings": [
        \\    { "id": 1, "keys": ["a"], "effect": "First", "dead": true } ] },
        \\  { "id": 2, "title": "Two", "bindings": [
        \\    { "id": 1, "keys": ["b"], "effect": "Second" } ] }
        \\] } ]
    ;
    var problem: Problem = .{};
    const raw = try parseRaw(arena, json);
    try testing.expectError(error.DuplicateBindingId, validate(arena, raw, .macos, &problem));
    try testing.expectEqualStrings("app", problem.app);
    try testing.expectEqual(1, problem.id);
}

test "validate rejects an alias that another app uses" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const json =
        \\[
        \\  { "name": "one", "full_name": "One", "binding_groups": [] },
        \\  { "name": "two", "aliases": ["one"], "full_name": "Two", "binding_groups": [] }
        \\]
    ;
    var problem: Problem = .{};
    const raw = try parseRaw(arena, json);
    try testing.expectError(error.DuplicateName, validate(arena, raw, .macos, &problem));
    try testing.expectEqualStrings("two", problem.app);
}

test "validate rejects a broken name, a reused group id and an empty field" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cases = [_]struct { expected: ValidateError, json: []const u8 }{
        .{ .expected = error.InvalidName, .json =
        \\[ { "name": "Two Words", "full_name": "App", "binding_groups": [] } ]
        },
        .{ .expected = error.DuplicateGroupId, .json =
        \\[ { "name": "app", "full_name": "App", "binding_groups": [
        \\  { "id": 1, "title": "One", "dead": true, "bindings": [] },
        \\  { "id": 1, "title": "Two", "bindings": [] }
        \\] } ]
        },
        .{ .expected = error.EmptyField, .json =
        \\[ { "name": "app", "full_name": "App", "binding_groups": [
        \\  { "id": 1, "title": "One", "bindings": [
        \\    { "id": 1, "keys": [], "effect": "No keys" } ] }
        \\] } ]
        },
        .{ .expected = error.EmptyField, .json =
        \\[ { "name": "app", "full_name": "App", "binding_groups": [
        \\  { "id": 1, "title": "One", "note": "", "bindings": [] }
        \\] } ]
        },
        .{ .expected = error.InvalidKeys, .json =
        \\[ { "name": "app", "full_name": "App", "binding_groups": [
        \\  { "id": 1, "title": "One", "bindings": [
        \\    { "id": 1, "keys": ["Cmd+N", "Command+N"], "effect": "Long spelling" } ] }
        \\] } ]
        },
    };
    for (cases) |case| {
        var problem: Problem = .{};
        const raw = try parseRaw(arena, case.json);
        try testing.expectError(case.expected, validate(arena, raw, .macos, &problem));
    }
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
    try testing.expect(isValidName("gnome files", .spaces_allowed));

    try testing.expect(!isValidName("", .no_spaces));
    try testing.expect(!isValidName("Vim", .no_spaces));
    try testing.expect(!isValidName("gnome files", .no_spaces));
    try testing.expect(!isValidName(" files", .spaces_allowed));
    try testing.expect(!isValidName("files ", .spaces_allowed));
}
