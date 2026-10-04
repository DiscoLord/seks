//! Finds the app that a typed name refers to.
const std = @import("std");
const data = @import("data.zig");

/// Returns the app whose name or alias equals `query`, or null when there is
/// none. The comparison ignores case.
///
/// The data rules make every name and alias unique, so at most one app
/// matches.
pub fn findApp(apps: []const data.App, query: []const u8) ?data.App {
    for (apps) |app| {
        if (std.ascii.eqlIgnoreCase(query, app.name)) return app;
        for (app.aliases) |alias| {
            if (std.ascii.eqlIgnoreCase(query, alias)) return app;
        }
    }
    return null;
}

const testing = std.testing;

const test_apps = [_]data.App{
    .{ .name = "vim", .full_name = "Vim", .binding_groups = &.{} },
    .{
        .name = "nautilus",
        .aliases = &.{ "files", "gnome files" },
        .full_name = "GNOME Files",
        .binding_groups = &.{},
    },
};

test "findApp matches the name" {
    try testing.expectEqualStrings("Vim", findApp(&test_apps, "vim").?.full_name);
}

test "findApp matches an alias, also one with a space" {
    try testing.expectEqualStrings("GNOME Files", findApp(&test_apps, "files").?.full_name);
    try testing.expectEqualStrings("GNOME Files", findApp(&test_apps, "gnome files").?.full_name);
}

test "findApp ignores case" {
    try testing.expectEqualStrings("Vim", findApp(&test_apps, "VIM").?.full_name);
    try testing.expectEqualStrings("GNOME Files", findApp(&test_apps, "Gnome Files").?.full_name);
}

test "findApp returns null when no app matches" {
    try testing.expectEqual(null, findApp(&test_apps, "emacs"));
    try testing.expectEqual(null, findApp(&test_apps, "vi"));
    try testing.expectEqual(null, findApp(&.{}, "vim"));
}
