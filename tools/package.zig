//! Deterministic offline manifests and portable distributions; no package manager.
const std = @import("std");
const cwd = std.Io.Dir.cwd();
const Asset = struct { path: []const u8, bytes: usize, sha256: []const u8 };
const File = struct { path: []const u8, data: []const u8 };
fn hash(gpa: std.mem.Allocator, data: []const u8) ![]const u8 {
    var bytes: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &bytes, .{});
    return gpa.dupe(u8, &std.fmt.bytesToHex(bytes, .lower));
}
fn json(gpa: std.mem.Allocator, value: anytype) ![]const u8 {
    var w: std.Io.Writer.Allocating = .init(gpa);
    try std.json.Stringify.value(value, .{}, &w.writer);
    return w.toOwnedSlice();
}
fn read(gpa: std.mem.Allocator, io: std.Io, root: []const u8, relative: []const u8) ![]const u8 {
    return cwd.readFileAlloc(io, try std.fs.path.join(gpa, &.{ root, relative }), gpa, .limited(64 * 1024 * 1024));
}
fn write(gpa: std.mem.Allocator, io: std.Io, root: []const u8, relative: []const u8, bytes: []const u8) !void {
    const path = try std.fs.path.join(gpa, &.{ root, relative });
    try cwd.createDirPath(io, std.fs.path.dirname(path).?);
    try cwd.writeFile(io, .{ .sub_path = path, .data = bytes });
}
fn archive(gpa: std.mem.Allocator, files: []const File) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    var directory: std.Io.Writer.Allocating = .init(gpa);
    for (files) |file| {
        const offset = out.written().len;
        const crc = std.hash.Crc32.hash(file.data);
        var local: [30]u8 = @splat(0);
        std.mem.writeInt(u32, local[0..4], 0x04034b50, .little);
        std.mem.writeInt(u16, local[4..6], 20, .little);
        std.mem.writeInt(u16, local[6..8], 0x800, .little);
        std.mem.writeInt(u32, local[14..18], crc, .little);
        std.mem.writeInt(u32, local[18..22], @intCast(file.data.len), .little);
        std.mem.writeInt(u32, local[22..26], @intCast(file.data.len), .little);
        std.mem.writeInt(u16, local[26..28], @intCast(file.path.len), .little);
        try out.writer.writeAll(&local);
        try out.writer.writeAll(file.path);
        try out.writer.writeAll(file.data);
        var entry: [46]u8 = @splat(0);
        std.mem.writeInt(u32, entry[0..4], 0x02014b50, .little);
        std.mem.writeInt(u16, entry[4..6], 0x314, .little); // Unix creator; executables remain executable.
        std.mem.writeInt(u16, entry[6..8], 20, .little);
        std.mem.writeInt(u16, entry[8..10], 0x800, .little);
        std.mem.writeInt(u32, entry[16..20], crc, .little);
        std.mem.writeInt(u32, entry[20..24], @intCast(file.data.len), .little);
        std.mem.writeInt(u32, entry[24..28], @intCast(file.data.len), .little);
        std.mem.writeInt(u16, entry[28..30], @intCast(file.path.len), .little);
        const executable = std.mem.eql(u8, file.path, "roclet") or std.mem.eql(u8, file.path, "roclet-serve");
        std.mem.writeInt(u32, entry[38..42], @as(u32, if (executable) 0o100755 else 0o100644) << 16, .little);
        std.mem.writeInt(u32, entry[42..46], @intCast(offset), .little);
        try directory.writer.writeAll(&entry);
        try directory.writer.writeAll(file.path);
    }
    const offset = out.written().len;
    try out.writer.writeAll(directory.written());
    var end: [22]u8 = @splat(0);
    std.mem.writeInt(u32, end[0..4], 0x06054b50, .little);
    std.mem.writeInt(u16, end[8..10], @intCast(files.len), .little);
    std.mem.writeInt(u16, end[10..12], @intCast(files.len), .little);
    std.mem.writeInt(u32, end[12..16], @intCast(directory.written().len), .little);
    std.mem.writeInt(u32, end[16..20], @intCast(offset), .little);
    try out.writer.writeAll(&end);
    return out.toOwnedSlice();
}
pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(a);
    if (args.len < 2 or args.len > 3) return error.ExpectedRootAndOptionalPackage;
    const root = args[1];
    try write(a, io, root, "web/vendor/md4c.LICENSE.md", try read(a, io, root, "vendor/md4c/LICENSE.md"));
    var paths: std.ArrayList([]const u8) = .empty;
    for ([_][]const u8{
        "web/studio.html",             "web/studio.mjs",              "web/studio-model.mjs",     "web/compiler-tools.mjs",   "web/studio-store.mjs",                "web/studio-cells.mjs",
        "web/cell-editor.mjs",         "web/editor-navigation.mjs",   "web/roc-highlighting.mjs", "web/document-session.mjs", "web/format-worker.mjs",               "web/markdown-view.mjs",
        "web/archive.mjs",             "web/sharing.mjs",             "web/offline.mjs",          "web/offline-cache.mjs",    "web/offline-runtime.mjs",             "web/formats.html",
        "web/formats.mjs",             "compiler-adapter/wasm.mjs",   "artifacts/roclet.wasm",    "artifacts/manifest.json",  "compiler-adapter/ROC-LICENSE",        "web/vendor/md4c.LICENSE.md",
        "web/math-view.mjs", "web/vendor/katex/katex.mjs", "web/vendor/katex/katex.css", "web/vendor/katex/LICENSE", "web/vendor/katex/README.md", "web/vendor/katex/lock.json",
        "web/vendor/editor/lock.json", "web/vendor/editor/README.md", "web/display-view.mjs",     "library/Display.roc",      "fixtures/documents/rich-outputs.roc",
    }) |path| try paths.append(a, path);
    const lock = try std.json.parseFromSliceLeaky(std.json.Value, a, try read(a, io, root, "web/vendor/editor/lock.json"), .{});
    for (lock.object.get("packages").?.array.items) |package| {
        for ([_][]const u8{ "file", "licenseFile" }) |field| try paths.append(a, try std.fmt.allocPrint(a, "web/vendor/editor/{s}", .{package.object.get(field).?.string}));
    }
    var assets: std.ArrayList(Asset) = .empty;
    var files: std.ArrayList(File) = .empty;
    for (paths.items) |path| {
        const data = try read(a, io, root, path);
        try files.append(a, .{ .path = path, .data = data });
        try assets.append(a, .{ .path = if (std.mem.startsWith(u8, path, "web/")) path[4..] else try std.mem.concat(a, u8, &.{ "../", path }), .bytes = data.len, .sha256 = try hash(a, data) });
    }
    const release = try json(a, .{ .schema = 1, .version = try hash(a, try json(a, assets.items)), .assets = assets.items });
    const worker = try std.mem.concat(a, u8, &.{ "import {installOffline} from './offline-runtime.mjs';\ninstallOffline(", release, ");\n" });
    try write(a, io, root, "web/offline-release.json", release);
    try write(a, io, root, "web/offline-worker.mjs", worker);
    try files.append(a, .{ .path = "web/offline-release.json", .data = release });
    try files.append(a, .{ .path = "web/offline-worker.mjs", .data = worker });
    if (args.len == 3 and std.mem.eql(u8, args[2], "package")) {
        const instructions = "Roclet offline distribution\n\nServe this directory over HTTPS or localhost. With the included host-platform server:\n  ./roclet-serve . 4173\nThen open http://127.0.0.1:4173/web/studio.html\nChoose File > Offline & storage > Prepare for offline use before disconnecting.\nNo Node, npm, Python, external CDN or account is required.\n\nHeadless runner (host platform): ./roclet run notebook.roc (or notebook.md).\nJSON stdout uses the same core and evaluation contract as the browser. Exit 1 means diagnostics/failure; 0 means success. Bound execution time in your job supervisor for untrusted/nonterminating programs. Imports remain limited to the pinned adapter capabilities.\nThe native binary is specific to the platform in artifacts/manifest.json.\n\nRoclet project licensing must be decided before public redistribution. Third-party notices are included.\n";
        try files.append(a, .{ .path = "README.txt", .data = instructions });
        try files.append(a, .{ .path = "roclet-serve", .data = try read(a, io, root, "zig-out/bin/roclet-serve") });
        const distribution = try archive(a, files.items);
        try write(a, io, root, "zig-out/roclet.zip", distribution);
        var runner: std.ArrayList(File) = .empty;
        try runner.append(a, .{ .path = "roclet", .data = try read(a, io, root, "artifacts/roclet-native") });
        try runner.append(a, .{ .path = "README.txt", .data = instructions });
        for ([_][]const u8{ "artifacts/manifest.json", "compiler-adapter/ROC-LICENSE", "vendor/md4c/LICENSE.md" }) |path| try runner.append(a, .{ .path = path, .data = try read(a, io, root, path) });
        try write(a, io, root, "zig-out/roclet-headless.zip", try archive(a, runner.items));
        std.debug.print("Packaged zig-out/roclet.zip and zig-out/roclet-headless.zip\n", .{});
    }
    std.debug.print("Offline release: {d} verified assets\n", .{assets.items.len});
}
