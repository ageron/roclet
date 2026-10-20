//! Roclet M0 whole-module bridge. Built unchanged for native and wasm32.
const std = @import("std");
const builtin = @import("builtin");
pub const runner = @import("engine.zig");
pub const platform = @import("platform.zig");
pub const notebook = @import("notebook.zig");
pub const script = @import("script.zig");
const analysis = @import("analysis.zig");
const Workspace = @import("workspace.zig");
pub const Engine = @import("engine_state.zig").Engine;
pub const roc_compressed_builtins = @import("compressed_builtins");

const is_wasm = builtin.cpu.arch == .wasm32;
const gpa = if (is_wasm) std.heap.wasm_allocator else std.heap.page_allocator;
pub const std_options: std.Options = .{ .logFn = quietLog };
fn quietLog(comptime _: std.log.Level, comptime _: @TypeOf(.enum_literal), comptime _: []const u8, _: anytype) void {}

/// The protocol-1 program request: `operation: "program"` (or, until the M0
/// adapter is retired, an object without `operation`).
const Request = struct {
    operation: ?[]const u8 = null,
    protocol: u32,
    source: []const u8,
    user_bytes: u32,
    check_only: bool = false,
    rich_output: bool = false,
    args: []const []const u8 = &.{},
    modules: []const runner.ExtraFile = &.{},
    app_header: []const u8 = "",
    root: ?[]const u8 = null,
    notebook: ?notebook.Metadata = null,
    files: []const struct { path: []const u8, source: []const u8 } = &.{},
};
const Response = struct {
    protocol: u32 = 1,
    display_module: bool = false,
    status: []const u8 = "ok",
    definitions: []const analysis.Definition = &.{},
    failure: ?[]const u8 = null,
    dependency_scope: []const u8 = "definitions",
    binders: []const []const u8 = &.{},
};
/// The protocol-1 response of one raw `notebook` request (the M0 `cells`
/// adapter), with its observation bounds.
const ResponseBuilder = struct {
    response: Response = .{},
    events: platform.EventBuffer,
    diagnostic_list: runner.DiagnosticList,

    fn init(arena: std.mem.Allocator) ResponseBuilder {
        return .{ .events = .{ .arena = arena }, .diagnostic_list = .{ .arena = arena } };
    }
    /// The request observer; the notebook pipeline sets its `root` per execution.
    fn observer(self: *ResponseBuilder) platform.Observer {
        return self.events.observer();
    }
    fn diagnostics(self: *ResponseBuilder) runner.Diagnostics {
        return self.diagnostic_list.diagnostics();
    }
    fn setAnalysis(self: *ResponseBuilder, result: *const analysis.Analysis) void {
        self.response.definitions = result.definitions;
        self.response.binders = result.binders;
        self.response.dependency_scope = @tagName(result.dependency_scope);
    }
    /// Record a pipeline failure and serialize the final response.
    fn finish(self: *ResponseBuilder, engine: *Engine, outcome: anytype) ![]u8 {
        const exit_code = outcome catch |err| code: {
            self.response.status = switch (err) {
                error.CompilationFailed => "diagnostic",
                else => "runtime_error",
            };
            if (self.diagnostic_list.failure == null) self.response.failure = @errorName(err);
            break :code 0;
        };
        if (exit_code != 0) self.response.status = "runtime_error";
        if (self.events.failed or self.diagnostic_list.failed) return error.OutOfMemory;
        return encode(script.Outcome{
            .display_module = self.response.display_module,
            .status = self.response.status,
            .definitions = self.response.definitions,
            .dependency_scope = self.response.dependency_scope,
            .binders = self.response.binders,
            .diagnostics = self.diagnostic_list.items.items,
            .events = self.events.events.items,
            .failure = self.diagnostic_list.failure orelse self.response.failure,
            .packagesRequired = engine.workspace.required.items,
            .workspaceCache = engine.stats,
        });
    }
};

/// Serve one top-level request. The response is owned by the page allocator
/// (the WASM allocator in the browser).
pub fn process(engine: *Engine, bytes: []const u8) ![]u8 {
    engine.beginRequest();
    const probe = std.json.parseFromSlice(std.json.Value, gpa, bytes, .{}) catch return processSource(engine, bytes);
    defer probe.deinit();
    if (probe.value == .object) try mountFiles(engine, probe.value, gpa);
    if (probe.value == .object) if (probe.value.object.get("operation")) |operation| {
        if (operation == .string and std.mem.eql(u8, operation.string, "program")) return processSource(engine, bytes);
        return processDocument(engine, bytes);
    };
    if (probe.value == .object and probe.value.object.contains("cells")) {
        return withRequiredPackages(engine, try @import("snapshot.zig").evaluate(gpa, bytes, Compiler{ .engine = engine }));
    }
    return processSource(engine, bytes);
}

/// Binds the protocol-1 entry point to one engine for the document and
/// snapshot layers, which issue nested protocol-1 requests.
const Compiler = struct {
    engine: *Engine,
    pub fn compile(self: Compiler, bytes: []const u8) ![]u8 {
        return processSource(self.engine, bytes);
    }
};
fn processSource(engine: *Engine, bytes: []const u8) ![]u8 {
    var arena_impl = std.heap.ArenaAllocator.init(gpa);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();
    const parsed = std.json.parseFromSlice(Request, arena, bytes, .{ .allocate = .alloc_always }) catch {
        return encode(script.rejected(engine, "Malformed request"));
    };
    const req = parsed.value;
    if (req.protocol != 1 or req.user_bytes > req.source.len or req.source.len > 1024 * 1024) {
        return encode(script.rejected(engine, "Unsupported protocol or invalid source length (limit 1 MiB)"));
    }
    for (req.files) |file| {
        const path = if (std.mem.startsWith(u8, file.path, "/")) file.path else try std.mem.concat(arena, u8, &.{ engine.paths.extras_prefix, file.path });
        try engine.workspace.put(path, file.source, false);
    }
    if (req.notebook) |metadata| return processNotebook(engine, arena, req, metadata);
    return encode(try script.run(engine, arena, .{
        .source = req.source,
        .user_bytes = req.user_bytes,
        .app_header = req.app_header,
        .modules = req.modules,
        .check_only = req.check_only,
        .args = req.args,
        .root = req.root,
        .rich_output = req.rich_output,
    }));
}
fn processNotebook(engine: *Engine, arena: std.mem.Allocator, req: Request, metadata: notebook.Metadata) ![]u8 {
    var builder: ResponseBuilder = .init(arena);
    builder.events.rich = req.rich_output;
    const modules = try runner.programModules(arena, engine.workspace.io(arena), engine.paths.extras_prefix, req.modules, req.source[0..req.user_bytes]);
    builder.response.display_module = modules.rich_support;
    try runner.prepareBuiltins();
    var analyzed: ?*const analysis.Analysis = null;
    const outcome = notebook.run(engine, .{
        .inputs = .{
            .program = req.source,
            .app_header = req.app_header,
            .extras = modules.extras,
            .roots = metadata.roots,
            .expectations = metadata.expectations,
            .rich_support = modules.rich_support,
            .paths = engine.paths,
            .roc_target = runner.hostRocTarget(),
        },
        .metadata = metadata,
        .root = req.root,
        .diagnostics = builder.diagnostics(),
        .observer = builder.observer(),
        .analysis = &analyzed,
    });
    if (analyzed) |result| builder.setAnalysis(result);
    return builder.finish(engine, outcome);
}
fn encode(value: anytype) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(gpa);
    errdefer writer.deinit();
    try std.json.Stringify.value(value, .{}, &writer.writer);
    return writer.toOwnedSlice();
}

/// The worker's single engine. Native hosts construct their own instances.
var wasm_engine: Engine = .init(gpa, .failing);

export fn roclet_alloc(len: u32) u32 {
    const bytes = gpa.alloc(u8, len) catch return 0;
    return @intCast(@intFromPtr(bytes.ptr));
}
export fn roclet_free(ptr: u32, len: u32) void {
    if (ptr == 0) return;
    const bytes: [*]u8 = @ptrFromInt(ptr);
    gpa.free(bytes[0..len]);
}
export fn roclet_process(ptr: u32, len: u32) u32 {
    if (ptr == 0) return 0;
    const bytes: [*]const u8 = @ptrFromInt(ptr);
    const result = process(&wasm_engine, bytes[0..len]) catch return 0;
    defer gpa.free(result);
    const stored = gpa.alloc(u8, result.len + 4) catch return 0;
    std.mem.writeInt(u32, stored[0..4], @intCast(result.len), .little);
    @memcpy(stored[4..], result);
    return @intCast(@intFromPtr(stored.ptr));
}
export fn roclet_free_response(ptr: u32) void {
    if (ptr == 0) return;
    const bytes: [*]u8 = @ptrFromInt(ptr);
    const len = std.mem.readInt(u32, bytes[0..4], .little);
    gpa.free(bytes[0 .. @as(usize, len) + 4]);
}

fn storedResponse(bytes: []const u8) u32 {
    const stored = gpa.alloc(u8, bytes.len + 4) catch return 0;
    std.mem.writeInt(u32, stored[0..4], @intCast(bytes.len), .little);
    @memcpy(stored[4..], bytes);
    return @intCast(@intFromPtr(stored.ptr));
}
fn input(ptr: u32, len: u32) []const u8 {
    const p: [*]const u8 = @ptrFromInt(ptr);
    return p[0..len];
}
export fn roclet_file_put(path_ptr: u32, path_len: u32, ptr: u32, len: u32) u32 {
    wasm_engine.workspace.put(input(path_ptr, path_len), input(ptr, len), false) catch return 0;
    return 1;
}
export fn roclet_file_drop(ptr: u32, len: u32) u32 {
    wasm_engine.workspace.drop(input(ptr, len));
    return 1;
}
export fn roclet_cache_import(ptr: u32, len: u32) u32 {
    wasm_engine.workspace.importCache(input(ptr, len)) catch return 0;
    return 1;
}
export fn roclet_cache_take_updates() u32 {
    const bytes = wasm_engine.workspace.takeUpdates() catch return 0;
    defer gpa.free(bytes);
    return storedResponse(bytes);
}
export fn roclet_cache_stats() u32 {
    const bytes = @import("snapshot.zig").json(gpa, wasm_engine.stats) catch return 0;
    defer gpa.free(bytes);
    return storedResponse(bytes);
}
export fn roclet_cache_identity() u32 {
    return storedResponse(Workspace.identity);
}
export fn roclet_package_install(url_ptr: u32, url_len: u32, ptr: u32, len: u32) u32 {
    wasm_engine.workspace.installPackage(input(url_ptr, url_len), input(ptr, len)) catch return 0;
    return 1;
}

fn processDocument(engine: *Engine, bytes: []const u8) ![]u8 {
    var storage = std.heap.ArenaAllocator.init(gpa);
    defer storage.deinit();
    const a = storage.allocator();
    var request = try std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{});
    try request.object.put(a, "workspaceFingerprint", .{ .string = try engine.workspace.contentIdentity(a) });
    if (request.object.getPtr("reactivity")) |reactivity| if (reactivity.* == .object and reactivity.object.get("previous") == null) {
        if (engine.previous_graph) |graph| try reactivity.object.put(a, "previous", try std.json.parseFromSliceLeaky(std.json.Value, a, graph, .{}));
    };
    const input_bytes = try @import("snapshot.zig").json(a, request);
    const result = try @import("document.zig").process(gpa, input_bytes, Compiler{ .engine = engine });
    defer gpa.free(result);
    var parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, result, .{});
    if (parsed == .object) {
        if (parsed.object.get("graph")) |graph| {
            const owned = try @import("snapshot.zig").json(engine.gpa, graph);
            if (engine.previous_graph) |old| engine.gpa.free(old);
            engine.previous_graph = owned;
        }
        try parsed.object.put(a, "workspaceCache", try std.json.parseFromSliceLeaky(std.json.Value, a, try @import("snapshot.zig").json(a, engine.stats), .{}));
        try parsed.object.put(a, "packagesRequired", try std.json.parseFromSliceLeaky(std.json.Value, a, try @import("snapshot.zig").json(a, engine.workspace.required.items), .{}));
    }
    return @import("snapshot.zig").json(gpa, parsed);
}

fn mountFiles(engine: *Engine, request: std.json.Value, a: std.mem.Allocator) !void {
    if (request.object.get("files")) |files| if (files == .array) for (files.array.items) |file| {
        const path = file.object.get("path").?.string;
        const full = if (std.mem.startsWith(u8, path, "/")) path else try std.mem.concat(a, u8, &.{ engine.paths.extras_prefix, path });
        defer if (full.ptr != path.ptr) a.free(full);
        try engine.workspace.put(full, file.object.get("source").?.string, false);
    };
}

fn withRequiredPackages(engine: *Engine, result: []u8) ![]u8 {
    defer gpa.free(result);
    var temporary = std.heap.ArenaAllocator.init(gpa);
    defer temporary.deinit();
    const a = temporary.allocator();
    var parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, result, .{});
    const json = @import("snapshot.zig").json;
    try parsed.object.put(a, "workspaceCache", try std.json.parseFromSliceLeaky(std.json.Value, a, try json(a, engine.stats), .{}));
    try parsed.object.put(a, "packagesRequired", try std.json.parseFromSliceLeaky(std.json.Value, a, try json(a, engine.workspace.required.items), .{}));
    return json(gpa, parsed);
}
