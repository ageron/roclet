//! Prepare a pinned compiler snapshot without modifying the supplied checkout.
const std = @import("std");
const Allocator = std.mem.Allocator;
const cwd = std.Io.Dir.cwd();
const inputs = [_][]const u8{ "build.zig", "tools/build-tool.zig", "compiler.lock.json", "compiler-adapter/bridge.zig", "compiler-adapter/native.zig", "compiler-adapter/snapshot.zig", "compiler-adapter/overlay.json", "compiler-adapter/syntax.zig", "compiler-adapter/document.zig", "core/Document.roc", "package/Display.roc", "package/display-package-url.txt", "vendor/md4c/md4c.c", "vendor/md4c/md4c.h", "vendor/md4c/roclet-md.h" };
const Lock = struct { protocol: u32, compilerRepository: []const u8, compilerCommit: []const u8, zigVersion: []const u8, nativeOptimize: []const u8, wasmOptimize: []const u8 };
const Patch = struct { path: []const u8, before: []const u8, after: []const u8 };
fn path(gpa: Allocator, root: []const u8, relative: []const u8) ![]const u8 {
    return std.fs.path.join(gpa, &.{ root, relative });
}
fn read(gpa: Allocator, io: std.Io, file: []const u8) ![]u8 {
    return cwd.readFileAlloc(io, file, gpa, .limited(256 * 1024 * 1024));
}
fn digest(bytes: []const u8) [64]u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    return std.fmt.bytesToHex(hash, .lower);
}
fn writeJson(gpa: Allocator, io: std.Io, file: []const u8, value: anytype) !void {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try std.json.Stringify.value(value, .{ .whitespace = .indent_2 }, &out.writer);
    try out.writer.writeByte('\n');
    try cwd.writeFile(io, .{ .sub_path = file, .data = out.written() });
}
fn command(io: std.Io, argv: []const []const u8) !void {
    var child = try std.process.spawn(io, .{ .argv = argv });
    const term = try child.wait(io);
    if (term != .exited or term.exited != 0) return error.CommandFailed;
}
fn fingerprint(gpa: Allocator, io: std.Io, root: []const u8) ![64]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    for (inputs) |name| {
        hash.update(name);
        const bytes = try read(gpa, io, try path(gpa, root, name));
        hash.update(&digest(bytes));
    }
    var result: [32]u8 = undefined;
    hash.final(&result);
    return std.fmt.bytesToHex(result, .lower);
}
fn replaceOnce(gpa: Allocator, source: []const u8, before: []const u8, after: []const u8) ![]u8 {
    if (before.len == 0) return error.EmptyPatch;
    const at = std.mem.find(u8, source, before) orelse return error.CompilerSourceDrift;
    if (std.mem.find(u8, source[at + before.len ..], before) != null) return error.AmbiguousCompilerPatch;
    return std.mem.concat(gpa, u8, &.{ source[0..at], after, source[at + before.len ..] });
}
fn prepare(gpa: Allocator, io: std.Io, root: []const u8, checkout: []const u8, lock: Lock) !void {
    const source = try path(gpa, root, ".toolchain/compiler");
    const stamp = try path(gpa, source, ".roclet-inputs");
    const key = try fingerprint(gpa, io, root);
    const old = read(gpa, io, stamp) catch "";
    if (std.mem.eql(u8, old, &key)) {
        try std.Io.File.stderr().writeStreamingAll(io, "Compiler overlay unchanged; reusing prepared source and build cache.\n");
        return;
    }
    const staging = try path(gpa, root, ".toolchain/preparing");
    try cwd.deleteTree(io, staging);
    try cwd.createDirPath(io, staging);
    defer cwd.deleteTree(io, staging) catch {};
    const archive = try path(gpa, root, ".toolchain/compiler.tar");
    defer cwd.deleteFile(io, archive) catch {};
    try command(io, &.{ "git", "-C", checkout, "archive", "--format=tar", "-o", archive, lock.compilerCommit });
    try command(io, &.{ "tar", "-xf", archive, "-C", staging });
    const overlay = try read(gpa, io, try path(gpa, root, "compiler-adapter/overlay.json"));
    const patches = try std.json.parseFromSliceLeaky([]const Patch, gpa, overlay, .{});
    for (patches) |patch| {
        const file = try path(gpa, staging, patch.path);
        const original = try read(gpa, io, file);
        const edited = replaceOnce(gpa, original, patch.before, patch.after) catch |err| {
            std.debug.print("Compiler overlay failed in {s}: {s}\n", .{ patch.path, @errorName(err) });
            return err;
        };
        try cwd.writeFile(io, .{ .sub_path = file, .data = edited });
    }
    const copies = .{
        .{ "bridge.zig", "roclet.zig" }, .{ "native.zig", "roclet_native.zig" }, .{ "snapshot.zig", "roclet_snapshot.zig" }, .{ "syntax.zig", "roclet_syntax.zig" }, .{ "document.zig", "roclet_document.zig" },
    };
    inline for (copies) |copy| try cwd.copyFile(try path(gpa, root, "compiler-adapter/" ++ copy[0]), cwd, try path(gpa, staging, "src/echo_platform/" ++ copy[1]), io, .{});
    try cwd.copyFile(try path(gpa, root, "core/Document.roc"), cwd, try path(gpa, staging, "src/echo_platform/Document.roc"), io, .{});
    try cwd.copyFile(try path(gpa, root, "package/Display.roc"), cwd, try path(gpa, staging, "src/echo_platform/Display.roc"), io, .{});
    try cwd.copyFile(try path(gpa, root, "package/display-package-url.txt"), cwd, try path(gpa, staging, "src/echo_platform/display-package-url.txt"), io, .{});
    inline for (.{ "md4c.c", "md4c.h", "roclet-md.h" }) |file| try cwd.copyFile(try path(gpa, root, "vendor/md4c/" ++ file), cwd, try path(gpa, staging, "src/echo_platform/" ++ file), io, .{});
    // Preserve downloaded packages and compiler caches when updating the overlay.
    for ([_][]const u8{ ".zig-cache", "zig-pkg" }) |cache| {
        cwd.rename(try path(gpa, source, cache), cwd, try path(gpa, staging, cache), io) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }
    try cwd.writeFile(io, .{ .sub_path = try path(gpa, staging, ".roclet-inputs"), .data = &key });
    try cwd.deleteTree(io, source);
    try cwd.rename(staging, cwd, source, io);
    try std.Io.File.stderr().writeStreamingAll(io, "Prepared pinned compiler with exact-match Roclet overlay.\n");
}
fn publish(gpa: Allocator, io: std.Io, root: []const u8, lock: Lock) !void {
    const prepared = try read(gpa, io, try path(gpa, root, ".toolchain/compiler/.roclet-inputs"));
    if (!std.mem.eql(u8, prepared, &try fingerprint(gpa, io, root))) return error.InputsChangedDuringBuild;
    try cwd.createDirPath(io, try path(gpa, root, "artifacts"));
    const native_source = ".toolchain/compiler/zig-out/bin/echo_native" ++ comptime @import("builtin").target.exeFileExt();
    try cwd.copyFile(try path(gpa, root, native_source), cwd, try path(gpa, root, "artifacts/roclet-native"), io, .{});
    try cwd.copyFile(try path(gpa, root, ".toolchain/compiler/zig-out/lib/echo/echo.wasm"), cwd, try path(gpa, root, "artifacts/roclet.wasm"), io, .{});
    var artifacts: std.json.ObjectMap = .empty;
    for ([_][]const u8{ "roclet-native", "roclet.wasm" }) |name| {
        const bytes = try read(gpa, io, try path(gpa, root, try std.fmt.allocPrint(gpa, "artifacts/{s}", .{name})));
        var item: std.json.ObjectMap = .empty;
        try item.put(gpa, "bytes", .{ .integer = @intCast(bytes.len) });
        try item.put(gpa, "sha256", .{ .string = try gpa.dupe(u8, &digest(bytes)) });
        try artifacts.put(gpa, name, .{ .object = item });
    }
    var input_hashes: std.json.ObjectMap = .empty;
    for (inputs) |name| try input_hashes.put(gpa, name, .{ .string = try gpa.dupe(u8, &digest(try read(gpa, io, try path(gpa, root, name)))) });
    try writeJson(gpa, io, try path(gpa, root, "artifacts/manifest.json"), .{
        .protocol = lock.protocol,
        .compilerRepository = lock.compilerRepository,
        .compilerCommit = lock.compilerCommit,
        .zigVersion = lock.zigVersion,
        .nativeOptimize = lock.nativeOptimize,
        .wasmOptimize = lock.wasmOptimize,
        .host = @tagName(@import("builtin").os.tag) ++ "-" ++ @tagName(@import("builtin").cpu.arch),
        .inputs = std.json.Value{ .object = input_hashes },
        .artifacts = std.json.Value{ .object = artifacts },
    });
}
fn check(gpa: Allocator, io: std.Io, root: []const u8) !void {
    const bytes = read(gpa, io, try path(gpa, root, "artifacts/manifest.json")) catch {
        std.debug.print("Build the adapter first: zig build -Droc-source=/path/to/roc\n", .{});
        return error.MissingAdapter;
    };
    const manifest = try std.json.parseFromSliceLeaky(std.json.Value, gpa, bytes, .{});
    for (inputs) |name| {
        const expected = manifest.object.get("inputs").?.object.get(name) orelse return error.OutdatedAdapter;
        if (!std.mem.eql(u8, expected.string, &digest(try read(gpa, io, try path(gpa, root, name))))) {
            std.debug.print("Adapter inputs changed ({s}); rebuild with -Droc-source=/path/to/roc\n", .{name});
            return error.OutdatedAdapter;
        }
    }
    var it = manifest.object.get("artifacts").?.object.iterator();
    while (it.next()) |entry| {
        const file = try path(gpa, root, try std.fmt.allocPrint(gpa, "artifacts/{s}", .{entry.key_ptr.*}));
        if (!std.mem.eql(u8, entry.value_ptr.object.get("sha256").?.string, &digest(try read(gpa, io, file)))) return error.ArtifactHashMismatch;
    }
}
pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const args = try init.minimal.args.toSlice(gpa);
    if (args.len < 3) return error.InvalidArguments;
    const root = args[2];
    const lock = try std.json.parseFromSliceLeaky(Lock, gpa, try read(gpa, init.io, try path(gpa, root, "compiler.lock.json")), .{});
    if (std.mem.eql(u8, args[1], "prepare") and args.len == 4) return prepare(gpa, init.io, root, args[3], lock);
    if (std.mem.eql(u8, args[1], "publish")) return publish(gpa, init.io, root, lock);
    if (std.mem.eql(u8, args[1], "check")) return check(gpa, init.io, root);
    return error.InvalidArguments;
}
test "overlay rejects missing and ambiguous source anchors" {
    try std.testing.expectError(error.CompilerSourceDrift, replaceOnce(std.testing.allocator, "abc", "d", "x"));
    try std.testing.expectError(error.AmbiguousCompilerPatch, replaceOnce(std.testing.allocator, "abcabc", "abc", "x"));
    const result = try replaceOnce(std.testing.allocator, "before target after", "target", "replacement");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("before replacement after", result);
}
