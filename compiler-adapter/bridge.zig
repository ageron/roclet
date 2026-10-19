//! Roclet M0 whole-module bridge. Built unchanged for native and wasm32.
const std = @import("std");
const builtin = @import("builtin");
const runner = @import("engine.zig");
const platform = @import("platform.zig");
const can = @import("can");
const collections = @import("collections");
const reporting = @import("reporting");
const Workspace = @import("workspace.zig");
const compiled_builtins = @import("compiled_builtins");

const is_wasm = builtin.cpu.arch == .wasm32;
const gpa = if (is_wasm) std.heap.wasm_allocator else std.heap.page_allocator;
pub const std_options: std.Options = .{ .logFn = quietLog };
fn quietLog(comptime _: std.log.Level, comptime _: @TypeOf(.enum_literal), comptime _: []const u8, _: anytype) void {}

const Request = struct {
    protocol: u32,
    source: []const u8,
    user_bytes: u32,
    check_only: bool = false,
    rich_output: bool = false,
    args: []const []const u8 = &.{},
    modules: []const runner.ExtraFile = &.{},
    app_header: []const u8 = "",
    files: []const struct { path: []const u8, source: []const u8 } = &.{},
};
const Region = struct { start: u32, end: u32 };
const Definition = struct {
    name: []const u8,
    type: []const u8,
    region: Region,
    name_region: Region,
    dependencies: []const []const u8,
    references: []const Region,
    rename_safe: bool,
};
const Diagnostic = struct {
    title: []const u8,
    severity: []const u8,
    message: []const u8,
    filename: ?[]const u8 = null,
    location: ?struct { start_line: u32, start_column: u32, end_line: u32, end_column: u32 } = null,
};
const Event = struct { kind: []const u8, message: []const u8 };
const Response = struct {
    protocol: u32 = 1,
    display_module: bool = false,
    status: []const u8 = "ok",
    definitions: std.ArrayList(Definition) = .empty,
    diagnostics: std.ArrayList(Diagnostic) = .empty,
    events: std.ArrayList(Event) = .empty,
    failure: ?[]const u8 = null,
    dependency_scope: []const u8 = "definitions",
    binders: std.ArrayList([]const u8) = .empty,
};
var response: Response = .{};
var arena: std.mem.Allocator = undefined;
var user_bytes: u32 = 0;
var callback_failed = false;
var bounded_events = true;
var event_bytes: usize = 0;
var events_truncated = false;
var rich_output = false;
var value_index: usize = 0;

fn dupe(s: []const u8) []const u8 {
    return arena.dupe(u8, s) catch {
        callback_failed = true;
        return "";
    };
}
fn observe(kind: []const u8, message: []const u8) void {
    var end = message.len;
    if (bounded_events) {
        const designated = std.mem.eql(u8, kind, "value");
        const value_limit: usize = if (rich_output and value_index == 1) 512 * 1024 else 64 * 1024;
        if (designated) value_index += 1;
        end = @min(end, if (designated) value_limit else @min(@as(usize, 64 * 1024), 256 * 1024 -| event_bytes));
        if (!designated and response.events.items.len >= 1000) end = 0;
        while (end > 0 and end < message.len and message[end] & 0xc0 == 0x80) end -= 1;
        if (end < message.len and !events_truncated) {
            events_truncated = true;
            response.events.append(arena, .{ .kind = "truncated", .message = "Output truncated: at most 1,000 observations, 256 KiB of observations, and 64 KiB per text result/message (512 KiB for rich data) are retained per root." }) catch {
                callback_failed = true;
            };
        }
        if (end == 0 and message.len > 0 and !designated) return;
    }
    event_bytes += end;
    response.events.append(arena, .{ .kind = kind, .message = dupe(message[0..end]) }) catch {
        callback_failed = true;
    };
}
fn writeFailure(_: ?*anyopaque, message: []const u8) void {
    response.failure = dupe(message);
}
fn emitReport(_: ?*anyopaque, _: std.mem.Allocator, report: *reporting.Report) void {
    var writer: std.Io.Writer.Allocating = .init(arena);
    defer writer.deinit();
    reporting.renderReport(report, &writer.writer, .markdown) catch {
        callback_failed = true;
        return;
    };
    const loc = report.getRegionInfo();
    var filename: ?[]const u8 = null;
    for (report.document.elements.items) |element| {
        const file = switch (element) {
            .source_code_region => |r| r.filename,
            .source_code_with_underlines => |r| r.display_region.filename,
            .source_code_multi_region => |r| r.filename,
            else => null,
        };
        if (file) |name| {
            filename = dupe(name);
            break;
        }
    }
    response.diagnostics.append(arena, .{
        .title = dupe(report.title),
        .severity = if (report.severity.isError()) "error" else "warning",
        .message = dupe(writer.written()),
        .filename = filename,
        .location = if (loc) |r| .{
            .start_line = r.start_line_idx,
            .start_column = r.start_col_idx,
            .end_line = r.end_line_idx,
            .end_column = r.end_col_idx,
        } else null,
    }) catch {
        callback_failed = true;
    };
}
fn analyze(env: *can.ModuleEnv, prefix: u32) void {
    analyzeFallible(env, prefix) catch {
        callback_failed = true;
    };
}
fn analyzeFallible(env: *can.ModuleEnv, prefix: u32) !void {
    const defs = env.store.sliceDefs(env.all_defs);
    var patterns: std.AutoHashMapUnmanaged(can.CIR.Pattern.Idx, can.CIR.Def.Idx) = .{};
    var binders: std.ArrayList(can.CIR.Pattern.Idx) = .empty;
    var binder_stack: std.ArrayList(can.CIR.Pattern.Idx) = .empty;
    for (defs) |idx| {
        binders.clearRetainingCapacity();
        try can.DependencyGraph.appendPatternBinders(env, env.store.getDef(idx).pattern, &binders, &binder_stack, arena);
        for (binders.items) |binder| try patterns.put(arena, binder, idx);
        const d = env.store.getDef(idx);
        const r = env.store.getExprRegion(d.expr);
        if (r.start.offset >= prefix and r.end.offset <= prefix + user_bytes and env.store.getPattern(d.pattern) != .assign) response.dependency_scope = "module";
    }
    const tags = env.store.nodes.items.items(.tag);
    for (tags, 0..) |tag, i| {
        const r = env.store.regions.items.items[i];
        if (r.start.offset < prefix or r.end.offset > prefix + user_bytes) continue;
        // User-defined dispatch/defaults need checked-template dependencies, which
        // this pinned adapter does not expose. Never guess those edges.
        switch (tag) {
            .statement_nominal_decl, .statement_alias_decl, .statement_where_alias_decl, .expr_associated_lookup_local, .expr_associated_lookup_resolved => response.dependency_scope = "module",
            .pattern_identifier, .pattern_var_identifier, .pattern_as => {
                const p = env.store.getPattern(@fromBackingInt(@intCast(i)));
                const ident = switch (p) {
                    .assign => |v| v.ident,
                    .var_assign => |v| v.ident,
                    .as => |v| v.ident,
                    else => unreachable,
                };
                try response.binders.append(arena, dupe(env.getIdent(ident)));
            },
            else => {},
        }
    }
    var refs: std.AutoHashMapUnmanaged(can.CIR.Def.Idx, void) = .{};
    var stack: std.ArrayList(can.CIR.Expr.Idx) = .empty;
    var defaults: std.AutoHashMapUnmanaged(can.CIR.Expr.Idx, void) = .{};
    for (defs) |idx| {
        const def = env.store.getDef(idx);
        const pattern = env.store.getPattern(def.pattern);
        if (pattern != .assign) continue;
        const name_region = env.store.getPatternRegion(def.pattern);
        const expr_region = env.store.getExprRegion(def.expr);
        if (name_region.start.offset < prefix or expr_region.end.offset > prefix + user_bytes) continue;
        const name = env.getIdent(pattern.assign.ident);
        if (std.mem.indexOfScalar(u8, name, '.') != null) response.dependency_scope = "module";
        refs.clearRetainingCapacity();
        try can.DependencyGraph.collectNameReferences(env, &patterns, def.expr, &refs, &stack, &defaults, arena);
        var deps: std.ArrayList([]const u8) = .empty;
        // Source order is deterministic; references include uncalled lambda bodies.
        for (defs) |other| if (refs.contains(other)) {
            const p = env.store.getPattern(env.store.getDef(other).pattern);
            if (p == .assign) try deps.append(arena, dupe(env.getIdent(p.assign.ident))) else response.dependency_scope = "module";
        };
        var occurrences: std.ArrayList(Region) = .empty;
        var rename_safe = true;
        for (tags, 0..) |tag, i| {
            if (tag == .expr_var) {
                const e: can.CIR.Expr.Idx = @fromBackingInt(@intCast(i));
                if (env.store.getExpr(e).e_lookup_local.pattern_idx != def.pattern) continue;
                const r = env.store.getExprRegion(e);
                if (r.start.offset < prefix or r.end.offset > prefix + user_bytes) continue;
                if (std.mem.eql(u8, env.common.source[r.start.offset..r.end.offset], name)) {
                    try occurrences.append(arena, .{ .start = r.start.offset - prefix, .end = r.end.offset - prefix });
                } else rename_safe = false;
            } else if (tag == .record_field) {
                const field = env.store.getRecordField(@fromBackingInt(@intCast(i)));
                const e = env.store.getExpr(field.value);
                // A shorthand field also names a public record label. Refuse
                // rename until an explicit shorthand expansion is available.
                if (e == .e_lookup_local and e.e_lookup_local.pattern_idx == def.pattern) rename_safe = false;
            }
        }
        var tw = try env.initTypeWriter();
        defer tw.deinit();
        try tw.write(can.ModuleEnv.varFrom(idx), .one_line);
        try response.definitions.append(arena, .{
            .name = dupe(name),
            .type = dupe(tw.get()),
            .region = .{ .start = name_region.start.offset - prefix, .end = expr_region.end.offset - prefix },
            .name_region = .{ .start = name_region.start.offset - prefix, .end = name_region.end.offset - prefix },
            .dependencies = deps.items,
            .references = occurrences.items,
            .rename_safe = rename_safe,
        });
    }
}
const diag_vtable: runner.Diagnostics.VTable = .{ .write = writeFailure, .emitReport = emitReport };

fn serialize() ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(gpa);
    errdefer writer.deinit();
    try std.json.Stringify.value(.{
        .protocol = response.protocol,
        .display_module = response.display_module,
        .status = response.status,
        .definitions = response.definitions.items,
        .dependency_scope = response.dependency_scope,
        .binders = response.binders.items,
        .diagnostics = response.diagnostics.items,
        .events = response.events.items,
        .failure = response.failure,
        .packagesRequired = Workspace.global.required.items,
        .workspaceCache = runner.last_cache_stats,
    }, .{}, &writer.writer);
    return writer.toOwnedSlice();
}
pub fn process(bytes: []const u8) ![]u8 {
    Workspace.global.clearRequired();
    const probe = std.json.parseFromSlice(std.json.Value, gpa, bytes, .{}) catch return processSource(bytes);
    defer probe.deinit();
    if (probe.value == .object and probe.value.object.contains("operation")) {
        return processDocument(bytes, probe.value);
    }
    if (probe.value == .object and probe.value.object.contains("cells")) {
        return @import("snapshot.zig").evaluate(gpa, bytes, processSource);
    }
    return processSource(bytes);
}

var core_cache: runner.CachedProgram = .{ .allocator = gpa };
fn processCore(bytes: []const u8) ![]u8 {
    return processSourceImpl(bytes, &core_cache);
}
fn processSource(bytes: []const u8) ![]u8 {
    return processSourceImpl(bytes, null);
}
fn processSourceImpl(bytes: []const u8, cache: ?*runner.CachedProgram) ![]u8 {
    var arena_impl = std.heap.ArenaAllocator.init(gpa);
    defer arena_impl.deinit();
    arena = arena_impl.allocator();
    response = .{};
    callback_failed = false;
    bounded_events = cache == null;
    event_bytes = 0;
    events_truncated = false;
    const parsed = std.json.parseFromSlice(Request, arena, bytes, .{ .allocate = .alloc_always }) catch {
        response.status = "protocol_error";
        response.failure = "Malformed request";
        return serialize();
    };
    const req = parsed.value;
    if (req.protocol != 1 or req.user_bytes > req.source.len or req.source.len > 1024 * 1024) {
        response.status = "protocol_error";
        response.failure = "Unsupported protocol or invalid source length (limit 1 MiB)";
        return serialize();
    }
    for (req.files) |file| {
        const path = if (std.mem.startsWith(u8, file.path, "/")) file.path else try std.mem.concat(arena, u8, &.{ "/workspace/", file.path });
        try Workspace.global.put(path, file.source, false);
    }
    user_bytes = req.user_bytes;
    rich_output = req.rich_output;
    value_index = 0;
    var extras: std.ArrayList(runner.ExtraFile) = .empty;
    try extras.appendSlice(arena, req.modules);
    var trusted_display = true;
    var supplied_display = false;
    for (req.modules) |module| if (std.mem.eql(u8, module.name, "Display")) {
        supplied_display = true;
        trusted_display = std.mem.eql(u8, module.content, @embedFile("Display.roc"));
    };
    if (!supplied_display) try extras.append(arena, .{ .name = "Display", .content = @embedFile("Display.roc") });
    // Only the checked, unaliased import of our bundled nominal type opts in.
    // A local type called Display or a different supplied module stays ordinary.
    if (trusted_display and cache == null) {
        const facts = try @import("syntax.zig").roc(arena, req.source[0..req.user_bytes]);
        for (facts.statements) |statement| if (std.mem.eql(u8, statement.kind, "import")) {
            var count: usize = 0;
            var name: []const u8 = "";
            for (facts.tokens) |token| if (token.start >= statement.start and token.end <= statement.end) {
                if (count == 1) name = req.source[@intCast(token.start)..@intCast(token.end)];
                count += 1;
            };
            if (count == 2 and std.mem.eql(u8, name, "Display")) response.display_module = true;
        };
    }
    if (is_wasm) try compiled_builtins.decompress();
    const cold_core = cache != null and cache.?.bytes == null;
    const runtime_buffer = try gpa.alignedAlloc(u8, .@"16", (if (cold_core) @as(usize, if (is_wasm) 1024 else 2048) else 256) * 1024 * 1024);
    defer gpa.free(runtime_buffer);
    var fba = std.heap.FixedBufferAllocator.init(runtime_buffer);

    platform.observer = observe;
    defer platform.observer = null;
    const exit_code = runner.runEcho(.{
        .runtime_fba = &fba,
        .fallback_io = Workspace.global.io(fba.allocator()),
        .std_io = std.Io.failing,
        .source = req.source,
        .app_header = req.app_header,
        .extras = extras.items,
        .diagnostics = .{ .ctx = null, .vtable = &diag_vtable },
        .analyze = if (cache == null) analyze else null,
        .args = req.args,
        .cached_program = cache,
        .check_only = req.check_only,
        .target_usize = if (is_wasm) .u32 else .native,
        .roc_target = if (is_wasm) .wasm32 else @import("roc_target").RocTarget.detectNative(),
    }) catch |err| {
        response.status = if (err == error.CompilationFailed) "diagnostic" else "runtime_error";
        if (response.failure == null) response.failure = dupe(@errorName(err));
        if (callback_failed) return error.OutOfMemory;
        return serialize();
    };
    if (exit_code != 0) response.status = "runtime_error";
    if (callback_failed) return error.OutOfMemory;
    return serialize();
}

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
    const result = process(bytes[0..len]) catch return 0;
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
    Workspace.global.put(input(path_ptr, path_len), input(ptr, len), false) catch return 0;
    return 1;
}
export fn roclet_file_drop(ptr: u32, len: u32) u32 {
    Workspace.global.drop(input(ptr, len));
    return 1;
}
export fn roclet_cache_import(ptr: u32, len: u32) u32 {
    Workspace.global.importCache(input(ptr, len)) catch return 0;
    return 1;
}
export fn roclet_cache_take_updates() u32 {
    const bytes = Workspace.global.takeUpdates() catch return 0;
    defer gpa.free(bytes);
    return storedResponse(bytes);
}
export fn roclet_cache_stats() u32 {
    const bytes = @import("snapshot.zig").json(gpa, runner.last_cache_stats) catch return 0;
    defer gpa.free(bytes);
    return storedResponse(bytes);
}
export fn roclet_cache_identity() u32 {
    return storedResponse(Workspace.identity);
}
export fn roclet_package_install(url_ptr: u32, url_len: u32, ptr: u32, len: u32) u32 {
    Workspace.global.installPackage(input(url_ptr, url_len), input(ptr, len)) catch return 0;
    return 1;
}

var previous_graph: ?[]u8 = null;
fn processDocument(bytes: []const u8, value: std.json.Value) ![]u8 {
    _ = value;
    var storage = std.heap.ArenaAllocator.init(gpa);
    defer storage.deinit();
    const a = storage.allocator();
    var request = try std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{});
    if (request.object.get("files")) |files| if (files == .array) for (files.array.items) |file| {
        const path = file.object.get("path").?.string;
        const full = if (std.mem.startsWith(u8, path, "/")) path else try std.mem.concat(a, u8, &.{ "/workspace/", path });
        try Workspace.global.put(full, file.object.get("source").?.string, false);
    };
    try request.object.put(a, "workspaceFingerprint", .{ .string = try Workspace.global.contentIdentity(a) });
    if (request.object.getPtr("reactivity")) |reactivity| if (reactivity.* == .object and reactivity.object.get("previous") == null) {
        if (previous_graph) |graph| try reactivity.object.put(a, "previous", try std.json.parseFromSliceLeaky(std.json.Value, a, graph, .{}));
    };
    const input_bytes = try @import("snapshot.zig").json(a, request);
    const result = try @import("document.zig").process(gpa, input_bytes, processSource, processCore);
    defer gpa.free(result);
    var parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, result, .{});
    if (parsed == .object) {
        if (parsed.object.get("graph")) |graph| {
            const owned = try @import("snapshot.zig").json(gpa, graph);
            if (previous_graph) |old| gpa.free(old);
            previous_graph = owned;
        }
        try parsed.object.put(a, "packagesRequired", try std.json.parseFromSliceLeaky(std.json.Value, a, try @import("snapshot.zig").json(a, Workspace.global.required.items), .{}));
    }
    return @import("snapshot.zig").json(gpa, parsed);
}
