//! Native/WASM notebook frontend and evaluator. Source assembly is native UTF-8.
//! Requests arrive as a typed `Request` and leave as a typed `Response`; the
//! bridge parses and serialises them exactly once.
const std = @import("std");
const syntax = @import("syntax.zig");
const notebook = @import("notebook.zig");
const script = @import("script.zig");
const Engine = @import("engine_state.zig").Engine;
const frontend = @import("document_frontend.zig");
const baseline = @import("baseline.zig");
const workspace = @import("workspace.zig");
const A = std.mem.Allocator;
const V = std.json.Value;
fn json(a: A, data: anytype) ![]u8 {
    var w: std.Io.Writer.Allocating = .init(a);
    try std.json.Stringify.value(data, .{}, &w.writer);
    return w.toOwnedSlice();
}
fn eql(x: []const u8, y: []const u8) bool {
    return std.mem.eql(u8, x, y);
}

pub const Module = notebook.Module;

/// A document request (`operation` other than `program`). Optional fields
/// keep the protocol-1 leniency: a field of the wrong JSON type reads as its
/// default, except where a malformed value is reported when it is used.
pub const Request = struct {
    operation: []const u8 = "",
    source: []const u8 = "",
    format: []const u8 = "roc",
    action: []const u8 = "parse",
    /// Defaults to `format`.
    target: ?[]const u8 = null,
    compact: bool = false,
    draft: Draft = .absent,
    /// Markdown editing context: document-level Roc configuration.
    context: ?Context = null,
    selected_cell: ?SelectedCell = null,
    reactivity: Reactivity = .absent,
    force_all: bool = false,
    isolate_errors: bool = false,
    render: bool = false,
    modules: Modules = .{},
    /// Identity of the workspace files, set by the bridge.
    workspace_fingerprint: []const u8 = "",

    pub const Draft = union(enum) { absent, malformed, value: frontend.Draft };
    pub const Context = struct { preamble: []const u8, metadata: []const u8 };
    pub const SelectedCell = union(enum) { index: i64, invalid };
    /// `participate` reads and updates the engine's own baseline; `legacy`
    /// is a caller-held baseline, which is rejected.
    pub const Reactivity = union(enum) { absent, malformed, legacy, participate: Participation };
    pub const Participation = struct {
        force: []const []const u8 = &.{},
        /// Forget the engine baseline before planning.
        reset: bool = false,
    };
    pub const Modules = struct {
        /// Null when `modules` is not a list of modules.
        items: ?[]const Module = &.{},
        /// Every module has exactly `name` and `content` (script runs require it).
        strict: bool = true,
    };

    /// Read a parsed request object.
    pub fn fromValue(a: A, request: V, workspace_fingerprint: []const u8) !Request {
        const object = request.object;
        const format = string(request, "format", "roc");
        var result: Request = .{
            .operation = string(request, "operation", ""),
            .source = string(request, "source", ""),
            .format = format,
            .action = string(request, "action", "parse"),
            .target = string(request, "target", format),
            .compact = flag(object.get("compact")),
            .force_all = flag(object.get("forceAll")),
            .isolate_errors = flag(object.get("isolateErrors")),
            .render = flag(object.get("render")),
            .workspace_fingerprint = workspace_fingerprint,
        };
        if (object.get("draft")) |raw| {
            result.draft = .malformed;
            if (raw == .object and raw.object.get("cells") != null) {
                if (std.json.parseFromValueLeaky(frontend.Draft, a, raw, .{ .ignore_unknown_fields = true })) |draft| {
                    result.draft = .{ .value = draft };
                } else |_| {}
            }
        }
        if (object.get("context")) |context| result.context = .{ .preamble = string(context, "preamble", ""), .metadata = string(context, "metadata", "") };
        if (object.get("selectedCell")) |selected| result.selected_cell = if (selected == .integer) .{ .index = selected.integer } else .invalid;
        if (object.get("reactivity")) |raw| {
            result.reactivity = .malformed;
            const legacy = raw == .object and for (legacy_reactivity) |key| {
                if (raw.object.get(key) != null) break true;
            } else false;
            if (legacy) {
                result.reactivity = .legacy;
            } else if (std.json.parseFromValueLeaky(Participation, a, raw, .{ .ignore_unknown_fields = true })) |participation| {
                result.reactivity = .{ .participate = participation };
            } else |_| {}
        }
        if (object.get("modules")) |modules| {
            result.modules = .{
                .items = std.json.parseFromValueLeaky([]const Module, a, modules, .{ .ignore_unknown_fields = true }) catch null,
                .strict = if (std.json.parseFromValueLeaky([]const Module, a, modules, .{})) |_| true else |_| false,
            };
        }
        return result;
    }
    /// Members of a caller-held baseline, from before the engine owned it.
    const legacy_reactivity = [_][]const u8{ "known", "previous", "current", "available", "roots" };
    fn string(o: V, key: []const u8, fallback: []const u8) []const u8 {
        const v = if (o == .object) o.object.get(key) else null;
        return if (v != null and v.? == .string) v.?.string else fallback;
    }
    fn flag(v: ?V) bool {
        return if (v) |value| value == .bool and value.bool else false;
    }
};

/// A document response. `writeFields` emits the protocol-1 members; the
/// bridge appends `workspaceCache` and `packagesRequired`.
pub const Response = union(enum) {
    rejected: struct { status: []const u8 = "protocol_error", failure: []const u8 },
    syntax: struct { facts: syntax.Facts, blocks: []const syntax.Block },
    markdown: struct { status: []const u8 = "ok", events: []const syntax.MarkdownEvent },
    document: *Document,

    pub fn writeFields(self: Response, w: anytype) !void {
        switch (self) {
            .document => |document| try document.writeFields(w),
            inline else => |payload| inline for (@typeInfo(@TypeOf(payload)).@"struct".field_names) |name| {
                try w.objectField(name);
                try w.write(@field(payload, name));
            },
        }
    }
    pub fn jsonStringify(self: Response, w: anytype) !void {
        try w.beginObject();
        try self.writeFields(w);
        try w.endObject();
    }
    fn reject(failure: []const u8) Response {
        return .{ .rejected = .{ .failure = failure } };
    }
};

/// Members of a document response, in protocol-1 wire order. `order`
/// replays how the members were added (and, for compact responses, how
/// `program` was removed), so the wire order stays exactly as before.
const Key = enum { plan, status, model, draft, source, program, execution, roots, expectations, mappings, protocol, graph, evaluation, rendering };
pub const Document = struct {
    order: std.ArrayList(Key) = .empty,
    compact: bool,
    result: frontend.Result,
    diagnostics: []ModelDiagnostic = &.{},
    /// The checked dependency graph; a participating request commits it to
    /// the engine baseline.
    graph: ?frontend.Graph = null,
    evaluation: ?Evaluation = null,
    rendering: []const Rendering = &.{},

    fn put(self: *Document, a: A, key: Key) !void {
        if (std.mem.findScalar(Key, self.order.items, key) == null) try self.order.append(a, key);
    }
    /// `std.json.ObjectMap.swapRemove`: the last member takes the removed slot.
    fn swapRemove(self: *Document, key: Key) void {
        const index = std.mem.findScalar(Key, self.order.items, key) orelse return;
        _ = self.order.swapRemove(index);
    }
    fn writeFields(self: *const Document, w: anytype) !void {
        for (self.order.items) |key| {
            try w.objectField(@tagName(key));
            switch (key) {
                .model => try w.write(ModelView{ .model = self.result.model, .compact = self.compact, .diagnostics = self.diagnostics }),
                .protocol => try w.write(@as(u32, 1)),
                .graph => try w.write(self.graph.?),
                .evaluation => switch (self.evaluation.?) {
                    inline else => |evaluation| try w.write(evaluation),
                },
                .rendering => try w.write(self.rendering),
                inline else => |field| try w.write(@field(self.result, @tagName(field))),
            }
        }
    }
};
const Location = struct { line: u64, column: u64 };
/// A model diagnostic with its source location (and `scope: "cell"` for drafts).
const ModelDiagnostic = struct {
    code: []const u8,
    message: []const u8,
    severity: []const u8,
    start: u64,
    end: u64,
    cell: u64,
    location: Location = .{ .line = 1, .column = 1 },
    scope: ?[]const u8 = null,
    pub fn jsonStringify(self: ModelDiagnostic, w: anytype) !void {
        try w.beginObject();
        inline for (.{ "code", "message", "severity", "start", "end", "cell", "location" }) |name| {
            try w.objectField(name);
            try w.write(@field(self, name));
        }
        if (self.scope) |scope| {
            try w.objectField("scope");
            try w.write(scope);
        }
        try w.endObject();
    }
};
/// Execution responses retain checked source locations and user-visible results.
/// Parser internals and duplicate encodings are only needed by format operations.
const ModelView = struct {
    model: frontend.Model,
    compact: bool,
    diagnostics: []const ModelDiagnostic,
    pub fn jsonStringify(self: ModelView, w: anytype) !void {
        try w.beginObject();
        inline for (.{ "format", "original", "preamble", "metadata" }) |name| {
            if (!(self.compact and comptime eql(name, "original"))) {
                try w.objectField(name);
                try w.write(@field(self.model, name));
            }
        }
        try w.objectField("cells");
        if (self.compact) {
            try w.beginArray();
            for (self.model.cells) |cell| {
                try w.beginObject();
                inline for (.{ "kind", "source", "attributes", "id", "output", "expectations", "outputs", "start", "end", "body_start" }) |name| {
                    try w.objectField(name);
                    try w.write(@field(cell, name));
                }
                try w.endObject();
            }
            try w.endArray();
        } else try w.write(self.model.cells);
        try w.objectField("diagnostics");
        try w.write(self.diagnostics);
        try w.endObject();
    }
};
const Rendering = struct { cell: usize, events: []const syntax.MarkdownEvent };
const Evaluation = union(enum) { document: DocumentEvaluation, script: script.Outcome };
/// `notebook.Evaluation` with events, tests and values attributed to cells.
const DocumentEvaluation = struct {
    protocol: u32,
    requestId: []const u8,
    documentRevision: u64,
    inputRevision: u64,
    workerGeneration: u64,
    status: []const u8,
    definitions: []const notebook.Definition,
    dependency_scope: []const u8,
    binders: []const []const u8,
    root_errors: []const notebook.RootError,
    evaluated_roots: []const []const u8,
    values: []const Value,
    tests: []const TestResult,
    events: []const Event,
    diagnostics: []const @import("engine.zig").Diagnostic,
    failure: ?[]const u8,
};
/// `reused`: the presentation is retained from an earlier request.
const Event = struct { kind: @import("platform.zig").EventKind, message: []const u8, root: []const u8, region: ?notebook.Region = null, sequence: usize, cell: ?usize, reused: bool };
const Placement = struct { cell: u64, start: u64, end: u64, location: Location, scope: []const u8 };
const TestResult = struct {
    root: []const u8,
    passed: bool,
    message: []const u8,
    placement: ?Placement = null,
    reused: bool,
    pub fn jsonStringify(self: TestResult, w: anytype) !void {
        try w.beginObject();
        inline for (.{ "root", "passed", "message" }) |name| {
            try w.objectField(name);
            try w.write(@field(self, name));
        }
        if (self.placement) |placement| inline for (@typeInfo(Placement).@"struct".field_names) |name| {
            try w.objectField(name);
            try w.write(@field(placement, name));
        };
        try w.objectField("reused");
        try w.write(self.reused);
        try w.endObject();
    }
};
const Value = struct {
    root: []const u8,
    text: []const u8,
    display: ?V = null,
    /// Rendered Markdown of a `markdown` display, written as its `events`.
    markdown: ?[]const syntax.MarkdownEvent = null,
    reused: bool,
    pub fn jsonStringify(self: Value, w: anytype) !void {
        try w.beginObject();
        try w.objectField("root");
        try w.write(self.root);
        try w.objectField("text");
        try w.write(self.text);
        if (self.display) |display| {
            try w.objectField("display");
            if (self.markdown) |events| {
                try w.beginObject();
                var it = display.object.iterator();
                while (it.next()) |entry| {
                    try w.objectField(entry.key_ptr.*);
                    if (eql(entry.key_ptr.*, "events")) try w.write(events) else try w.write(entry.value_ptr.*);
                }
                if (display.object.get("events") == null) {
                    try w.objectField("events");
                    try w.write(events);
                }
                try w.endObject();
            } else try w.write(display);
        }
        try w.objectField("reused");
        try w.write(self.reused);
        try w.endObject();
    }
};

// Only the pinned first-party package is supplied by the offline runtime.
const display_package_url = std.mem.trim(u8, @embedFile("display-package-url.txt"), "\r\n");
fn displayDependency(a: A, source: []const u8) !?[]const u8 {
    const facts = try syntax.roc(a, source);
    for (facts.tokens, 0..) |token, i| {
        if (token.start >= facts.header_end) break;
        if (token.depth == 1 and std.mem.eql(u8, source[@intCast(token.start)..@intCast(token.end)], "roclet") and i + 4 < facts.tokens.len) {
            const ts = facts.tokens[i + 1 .. i + 5];
            if (std.mem.eql(u8, ts[0].tag, "OpColon") and std.mem.eql(u8, ts[1].tag, "StringStart") and std.mem.eql(u8, ts[2].tag, "StringPart") and std.mem.eql(u8, ts[3].tag, "StringEnd")) return source[@intCast(ts[2].start)..@intCast(ts[2].end)];
            return "";
        }
    }
    return null;
}
// Parser spans prevent changes inside strings, comments, or Markdown prose.
fn displayImports(a: A, source: []const u8, packaged: bool) ![]const u8 {
    const facts = try syntax.roc(a, source);
    var edits: std.ArrayList(u8) = .empty;
    var cursor: usize = 0;
    for (facts.statements) |stmt| {
        if (!std.mem.eql(u8, stmt.kind, "import")) continue;
        var tokens: std.ArrayList(syntax.Token) = .empty;
        for (facts.tokens) |token| if (token.start >= stmt.start and token.end <= stmt.end) try tokens.append(a, token);
        const ts = tokens.items;
        if (ts.len < 2) continue;
        const start: usize = @intCast(ts[1].start);
        const end: usize = @intCast(ts[1].end);
        if (packaged and (std.mem.eql(u8, source[start..end], "Display") or std.mem.eql(u8, source[start..end], "Input"))) {
            try edits.appendSlice(a, source[cursor..start]);
            try edits.appendSlice(a, "roclet.");
            cursor = start;
        } else if (!packaged and ts.len >= 3 and std.mem.eql(u8, source[start..end], "roclet") and (std.mem.eql(u8, source[@intCast(ts[2].start)..@intCast(ts[2].end)], ".Display") or std.mem.eql(u8, source[@intCast(ts[2].start)..@intCast(ts[2].end)], ".Input"))) {
            // Keep byte positions identical for diagnostics and dependency spans.
            try edits.appendSlice(a, source[cursor..start]);
            try edits.appendNTimes(a, ' ', @intCast(ts[2].start + 1 - start));
            cursor = @intCast(ts[2].start + 1);
        }
    }
    try edits.appendSlice(a, source[cursor..]);
    return edits.toOwnedSlice(a);
}
fn packageRocExport(a: A, source: []const u8) ![]const u8 {
    const rewritten = try displayImports(a, source, true);
    if (std.mem.eql(u8, source, rewritten)) return source;
    if (try displayDependency(a, source)) |url| {
        if (!std.mem.eql(u8, url, display_package_url)) return error.ConflictingRocletPackage;
        return rewritten;
    }
    const facts = try syntax.roc(a, rewritten);
    // The document core supplies the app header. Insert into its dependency record.
    var opening: ?usize = null;
    for (facts.tokens) |token| {
        if (token.start >= facts.header_end) break;
        if (token.depth == 0 and std.mem.eql(u8, token.tag, "OpenCurly")) opening = @intCast(token.end);
    }
    const at = opening orelse return error.MissingAppDependencies;
    const closing: usize = @intCast(facts.header_end - 1);
    const comma = if (std.mem.trim(u8, rewritten[at..closing], " \t\r\n").len == 0) "" else ",";
    return std.fmt.allocPrint(a, "{s} roclet: \"{s}\"{s}{s}", .{ rewritten[0..at], display_package_url, comma, rewritten[at..] });
}
/// Serve one document request. Everything the response references is
/// allocated in `a` (or borrowed from `request`).
pub fn process(engine: *Engine, a: A, request: Request) !Response {
    switch (request.reactivity) {
        .legacy => return .reject("reactivity.known, previous, current, available and roots are not accepted; the engine keeps the baseline"),
        .participate => |participation| if (participation.reset) engine.baseline.clear(),
        else => {},
    }
    const source = request.source;
    if (source.len > 256 * 1024) return .reject("Document limit is 256 KiB");
    const format = request.format;
    if (eql(request.operation, "syntax")) {
        return .{ .syntax = .{ .facts = try syntax.roc(a, source), .blocks = try syntax.markdown(a, source) } };
    }
    if (eql(request.operation, "markdown")) return .{ .markdown = .{ .events = try syntax.renderMarkdown(a, source) } };
    const action = request.action;
    const target = request.target orelse format;
    const compact = request.compact and (eql(action, "analyze") or eql(action, "evaluate"));
    if ((!eql(format, "roc") and !eql(format, "markdown")) or (!eql(target, "roc") and !eql(target, "markdown"))) return .reject("Expected roc or markdown format");
    var draft: frontend.Draft = .{};
    switch (request.draft) {
        .absent => {},
        .malformed => return .reject("Malformed notebook draft"),
        .value => |supplied| {
            draft = supplied;
            var size = draft.preamble.len + draft.metadata.len;
            if (draft.cells.len > 500) return .reject("Notebook limit is 500 cells");
            for (draft.cells) |cell| {
                if (!eql(cell.kind, "code") and !eql(cell.kind, "markdown") and !eql(cell.kind, "generated")) return .reject("Invalid cell kind");
                size += cell.source.len + cell.attributes.len;
                for (cell.outputs) |output| size += output.source.len;
            }
            if (size > 256 * 1024) return .reject("Document limit is 256 KiB");
        },
    }
    draft.supplied = request.draft != .absent;
    var input: frontend.Input = .{
        .compact = compact,
        .phase = "segment",
        .format = format,
        .target = target,
        .source = source,
        .facts = if (eql(format, "roc") and !draft.supplied) try syntax.roc(a, source) else .{},
        .blocks = if (eql(format, "markdown") and !draft.supplied) try syntax.markdown(a, source) else &.{},
        .draft = draft,
    };
    var model = (try frontend.run(a, input)).model;
    for (model.cells) |*cell| {
        if (eql(cell.kind, "code")) cell.facts = try syntax.roc(a, cell.source);
        if (eql(cell.kind, "markdown")) {
            var marker_lines: std.ArrayList(u64) = .empty;
            cell.blocks = try syntax.markdown(a, cell.source);
            if (cell.blocks.len > 0) cell.first_block = cell.blocks[0];
            for (cell.blocks) |block| if (eql(block.kind, "html")) {
                try marker_lines.append(a, std.mem.count(u8, cell.source[0..@intCast(block.start)], "\n"));
            };
            cell.marker_lines = try marker_lines.toOwnedSlice(a);
        }
    }
    // Editing Markdown keeps document-level Roc configuration outside the text.
    if (!draft.supplied and eql(format, "markdown") and model.metadata.len == 0) {
        if (request.context) |context| {
            model.preamble = context.preamble;
            model.metadata = context.metadata;
        }
    }
    var fields: std.ArrayList(frontend.MetadataField) = .empty;
    if (model.metadata.len > 0) {
        const parsed = std.json.parseFromSliceLeaky(V, a, model.metadata, .{}) catch V.null;
        if (parsed == .object) {
            var it = parsed.object.iterator();
            while (it.next()) |entry| try fields.append(a, .{ .key = entry.key_ptr.*, .value = try json(a, entry.value_ptr.*) });
        }
    }
    input.metadata_fields = fields.items;
    input.facts = try syntax.roc(a, model.preamble);
    input.phase = action;
    input.model = model;
    const app_header = model.preamble[0..@intCast(@min(input.facts.header_end, model.preamble.len))];
    const document = try a.create(Document);
    document.* = .{ .compact = compact, .result = try frontend.run(a, input) };
    const result = &document.result;
    try document.order.appendSlice(a, if (compact) &.{ .plan, .status, .model, .program, .roots, .expectations, .mappings } else &.{ .plan, .status, .model, .draft, .source, .program, .execution, .roots, .expectations, .mappings });
    // Compact responses omit `execution` (and never run scripts).
    if (compact) result.execution = "";
    document.diagnostics = try a.alloc(ModelDiagnostic, result.model.diagnostics.len);
    for (document.diagnostics, result.model.diagnostics) |*out, d| out.* = .{ .code = d.code, .message = d.message, .severity = d.severity, .start = d.start, .end = d.end, .cell = d.cell };
    try document.put(a, .protocol);
    if (try displayDependency(a, model.preamble)) |url| {
        if (eql(url, display_package_url)) {
            result.program = try displayImports(a, result.program, false);
            result.execution = try displayImports(a, result.execution, false);
            try document.put(a, .program);
            try document.put(a, .execution);
        }
    }
    if (eql(result.status, "ok") and eql(target, "roc") and (eql(action, "export") or eql(action, "normalize") or (eql(action, "convert") and !eql(format, target)))) {
        result.source = try packageRocExport(a, result.source);
        try document.put(a, .source);
    }

    if ((eql(action, "evaluate") or eql(action, "analyze")) and eql(result.status, "ok")) {
        const program = result.program;
        const cells = result.model.cells;
        var all_roots: std.ArrayList([]const u8) = .empty;
        try all_roots.appendSlice(a, result.roots);
        for (result.expectations) |expectation| try all_roots.append(a, expectation.root);
        result.roots = all_roots.items;
        var roots = result.roots;
        const reactive = request.reactivity != .absent;
        var selected_cell: ?*const frontend.Cell = null;
        if (request.selected_cell) |selected| {
            const index = switch (selected) {
                .index => |index| index,
                .invalid => -1,
            };
            if (index < 0 or index >= cells.len) return .reject("Invalid selected cell");
            selected_cell = &cells[@intCast(index)];
            if (!reactive) roots = try cellRoots(a, selected_cell.?.*);
        }
        const failure_roots = if (selected_cell) |cell| try cellRoots(a, cell.*) else roots;
        const modules = request.modules.items orelse return error.MalformedModules;
        const expectations = try a.alloc(notebook.Expectation, result.expectations.len);
        for (expectations, result.expectations) |*out, expectation| out.* = .{ .root = expectation.root, .start = @intCast(expectation.start), .end = @intCast(expectation.end), .cell = expectation.cell };
        var checked = try notebook.checkDocument(engine, a, .{
            .program = program,
            .app_header = app_header,
            .modules = modules,
            .roots = result.roots,
            .expectations = expectations,
            .cells = &.{.{ .key = "document", .start = 0, .end = program.len }},
            .failure_roots = if (eql(action, "evaluate")) failure_roots else &.{},
            .isolate_errors = request.isolate_errors,
        });
        if (eql(checked.evaluation.status, "ok")) {
            const current = try dependencyGraph(a, &checked, app_header, request.workspace_fingerprint);
            document.graph = current;
            try document.put(a, .graph);
            var reactivity: frontend.PlanInput = switch (request.reactivity) {
                .absent, .legacy => .{},
                .malformed => return error.MalformedReactivity,
                .participate => |participation| try engine.baseline.planInput(a, current, roots, participation.force),
            };
            reactivity.current = current;
            reactivity.roots = roots;
            if (request.force_all) reactivity.force = reactivity.roots;
            if (reactive) if (selected_cell) |cell| {
                reactivity.force = try cellRoots(a, cell.*);
            };
            result.plan = try frontend.plan(a, reactivity);
            if (eql(action, "evaluate") and result.plan.evaluate.len > 0) try checked.evaluate(result.plan.evaluate);
        }
        const evaluation = checked.evaluation;
        // A participating request answers for every root: retained
        // presentations of reused roots, fresh ones of evaluated roots.
        var outcomes: baseline.Outcomes = .{ .values = evaluation.values, .tests = evaluation.tests, .events = evaluation.events };
        const merging = request.reactivity == .participate and document.graph != null;
        if (merging) {
            const reused = result.plan.reused;
            outcomes = try engine.baseline.merge(a, result.roots, reused, outcomes);
            try engine.baseline.commit(document.graph.?, result.roots, reused, .{ .values = evaluation.values, .tests = evaluation.tests, .events = evaluation.events });
        }
        var reused_roots: std.StringHashMapUnmanaged(void) = .empty;
        if (merging) for (result.plan.reused) |root| try reused_roots.put(a, root, {});
        const events = try a.alloc(Event, outcomes.events.len);
        for (events, outcomes.events, 0..) |*out, event, sequence| {
            out.* = .{ .kind = event.kind, .message = event.message, .root = event.root, .region = event.region, .sequence = sequence, .cell = null, .reused = reused_roots.contains(event.root) };
            for (cells, 0..) |cell, index| {
                var matches = eql(cell.output, event.root);
                for (cell.expectations) |expectation| if (eql(expectation, event.root)) {
                    matches = true;
                };
                if (matches) {
                    out.cell = index;
                    break;
                }
            }
        }
        const tests = try a.alloc(TestResult, outcomes.tests.len);
        for (tests, outcomes.tests) |*out, test_result| {
            out.* = .{ .root = test_result.root, .passed = test_result.passed, .message = test_result.message, .reused = reused_roots.contains(test_result.root) };
            for (result.expectations) |expectation| if (eql(expectation.root, test_result.root)) {
                const index = expectation.cell;
                const start = expectation.start;
                const end = expectation.end;
                for (result.mappings) |m| if (m.cell == index and start >= m.generated_start and start < m.generated_end) {
                    const source_start = m.source_start + start - m.generated_start;
                    const cell = cells[@intCast(index)];
                    const test_offset = if (draft.supplied) source_start - cell.body_start else source_start;
                    out.placement = .{
                        .cell = index,
                        .start = test_offset,
                        .end = test_offset + end - start,
                        .location = location(if (draft.supplied) cell.source else source, test_offset),
                        .scope = if (draft.supplied) "cell" else "source",
                    };
                    break;
                };
                break;
            };
        }
        const values = try a.alloc(Value, outcomes.values.len);
        for (values, outcomes.values) |*out, output| {
            out.* = .{ .root = output.root, .text = output.text, .display = output.display, .reused = reused_roots.contains(output.root) };
            if (output.display) |display| {
                if (display == .object and eql(Request.string(display, "kind", ""), "markdown")) {
                    out.markdown = try syntax.renderMarkdown(a, Request.string(display, "content", ""));
                }
            }
        }
        try mapDiagnostics(a, document, evaluation.diagnostics, source, program);
        document.evaluation = .{ .document = .{
            .protocol = evaluation.protocol,
            .requestId = evaluation.requestId,
            .documentRevision = evaluation.documentRevision,
            .inputRevision = evaluation.inputRevision,
            .workerGeneration = evaluation.workerGeneration,
            .status = evaluation.status,
            .definitions = evaluation.definitions,
            .dependency_scope = evaluation.dependency_scope,
            .binders = evaluation.binders,
            .root_errors = evaluation.root_errors,
            .evaluated_roots = evaluation.evaluated_roots,
            .values = values,
            .tests = tests,
            .events = events,
            .diagnostics = evaluation.diagnostics,
            .failure = evaluation.failure,
        } };
        try document.put(a, .evaluation);
        result.status = evaluation.status;
    }
    const check_export = eql(action, "export") and eql(target, "roc");
    if ((eql(action, "check") or eql(action, "run") or check_export) and eql(result.status, "ok")) {
        const execution = result.execution;
        const outcome = try runScript(engine, a, execution, check_export or eql(action, "check"), app_header, request.modules);
        try mapDiagnostics(a, document, outcome.diagnostics, source, execution);
        document.evaluation = .{ .script = outcome };
        try document.put(a, .evaluation);
        result.status = outcome.status;
    }
    locateDiagnostics(document, source, draft.supplied);
    if (request.render) {
        var rendering: std.ArrayList(Rendering) = .empty;
        for (result.model.cells, 0..) |cell, index| {
            if (eql(cell.kind, "markdown")) try rendering.append(a, .{ .cell = index, .events = try syntax.renderMarkdown(a, cell.source) });
        }
        document.rendering = rendering.items;
        try document.put(a, .rendering);
    }
    if (compact) document.swapRemove(.program);
    return .{ .document = document };
}

/// Check (and for `run`, execute) the runnable `execution` text exactly as
/// ordinary `roc` would, with the script pipeline.
fn runScript(engine: *Engine, a: A, execution: []const u8, check_only: bool, app_header: []const u8, modules: Request.Modules) !script.Outcome {
    if (execution.len > notebook.source_limit) return script.rejected(engine, "Unsupported protocol or invalid source length (limit 1 MiB)");
    if (!modules.strict) return script.rejected(engine, "Malformed request");
    return script.run(engine, a, .{ .source = execution, .user_bytes = @intCast(execution.len), .check_only = check_only, .app_header = app_header, .modules = modules.items.? });
}

fn offset(source: []const u8, line: u64, column: u64) usize {
    var pos: usize = 0;
    var n: u64 = 1;
    while (pos < source.len and n < line) : (pos += 1) if (source[pos] == '\n') {
        n += 1;
    };
    return @min(source.len, pos + column -| 1);
}
fn location(source: []const u8, pos: u64) Location {
    var line: u64 = 1;
    var col: u64 = 1;
    for (source[0..@min(source.len, pos)]) |c| {
        if (c == '\n') {
            line += 1;
            col = 1;
        } else col += 1;
    }
    return .{ .line = line, .column = col };
}
/// Attribute compiler diagnostics in the generated `execution` to cells.
fn mapDiagnostics(a: A, document: *Document, diagnostics: []const @import("engine.zig").Diagnostic, source: []const u8, execution: []const u8) !void {
    var mapped: std.ArrayList(ModelDiagnostic) = .fromOwnedSlice(document.diagnostics);
    for (diagnostics) |diag| {
        const filename = diag.filename orelse "";
        if (filename.len > 0 and !eql(std.fs.path.basename(filename), "main.roc")) continue;
        const loc = diag.location orelse continue;
        const begin = offset(execution, loc.start_line, loc.start_column);
        const end = offset(execution, loc.end_line, loc.end_column);
        for (document.result.mappings) |m| {
            if (m.generated_start <= begin and begin < m.generated_end) {
                const start = @min(m.source_end, m.source_start + begin - m.generated_start);
                const finish = @min(m.source_end, m.source_start + end - m.generated_start);
                try mapped.append(a, .{ .code = "roc-check", .message = diag.message, .severity = diag.severity, .start = start, .end = finish, .cell = m.cell, .location = location(source, start) });
                break;
            }
        }
    }
    document.diagnostics = mapped.items;
}

fn originalOffset(cell: frontend.Cell, absolute: u64) u64 {
    const base = cell.body_start;
    if (absolute < base) return absolute;
    const relative = absolute - base;
    for (cell.source_map) |m| {
        if (m.start <= relative and relative < m.end) return base + @min(m.original_end, m.original_start + relative - m.start);
    }
    for (cell.source_map) |m| if (m.end == relative and m.end > m.start) return base + m.original_end;
    return absolute;
}
fn locateDiagnostics(document: *Document, source: []const u8, draft: bool) void {
    const cells = document.result.model.cells;
    for (document.diagnostics) |*d| {
        var start = d.start;
        var end = d.end;
        const index = d.cell;
        if (index < cells.len) {
            start = originalOffset(cells[@intCast(index)], start);
            end = originalOffset(cells[@intCast(index)], end);
        }
        d.start = start;
        d.end = end;
        d.location = location(if (draft and index < cells.len) cells[@intCast(index)].source else source, start);
        if (draft) d.scope = "cell";
    }
}
fn cellRoots(a: A, cell: frontend.Cell) ![]const []const u8 {
    var roots: std.ArrayList([]const u8) = .empty;
    if (cell.output.len > 0) try roots.append(a, cell.output);
    try roots.appendSlice(a, cell.expectations);
    return roots.items;
}

/// The request's graph: the revision's checked nodes (`analysis.zig`) and a
/// context covering everything outside them that can change a result.
fn dependencyGraph(a: A, checked: *const notebook.Checked, app_header: []const u8, workspace_fingerprint: []const u8) !frontend.Graph {
    const analysis = checked.analysis.?;
    var context = std.crypto.hash.sha2.Sha256.init(.{});
    workspace.hashField(&context, "roclet-context-v2");
    // The target-independent compiler identity: native and WASM engines must
    // agree on every graph, and the compatibility id hashes target and mode.
    workspace.hashField(&context, &@import("build_options").compiler_artifact_hash);
    for ((try syntax.roc(a, app_header)).tokens) |token| {
        workspace.hashField(&context, token.tag);
        workspace.hashField(&context, app_header[@intCast(token.start)..@intCast(token.end)]);
    }
    workspace.hashField(&context, analysis.graph.context);
    workspace.hashField(&context, if (checked.rich_support) "rich" else "plain");
    workspace.hashField(&context, workspace_fingerprint);
    var digest: [32]u8 = undefined;
    context.final(&digest);
    return .{
        .context = try a.dupe(u8, &std.fmt.bytesToHex(digest, .lower)),
        .scope = @tagName(analysis.dependency_scope),
        .definitions = analysis.graph.definitions,
        .types = analysis.graph.types,
        .modules = analysis.graph.modules,
    };
}

test {
    _ = baseline;
}

test "compact execution response omits parser payloads and preserves editor and output contracts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cell: frontend.Cell = .{
        .kind = "code",
        .source = "out_total = 7",
        .attributes = "id=total",
        .id = "total",
        .output = "out_total",
        .outputs = &.{.{ .kind = "text", .source = "saved 7" }},
        .start = 0,
        .end = 13,
        .body_start = 0,
        .facts = .{ .tokens = try a.alloc(syntax.Token, 100) },
        .source_map = &.{.{ .start = 0, .end = 13, .original_start = 0, .original_end = 13 }},
    };
    for (cell.facts.tokens) |*token| token.* = .{ .start = 0, .end = 9, .depth = 0, .tag = "LowerIdent" };
    const prepared: frontend.Result = .{
        .model = .{ .original = "# %%\nout_total = 7", .cells = @as([*]frontend.Cell, @ptrCast(&cell))[0..1] },
        .draft = .{ .cells = &.{.{ .kind = "code", .source = "out_total = 7" }} },
        .source = "# %%\nout_total = 7",
        .program = "out_total = 7\n\n",
        .execution = "out_total = 7\n\nmain! = |_args| Ok({})",
        .roots = &.{"out_total"},
        .mappings = &.{.{ .generated_start = 0, .generated_end = 13, .source_start = 0, .source_end = 13, .cell = 0 }},
    };
    var full: Document = .{ .compact = false, .result = prepared };
    try full.order.appendSlice(a, &.{ .plan, .status, .model, .draft, .source, .program, .execution, .roots, .expectations, .mappings, .protocol });
    var compact: Document = .{ .compact = true, .result = prepared };
    try compact.order.appendSlice(a, &.{ .plan, .status, .model, .program, .roots, .expectations, .mappings, .protocol });
    compact.swapRemove(.program);
    const full_json = try json(a, Response{ .document = &full });
    const compact_json = try json(a, Response{ .document = &compact });
    try std.testing.expect(compact_json.len * 4 < full_json.len);
    const parsed = try std.json.parseFromSliceLeaky(V, a, compact_json, .{});
    for ([_][]const u8{ "program", "execution", "source", "draft" }) |key| try std.testing.expect(parsed.object.get(key) == null);
    // Removing `program` moves the last member into its slot, as protocol 1 always has.
    try std.testing.expectEqualStrings("protocol", parsed.object.keys()[3]);
    const model = parsed.object.get("model").?;
    try std.testing.expect(model.object.get("original") == null);
    const out = model.object.get("cells").?.array.items[0];
    for ([_][]const u8{ "facts", "blocks", "first_block", "marker_lines", "source_map" }) |key| try std.testing.expect(out.object.get(key) == null);
    try std.testing.expectEqualStrings(cell.source, out.object.get("source").?.string);
    try std.testing.expectEqualStrings(cell.output, out.object.get("output").?.string);
    try std.testing.expectEqualStrings("saved 7", out.object.get("outputs").?.array.items[0].object.get("source").?.string);
    try std.testing.expectEqual(@as(i64, 0), out.object.get("body_start").?.integer);
    try std.testing.expectEqual(@as(usize, 1), parsed.object.get("mappings").?.array.items.len);
    try std.testing.expectEqualStrings("out_total", parsed.object.get("roots").?.array.items[0].string);
}
