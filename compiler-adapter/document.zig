//! Native/WASM notebook frontend and evaluator. Source assembly is native UTF-8.
const std = @import("std");
const syntax = @import("syntax.zig");
const snapshot = @import("snapshot.zig");
const frontend = @import("document_frontend.zig");
const A = std.mem.Allocator;
const V = std.json.Value;
fn json(a: A, data: anytype) ![]u8 {
    var w: std.Io.Writer.Allocating = .init(a);
    try std.json.Stringify.value(data, .{}, &w.writer);
    return w.toOwnedSlice();
}
fn value(a: A, data: anytype) !V {
    return std.json.parseFromSliceLeaky(V, a, try json(a, data), .{ .allocate = .alloc_always });
}
fn string(o: V, key: []const u8, fallback: []const u8) []const u8 {
    const v = if (o == .object) o.object.get(key) else null;
    return if (v != null and v.? == .string) v.?.string else fallback;
}
// Execution responses retain checked source locations and user-visible results.
// Parser internals and duplicate encodings are only needed by format operations.
const CompactCell = struct {
    kind: []const u8,
    source: []const u8,
    attributes: []const u8,
    id: []const u8,
    output: []const u8,
    expectations: []const []const u8,
    outputs: []const frontend.Output,
    start: u64,
    end: u64,
    body_start: u64,
    source_map: []const frontend.SourceMap,
};
fn frontendValue(a: A, result: frontend.Result, compact: bool) !V {
    if (!compact) return value(a, result);
    const cells = try a.alloc(CompactCell, result.model.cells.len);
    for (result.model.cells, cells) |c, *out| out.* = .{
        .kind = c.kind,
        .source = c.source,
        .attributes = c.attributes,
        .id = c.id,
        .output = c.output,
        .expectations = c.expectations,
        .outputs = c.outputs,
        .start = c.start,
        .end = c.end,
        .body_start = c.body_start,
        .source_map = c.source_map,
    };
    return value(a, .{ .plan = result.plan, .status = result.status, .model = .{ .format = result.model.format, .preamble = result.model.preamble, .metadata = result.model.metadata, .cells = cells, .diagnostics = result.model.diagnostics }, .program = result.program, .roots = result.roots, .expectations = result.expectations, .mappings = result.mappings });
}
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
        if (packaged and std.mem.eql(u8, source[start..end], "Display")) {
            try edits.appendSlice(a, source[cursor..start]);
            try edits.appendSlice(a, "roclet.");
            cursor = start;
        } else if (!packaged and ts.len >= 3 and std.mem.eql(u8, source[start..end], "roclet") and std.mem.eql(u8, source[@intCast(ts[2].start)..@intCast(ts[2].end)], ".Display")) {
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
fn finishCompact(result: *V) void {
    _ = result.object.swapRemove("program");
    for (fieldArray(result.object.get("model").?, "cells")) |*cell| _ = cell.object.swapRemove("source_map");
}
/// `compiler.compile(request)` serves each nested protocol-1 request.
pub fn process(gpa: A, bytes: []const u8, compiler: anytype) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const request = try std.json.parseFromSliceLeaky(V, a, bytes, .{});
    const source = string(request, "source", "");
    if (source.len > 256 * 1024) return json(gpa, .{ .status = "protocol_error", .failure = "Document limit is 256 KiB" });
    const format = string(request, "format", "roc");
    if (std.mem.eql(u8, string(request, "operation", ""), "syntax")) {
        return json(gpa, .{ .facts = try syntax.roc(a, source), .blocks = try syntax.markdown(a, source) });
    }
    if (std.mem.eql(u8, string(request, "operation", ""), "markdown")) return json(gpa, .{ .status = "ok", .events = try syntax.renderMarkdown(a, source) });
    const action = string(request, "action", "parse");
    const target = string(request, "target", format);
    const compact_requested = request.object.get("compact") orelse .null;
    const compact = compact_requested == .bool and compact_requested.bool and (std.mem.eql(u8, action, "analyze") or std.mem.eql(u8, action, "evaluate"));
    if ((!std.mem.eql(u8, format, "roc") and !std.mem.eql(u8, format, "markdown")) or (!std.mem.eql(u8, target, "roc") and !std.mem.eql(u8, target, "markdown"))) return json(gpa, .{ .status = "protocol_error", .failure = "Expected roc or markdown format" });
    const draft_value = request.object.get("draft");
    var draft: frontend.Draft = .{};
    if (draft_value) |raw| {
        if (raw != .object or raw.object.get("cells") == null) return json(gpa, .{ .status = "protocol_error", .failure = "Malformed notebook draft" });
        draft = std.json.parseFromValueLeaky(frontend.Draft, a, raw, .{ .ignore_unknown_fields = true }) catch return json(gpa, .{ .status = "protocol_error", .failure = "Malformed notebook draft" });
        var size = draft.preamble.len + draft.metadata.len;
        if (draft.cells.len > 500) return json(gpa, .{ .status = "protocol_error", .failure = "Notebook limit is 500 cells" });
        for (draft.cells) |cell| {
            if (!std.mem.eql(u8, cell.kind, "code") and !std.mem.eql(u8, cell.kind, "markdown") and !std.mem.eql(u8, cell.kind, "generated")) return json(gpa, .{ .status = "protocol_error", .failure = "Invalid cell kind" });
            size += cell.source.len + cell.attributes.len;
            for (cell.outputs) |output| size += output.source.len;
        }
        if (size > 256 * 1024) return json(gpa, .{ .status = "protocol_error", .failure = "Document limit is 256 KiB" });
    }
    draft.supplied = draft_value != null;
    var input: frontend.Input = .{
        .compact = compact,
        .phase = "segment",
        .format = format,
        .target = target,
        .source = source,
        .facts = if (std.mem.eql(u8, format, "roc") and !draft.supplied) try syntax.roc(a, source) else .{},
        .blocks = if (std.mem.eql(u8, format, "markdown") and !draft.supplied) try syntax.markdown(a, source) else &.{},
        .draft = draft,
    };
    var model = (try frontend.run(a, input)).model;
    for (model.cells) |*cell| {
        if (std.mem.eql(u8, cell.kind, "code")) cell.facts = try syntax.roc(a, cell.source);
        if (std.mem.eql(u8, cell.kind, "markdown")) {
            var marker_lines: std.ArrayList(u64) = .empty;
            cell.blocks = try syntax.markdown(a, cell.source);
            if (cell.blocks.len > 0) cell.first_block = cell.blocks[0];
            for (cell.blocks) |block| if (std.mem.eql(u8, block.kind, "html")) {
                try marker_lines.append(a, std.mem.count(u8, cell.source[0..@intCast(block.start)], "\n"));
            };
            cell.marker_lines = try marker_lines.toOwnedSlice(a);
        }
    }
    // Editing Markdown keeps document-level Roc configuration outside the text.
    if (!draft.supplied and std.mem.eql(u8, format, "markdown") and model.metadata.len == 0) {
        if (request.object.get("context")) |context| {
            model.preamble = string(context, "preamble", "");
            model.metadata = string(context, "metadata", "");
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
    var result = try frontendValue(a, try frontend.run(a, input), compact);
    try result.object.put(a, "protocol", .{ .integer = 1 });
    if (try displayDependency(a, model.preamble)) |url| {
        if (std.mem.eql(u8, url, display_package_url)) {
            inline for (.{ "program", "execution" }) |key| try result.object.put(a, key, .{ .string = try displayImports(a, string(result, key, ""), false) });
        }
    }
    if (std.mem.eql(u8, string(result, "status", ""), "ok") and std.mem.eql(u8, target, "roc") and (std.mem.eql(u8, action, "export") or std.mem.eql(u8, action, "normalize") or (std.mem.eql(u8, action, "convert") and !std.mem.eql(u8, format, target)))) {
        try result.object.put(a, "source", .{ .string = try packageRocExport(a, string(result, "source", "")) });
    }

    if ((std.mem.eql(u8, action, "evaluate") or std.mem.eql(u8, action, "analyze")) and std.mem.eql(u8, string(result, "status", ""), "ok")) {
        const program = string(result, "program", "");
        var all_roots = result.object.get("roots").?;
        for (fieldArray(result, "expectations")) |expectation| try all_roots.array.append(expectation.object.get("root").?);
        try result.object.put(a, "roots", all_roots);
        var roots = all_roots;
        const reactive = request.object.get("reactivity");
        if (request.object.get("selectedCell")) |selected| {
            const cells = fieldArray(result.object.get("model").?, "cells");
            if (selected != .integer or selected.integer < 0 or selected.integer >= cells.len) return json(gpa, .{ .status = "protocol_error", .failure = "Invalid selected cell" });
            if (reactive == null) {
                roots = try cellRoots(a, cells[@intCast(selected.integer)]);
            }
        }
        var failure_roots = roots;
        if (request.object.get("selectedCell")) |selected| {
            const cell = fieldArray(result.object.get("model").?, "cells")[@intCast(selected.integer)];
            failure_roots = try cellRoots(a, cell);
        }
        const modules = request.object.get("modules") orelse try value(a, &[_]V{});
        const checked_bytes = try snapshot.evaluate(gpa, try json(a, .{
            .cells = .{.{ .key = "document", .source = program }},
            .roots = &[_]V{},
            .possible_roots = result.object.get("roots").?,
            .failure_roots = if (std.mem.eql(u8, action, "evaluate")) failure_roots else try value(a, &[_]V{}),
            .isolate_errors = if (request.object.get("isolateErrors")) |v| v == .bool and v.bool else false,
            .modules = modules,
            .app_header = app_header,
            .expectations = result.object.get("expectations").?,
        }), compiler);
        defer gpa.free(checked_bytes);
        var evaluation = try std.json.parseFromSliceLeaky(V, a, checked_bytes, .{ .allocate = .alloc_always });
        if (std.mem.eql(u8, string(evaluation, "status", ""), "ok")) {
            const graph = try dependencyGraph(a, program, evaluation, modules, string(request, "workspaceFingerprint", ""));
            try result.object.put(a, "graph", graph);
            var reactivity = if (reactive) |raw| try std.json.parseFromValueLeaky(frontend.Reactive, a, raw, .{ .ignore_unknown_fields = true }) else frontend.Reactive{};
            reactivity.current = try std.json.parseFromValueLeaky(frontend.Graph, a, graph, .{});
            reactivity.roots = try std.json.parseFromValueLeaky([]const []const u8, a, roots, .{});
            if (request.object.get("forceAll")) |force| {
                if (force == .bool and force.bool) reactivity.force = reactivity.roots;
            }
            if (reactive != null) if (request.object.get("selectedCell")) |selected| {
                const cell = fieldArray(result.object.get("model").?, "cells")[@intCast(selected.integer)];
                reactivity.force = try std.json.parseFromValueLeaky([]const []const u8, a, try cellRoots(a, cell), .{});
            };
            const plan = try value(a, try frontend.plan(a, reactivity));
            try result.object.put(a, "plan", plan);
            const selected_roots = plan.object.get("evaluate").?;
            if (std.mem.eql(u8, action, "evaluate") and selected_roots.array.items.len > 0) {
                const evaluated = try snapshot.evaluate(gpa, try json(a, .{
                    .cells = .{.{ .key = "document", .source = program }},
                    .roots = selected_roots,
                    .possible_roots = result.object.get("roots").?,
                    .modules = modules,
                    .app_header = app_header,
                    .expectations = result.object.get("expectations").?,
                    .isolate_errors = if (request.object.get("isolateErrors")) |v| v == .bool and v.bool else false,
                }), compiler);
                defer gpa.free(evaluated);
                evaluation = try std.json.parseFromSliceLeaky(V, a, evaluated, .{ .allocate = .alloc_always });
            }
        }
        const cells = fieldArray(result.object.get("model").?, "cells");
        for (evaluation.object.getPtr("events").?.array.items, 0..) |*event, sequence| {
            try event.object.put(a, "sequence", .{ .integer = @intCast(sequence) });
            try event.object.put(a, "cell", .null);
            for (cells, 0..) |cell, index| {
                const root = string(event.*, "root", "");
                var matches = std.mem.eql(u8, string(cell, "output", ""), root);
                for (fieldArray(cell, "expectations")) |expectation| if (std.mem.eql(u8, expectation.string, root)) {
                    matches = true;
                };
                if (matches) {
                    try event.object.put(a, "cell", .{ .integer = @intCast(index) });
                    break;
                }
            }
        }
        for (fieldArray(evaluation, "tests")) |*test_result| {
            for (fieldArray(result, "expectations")) |expectation| if (std.mem.eql(u8, string(expectation, "root", ""), string(test_result.*, "root", ""))) {
                const index = number(expectation, "cell");
                const start = number(expectation, "start");
                const end = number(expectation, "end");
                const maps = fieldArray(result, "mappings");
                for (maps) |m| if (number(m, "cell") == index and start >= number(m, "generated_start") and start < number(m, "generated_end")) {
                    const source_start = number(m, "source_start") + start - number(m, "generated_start");
                    const cell = cells[@intCast(index)];
                    const draft_mode = draft.supplied;
                    const test_offset = if (draft_mode) source_start - number(cell, "body_start") else source_start;
                    try test_result.object.put(a, "cell", .{ .integer = @intCast(index) });
                    try test_result.object.put(a, "start", .{ .integer = @intCast(test_offset) });
                    try test_result.object.put(a, "end", .{ .integer = @intCast(test_offset + end - start) });
                    try test_result.object.put(a, "location", try value(a, location(if (draft_mode) string(cell, "source", "") else source, test_offset)));
                    try test_result.object.put(a, "scope", .{ .string = if (draft_mode) "cell" else "source" });
                    break;
                };
                break;
            };
        }
        for (fieldArray(evaluation, "values")) |*output| {
            if (output.object.getPtr("display")) |display| {
                if (display.* == .object and std.mem.eql(u8, string(display.*, "kind", ""), "markdown")) {
                    try display.object.put(a, "events", try value(a, try syntax.renderMarkdown(a, string(display.*, "content", ""))));
                }
            }
        }
        try mapDiagnostics(a, &result, evaluation, source, program);
        try result.object.put(a, "evaluation", evaluation);
        try result.object.put(a, "status", evaluation.object.get("status").?);
    }
    const check_export = std.mem.eql(u8, action, "export") and std.mem.eql(u8, target, "roc");
    if ((std.mem.eql(u8, action, "check") or std.mem.eql(u8, action, "run") or check_export) and std.mem.eql(u8, string(result, "status", ""), "ok")) {
        const execution = string(result, "execution", "");
        const checked = try compiler.compile(try json(a, .{ .protocol = 1, .source = execution, .user_bytes = execution.len, .check_only = check_export or std.mem.eql(u8, action, "check"), .app_header = app_header, .modules = request.object.get("modules") orelse try value(a, &[_]V{}) }));
        defer gpa.free(checked);
        const evaluation = try std.json.parseFromSliceLeaky(V, a, checked, .{ .allocate = .alloc_always });
        try mapDiagnostics(a, &result, evaluation, source, execution);
        try result.object.put(a, "evaluation", evaluation);
        try result.object.put(a, "status", evaluation.object.get("status").?);
    }
    try locateDiagnostics(a, &result, source, draft_value != null);
    if (request.object.get("render")) |render| if (render == .bool and render.bool) {
        var rendering: std.ArrayList(V) = .empty;
        for (fieldArray(result.object.get("model").?, "cells"), 0..) |cell, index| {
            if (std.mem.eql(u8, string(cell, "kind", ""), "markdown")) try rendering.append(a, try value(a, .{ .cell = index, .events = try syntax.renderMarkdown(a, string(cell, "source", "")) }));
        }
        try result.object.put(a, "rendering", try value(a, rendering.items));
    };
    if (compact) finishCompact(&result);
    return json(gpa, result);
}

fn number(v: V, key: []const u8) u64 {
    return @intCast(v.object.get(key).?.integer);
}
fn offset(source: []const u8, line: u64, column: u64) usize {
    var pos: usize = 0;
    var n: u64 = 1;
    while (pos < source.len and n < line) : (pos += 1) if (source[pos] == '\n') {
        n += 1;
    };
    return @min(source.len, pos + column -| 1);
}
fn location(source: []const u8, pos: u64) struct { line: u64, column: u64 } {
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
fn mapDiagnostics(a: A, result: *V, evaluation: V, source: []const u8, execution: []const u8) !void {
    const maps = result.object.get("mappings").?.array.items;
    const model = result.object.getPtr("model").?;
    const diagnostics = model.object.getPtr("diagnostics").?;
    for (evaluation.object.get("diagnostics").?.array.items) |diag| {
        const filename = string(diag, "filename", "");
        if (filename.len > 0 and !std.mem.eql(u8, std.fs.path.basename(filename), "main.roc")) continue;
        const loc = diag.object.get("location") orelse continue;
        if (loc != .object) continue;
        const begin = offset(execution, number(loc, "start_line"), number(loc, "start_column"));
        const end = offset(execution, number(loc, "end_line"), number(loc, "end_column"));
        for (maps) |m| {
            const gs = number(m, "generated_start");
            const ge = number(m, "generated_end");
            if (gs <= begin and begin < ge) {
                const ss = number(m, "source_start");
                const se = number(m, "source_end");
                const start = @min(se, ss + begin - gs);
                const finish = @min(se, ss + end - gs);
                try diagnostics.array.append(try value(a, .{ .code = "roc-check", .message = string(diag, "message", ""), .severity = string(diag, "severity", "error"), .start = start, .end = finish, .cell = number(m, "cell"), .location = location(source, start) }));
                break;
            }
        }
    }
}

fn originalOffset(cell: V, absolute: u64) u64 {
    const base = number(cell, "body_start");
    if (absolute < base) return absolute;
    const relative = absolute - base;
    const maps = cell.object.get("source_map") orelse return absolute;
    for (maps.array.items) |m| {
        const begin = number(m, "start");
        const end = number(m, "end");
        if (begin <= relative and relative < end) return base + @min(number(m, "original_end"), number(m, "original_start") + relative - begin);
    }
    for (maps.array.items) |m| if (number(m, "end") == relative and number(m, "end") > number(m, "start")) return base + number(m, "original_end");
    return absolute;
}
fn locateDiagnostics(a: A, result: *V, source: []const u8, draft: bool) !void {
    const model = result.object.getPtr("model").?;
    const cells = fieldArray(model.*, "cells");
    for (model.object.getPtr("diagnostics").?.array.items) |*d| {
        var start = number(d.*, "start");
        var end = number(d.*, "end");
        const index = number(d.*, "cell");
        if (index < cells.len) {
            start = originalOffset(cells[@intCast(index)], start);
            end = originalOffset(cells[@intCast(index)], end);
        }
        try d.object.put(a, "start", .{ .integer = @intCast(start) });
        try d.object.put(a, "end", .{ .integer = @intCast(end) });
        try d.object.put(a, "location", try value(a, location(if (draft and index < cells.len) string(cells[@intCast(index)], "source", "") else source, start)));
        if (draft) try d.object.put(a, "scope", .{ .string = "cell" });
    }
}
fn cellRoots(a: A, cell: V) !V {
    var roots = try value(a, &[_]V{});
    const output = string(cell, "output", "");
    if (output.len > 0) try roots.array.append(.{ .string = output });
    if (cell.object.get("expectations")) |expectations| try roots.array.appendSlice(expectations.array.items);
    return roots;
}
fn fieldArray(v: V, key: []const u8) []V {
    return v.object.get(key).?.array.items;
}

// The fingerprint covers exact definition source and its inferred type. Anything
// outside these regions (annotations, imports, type declarations, preamble) is
// module context. Imported module contents are part of that context as well.
fn digest(a: A, bytes: []const u8) ![]const u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    return a.dupe(u8, &std.fmt.bytesToHex(hash, .lower));
}
fn dependencyGraph(a: A, program: []const u8, evaluation: V, modules: V, workspace_fingerprint: []const u8) !V {
    var definitions: std.ArrayList(V) = .empty;
    const covered = try a.alloc(bool, program.len);
    @memset(covered, false);
    for (fieldArray(evaluation, "definitions")) |definition| {
        const r = definition.object.get("region").?;
        const start = @min(program.len, number(r, "start"));
        const end = @max(start, @min(program.len, number(r, "end")));
        @memset(covered[start..end], true);
        try definitions.append(a, try value(a, .{
            .name = string(definition, "name", ""),
            .fingerprint = try digest(a, try json(a, .{ program[start..end], string(definition, "type", "") })),
            .dependencies = definition.object.get("dependencies").?,
        }));
    }
    var context: std.Io.Writer.Allocating = .init(a);
    for (program, covered) |byte, skip| if (!skip) try context.writer.writeByte(byte);
    try context.writer.writeAll(try json(a, modules));
    try context.writer.writeAll(workspace_fingerprint);
    return value(a, .{ .definitions = definitions.items, .scope = string(evaluation, "dependency_scope", "module"), .context = try digest(a, context.written()) });
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
    const full = try frontendValue(a, prepared, false);
    var compact = try frontendValue(a, prepared, true);
    finishCompact(&compact);
    try std.testing.expect((try json(a, compact)).len * 4 < (try json(a, full)).len);
    for ([_][]const u8{ "program", "execution", "source", "draft" }) |key| try std.testing.expect(compact.object.get(key) == null);
    const model = compact.object.get("model").?;
    try std.testing.expect(model.object.get("original") == null);
    const out = fieldArray(model, "cells")[0];
    for ([_][]const u8{ "facts", "blocks", "first_block", "marker_lines", "source_map" }) |key| try std.testing.expect(out.object.get(key) == null);
    try std.testing.expectEqualStrings(cell.source, string(out, "source", ""));
    try std.testing.expectEqualStrings(cell.output, string(out, "output", ""));
    try std.testing.expectEqualStrings("saved 7", string(fieldArray(out, "outputs")[0], "source", ""));
    try std.testing.expectEqual(@as(u64, 0), number(out, "body_start"));
    try std.testing.expectEqual(@as(usize, 1), fieldArray(compact, "mappings").len);
    try std.testing.expectEqualStrings("out_total", fieldArray(compact, "roots")[0].string);
}
