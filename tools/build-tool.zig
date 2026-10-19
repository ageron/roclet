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
fn artifactHash(io: std.Io, file: []const u8) !struct { bytes: u64, sha256: [64]u8 } {
    const f = try cwd.openFile(io, file, .{});
    defer f.close(io);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [64 * 1024]u8 = undefined;
    var size: u64 = 0;
    while (true) {
        const n = try f.readStreaming(io, &.{&buffer});
        if (n == 0) break;
        hasher.update(buffer[0..n]);
        size += n;
    }
    var hash: [32]u8 = undefined;
    hasher.final(&hash);
    return .{ .bytes = size, .sha256 = std.fmt.bytesToHex(hash, .lower) };
}
fn publish(gpa: Allocator, io: std.Io, root: []const u8, lock: Lock, binaries: []const []const u8) !void {
    try cwd.createDirPath(io, try path(gpa, root, "artifacts"));
    if (binaries.len < 2 or binaries.len > 4) return error.InvalidArguments;
    const native_mode = if (binaries.len >= 3) binaries[2] else lock.nativeOptimize;
    const wasm_mode = if (binaries.len == 4) binaries[3] else if (binaries.len == 3) binaries[2] else lock.wasmOptimize;
    try cwd.copyFile(binaries[0], cwd, try path(gpa, root, "artifacts/roclet-native"), io, .{});
    try cwd.copyFile(binaries[1], cwd, try path(gpa, root, "artifacts/roclet-profile.wasm"), io, .{});
    const wasm = try stripWasmDebug(gpa, try read(gpa, io, binaries[1]));
    defer gpa.free(wasm);
    try cwd.writeFile(io, .{ .sub_path = try path(gpa, root, "artifacts/roclet.wasm"), .data = wasm });
    var artifacts: std.json.ObjectMap = .empty;
    for ([_][]const u8{ "roclet-native", "roclet.wasm" }) |name| {
        const hash = try artifactHash(io, try path(gpa, root, try std.fmt.allocPrint(gpa, "artifacts/{s}", .{name})));
        var item: std.json.ObjectMap = .empty;
        try item.put(gpa, "bytes", .{ .integer = @intCast(hash.bytes) });
        try item.put(gpa, "sha256", .{ .string = try gpa.dupe(u8, &hash.sha256) });
        try artifacts.put(gpa, name, .{ .object = item });
    }
    var input_hashes: std.json.ObjectMap = .empty;
    for (inputs) |name| try input_hashes.put(gpa, name, .{ .string = try gpa.dupe(u8, &digest(try read(gpa, io, try path(gpa, root, name)))) });
    try writeJson(gpa, io, try path(gpa, root, "artifacts/manifest.json"), .{
        .protocol = lock.protocol,
        .compilerRepository = lock.compilerRepository,
        .compilerCommit = lock.compilerCommit,
        .zigVersion = lock.zigVersion,
        .nativeOptimize = native_mode,
        .wasmOptimize = wasm_mode,
        .host = @tagName(@import("builtin").os.tag) ++ "-" ++ @tagName(@import("builtin").cpu.arch),
        .inputs = std.json.Value{ .object = input_hashes },
        .artifacts = std.json.Value{ .object = artifacts },
    });
}
fn check(gpa: Allocator, io: std.Io, root: []const u8) !void {
    const bytes = read(gpa, io, try path(gpa, root, "artifacts/manifest.json")) catch {
        std.debug.print("Prepare the compiler with sh tools/prepare-compiler.sh /path/to/roc, then run zig build\n", .{});
        return error.MissingAdapter;
    };
    const manifest = try std.json.parseFromSliceLeaky(std.json.Value, gpa, bytes, .{});
    for (inputs) |name| {
        const expected = manifest.object.get("inputs").?.object.get(name) orelse return error.OutdatedAdapter;
        if (!std.mem.eql(u8, expected.string, &digest(try read(gpa, io, try path(gpa, root, name))))) {
            std.debug.print("Adapter inputs changed ({s}); rebuild with zig build\n", .{name});
            return error.OutdatedAdapter;
        }
    }
    var it = manifest.object.get("artifacts").?.object.iterator();
    while (it.next()) |entry| {
        const file = try path(gpa, root, try std.fmt.allocPrint(gpa, "artifacts/{s}", .{entry.key_ptr.*}));
        if (!std.mem.eql(u8, entry.value_ptr.object.get("sha256").?.string, &(try artifactHash(io, file)).sha256)) return error.ArtifactHashMismatch;
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

// Keep full DWARF in the adjacent profiling artifact; browsers load only code,
// data and function names. This does not require an external wasm-strip tool.
fn readLeb(bytes: []const u8, at: *usize) !u32 {
    var result: u32 = 0;
    var shift: u5 = 0;
    for (0..5) |i| {
        if (at.* == bytes.len) return error.InvalidWasm;
        const byte = bytes[at.*];
        at.* += 1;
        if (i == 4 and byte > 15) return error.InvalidWasm;
        result |= @as(u32, byte & 127) << shift;
        if (byte < 128) return result;
        if (i < 4) shift += 7;
    }
    return error.InvalidWasm;
}
fn stripWasmDebug(a: Allocator, bytes: []const u8) ![]u8 {
    if (bytes.len < 8 or !std.mem.eql(u8, bytes[0..8], "\x00asm\x01\x00\x00\x00")) return error.InvalidWasm;
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    try out.writer.writeAll(bytes[0..8]);
    var at: usize = 8;
    while (at < bytes.len) {
        const start = at;
        const kind = bytes[at];
        at += 1;
        const size: usize = try readLeb(bytes, &at);
        if (size > bytes.len - at) return error.InvalidWasm;
        const end = at + size;
        var skip = false;
        if (kind == 0) {
            const name_len: usize = try readLeb(bytes[0..end], &at);
            if (name_len > end - at) return error.InvalidWasm;
            skip = std.mem.startsWith(u8, bytes[at..][0..name_len], ".debug_");
        }
        if (!skip) try out.writer.writeAll(bytes[start..end]);
        at = end;
    }
    return out.toOwnedSlice();
}
test "WASM publication removes DWARF but keeps named code" {
    const input = "\x00asm\x01\x00\x00\x00" ++ "\x00\x0a\x08.debug_x!" ++ "\x00\x06\x04name!";
    const output = try stripWasmDebug(std.testing.allocator, input);
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("\x00asm\x01\x00\x00\x00\x00\x06\x04name!", output);
}
