//! Prepare a pinned compiler snapshot without modifying the supplied checkout.
const std = @import("std");
const Allocator = std.mem.Allocator;
const cwd = std.Io.Dir.cwd();
const inputs = [_][]const u8{ "build.zig", "build.zig.zon", "tools/prepare-compiler.sh", "compiler-adapter/embedding.patch", "compiler-adapter/engine.zig", "compiler-adapter/workspace.zig", "compiler-adapter/platform.zig", "compiler-adapter/platform/main.roc", "compiler-adapter/platform/Echo.roc", "tools/build-tool.zig", "compiler.lock.json", "compiler-adapter/bridge.zig", "compiler-adapter/native.zig", "compiler-adapter/snapshot.zig", "compiler-adapter/syntax.zig", "compiler-adapter/document.zig", "compiler-adapter/document_frontend.zig", "core/Document.roc", "library/Display.roc", "vendor/md4c/md4c.c", "vendor/md4c/md4c.h", "vendor/md4c/roclet-md.h" };
const Lock = struct { protocol: u32, compilerRepository: []const u8, compilerCommit: []const u8, zigVersion: []const u8, nativeOptimize: []const u8, wasmOptimize: []const u8 };
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
fn publish(gpa: Allocator, io: std.Io, root: []const u8, lock: Lock, binaries: []const []const u8) !void {
    try cwd.createDirPath(io, try path(gpa, root, "artifacts"));
    if (binaries.len != 2 and binaries.len != 3) return error.InvalidArguments;
    const mode = if (binaries.len == 3) binaries[2] else lock.nativeOptimize;
    try cwd.copyFile(binaries[0], cwd, try path(gpa, root, "artifacts/roclet-native"), io, .{});
    try cwd.copyFile(binaries[1], cwd, try path(gpa, root, "artifacts/roclet.wasm"), io, .{});
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
        .nativeOptimize = mode,
        .wasmOptimize = mode,
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
    if (std.mem.eql(u8, args[1], "publish")) return publish(gpa, init.io, root, lock, args[3..]);
    if (std.mem.eql(u8, args[1], "check")) return check(gpa, init.io, root);
    return error.InvalidArguments;
}
