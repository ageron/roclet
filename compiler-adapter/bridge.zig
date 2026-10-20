//! Roclet M0 whole-module bridge. Built unchanged for native and wasm32.
const std = @import("std");
const builtin = @import("builtin");
const runner = @import("engine.zig");
pub const platform = @import("platform.zig");
const can = @import("can");
const reporting = @import("reporting");
const Workspace = @import("workspace.zig");
pub const Engine = @import("engine_state.zig").Engine;
const compiled_builtins = @import("compiled_builtins");
pub const roc_compressed_builtins = @import("compressed_builtins");

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
    root: ?[]const u8 = null,
    notebook: ?@import("notebook.zig").Metadata = null,
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
const Event = struct {
    kind: []const u8,
    message: []const u8,
    root: ?[]const u8 = null,
    pub fn jsonStringify(self: @This(), w: anytype) !void {
        try w.beginObject();
        try w.objectField("kind");
        try w.write(self.kind);
        try w.objectField("message");
        try w.write(self.message);
        if (self.root) |root| {
            try w.objectField("root");
            try w.write(root);
        }
        try w.endObject();
    }
};
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
/// The protocol-1 response being built for one `processSource` call, with its
/// observation bounds. Compiler callbacks reach it through `Diagnostics.ctx`,
/// the analysis callback context and `platform.Observer.ctx`.
const ResponseBuilder = struct {
    arena: std.mem.Allocator,
    response: Response = .{},
    user_bytes: u32 = 0,
    /// An allocation failed inside a callback that cannot return an error.
    failed: bool = false,
    event_bytes: usize = 0,
    truncated: bool = false,
    rich_output: bool = false,
    value_index: usize = 0,
    expectations: []const @import("notebook.zig").Expectation = &.{},

    fn dupe(self: *ResponseBuilder, s: []const u8) []const u8 {
        return self.arena.dupe(u8, s) catch {
            self.failed = true;
            return "";
        };
    }
    /// The request observer; the notebook pipeline sets its `root` per execution.
    fn observer(self: *ResponseBuilder) platform.Observer {
        return .{ .ctx = self, .emit = observe };
    }
    fn diagnostics(self: *ResponseBuilder) runner.Diagnostics {
        return .{ .ctx = self, .vtable = &diag_vtable };
    }
    fn analyzer(self: *ResponseBuilder) runner.Analyzer {
        return .{ .ctx = self, .call = analyze };
    }
    fn serialize(self: *ResponseBuilder, engine: *Engine) ![]u8 {
        var writer: std.Io.Writer.Allocating = .init(gpa);
        errdefer writer.deinit();
        try std.json.Stringify.value(.{
            .protocol = self.response.protocol,
            .display_module = self.response.display_module,
            .status = self.response.status,
            .definitions = self.response.definitions.items,
            .dependency_scope = self.response.dependency_scope,
            .binders = self.response.binders.items,
            .diagnostics = self.response.diagnostics.items,
            .events = self.response.events.items,
            .failure = self.response.failure,
            .packagesRequired = engine.workspace.required.items,
            .workspaceCache = engine.stats,
        }, .{}, &writer.writer);
        return writer.toOwnedSlice();
    }
    /// Record a pipeline failure and serialize the final response.
    fn finish(self: *ResponseBuilder, engine: *Engine, outcome: anytype) ![]u8 {
        const exit_code = outcome catch |err| code: {
            self.response.status = switch (err) {
                error.CompilationFailed => "diagnostic",
                else => "runtime_error",
            };
            if (self.response.failure == null) self.response.failure = self.dupe(@errorName(err));
            break :code 0;
        };
        if (exit_code != 0) self.response.status = "runtime_error";
        if (self.failed) return error.OutOfMemory;
        return self.serialize(engine);
    }
};
fn builderFrom(ctx: ?*anyopaque) *ResponseBuilder {
    return @ptrCast(@alignCast(ctx orelse unreachable));
}
fn observe(ctx: *anyopaque, kind: []const u8, message: []const u8, root: ?[]const u8) void {
    const self: *ResponseBuilder = @ptrCast(@alignCast(ctx));
    const designated = std.mem.eql(u8, kind, "value");
    const value_limit: usize = if (self.rich_output and self.value_index == 1) 512 * 1024 else 64 * 1024;
    if (designated) self.value_index += 1;
    var end = @min(message.len, if (designated) value_limit else @min(@as(usize, 64 * 1024), 256 * 1024 -| self.event_bytes));
    if (!designated and self.response.events.items.len >= 1000) end = 0;
    while (end > 0 and end < message.len and message[end] & 0xc0 == 0x80) end -= 1;
    if (end < message.len and !self.truncated) {
        self.truncated = true;
        self.response.events.append(self.arena, .{ .kind = "truncated", .message = "Output truncated: at most 1,000 observations, 256 KiB of observations, and 64 KiB per text result/message (512 KiB for rich data) are retained per root." }) catch {
            self.failed = true;
        };
    }
    if (end == 0 and message.len > 0 and !designated) return;
    self.event_bytes += end;
    self.response.events.append(self.arena, .{ .kind = kind, .message = self.dupe(message[0..end]), .root = if (root) |name| self.dupe(name) else null }) catch {
        self.failed = true;
    };
}
fn writeFailure(ctx: ?*anyopaque, message: []const u8) void {
    const self = builderFrom(ctx);
    self.response.failure = self.dupe(message);
}
fn emitReport(ctx: ?*anyopaque, _: std.mem.Allocator, report: *reporting.Report) void {
    const self = builderFrom(ctx);
    var writer: std.Io.Writer.Allocating = .init(self.arena);
    defer writer.deinit();
    reporting.renderReport(report, &writer.writer, .markdown) catch {
        self.failed = true;
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
            filename = self.dupe(name);
            break;
        }
    }
    self.response.diagnostics.append(self.arena, .{
        .title = self.dupe(report.title),
        .severity = if (report.severity.isError()) "error" else "warning",
        .message = self.dupe(writer.written()),
        .filename = filename,
        .location = if (loc) |r| .{
            .start_line = r.start_line_idx,
            .start_column = r.start_col_idx,
            .end_line = r.end_line_idx,
            .end_column = r.end_col_idx,
        } else null,
    }) catch {
        self.failed = true;
    };
}
fn analyze(ctx: *anyopaque, env: *can.ModuleEnv, prefix: u32) void {
    const self: *ResponseBuilder = @ptrCast(@alignCast(ctx));
    analyzeFallible(self, env, prefix) catch {
        self.failed = true;
    };
}
fn analyzeFallible(self: *ResponseBuilder, env: *can.ModuleEnv, prefix: u32) !void {
    const defs = env.store.sliceDefs(env.all_defs);
    var patterns: std.AutoHashMapUnmanaged(can.CIR.Pattern.Idx, can.CIR.Def.Idx) = .{};
    var binders: std.ArrayList(can.CIR.Pattern.Idx) = .empty;
    var binder_stack: std.ArrayList(can.CIR.Pattern.Idx) = .empty;
    for (defs) |idx| {
        binders.clearRetainingCapacity();
        try can.DependencyGraph.appendPatternBinders(env, env.store.getDef(idx).pattern, &binders, &binder_stack, self.arena);
        for (binders.items) |binder| try patterns.put(self.arena, binder, idx);
        const d = env.store.getDef(idx);
        const r = env.store.getExprRegion(d.expr);
        if (r.start.offset >= prefix and r.end.offset <= prefix + self.user_bytes and env.store.getPattern(d.pattern) != .assign) self.response.dependency_scope = "module";
    }
    const tags = env.store.nodes.items.items(.tag);
    for (tags, 0..) |tag, i| {
        const r = env.store.regions.items.items[i];
        if (r.start.offset < prefix or r.end.offset > prefix + self.user_bytes) continue;
        // User-defined dispatch/defaults need checked-template dependencies, which
        // this pinned adapter does not expose. Never guess those edges.
        switch (tag) {
            .statement_nominal_decl, .statement_alias_decl, .statement_where_alias_decl, .expr_associated_lookup_local, .expr_associated_lookup_resolved => self.response.dependency_scope = "module",
            .pattern_identifier, .pattern_var_identifier, .pattern_as => {
                const p = env.store.getPattern(@fromBackingInt(@intCast(i)));
                const ident = switch (p) {
                    .assign => |v| v.ident,
                    .var_assign => |v| v.ident,
                    .as => |v| v.ident,
                    else => unreachable,
                };
                try self.response.binders.append(self.arena, self.dupe(env.getIdent(ident)));
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
        if (name_region.start.offset < prefix or expr_region.end.offset > prefix + self.user_bytes) continue;
        const name = env.getIdent(pattern.assign.ident);
        if (std.mem.findScalar(u8, name, '.') != null) self.response.dependency_scope = "module";
        refs.clearRetainingCapacity();
        try can.DependencyGraph.collectNameReferences(env, &patterns, def.expr, &refs, &stack, &defaults, self.arena);
        var deps: std.ArrayList([]const u8) = .empty;
        // Source order is deterministic; references include uncalled lambda bodies.
        for (defs) |other| if (refs.contains(other)) {
            const p = env.store.getPattern(env.store.getDef(other).pattern);
            if (p == .assign) try deps.append(self.arena, self.dupe(env.getIdent(p.assign.ident))) else self.response.dependency_scope = "module";
        };
        var occurrences: std.ArrayList(Region) = .empty;
        var rename_safe = true;
        for (tags, 0..) |tag, i| {
            if (tag == .expr_var) {
                const e: can.CIR.Expr.Idx = @fromBackingInt(@intCast(i));
                if (env.store.getExpr(e).e_lookup_local.pattern_idx != def.pattern) continue;
                const r = env.store.getExprRegion(e);
                if (r.start.offset < prefix or r.end.offset > prefix + self.user_bytes) continue;
                if (std.mem.eql(u8, env.common.source[r.start.offset..r.end.offset], name)) {
                    try occurrences.append(self.arena, .{ .start = r.start.offset - prefix, .end = r.end.offset - prefix });
                } else rename_safe = false;
            } else if (tag == .record_field) {
                const field = env.store.getRecordField(@fromBackingInt(@intCast(i)));
                const e = env.store.getExpr(field.value);
                // A shorthand field also names a public record label. Refuse
                // rename until an explicit shorthand expansion is available.
                if (e == .e_lookup_local and e.e_lookup_local.pattern_idx == def.pattern) rename_safe = false;
            }
        }
        var tw = try runner.scratchTypeWriter(env, self.arena);
        defer tw.deinit();
        try tw.write(can.ModuleEnv.varFrom(idx), .one_line);
        try self.response.definitions.append(self.arena, .{
            .name = self.dupe(name),
            .type = self.dupe(tw.get()),
            .region = .{ .start = name_region.start.offset - prefix, .end = expr_region.end.offset - prefix },
            .name_region = .{ .start = name_region.start.offset - prefix, .end = name_region.end.offset - prefix },
            .dependencies = deps.items,
            .references = occurrences.items,
            .rename_safe = rename_safe,
        });
    }
    // Tests are real checked statement roots rather than generated bindings.
    // Expose their resolved references to the same reactive graph as outputs.
    for (self.expectations) |expectation| {
        for (env.store.sliceStatements(env.all_statements)) |idx| {
            const statement = env.store.getStatement(idx);
            if (statement != .s_expect) continue;
            const region = env.store.getStatementRegion(idx);
            if (region.start.offset < prefix or region.start.offset - prefix < expectation.start or region.start.offset - prefix >= expectation.end) continue;
            refs.clearRetainingCapacity();
            try can.DependencyGraph.collectNameReferences(env, &patterns, statement.s_expect.body, &refs, &stack, &defaults, self.arena);
            var deps: std.ArrayList([]const u8) = .empty;
            for (defs) |other| if (refs.contains(other)) {
                const pattern = env.store.getPattern(env.store.getDef(other).pattern);
                if (pattern == .assign) try deps.append(self.arena, self.dupe(env.getIdent(pattern.assign.ident))) else self.response.dependency_scope = "module";
            };
            try self.response.definitions.append(self.arena, .{
                .name = self.dupe(expectation.root),
                .type = "Bool",
                .region = .{ .start = expectation.start, .end = expectation.end },
                .name_region = .{ .start = expectation.start, .end = expectation.start },
                .dependencies = deps.items,
                .references = &.{},
                .rename_safe = false,
            });
            break;
        }
    }
}
const diag_vtable: runner.Diagnostics.VTable = .{ .write = writeFailure, .emitReport = emitReport };

/// Serve one top-level request. The response is owned by the page allocator
/// (the WASM allocator in the browser).
pub fn process(engine: *Engine, bytes: []const u8) ![]u8 {
    engine.beginRequest();
    const probe = std.json.parseFromSlice(std.json.Value, gpa, bytes, .{}) catch return processSource(engine, bytes);
    defer probe.deinit();
    if (probe.value == .object) try mountFiles(engine, probe.value, gpa);
    if (probe.value == .object and probe.value.object.contains("operation")) {
        return processDocument(engine, bytes);
    }
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
    var builder: ResponseBuilder = .{ .arena = arena_impl.allocator() };
    const arena = builder.arena;
    const parsed = std.json.parseFromSlice(Request, arena, bytes, .{ .allocate = .alloc_always }) catch {
        builder.response.status = "protocol_error";
        builder.response.failure = "Malformed request";
        return builder.serialize(engine);
    };
    const req = parsed.value;
    if (req.protocol != 1 or req.user_bytes > req.source.len or req.source.len > 1024 * 1024) {
        builder.response.status = "protocol_error";
        builder.response.failure = "Unsupported protocol or invalid source length (limit 1 MiB)";
        return builder.serialize(engine);
    }
    for (req.files) |file| {
        const path = if (std.mem.startsWith(u8, file.path, "/")) file.path else try std.mem.concat(arena, u8, &.{ engine.paths.extras_prefix, file.path });
        try engine.workspace.put(path, file.source, false);
    }
    builder.user_bytes = req.user_bytes;
    builder.rich_output = req.rich_output;
    var extras: std.ArrayList(runner.ExtraFile) = .empty;
    try extras.appendSlice(arena, req.modules);
    var trusted_display = true;
    var supplied_display = false;
    for (req.modules) |module| if (std.mem.eql(u8, module.name, "Display")) {
        supplied_display = true;
        trusted_display = std.mem.eql(u8, module.content, @embedFile("Display.roc"));
    };
    if (!supplied_display) {
        const display_path = try std.mem.concat(arena, u8, &.{ engine.paths.extras_prefix, "Display.roc" });
        const io = engine.workspace.io(arena);
        const display_source = io.readFile(display_path, arena) catch null;
        if (display_source) |content| {
            trusted_display = std.mem.eql(u8, content, @embedFile("Display.roc"));
            try extras.append(arena, .{ .name = "Display", .content = content });
        } else try extras.append(arena, .{ .name = "Display", .content = @embedFile("Display.roc") });
    }
    // Only the checked, unaliased import of our bundled nominal type opts in.
    // A local type called Display or a different supplied module stays ordinary.
    if (trusted_display) {
        const facts = try @import("syntax.zig").roc(arena, req.source[0..req.user_bytes]);
        for (facts.statements) |statement| if (std.mem.eql(u8, statement.kind, "import")) {
            var count: usize = 0;
            var name: []const u8 = "";
            for (facts.tokens) |token| if (token.start >= statement.start and token.end <= statement.end) {
                if (count == 1) name = req.source[@intCast(token.start)..@intCast(token.end)];
                count += 1;
            };
            if (count == 2 and std.mem.eql(u8, name, "Display")) builder.response.display_module = true;
        };
    }
    if (is_wasm) try compiled_builtins.decompress();
    if (req.notebook) |notebook| {
        builder.expectations = notebook.expectations;
        return builder.finish(engine, @import("notebook.zig").run(engine, .{
            .source = req.source,
            .app_header = req.app_header,
            .extras = extras.items,
            .paths = engine.paths,
            .metadata = notebook,
            .root = req.root,
            .rich_support = builder.response.display_module,
            .target_usize = if (is_wasm) .u32 else .native,
            .roc_target = if (is_wasm) .wasm32 else @import("roc_target").RocTarget.detectNative(),
            .diagnostics = builder.diagnostics(),
            .analyze = builder.analyzer(),
            .observer = builder.observer(),
        }));
    }
    const runtime_buffer = try gpa.alignedAlloc(u8, .@"16", 256 * 1024 * 1024);
    defer gpa.free(runtime_buffer);
    var fba = std.heap.FixedBufferAllocator.init(runtime_buffer);
    return builder.finish(engine, runner.runEcho(.{
        .runtime_fba = &fba,
        .paths = engine.paths,
        .fallback_io = engine.workspace.io(fba.allocator()),
        .std_io = engine.workspace.std_io,
        .stats = &engine.stats,
        .source = req.source,
        .app_header = req.app_header,
        .root_name = req.root,
        .extras = extras.items,
        .diagnostics = builder.diagnostics(),
        .analyze = builder.analyzer(),
        .observer = builder.observer(),
        .args = req.args,
        .check_only = req.check_only,
        .target_usize = if (is_wasm) .u32 else .native,
        .roc_target = if (is_wasm) .wasm32 else @import("roc_target").RocTarget.detectNative(),
    }));
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
