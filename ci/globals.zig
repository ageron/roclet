//! Globals gate: compiler-adapter state belongs to an `Engine`, a request's
//! `ResponseBuilder` or a local. Only the declarations listed in `permitted`
//! may be module-level mutable variables in `compiler-adapter/*.zig`.
const std = @import("std");

const Permitted = struct { file: []const u8, name: []const u8, reason: []const u8 };

/// Keep in sync with "Engine instances and process-wide state" in
/// compiler-adapter/README.md.
const permitted = [_]Permitted{
    .{ .file = "platform.zig", .name = "active_roc_ops", .reason = "hosted functions receive no RocOps or environment pointer" },
    .{ .file = "engine.zig", .name = "builtin_modules", .reason = "immutable decoded builtins, borrowed by every BuildEnv" },
    .{ .file = "bridge.zig", .name = "wasm_engine", .reason = "the WASM worker's single Engine instance" },
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var dir = try std.Io.Dir.cwd().openDir(io, "compiler-adapter", .{ .iterate = true });
    defer dir.close(io);
    var failures: usize = 0;
    var seen: [permitted.len]bool = @splat(false);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".zig")) continue;
        const text = try dir.readFileAlloc(io, entry.name, gpa, .limited(16 * 1024 * 1024));
        defer gpa.free(text);
        var lines = std.mem.splitScalar(u8, text, '\n');
        var line_number: usize = 0;
        while (lines.next()) |line| {
            line_number += 1;
            const name = declaredVariable(line) orelse continue;
            if (permittedIndex(entry.name, name)) |index| {
                seen[index] = true;
                continue;
            }
            std.debug.print("compiler-adapter/{s}:{d}: error: module-level `var {s}`; move it onto Engine, ResponseBuilder or a local\n", .{ entry.name, line_number, name });
            failures += 1;
        }
    }
    for (permitted, seen) |item, found| if (!found) {
        std.debug.print("ci/globals.zig: error: permitted global {s} in compiler-adapter/{s} no longer exists; remove it from the list\n", .{ item.name, item.file });
        failures += 1;
    };
    if (failures != 0) std.process.exit(1);
}

fn declaredVariable(line: []const u8) ?[]const u8 {
    const rest = if (std.mem.startsWith(u8, line, "pub var ")) line["pub var ".len..] else if (std.mem.startsWith(u8, line, "var ")) line["var ".len..] else return null;
    const end = std.mem.findAny(u8, rest, ": =") orelse rest.len;
    return rest[0..end];
}

fn permittedIndex(file: []const u8, name: []const u8) ?usize {
    for (permitted, 0..) |item, i| if (std.mem.eql(u8, item.file, file) and std.mem.eql(u8, item.name, name)) return i;
    return null;
}

test "declaredVariable recognises top-level mutable declarations only" {
    try std.testing.expectEqualStrings("active_roc_ops", declaredVariable("var active_roc_ops: ?*T = null;").?);
    try std.testing.expectEqualStrings("global", declaredVariable("pub var global: Workspace = .{};").?);
    try std.testing.expect(declaredVariable("    var local = 1;") == null);
    try std.testing.expect(declaredVariable("pub const identity = \"x\";") == null);
}
