//! Local project API. Paths are relative to an explicitly selected directory.
const std = @import("std");
const A = std.mem.Allocator;
const Io = std.Io;
pub const Project = struct {
    root: []const u8,
    token: []const u8,
    host: []const u8,
    any_address: bool = false,
    initial: ?[]const u8 = null,
    mutex: Io.Mutex = .init,
};
pub fn validPath(path: []const u8) bool {
    if (path.len == 0 or path.len > 480) return false;
    for (path) |c| if (c < 32 or c == 127 or c == '\\' or c == ':') return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| if (part.len == 0 or part[0] == '.') return false;
    return true;
}
fn notebook(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".roc") or std.mem.endsWith(u8, path, ".md");
}
fn header(r: *std.http.Server.Request, name: []const u8) ?[]const u8 {
    var it = r.iterateHeaders();
    while (it.next()) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
    return null;
}
pub fn trusted(r: *std.http.Server.Request, p: *Project, a: A) !bool {
    const host = header(r, "Host") orelse return false;
    if (!allowedHost(p, host)) return false;
    if (header(r, "Sec-Fetch-Site")) |site| if (!std.mem.eql(u8, site, "same-origin") and !std.mem.eql(u8, site, "none")) return false;
    if (header(r, "Origin")) |origin| if (!std.mem.eql(u8, origin, try std.fmt.allocPrint(a, "http://{s}", .{host}))) return false;
    return true;
}
fn reply(r: *std.http.Server.Request, a: A, status: std.http.Status, value: anytype) !void {
    var w: Io.Writer.Allocating = .init(a);
    try std.json.Stringify.value(value, .{}, &w.writer);
    try r.respond(w.written(), .{ .status = status, .keep_alive = false, .extra_headers = &.{
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "Cache-Control", .value = "no-store" },
        .{ .name = "X-Content-Type-Options", .value = "nosniff" },
    } });
}
// Walk each parent through a directory handle, never following symlinks.
fn parent(io: Io, root: []const u8, path: []const u8) !Io.Dir {
    if (!validPath(path)) return error.InvalidPath;
    var dir = try Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    errdefer dir.close(io);
    if (std.fs.path.dirname(path)) |parents| {
        var parts = std.mem.splitScalar(u8, parents, '/');
        while (parts.next()) |part| {
            const next = try dir.openDir(io, part, .{ .iterate = true, .follow_symlinks = false });
            dir.close(io);
            dir = next;
        }
    }
    return dir;
}
fn read(io: Io, a: A, dir: Io.Dir, name: []const u8) ![]const u8 {
    const stat = try dir.statFile(io, name, .{ .follow_symlinks = false });
    if (stat.kind != .file) return error.NotRegularFile;
    const file = try dir.openFile(io, name, .{ .allow_directory = false });
    defer file.close(io);
    // Check the opened descriptor too: a symlink swapped in after stat must
    // never grant access to another file.
    var actual: [std.fs.max_path_bytes]u8 = undefined;
    const length = try file.realPath(io, &actual);
    const directory = try dir.realPathFileAlloc(io, ".", a);
    const expected = try std.fs.path.join(a, &.{ directory, name });
    if (!std.mem.eql(u8, actual[0..length], expected)) return error.NotRegularFile;
    var buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &buffer);
    const bytes = try reader.interface.allocRemaining(a, .limited(16 * 1024 * 1024));
    if (!std.unicode.utf8ValidateSlice(bytes) or std.mem.findScalar(u8, bytes, 0) != null) return error.NotTextFile;
    return bytes;
}
const Source = struct { path: []const u8, source: []const u8 };
fn skip(name: []const u8) bool {
    return name.len == 0 or name[0] == '.' or std.mem.eql(u8, name, "node_modules") or std.mem.eql(u8, name, "zig-out") or std.mem.eql(u8, name, "zig-pkg");
}
fn scan(io: Io, a: A, dir: Io.Dir, prefix: []const u8, excluded: []const u8, paths: *std.ArrayList([]const u8), sources: ?*std.ArrayList(Source), total: *usize, visited: *usize) anyerror!void {
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        visited.* += 1;
        if (visited.* > 10000) return error.ProjectTooLarge;
        if (skip(entry.name)) continue;
        const path = try std.mem.concat(a, u8, &.{ prefix, entry.name });
        if (!validPath(path)) continue;
        if (entry.kind == .directory) {
            if (std.mem.count(u8, path, "/") >= 16) continue;
            var child = try dir.openDir(io, entry.name, .{ .iterate = true, .follow_symlinks = false });
            defer child.close(io);
            try scan(io, a, child, try std.mem.concat(a, u8, &.{ path, "/" }), excluded, paths, sources, total, visited);
        } else if (entry.kind == .file) {
            if (sources) |files| {
                if (std.mem.eql(u8, path, excluded) or std.mem.eql(u8, path, "Main.roc") or std.mem.eql(u8, path, "main.roc")) continue;
                const bytes = read(io, a, dir, entry.name) catch |err| switch (err) {
                    error.NotTextFile => continue,
                    error.StreamTooLong => continue,
                    else => return err,
                };
                total.* += bytes.len;
                if (total.* > 16 * 1024 * 1024 or files.items.len >= 256) return error.ProjectTooLarge;
                try files.append(a, .{ .path = path, .source = bytes });
            } else if (notebook(path)) {
                const source = read(io, a, dir, entry.name) catch |err| switch (err) {
                    error.NotTextFile, error.StreamTooLong => continue,
                    else => return err,
                };
                if (source.len > 256 * 1024) continue;
                if (std.mem.endsWith(u8, path, ".roc")) {
                    var lines = std.mem.splitScalar(u8, source, '\n');
                    var module_file = false;
                    while (lines.next()) |line| {
                        const text = std.mem.trim(u8, line, " \t\r");
                        if (text.len == 0 or text[0] == '#') continue;
                        module_file = std.mem.startsWith(u8, text, "module ") or std.mem.startsWith(u8, text, "package ") or std.mem.startsWith(u8, text, "platform ");
                        break;
                    }
                    if (module_file) continue;
                }
                if (paths.items.len >= 2000) return error.ProjectTooLarge;
                try paths.append(a, path);
            }
        }
    }
}
const Input = struct { action: []const u8, path: []const u8 = "", source: ?[]const u8 = null, expected: ?[]const u8 = null };
fn execute(r: *std.http.Server.Request, p: *Project, io: Io, a: A, input: Input) !void {
    if (std.mem.eql(u8, input.action, "list")) {
        var dir = try Io.Dir.cwd().openDir(io, p.root, .{ .iterate = true });
        defer dir.close(io);
        var paths: std.ArrayList([]const u8) = .empty;
        var total: usize = 0;
        var visited: usize = 0;
        try scan(io, a, dir, "", "", &paths, null, &total, &visited);
        return reply(r, a, .ok, .{ .paths = paths.items });
    }
    var dir = try parent(io, p.root, input.path);
    defer dir.close(io);
    const name = std.fs.path.basename(input.path);
    if (std.mem.eql(u8, input.action, "workspace")) {
        var paths: std.ArrayList([]const u8) = .empty;
        var files: std.ArrayList(Source) = .empty;
        var total: usize = 0;
        var visited: usize = 0;
        try scan(io, a, dir, "", name, &paths, &files, &total, &visited);
        return reply(r, a, .ok, .{ .files = files.items });
    }
    if (!notebook(name)) return error.ExpectedNotebook;
    if (std.mem.eql(u8, input.action, "read")) {
        const source = read(io, a, dir, name) catch |err| switch (err) {
            error.FileNotFound => return reply(r, a, .ok, .{ .source = @as(?[]const u8, null) }),
            else => return err,
        };
        if (source.len > 256 * 1024) return error.NotebookTooLarge;
        return reply(r, a, .ok, .{ .source = source });
    }
    if (!std.mem.eql(u8, input.action, "write")) return error.UnknownAction;
    const source = input.source orelse return error.MissingSource;
    if (source.len > 256 * 1024) return error.NotebookTooLarge;
    // Serialize Roclet saves; compare content immediately before atomic replacement.
    try p.mutex.lock(io);
    defer p.mutex.unlock(io);
    const before = read(io, a, dir, name) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (if (before) |bytes| if (input.expected) |expected| !std.mem.eql(u8, bytes, expected) else true else input.expected != null)
        return reply(r, a, .conflict, .{ .@"error" = "This file changed outside Roclet. Reopen it or use Save as; nothing was overwritten." });
    const permissions = if (before != null) (try dir.statFile(io, name, .{})).permissions else Io.File.Permissions.default_file;
    var atomic = try dir.createFileAtomic(io, name, .{ .replace = before != null, .permissions = permissions });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, source);
    try atomic.file.sync(io);
    if (before) |old| {
        const latest = try read(io, a, dir, name);
        if (!std.mem.eql(u8, latest, old)) return reply(r, a, .conflict, .{ .@"error" = "The file changed during saving. Nothing was overwritten; use Save as." });
        try atomic.replace(io);
    } else try atomic.link(io);
    return reply(r, a, .ok, .{ .saved = true });
}
pub fn handle(r: *std.http.Server.Request, p: *Project, io: Io, a: A) !void {
    if (!try trusted(r, p, a)) return reply(r, a, .forbidden, .{ .@"error" = "Local project requests must come from this Roclet server." });
    if (std.mem.eql(u8, r.head.target, "/api/local/config") and r.head.method == .GET)
        return reply(r, a, .ok, .{ .root = p.root, .token = p.token, .initial = p.initial });
    if (!std.mem.eql(u8, header(r, "X-Roclet-Token") orelse "", p.token)) return reply(r, a, .forbidden, .{ .@"error" = "Reload Roclet to reconnect to the local server." });
    if (!std.mem.eql(u8, r.head.target, "/api/local/files") or r.head.method != .POST) return reply(r, a, .not_found, .{ .@"error" = "Unknown local API request" });
    var buffer: [4096]u8 = undefined;
    const body = try (try r.readerExpectContinue(&buffer)).allocRemaining(a, .limited(2 * 1024 * 1024));
    const input = std.json.parseFromSliceLeaky(Input, a, body, .{}) catch return reply(r, a, .bad_request, .{ .@"error" = "Invalid request" });
    execute(r, p, io, a, input) catch |err| return reply(r, a, .bad_request, .{ .@"error" = @errorName(err) });
}
test "project paths exclude hidden paths, traversal and absolute paths" {
    for ([_][]const u8{ "../a.roc", "/a.roc", "a//b.roc", "a/./b", ".git/config", "a\\b", "C:/x", "a\x00b" }) |path| try std.testing.expect(!validPath(path));
    try std.testing.expect(validPath("notes/My notebook.roc"));
}

fn allowedHost(p: *const Project, host: []const u8) bool {
    if (std.mem.eql(u8, host, p.host)) return true;
    if (!p.any_address) return false;
    // Allow numeric interface addresses for wildcard binds, never arbitrary DNS
    // names: accepting those would allow DNS rebinding to expose project files.
    const address = Io.net.IpAddress.parseLiteral(host) catch return false;
    const bound = Io.net.IpAddress.parseLiteral(p.host) catch return false;
    return address.getPort() == bound.getPort();
}

test "wildcard project hosts require an IP and the bound port" {
    var p: Project = .{ .root = ".", .token = "test", .host = "[::]:4173", .any_address = true };
    try std.testing.expect(allowedHost(&p, "[::1]:4173"));
    try std.testing.expect(allowedHost(&p, "[2001:db8::1]:4173"));
    try std.testing.expect(!allowedHost(&p, "[::1]:4174"));
    try std.testing.expect(!allowedHost(&p, "example.com:4173"));
    try std.testing.expect(!allowedHost(&p, "127.0.0.1:4173@evil.example"));
    p.any_address = false;
    p.host = "127.0.0.1:4173";
    try std.testing.expect(allowedHost(&p, "127.0.0.1:4173"));
    try std.testing.expect(!allowedHost(&p, "192.0.2.10:4173"));
}
