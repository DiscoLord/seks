//! The binding data: the structs that mirror the JSON, and the parser.
//!
//! The source is one JSON file per app in `data/<platform>/`. The build
//! checks each file with `check.zig`, merges the files of a platform into
//! one JSON array, and this file embeds that array.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

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
///
/// A field that the structs do not have is an error. A misspelled field,
/// such as `"Dead"`, would otherwise be ignored in silence.
pub fn parseRaw(arena: Allocator, json: []const u8) ![]const App {
    return std.json.parseFromSliceLeaky([]const App, arena, json, .{});
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

const testing = std.testing;

const test_json =
    \\[
    \\  {
    \\    "name": "tmux",
    \\    "full_name": "tmux",
    \\    "note": "Prefix is Ctrl+b by default",
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

test "loadBundled returns the apps of this platform" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    const apps = try loadBundled(arena_state.allocator());
    try testing.expect(apps.len > 0);
}

test "parse fills the optional fields with their defaults" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    const apps = try parse(arena_state.allocator(), test_json);
    const app = apps[0];
    try testing.expectEqualStrings("tmux", app.name);
    try testing.expectEqual(0, app.aliases.len);
    try testing.expectEqualStrings("Prefix is Ctrl+b by default", app.note.?);
    try testing.expectEqual(null, app.source);
}

test "parse rejects a field that the structs do not have" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // `Dead` with a capital letter is not the `dead` field.
    const misspelled =
        \\[ { "name": "app", "full_name": "App", "binding_groups": [
        \\  { "id": 1, "title": "One", "Dead": true, "bindings": [] }
        \\] } ]
    ;
    try testing.expectError(error.UnknownField, parse(arena, misspelled));

    const unknown =
        \\[ { "name": "app", "full_name": "App", "alias": ["a"], "binding_groups": [] } ]
    ;
    try testing.expectError(error.UnknownField, parse(arena, unknown));
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
