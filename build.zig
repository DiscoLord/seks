const std = @import("std");
const zon = @import("build.zig.zon");

const check = @import("src/check.zig");
const data = @import("src/data.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const options = b.addOptions();
    options.addOption([]const u8, "version", zon.version);

    const exe = b.addExecutable(.{
        .name = "seks",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addOptions("build_options", options);

    // The module can embed both files. A build embeds only the file it
    // references: the executable takes the file of its target, the tests take
    // both.
    exe.root_module.addAnonymousImport("macos.json", .{
        .root_source_file = mergeApps(b, .macos),
    });
    exe.root_module.addAnonymousImport("linux.json", .{
        .root_source_file = mergeApps(b, .linux),
    });
    b.installArtifact(exe);

    // `zig build run -- <args>` runs the installed binary with the given args.
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // `zig build test` runs the `test` blocks that `src/main.zig` reaches.
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
}

/// Merges every `<app>.json` in `data/<platform>` into one JSON array of
/// apps. The file name without `.json` becomes the `name` of the app.
///
/// Returns the merged file. Stops the build with the path of the file when
/// a file is not valid JSON, has the wrong shape, or breaks a rule of
/// `check.zig`. So no build can ship data that was not checked.
fn mergeApps(b: *std.Build, platform: data.Platform) std.Build.LazyPath {
    const io = b.graph.io;
    const arena = b.allocator;
    const dir_path = b.pathJoin(&.{ "data", @tagName(platform) });

    // Zig caches the result of this function. Declare the directory and each
    // file as an input, so an added, removed or changed file runs it again.
    b.dependOnDirectoryContents(b.path(dir_path));

    var dir = b.root.openDir(io, dir_path, .{ .iterate = true }) catch |err| {
        std.process.fatal("{s}: unable to open the directory: {t}", .{ dir_path, err });
    };
    defer dir.close(io);

    var file_names: std.ArrayList([]const u8) = .empty;
    var entries = dir.iterate();
    while (entries.next(io) catch |err| {
        std.process.fatal("{s}: unable to list the directory: {t}", .{ dir_path, err });
    }) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        file_names.append(arena, b.dupe(entry.name)) catch @panic("OOM");
    }
    // A directory lists its entries in no fixed order. Sort them, so the
    // same files always give the same merged file.
    std.mem.sort([]const u8, file_names.items, {}, lessThan);

    var apps: std.json.Array = .init(arena);
    var parsed_apps: std.ArrayList(data.App) = .empty;
    for (file_names.items) |file_name| {
        const file_path = b.pathJoin(&.{ dir_path, file_name });
        b.dependOnFileContents(b.path(file_path));

        const json = dir.readFileAlloc(io, file_name, arena, .unlimited) catch |err| {
            std.process.fatal("{s}: unable to read the file: {t}", .{ file_path, err });
        };

        var scanner: std.json.Scanner = .initCompleteInput(arena, json);
        var diagnostics: std.json.Diagnostics = .{};
        scanner.enableDiagnostics(&diagnostics);
        var app = std.json.parseFromTokenSourceLeaky(std.json.Value, arena, &scanner, .{}) catch |err| {
            std.process.fatal("{s}:{d}:{d}: invalid JSON: {t}", .{
                file_path, diagnostics.getLine(), diagnostics.getColumn(), err,
            });
        };

        if (app != .object) {
            std.process.fatal("{s}: the top level must be an object", .{file_path});
        }
        if (app.object.contains("name")) {
            std.process.fatal("{s}: remove the `name` field, the file name is the name", .{file_path});
        }
        const name = file_name[0 .. file_name.len - ".json".len];
        app.object.put(arena, "name", .{ .string = name }) catch @panic("OOM");
        apps.append(app) catch @panic("OOM");

        // Parse into the same structs that the program uses. A wrong type,
        // a missing field or an unknown field stops the build here, not at
        // the first run of the program.
        const parsed = std.json.parseFromValueLeaky(data.App, arena, app, .{}) catch |err| {
            std.process.fatal("{s}: wrong shape: {t}. Compare the file with data/template.json", .{ file_path, err });
        };
        parsed_apps.append(arena, parsed) catch @panic("OOM");
    }

    var problem: check.Problem = .{};
    check.validate(arena, parsed_apps.items, platform, &problem) catch |err| switch (err) {
        error.OutOfMemory => @panic("OOM"),
        else => std.process.fatal("{s}/{s}.json: {t}{f}", .{ dir_path, problem.app, err, problem }),
    };

    const merged = std.json.Stringify.valueAlloc(arena, std.json.Value{ .array = apps }, .{}) catch @panic("OOM");
    return b.addWriteFiles().add(b.fmt("{t}.json", .{platform}), merged);
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}
