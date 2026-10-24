//! Run checked-in notebooks with ordinary Roc, outside the notebook adapter.
const std = @import("std");
pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    const root = args[1];
    const roc = args[2];
    const url = std.mem.trim(u8, try std.Io.Dir.cwd().readFileAlloc(init.io, try std.fs.path.join(a, &.{ root, "package/display-package-url.txt" }), a, .limited(1024)), "\r\n");
    const package = try std.fs.path.join(a, &.{ root, "package/main.roc" });
    const bundle_dir = try std.fs.path.join(a, &.{ root, "artifacts/display-package-test" });
    try std.Io.Dir.cwd().createDirPath(init.io, bundle_dir);
    const bundled = try std.process.run(a, init.io, .{ .argv = &.{ roc, "bundle", package, "--output-dir", bundle_dir }, .stdout_limit = .limited(1024 * 1024), .stderr_limit = .limited(1024 * 1024) });
    if (bundled.term != .exited or bundled.term.exited != 0) return error.PackageBuildFailed;
    var lines = std.mem.splitScalar(u8, bundled.stdout, '\n');
    var archive_path: ?[]const u8 = null;
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "Created: ")) archive_path = std.mem.trim(u8, line[9..], "\r");
    }
    // Roc may print a path relative to the project, but unbundle runs elsewhere.
    const archive = try std.fs.path.resolve(a, &.{ root, archive_path orelse return error.MissingBundle });
    const basename = std.fs.path.basename(archive);
    const extracted = try std.fs.path.join(a, &.{ bundle_dir, basename[0 .. basename.len - ".tar.zst".len] });
    // This directory contains only this test's generated extraction.
    try std.Io.Dir.cwd().deleteTree(init.io, extracted);
    const unpacked = try std.process.run(a, init.io, .{ .argv = &.{ roc, "unbundle", archive }, .cwd = .{ .path = bundle_dir }, .stdout_limit = .limited(1024 * 1024), .stderr_limit = .limited(1024 * 1024) });
    if (unpacked.term != .exited or unpacked.term.exited != 0) return error.PackageExtractionFailed;
    const bundled_package = try std.fs.path.join(a, &.{ extracted, "main.roc" });
    inline for (.{ "Display.roc", "Input.roc", "InputValues.roc", "main.roc" }) |name| {
        const from_archive = try std.Io.Dir.cwd().readFileAlloc(init.io, try std.fs.path.join(a, &.{ extracted, name }), a, .limited(1024 * 1024));
        const from_source = try std.Io.Dir.cwd().readFileAlloc(init.io, try std.fs.path.join(a, &.{ root, "package", name }), a, .limited(1024 * 1024));
        if (!std.mem.eql(u8, from_archive, from_source)) return error.StaleDisplayPackage;
    }
    // CI publishes precisely this archive, not a glob which might include old builds.
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = try std.fs.path.join(a, &.{ bundle_dir, "tested-bundle.txt" }), .data = archive });
    std.debug.print("PASS extracted Display archive matches its sources\n", .{});
    for ([_][]const u8{ "demos/01-reactivity.roc", "demos/02-coding-puzzle.roc", "fixtures/documents/rich-outputs.roc", "fixtures/documents/wall.roc" }) |file| {
        const path = try std.fs.path.join(a, &.{ root, file });
        const source = try std.Io.Dir.cwd().readFileAlloc(init.io, path, a, .limited(256 * 1024));
        const argv: []const []const u8 = if (std.mem.find(u8, source, url) != null) &.{ roc, "--replace-dep", url, bundled_package, path } else &.{ roc, path };
        const result = try std.process.run(a, init.io, .{ .argv = argv, .stdout_limit = .limited(1024 * 1024), .stderr_limit = .limited(1024 * 1024), .timeout = .{ .duration = .{ .raw = .fromSeconds(120), .clock = .awake } } });
        if (result.term != .exited or result.term.exited != 0 or (result.stdout.len == 0 and !std.mem.eql(u8, file, "demos/02-coding-puzzle.roc"))) {
            std.debug.print("FAIL ordinary Roc: {s}\n{s}\n{s}\n", .{ file, result.stdout, result.stderr });
            return error.DemoFailed;
        }
        std.debug.print("PASS ordinary Roc: {s}\n", .{file});
    }
}
