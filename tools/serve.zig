//! Small local static server for the browser host and conformance page.
const std = @import("std");
const proxy = @import("package-proxy.zig");
const local = @import("local-project.zig");
const Context = struct { root: []const u8, cache: proxy.Cache = .{}, proxy_only: bool = false, project: ?local.Project = null, disk_cache: ?[]const u8 = null };
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
    if (std.mem.eql(u8, decoded.items, "/")) return gpa.dupe(u8, "index.html");
    if (decoded.items.len == 0 or decoded.items[0] != '/') return error.InvalidPath;
    const relative = decoded.items[1..];
    var segments = std.mem.splitScalar(u8, relative, '/');
    while (segments.next()) |segment| if (segment.len == 0 or segment[0] == '.') return error.InvalidPath;
    if (std.mem.eql(u8, relative, "index.html") or std.mem.eql(u8, relative, "install.sh") or std.mem.eql(u8, relative, "install.ps1") or std.mem.eql(u8, relative, "LICENSE") or std.mem.eql(u8, relative, "THIRD_PARTY_NOTICES.md")) return gpa.dupe(u8, relative);
    for ([_][]const u8{ "demos/", "web/", "compiler-adapter/", "vendor/roclet-display/", "dependencies/", "fixtures/", "tests/", "artifacts/" }) |prefix| {
        if (std.mem.startsWith(u8, relative, prefix)) return gpa.dupe(u8, relative);
    }
    return error.InvalidPath;
}
fn mime(file: []const u8) []const u8 {
    const ext = std.fs.path.extension(file);
    if (std.mem.eql(u8, ext, ".png")) return "image/png";
    if (std.mem.eql(u8, ext, ".svg")) return "image/svg+xml";
    if (std.mem.eql(u8, ext, ".html")) return "text/html; charset=utf-8";
    if (std.mem.eql(u8, ext, ".mjs") or std.mem.eql(u8, ext, ".js")) return "text/javascript; charset=utf-8";
    if (std.mem.eql(u8, ext, ".css")) return "text/css; charset=utf-8";
    if (std.mem.eql(u8, ext, ".wasm")) return "application/wasm";
    if (std.mem.eql(u8, ext, ".json")) return "application/json";
    return "text/plain; charset=utf-8";
}
fn handle(io: std.Io, context: *Context, stream: std.Io.net.Stream) void {
    defer stream.close(io);
    serveOne(io, context, stream) catch |err| switch (err) {
        error.HttpConnectionClosing => {},
        else => std.debug.print("HTTP connection: {s}\n", .{@errorName(err)}),
    };
}
fn packageResponse(request: *std.http.Server.Request, status: std.http.Status, bytes: []const u8, cache: []const u8) !void {
    try request.respond(bytes, .{ .status = status, .keep_alive = false, .extra_headers = &.{
        .{ .name = "Content-Type", .value = if (status == .ok) "application/octet-stream" else "text/plain; charset=utf-8" },
        .{ .name = "Access-Control-Allow-Origin", .value = "*" },
        .{ .name = "Access-Control-Allow-Methods", .value = "GET, HEAD, OPTIONS" },
        .{ .name = "Access-Control-Expose-Headers", .value = "X-Roclet-Package-Cache" },
        .{ .name = "X-Roclet-Package-Cache", .value = cache },
        .{ .name = "Cache-Control", .value = if (status == .ok) "public, max-age=31536000, immutable" else "no-store" },
        .{ .name = "X-Content-Type-Options", .value = "nosniff" },
    } });
}
fn serveOne(io: std.Io, context: *Context, stream: std.Io.net.Stream) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var read_buffer: [8192]u8 = undefined;
    var write_buffer: [8192]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    var writer = stream.writer(io, &write_buffer);
    var server = std.http.Server.init(&reader.interface, &writer.interface);
    var request = try server.receiveHead();
    // Opaque-origin chart frames cannot send the project's SameSite cookie.
    // Expose only this bundled, non-project script, never notebooks or APIs.
    const chart_renderer = request.head.method == .GET and std.mem.eql(u8, request.head.target, "/web/vendor/plotly/plotly.min.js");
    if (context.project) |*project| {
        if (!chart_renderer) {
            if (!try local.trusted(&request, project, gpa)) return request.respond("Forbidden", .{ .status = .forbidden, .keep_alive = false });
            if (!try local.authorize(&request, project, gpa)) return;
        }
        if (std.mem.startsWith(u8, request.head.target, "/api/local/")) return local.handle(&request, project, io, gpa);
    }
    if (std.mem.startsWith(u8, request.head.target, proxy.prefix)) {
        if (request.head.method == .OPTIONS) return packageResponse(&request, .no_content, "", "none");
        if (request.head.method != .GET and request.head.method != .HEAD) return packageResponse(&request, .method_not_allowed, "Use GET or HEAD", "none");
        const package = proxy.parse(gpa, request.head.target) catch return packageResponse(&request, .bad_request, "Expected a GitHub release package with a Roc content hash", "none");
        if (context.cache.active.fetchAdd(1, .acq_rel) >= 4) {
            _ = context.cache.active.fetchSub(1, .acq_rel);
            return packageResponse(&request, .service_unavailable, "Package service is busy; try again", "none");
        }
        defer _ = context.cache.active.fetchSub(1, .acq_rel);
        if (try context.cache.get(gpa, io, package.hash)) |bytes| return packageResponse(&request, .ok, bytes, "hit");
        const cache_file = if (context.disk_cache) |path| try std.fs.path.join(gpa, &.{ path, &std.fmt.bytesToHex(package.hash, .lower) }) else null;
        if (cache_file) |path| {
            if (std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(proxy.limit))) |cached| {
                if (proxy.verify(cached, package.hash)) |_| return packageResponse(&request, .ok, cached, "disk") else |_| {}
            } else |_| {}
        }
        const bytes = proxy.download(gpa, io, package) catch |err| return packageResponse(&request, .bad_gateway, try std.fmt.allocPrint(gpa, "Package download failed: {s}", .{@errorName(err)}), "none");
        try context.cache.put(io, package.hash, bytes);
        if (cache_file) |path| {
            var atomic = try std.Io.Dir.cwd().createFileAtomic(io, path, .{ .replace = true, .make_path = true });
            defer atomic.deinit(io);
            try atomic.file.writeStreamingAll(io, bytes);
            try atomic.replace(io);
        }
        return packageResponse(&request, .ok, bytes, "miss");
    }
    if (context.proxy_only) return request.respond("Not found", .{ .status = .not_found, .keep_alive = false });
    if (request.head.method != .GET and request.head.method != .HEAD) {
        return request.respond("Method not allowed", .{ .status = .method_not_allowed, .keep_alive = false, .extra_headers = &.{.{ .name = "Allow", .value = "GET, HEAD" }} });
    }
    const relative = assetPath(gpa, request.head.target) catch return request.respond("Not found", .{ .status = .not_found, .keep_alive = false });
    const file = try std.fs.path.join(gpa, &.{ context.root, relative });
    const actual = std.Io.Dir.cwd().realPathFileAlloc(io, file, gpa) catch return request.respond("Not found", .{ .status = .not_found, .keep_alive = false });
    const prefix = try std.mem.concat(gpa, u8, &.{ context.root, std.fs.path.sep_str });
    if (!std.mem.startsWith(u8, actual, prefix)) return request.respond("Not found", .{ .status = .not_found, .keep_alive = false });
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, actual, gpa, .limited(128 * 1024 * 1024)) catch return request.respond("Not found", .{ .status = .not_found, .keep_alive = false });
    try request.respond(bytes, .{ .keep_alive = false, .extra_headers = &.{
        .{ .name = "Content-Type", .value = mime(relative) },
        .{ .name = "Cache-Control", .value = "no-store" },
        .{ .name = "X-Content-Type-Options", .value = "nosniff" },
    } });
}
pub fn printHelp(io: std.Io) !void {
    try std.Io.File.stdout().writeStreamingAll(io,
        \\Roclet — run notebooks in your browser
        \\
        \\Usage:
        \\  roclet serve [DIRECTORY|NOTEBOOK] [OPTIONS]
        \\    Open a project (default: current directory). Save writes to project files.
        \\  roclet serve-static [ASSETS] [OPTIONS]
        \\    Serve only the website (default: bundled assets). No project file access.
        \\
        \\Options for both commands:
        \\  --bind ADDRESS   IP address to listen on (default: 127.0.0.1).
        \\                   Use 0.0.0.0 for all IPv4 interfaces, or :: for IPv6.
        \\  --port PORT      Port to listen on (default: 4173).
        \\  -h, --help       Show this help.
        \\
        \\Project options:
        \\  --public-url URL HTTPS origin served by a local reverse proxy (no path).
        \\                   Requires loopback --bind; TLS is handled by the proxy.
        \\  --no-browser     Print the URL without opening a browser.
        \\  --assets DIR     Use website assets from DIR instead of the bundled copy.
        \\Static options:
        \\  --proxy-only     Serve only the package-download proxy.
        \\
        \\Examples:
        \\  roclet serve demos
        \\  roclet serve notes.roc --port 8080
        \\  roclet serve demos --bind 0.0.0.0 --no-browser
        \\  roclet serve-static ./website --port 8080
        \\
        \\Network project access uses a numeric server IP in the browser URL.
        \\Project access requires the private token URL printed at startup.
        \\Anyone with that URL can read and edit the project. A restart changes the token.
        \\Keep bundled assets beside the executable. Press Ctrl-C to stop.
        \\
    );
}
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len == 1) return printHelp(init.io);
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) return printHelp(init.io);
    }
    if (std.mem.eql(u8, args[1], "serve")) return serveProject(init, args[2..]);
    if (std.mem.eql(u8, args[1], "serve-static")) return serveStatic(init, args[2..]);
    std.debug.print("Unknown command '{s}'. Use 'roclet serve {s}' to open a project, or 'roclet --help'.\n", .{ args[1], args[1] });
    return error.UnknownCommand;
}
pub fn serveStatic(init: std.process.Init, args: []const []const u8) !void {
    var index: usize = 0;
    const explicit_root = index < args.len and !std.mem.startsWith(u8, args[index], "--");
    const root_arg = if (explicit_root) args[index] else std.fs.path.dirname(try std.process.executablePathAlloc(init.io, init.arena.allocator())).?;
    if (explicit_root) index += 1;
    const root = try std.Io.Dir.cwd().realPathFileAlloc(init.io, root_arg, init.arena.allocator());
    var port: u16 = 4173;
    var bind: []const u8 = "127.0.0.1";
    var context: Context = .{ .root = root };
    defer context.cache.deinit();
    if (index < args.len and !std.mem.startsWith(u8, args[index], "--")) {
        port = try std.fmt.parseInt(u16, args[index], 10);
        index += 1;
    }
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--proxy-only")) context.proxy_only = true else if (std.mem.eql(u8, args[index], "--bind")) {
            index += 1;
            if (index == args.len) return error.ExpectedBindAddress;
            bind = args[index];
        } else if (std.mem.eql(u8, args[index], "--port")) {
            index += 1;
            if (index == args.len) return error.ExpectedPort;
            port = try std.fmt.parseInt(u16, args[index], 10);
        } else return error.UnknownOption;
    }
    if (port == 0) return error.InvalidPort;
    try listen(init, &context, bind, port, false);
}
fn listen(init: std.process.Init, context: *Context, bind: []const u8, port: u16, browser: bool) !void {
    const address = try std.Io.net.IpAddress.parse(bind, port);
    var server = try address.listen(init.io, .{ .reuse_address = true });
    defer server.deinit(init.io);
    var group: std.Io.Group = .init;
    defer group.cancel(init.io);
    const display_bind = if (std.mem.eql(u8, bind, "0.0.0.0")) "127.0.0.1" else if (std.mem.eql(u8, bind, "::")) "::1" else bind;
    const origin = if (context.project) |p| p.public_url else null;
    const url = try std.fmt.allocPrint(init.arena.allocator(), "{s}/{s}{s}", .{ origin orelse try std.fmt.allocPrint(init.arena.allocator(), "http://{s}", .{try hostPort(init.arena.allocator(), display_bind, port)}), if (context.project != null) "?token=" else "", if (context.project) |p| p.token else "" });
    if (!std.mem.eql(u8, display_bind, bind)) std.debug.print("Listening on {s}; use this computer's network IP from another device.\n", .{bind});
    std.debug.print("Roclet: {s}\n", .{url});
    if (context.project) |project| std.debug.print("Project: {s}\nPress Ctrl-C to stop.\n", .{project.root});
    if (browser) {
        const command: []const []const u8 = switch (@import("builtin").os.tag) {
            .macos => &.{ "open", url },
            .windows => &.{ "cmd", "/c", "start", "", url },
            else => &.{ "xdg-open", url },
        };
        if (std.process.spawn(init.io, .{ .argv = command, .stdout = .ignore, .stderr = .ignore })) |child_value| {
            var child = child_value;
            _ = child.wait(init.io) catch {};
        } else |_| std.debug.print("Open the URL above in your browser.\n", .{});
    }
    while (true) {
        const stream = try server.accept(init.io);
        group.concurrent(init.io, handle, .{ init.io, context, stream }) catch |err| {
            stream.close(init.io);
            return err;
        };
    }
}
pub fn serveProject(init: std.process.Init, args: []const []const u8) !void {
    const a = init.arena.allocator();
    const io = init.io;
    var target: []const u8 = ".";
    var selected = false;
    var port: u16 = 4173;
    var browser = true;
    var bind: []const u8 = "127.0.0.1";
    var assets: ?[]const u8 = null;
    var public_url: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--no-browser")) {
            browser = false;
        } else if (std.mem.eql(u8, args[i], "--port") or std.mem.eql(u8, args[i], "--assets") or std.mem.eql(u8, args[i], "--bind") or std.mem.eql(u8, args[i], "--public-url")) {
            const option = args[i];
            i += 1;
            if (i == args.len) return error.MissingOptionValue;
            if (std.mem.eql(u8, option, "--port")) port = try std.fmt.parseInt(u16, args[i], 10) else if (std.mem.eql(u8, option, "--bind")) bind = args[i] else if (std.mem.eql(u8, option, "--public-url")) public_url = try publicOrigin(a, args[i]) else assets = args[i];
        } else if (!selected and !std.mem.startsWith(u8, args[i], "--")) {
            target = args[i];
            selected = true;
        } else return error.UnknownOption;
    }
    if (port == 0) return error.InvalidPort;
    if (public_url != null and !std.mem.eql(u8, bind, "127.0.0.1") and !std.mem.eql(u8, bind, "::1")) {
        std.debug.print("--public-url requires --bind 127.0.0.1 or ::1; run the HTTPS proxy on this computer.\n", .{});
        return error.ExpectedLoopbackBind;
    }
    const actual = try std.Io.Dir.cwd().realPathFileAlloc(io, target, a);
    const stat = try std.Io.Dir.cwd().statFile(io, actual, .{});
    if (stat.kind != .directory and !(stat.kind == .file and (std.mem.endsWith(u8, actual, ".roc") or std.mem.endsWith(u8, actual, ".md")))) return error.ExpectedDirectoryOrNotebook;
    const project_root = if (stat.kind == .directory) actual else std.fs.path.dirname(actual).?;
    const exe_dir = try std.process.executableDirPathAlloc(io, a);
    var asset_root = assets orelse exe_dir;
    if (assets == null) {
        const index = try std.fs.path.join(a, &.{ asset_root, "web/edit.html" });
        std.Io.Dir.cwd().access(io, index, .{}) catch {
            asset_root = try std.fs.path.resolve(a, &.{ exe_dir, "../.." });
        };
    }
    asset_root = try std.Io.Dir.cwd().realPathFileAlloc(io, asset_root, a);
    try std.Io.Dir.cwd().access(io, try std.fs.path.join(a, &.{ asset_root, "web/edit.html" }), .{});
    var random: [32]u8 = undefined;
    try io.randomSecure(&random);
    var context: Context = .{ .root = asset_root, .project = .{
        .root = project_root,
        .token = try a.dupe(u8, &std.fmt.bytesToHex(random, .lower)),
        .host = if (public_url) |url| url[8..] else try hostPort(a, bind, port),
        .public_url = public_url,
        .cookie_name = try std.fmt.allocPrint(a, "roclet_session_{d}", .{port}),
        .any_address = std.mem.eql(u8, bind, "0.0.0.0") or std.mem.eql(u8, bind, "::"),
        .initial = if (stat.kind == .file) std.fs.path.basename(actual) else null,
    } };
    // Separate from the project and web assets; survives server/browser restarts.
    if (init.environ_map.get("HOME")) |home| context.disk_cache = try std.fs.path.join(a, &.{ home, ".cache", "roclet", "packages" });
    defer context.cache.deinit();
    try listen(init, &context, bind, port, browser);
}

test "static asset paths reject traversal, hidden files, and malformed escapes" {
    const gpa = std.testing.allocator;
    for ([_][]const u8{ "/../compiler.lock.json", "/web/%2e%2e/.toolchain/x", "/web/%00x", "/web/%xy", "/web/%5csecret", "/.git/config", "/tools/build-tool.zig", "/web//x" }) |target| {
        try std.testing.expectError(error.InvalidPath, assetPath(gpa, target));
    }
    const result = try assetPath(gpa, "/web/edit.mjs?version=1");
    defer gpa.free(result);
    try std.testing.expectEqualStrings("web/edit.mjs", result);
    try std.testing.expectEqualStrings("application/wasm", mime("artifacts/roclet.wasm"));
    const display = try assetPath(gpa, "/vendor/roclet-display/Display.roc");
    defer gpa.free(display);
    try std.testing.expectEqualStrings("vendor/roclet-display/Display.roc", display);
}

fn hostPort(a: std.mem.Allocator, bind: []const u8, port: u16) ![]const u8 {
    return if (std.mem.findScalar(u8, bind, ':') != null)
        std.fmt.allocPrint(a, "[{s}]:{d}", .{ bind, port })
    else
        std.fmt.allocPrint(a, "{s}:{d}", .{ bind, port });
}

// Accept only an HTTPS origin. Never infer it from untrusted forwarded headers.
fn publicOrigin(a: std.mem.Allocator, value: []const u8) ![]const u8 {
    const url = if (std.mem.endsWith(u8, value, "/")) value[0 .. value.len - 1] else value;
    if (!std.mem.startsWith(u8, url, "https://") or url.len <= 8) return error.InvalidPublicUrl;
    for (url[8..]) |c| if (!std.ascii.isAlphanumeric(c) and c != '.' and c != '-' and c != ':' and c != '[' and c != ']') return error.InvalidPublicUrl;
    const uri = std.Uri.parse(url) catch return error.InvalidPublicUrl;
    if (uri.host == null or uri.host.?.isEmpty() or !uri.path.isEmpty() or uri.port == 0) return error.InvalidPublicUrl;
    // Match browser serialization: lowercase hosts and normalized ports.
    const authority = if (uri.port != null) url[8..std.mem.findScalarLast(u8, url, ':').?] else url[8..];
    const host = try std.ascii.allocLowerString(a, authority);
    return if (uri.port) |port|
        if (port == 443) try std.fmt.allocPrint(a, "https://{s}", .{host}) else try std.fmt.allocPrint(a, "https://{s}:{d}", .{ host, port })
    else
        try std.fmt.allocPrint(a, "https://{s}", .{host});
}
