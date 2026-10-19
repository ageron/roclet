//! Native/WASM host for the pure Roc document core.
const std = @import("std");
const syntax = @import("roclet_syntax.zig");
const snapshot = @import("roclet_snapshot.zig");
const A = std.mem.Allocator;
const V = std.json.Value;
const DraftOutput = struct { kind: []const u8, source: []const u8 };
const DraftCell = struct { kind: []const u8, source: []const u8, attributes: []const u8 = "", outputs: []const DraftOutput = &.{} };
const Draft = struct { preamble: []const u8 = "", metadata: []const u8 = "", cells: []const DraftCell };
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
fn core(a: A, input: V, evaluate: anytype) !V {
    // The application is immutable. Input is runtime data, never generated code.
    const source =
        \\import Document
        \\main! = |args| {
        \\    input : Try(Document.Input, _)
        \\    input = Json.parse(List.first(args).ok_or(""))
        \\    match input {
        \\        Ok(data) => echo!(Json.to_str(Document.run(data)))
        \\        Err(_) => echo!("{\"status\":\"protocol_error\",\"failure\":\"Invalid core input\"}")
        \\    }
        \\    Ok({})
        \\}
    ;
    const request = try json(a, .{ .protocol = 1, .source = source, .user_bytes = 0, .args = .{try json(a, input)}, .modules = .{.{ .name = "Document", .content = @embedFile("Document.roc") }} });
    const bytes = try evaluate(request);
    defer (if (@import("builtin").cpu.arch == .wasm32) std.heap.wasm_allocator else std.heap.page_allocator).free(bytes);
    const result = try std.json.parseFromSliceLeaky(V, a, bytes, .{ .allocate = .alloc_always });
    if (!std.mem.eql(u8, string(result, "status", ""), "ok")) return result;
    const events = result.object.get("events").?.array.items;
    for (events) |event| if (std.mem.eql(u8, string(event, "kind", ""), "value")) return std.json.parseFromSliceLeaky(V, a, string(event, "message", ""), .{ .allocate = .alloc_always });
    return error.MissingCoreResult;
}
pub fn process(gpa: A, bytes: []const u8, evaluate: anytype, evaluate_core: anytype) ![]u8 {
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
    if ((!std.mem.eql(u8, format, "roc") and !std.mem.eql(u8, format, "markdown")) or (!std.mem.eql(u8, target, "roc") and !std.mem.eql(u8, target, "markdown"))) return json(gpa, .{ .status = "protocol_error", .failure = "Expected roc or markdown format" });
    const draft_value = request.object.get("draft");
    var draft: Draft = .{ .cells = &.{} };
    if (draft_value) |raw| {
        draft = std.json.parseFromSliceLeaky(Draft, a, try json(a, raw), .{ .ignore_unknown_fields = true }) catch return json(gpa, .{ .status = "protocol_error", .failure = "Malformed notebook draft" });
        var size = draft.preamble.len + draft.metadata.len;
        if (draft.cells.len > 500) return json(gpa, .{ .status = "protocol_error", .failure = "Notebook limit is 500 cells" });
        for (draft.cells) |cell| {
            if (!std.mem.eql(u8, cell.kind, "code") and !std.mem.eql(u8, cell.kind, "markdown") and !std.mem.eql(u8, cell.kind, "generated")) return json(gpa, .{ .status = "protocol_error", .failure = "Invalid cell kind" });
            size += cell.source.len + cell.attributes.len;
            for (cell.outputs) |output| size += output.source.len;
        }
        if (size > 256 * 1024) return json(gpa, .{ .status = "protocol_error", .failure = "Document limit is 256 KiB" });
    }
    const empty_graph = try value(a, .{ .context = "", .scope = "module", .definitions = &[_]V{} });
    const empty_reactivity = try value(a, .{ .known = false, .previous = empty_graph, .current = empty_graph, .available = &[_]V{}, .roots = &[_]V{}, .force = &[_]V{} });
    var input = try value(a, .{
        .reactivity = empty_reactivity,
        .metadata_fields = &[_]V{},
        .phase = "segment",
        .format = format,
        .target = target,
        .source = source,
        .facts = if (std.mem.eql(u8, format, "roc")) try syntax.roc(a, source) else syntax.Facts{},
        .blocks = if (std.mem.eql(u8, format, "markdown")) try syntax.markdown(a, source) else &[_]syntax.Block{},
        .model = .{ .format = format, .original = source, .preamble = "", .metadata = "", .cells = &[_]V{}, .diagnostics = &[_]V{} },
        .draft = .{ .supplied = draft_value != null, .preamble = draft.preamble, .metadata = draft.metadata, .cells = draft.cells },
    });
    const first = try core(a, input, evaluate_core);
    var model = first.object.get("model") orelse return json(gpa, first);
    for (model.object.getPtr("cells").?.array.items) |*cell| {
        if (std.mem.eql(u8, string(cell.*, "kind", ""), "code")) try cell.object.put(a, "facts", try value(a, try syntax.roc(a, string(cell.*, "source", ""))));
        if (std.mem.eql(u8, string(cell.*, "kind", ""), "markdown")) {
            const prose = string(cell.*, "source", "");
            var marker_lines: std.ArrayList(u64) = .empty;
            const blocks = try syntax.markdown(a, prose);
            try cell.object.put(a, "blocks", try value(a, blocks));
            if (blocks.len > 0) try cell.object.put(a, "first_block", try value(a, blocks[0]));
            for (blocks) |block| if (std.mem.eql(u8, block.kind, "html")) {
                try marker_lines.append(a, std.mem.count(u8, prose[0..@intCast(block.start)], "\n"));
            };
            try cell.object.put(a, "marker_lines", try value(a, marker_lines.items));
        }
    }
    // Editing Markdown keeps document-level Roc configuration outside the text.
    // Explicit metadata in an opened/pasted document always takes precedence.
    if (draft_value == null and std.mem.eql(u8, format, "markdown") and string(model, "metadata", "").len == 0) {
        if (request.object.get("context")) |context| {
            try model.object.put(a, "preamble", .{ .string = string(context, "preamble", "") });
            try model.object.put(a, "metadata", .{ .string = string(context, "metadata", "") });
        }
    }
    const metadata = string(model, "metadata", "");
    var fields: std.ArrayList(struct { key: []const u8, value: []const u8 }) = .empty;
    if (metadata.len > 0) {
        const parsed = std.json.parseFromSliceLeaky(V, a, metadata, .{}) catch V.null;
        if (parsed == .object) {
            var it = parsed.object.iterator();
            while (it.next()) |entry| try fields.append(a, .{ .key = entry.key_ptr.*, .value = try json(a, entry.value_ptr.*) });
        }
    }
    try input.object.put(a, "metadata_fields", try value(a, fields.items));
    try input.object.put(a, "facts", try value(a, try syntax.roc(a, string(model, "preamble", ""))));
    try input.object.put(a, "phase", .{ .string = action });
    try input.object.put(a, "model", model);
    var result = try core(a, input, evaluate_core);
    if (result.object.get("model") == null) return json(gpa, result);
    try result.object.put(a, "protocol", .{ .integer = 1 });
    if ((std.mem.eql(u8, action, "evaluate") or std.mem.eql(u8, action, "analyze")) and std.mem.eql(u8, string(result, "status", ""), "ok")) {
        const program = string(result, "program", "");
        var roots = result.object.get("roots").?;
        const reactive = request.object.get("reactivity");
        if (request.object.get("selectedCell")) |selected| {
            const cells = fieldArray(result.object.get("model").?, "cells");
            if (selected != .integer or selected.integer < 0 or selected.integer >= cells.len) return json(gpa, .{ .status = "protocol_error", .failure = "Invalid selected cell" });
            if (reactive == null) {
                const output = string(cells[@intCast(selected.integer)], "output", "");
                roots = if (output.len == 0) try value(a, &[_]V{}) else try value(a, .{output});
            }
        }
        const modules = request.object.get("modules") orelse try value(a, &[_]V{});
        const checked_bytes = try snapshot.evaluate(gpa, try json(a, .{
            .cells = .{.{ .key = "document", .source = program }},
            .roots = &[_]V{},
            .modules = modules,
        }), evaluate);
        defer gpa.free(checked_bytes);
        var evaluation = try std.json.parseFromSliceLeaky(V, a, checked_bytes, .{ .allocate = .alloc_always });
        if (std.mem.eql(u8, string(evaluation, "status", ""), "ok")) {
            const graph = try dependencyGraph(a, program, evaluation, modules);
            try result.object.put(a, "graph", graph);
            var reactivity = reactive orelse empty_reactivity;
            try reactivity.object.put(a, "current", graph);
            try reactivity.object.put(a, "roots", roots);
            if (request.object.get("forceAll")) |force| {
                if (force == .bool and force.bool) try reactivity.object.put(a, "force", roots);
            }
            if (reactive != null) if (request.object.get("selectedCell")) |selected| {
                const cell = fieldArray(result.object.get("model").?, "cells")[@intCast(selected.integer)];
                const output = string(cell, "output", "");
                try reactivity.object.put(a, "force", if (output.len == 0) try value(a, &[_]V{}) else try value(a, .{output}));
            };
            try input.object.put(a, "reactivity", reactivity);
            try input.object.put(a, "phase", .{ .string = "plan" });
            const planned = try core(a, input, evaluate_core);
            const plan = planned.object.get("plan") orelse return json(gpa, planned);
            try result.object.put(a, "plan", plan);
            const selected_roots = plan.object.get("evaluate").?;
            if (std.mem.eql(u8, action, "evaluate") and selected_roots.array.items.len > 0) {
                const evaluated = try snapshot.evaluate(gpa, try json(a, .{
                    .cells = .{.{ .key = "document", .source = program }},
                    .roots = selected_roots,
                    .modules = modules,
                    .isolate_errors = if (request.object.get("isolateErrors")) |v| v == .bool and v.bool else false,
                }), evaluate);
                defer gpa.free(evaluated);
                evaluation = try std.json.parseFromSliceLeaky(V, a, evaluated, .{ .allocate = .alloc_always });
            }
        }
        const cells = fieldArray(result.object.get("model").?, "cells");
        for (evaluation.object.getPtr("events").?.array.items, 0..) |*event, sequence| {
            try event.object.put(a, "sequence", .{ .integer = @intCast(sequence) });
            try event.object.put(a, "cell", .null);
            for (cells, 0..) |cell, index| if (std.mem.eql(u8, string(cell, "output", ""), string(event.*, "root", ""))) {
                try event.object.put(a, "cell", .{ .integer = @intCast(index) });
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
    if ((std.mem.eql(u8, action, "check") or std.mem.eql(u8, action, "run")) and std.mem.eql(u8, string(result, "status", ""), "ok")) {
        const execution = string(result, "execution", "");
        const checked = try evaluate(try json(a, .{ .protocol = 1, .source = execution, .user_bytes = execution.len, .check_only = std.mem.eql(u8, action, "check"), .modules = request.object.get("modules") orelse try value(a, &[_]V{}) }));
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
fn dependencyGraph(a: A, program: []const u8, evaluation: V, modules: V) !V {
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
    return value(a, .{ .definitions = definitions.items, .scope = string(evaluation, "dependency_scope", "module"), .context = try digest(a, context.written()) });
}
