//! Small local static server for the browser host and conformance page.
const std = @import("std");
fn assetPath(gpa: std.mem.Allocator, target: []const u8) ![]u8 {
    const end = std.mem.findScalar(u8, target, '?') orelse target.len;
    const encoded = target[0..end];
    var decoded: std.ArrayList(u8) = .empty;
    defer decoded.deinit(gpa);
    var i: usize = 0;
    while (i < encoded.len) : (i += 1) {
        var c = encoded[i];
        if (c == '%') {
            if (i + 2 >= encoded.len) return error.InvalidPath;
            c = std.fmt.parseInt(u8, encoded[i + 1 .. i + 3], 16) catch return error.InvalidPath;
            i += 2;
        }
        if (c < 32 or c == 127 or c == '\\') return error.InvalidPath;
        try decoded.append(gpa, c);
    }
    if (std.mem.eql(u8, decoded.items, "/")) return gpa.dupe(u8, "web/index.html");
    if (decoded.items.len == 0 or decoded.items[0] != '/') return error.InvalidPath;
    const relative = decoded.items[1..];
    var segments = std.mem.splitScalar(u8, relative, '/');
    while (segments.next()) |segment| if (segment.len == 0 or segment[0] == '.') return error.InvalidPath;
    if (std.mem.eql(u8, relative, "LICENSE") or std.mem.eql(u8, relative, "THIRD_PARTY_NOTICES.md")) return gpa.dupe(u8, relative);
    for ([_][]const u8{ "demos/", "web/", "compiler-adapter/", "core/", "package/", "fixtures/", "tests/", "artifacts/" }) |prefix| {
        if (std.mem.startsWith(u8, relative, prefix)) return gpa.dupe(u8, relative);
    }
    return error.InvalidPath;
}
fn mime(file: []const u8) []const u8 {
    const ext = std.fs.path.extension(file);
    if (std.mem.eql(u8, ext, ".png")) return "image/png";
    if (std.mem.eql(u8, ext, ".html")) return "text/html; charset=utf-8";
    if (std.mem.eql(u8, ext, ".mjs") or std.mem.eql(u8, ext, ".js")) return "text/javascript; charset=utf-8";
    if (std.mem.eql(u8, ext, ".css")) return "text/css; charset=utf-8";
    if (std.mem.eql(u8, ext, ".wasm")) return "application/wasm";
    if (std.mem.eql(u8, ext, ".json")) return "application/json";
    return "text/plain; charset=utf-8";
}
fn handle(io: std.Io, root: []const u8, stream: std.Io.net.Stream) void {
    defer stream.close(io);
    serveOne(io, root, stream) catch |err| switch (err) {
        error.HttpConnectionClosing => {},
        else => std.debug.print("HTTP connection: {s}\n", .{@errorName(err)}),
    };
}
fn serveOne(io: std.Io, root: []const u8, stream: std.Io.net.Stream) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var read_buffer: [8192]u8 = undefined;
    var write_buffer: [8192]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    var writer = stream.writer(io, &write_buffer);
    var server = std.http.Server.init(&reader.interface, &writer.interface);
    var request = try server.receiveHead();
    if (request.head.method != .GET and request.head.method != .HEAD) {
        return request.respond("Method not allowed", .{ .status = .method_not_allowed, .keep_alive = false, .extra_headers = &.{.{ .name = "Allow", .value = "GET, HEAD" }} });
    }
    const relative = assetPath(gpa, request.head.target) catch return request.respond("Not found", .{ .status = .not_found, .keep_alive = false });
    const file = try std.fs.path.join(gpa, &.{ root, relative });
    const actual = std.Io.Dir.cwd().realPathFileAlloc(io, file, gpa) catch return request.respond("Not found", .{ .status = .not_found, .keep_alive = false });
    const prefix = try std.mem.concat(gpa, u8, &.{ root, std.fs.path.sep_str });
    if (!std.mem.startsWith(u8, actual, prefix)) return request.respond("Not found", .{ .status = .not_found, .keep_alive = false });
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, actual, gpa, .limited(64 * 1024 * 1024)) catch return request.respond("Not found", .{ .status = .not_found, .keep_alive = false });
    try request.respond(bytes, .{ .keep_alive = false, .extra_headers = &.{
        .{ .name = "Content-Type", .value = mime(relative) },
        .{ .name = "Cache-Control", .value = "no-store" },
        .{ .name = "X-Content-Type-Options", .value = "nosniff" },
    } });
}
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2 or args.len > 3) return error.ExpectedRootAndOptionalPort;
    const root = try std.Io.Dir.cwd().realPathFileAlloc(init.io, args[1], init.arena.allocator());
    const port = if (args.len == 3) try std.fmt.parseInt(u16, args[2], 10) else 4173;
    if (port == 0) return error.InvalidPort;
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", port);
    var server = try address.listen(init.io, .{ .reuse_address = true });
    defer server.deinit(init.io);
    var group: std.Io.Group = .init;
    defer group.cancel(init.io);
    std.debug.print("Roclet: http://127.0.0.1:{d}/web/edit.html\n", .{port});
    while (true) {
        const stream = try server.accept(init.io);
        group.concurrent(init.io, handle, .{ init.io, root, stream }) catch |err| {
            stream.close(init.io);
            return err;
        };
    }
}
test "static asset paths reject traversal, hidden files, and malformed escapes" {
    const gpa = std.testing.allocator;
    for ([_][]const u8{ "/../compiler.lock.json", "/web/%2e%2e/.toolchain/x", "/web/%00x", "/web/%xy", "/web/%5csecret", "/.git/config", "/tools/build-tool.zig", "/web//x" }) |target| {
        try std.testing.expectError(error.InvalidPath, assetPath(gpa, target));
    }
    const result = try assetPath(gpa, "/web/app.mjs?version=1");
    defer gpa.free(result);
    try std.testing.expectEqualStrings("web/app.mjs", result);
    try std.testing.expectEqualStrings("application/wasm", mime("artifacts/roclet.wasm"));
    const display = try assetPath(gpa, "/package/Display.roc");
    defer gpa.free(display);
    try std.testing.expectEqualStrings("package/Display.roc", display);
}
