//! Roclet M0 whole-module bridge. Built unchanged for native and wasm32.
const std = @import("std");
const builtin = @import("builtin");
pub const runner = @import("engine.zig");
pub const platform = @import("platform.zig");
pub const notebook = @import("notebook.zig");
pub const script = @import("script.zig");
const document = @import("document.zig");
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
    files: []const struct { path: []const u8, source: []const u8 } = &.{},
};
/// (the WASM allocator in the browser).
pub fn process(engine: *Engine, bytes: []const u8) ![]u8 {
    engine.beginRequest();
    const probe = std.json.parseFromSlice(std.json.Value, gpa, bytes, .{}) catch return processSource(engine, bytes);
    defer probe.deinit();
    if (probe.value == .object) try mountFiles(engine, probe.value, gpa);
    if (probe.value == .object) if (probe.value.object.get("operation")) |operation| {
        if (operation == .string and std.mem.eql(u8, operation.string, "program")) return processSource(engine, bytes);
        return processDocument(engine, probe.value);
    };
    if (probe.value == .object and probe.value.object.contains("cells")) {
        return processSnapshot(engine, bytes);
    }
    return processSource(engine, bytes);
}

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
    const bytes = encode(wasm_engine.stats) catch return 0;
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

/// One document request: the parsed request object in, one serialised
/// response out (with `workspaceCache` and `packagesRequired` appended).
fn processDocument(engine: *Engine, value: std.json.Value) ![]u8 {
    var storage = std.heap.ArenaAllocator.init(gpa);
    defer storage.deinit();
    const a = storage.allocator();
    const request = try document.Request.fromValue(a, value, engine.previous_graph, try engine.workspace.contentIdentity(a));
    const response = try document.process(engine, a, request);
    if (response == .document) if (response.document.graph) |graph| {
        var writer: std.Io.Writer.Allocating = .init(engine.gpa);
        errdefer writer.deinit();
        try std.json.Stringify.value(graph, .{}, &writer.writer);
        const owned = try writer.toOwnedSlice();
        if (engine.previous_graph) |old| engine.gpa.free(old);
        engine.previous_graph = owned;
    };
    return encode(Envelope{ .response = .{ .document = response }, .stats = engine.stats, .required = engine.workspace.required.items });
}
/// One M0 snapshot request (`cells`), evaluated through the typed API.
fn processSnapshot(engine: *Engine, bytes: []const u8) ![]u8 {
    var storage = std.heap.ArenaAllocator.init(gpa);
    defer storage.deinit();
    const evaluation = try @import("snapshot.zig").evaluate(engine, storage.allocator(), bytes);
    return encode(Envelope{ .response = .{ .snapshot = evaluation }, .stats = engine.stats, .required = engine.workspace.required.items });
}
/// A response with the engine's `workspaceCache` and `packagesRequired` appended.
const Envelope = struct {
    response: union(enum) { document: document.Response, snapshot: notebook.Evaluation },
    stats: runner.RequestStats,
    required: []const Workspace.RequiredPackage,
    pub fn jsonStringify(self: Envelope, w: anytype) !void {
        try w.beginObject();
        switch (self.response) {
            .document => |response| try response.writeFields(w),
            .snapshot => |evaluation| inline for (@typeInfo(notebook.Evaluation).@"struct".field_names) |name| {
                try w.objectField(name);
                try w.write(@field(evaluation, name));
            },
        }
        try w.objectField("workspaceCache");
        try w.write(self.stats);
        try w.objectField("packagesRequired");
        try w.write(self.required);
        try w.endObject();
    }
};

fn mountFiles(engine: *Engine, request: std.json.Value, a: std.mem.Allocator) !void {
    if (request.object.get("files")) |files| if (files == .array) for (files.array.items) |file| {
        const path = file.object.get("path").?.string;
        const full = if (std.mem.startsWith(u8, path, "/")) path else try std.mem.concat(a, u8, &.{ engine.paths.extras_prefix, path });
        defer if (full.ptr != path.ptr) a.free(full);
        try engine.workspace.put(full, file.object.get("source").?.string, false);
    };
}
