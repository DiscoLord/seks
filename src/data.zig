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

pub const Platform = enum {
    macos,
    linux,

    /// The platform this build runs on, and the platform of the bundled data.
    pub const native: Platform = switch (builtin.os.tag) {
        .macos => .macos,
        .linux => .linux,
        else => @compileError("seks supports macOS and Linux only"),
    };
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
    /// A tombstone. It keeps the `id` taken after the group is removed.
    dead: bool = false,
    bindings: []const Binding,
};

pub const Binding = struct {
    /// Unique among all bindings of one app. Never changed, never reused.
    id: u32,
    /// The alternatives that trigger the effect. In one alternative, `+`
    /// joins keys held together and a space separates keys pressed in order.
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
} || Allocator.Error;

/// Checks the rules that the parser cannot check. Dead entries count, so
/// call it on the result of `parseRaw`.
///
/// `arena` holds the lookup sets. Nothing is freed one by one. On failure,
/// `problem` holds the app of the first broken rule, and the id when the
/// rule is about a group or a binding.
fn validate(arena: Allocator, apps: []const App, problem: *Problem) ValidateError!void {
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

        var group_ids: std.AutoHashMap(u32, void) = .init(arena);
        var binding_ids: std.AutoHashMap(u32, void) = .init(arena);
        for (app.binding_groups) |group| {
            problem.id = group.id;
            if ((try group_ids.getOrPut(group.id)).found_existing) return error.DuplicateGroupId;
            if (group.title.len == 0) return error.EmptyField;

            for (group.bindings) |binding| {
                problem.id = binding.id;
                if ((try binding_ids.getOrPut(binding.id)).found_existing) return error.DuplicateBindingId;
                if (binding.effect.len == 0) return error.EmptyField;
                if (binding.keys.len == 0) return error.EmptyField;
                for (binding.keys) |alternative| {
                    if (alternative.len == 0) return error.EmptyField;
                }
            }
        }
    }
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

    const platforms = [_]struct { name: []const u8, json: []const u8 }{
        .{ .name = "data/macos", .json = @embedFile("macos.json") },
        .{ .name = "data/linux", .json = @embedFile("linux.json") },
    };
    for (platforms) |platform| {
        const raw = parseRaw(arena, platform.json) catch |err| {
            std.debug.print("{s}: {t}\n", .{ platform.name, err });
            return err;
        };
        var problem: Problem = .{};
        validate(arena, raw, &problem) catch |err| {
            std.debug.print("{s}/{s}.json: {t}, id {d}\n", .{ platform.name, problem.app, err, problem.id });
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
    try testing.expectError(error.DuplicateBindingId, validate(arena, raw, &problem));
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
    try testing.expectError(error.DuplicateName, validate(arena, raw, &problem));
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
    };
    for (cases) |case| {
        var problem: Problem = .{};
        const raw = try parseRaw(arena, case.json);
        try testing.expectError(case.expected, validate(arena, raw, &problem));
    }
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
