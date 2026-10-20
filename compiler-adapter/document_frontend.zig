//! Native notebook policy. Syntax facts are parser byte spans; source stays UTF-8.
//! No interpreter, generated Roc document application, or serialized calls are used.
const std = @import("std");
const syntax = @import("syntax.zig");
const A = std.mem.Allocator;
const S = []const u8;
const Strings = std.ArrayList(S);
pub const Expectation = struct { root: S, start: u64, end: u64, cell: u64 };
pub const Output = struct { kind: S, source: S };
pub const SourceMap = struct { start: u64, end: u64, original_start: u64, original_end: u64 };
pub const Cell = struct {
    kind: S,
    source: S,
    attributes: S = "",
    id: S = "",
    output: S = "",
    expectations: []const S = &.{},
    outputs: []const Output = &.{},
    start: u64,
    end: u64,
    body_start: u64,
    facts: syntax.Facts = .{},
    marker_lines: []const u64 = &.{},
    first_block: syntax.Block = .{ .start = 0, .end = 0, .body_start = 0, .body_end = 0, .kind = "" },
    blocks: []const syntax.Block = &.{},
    source_map: []const SourceMap = &.{},
};
pub const Diagnostic = struct { code: S, message: S, severity: S = "error", start: u64, end: u64, cell: u64 };
pub const Model = struct { format: S = "roc", original: S = "", preamble: S = "", metadata: S = "", cells: []Cell = &.{}, diagnostics: []const Diagnostic = &.{} };
pub const DraftCell = struct { kind: S, source: S, attributes: S = "", outputs: []const Output = &.{} };
pub const Draft = struct { supplied: bool = false, preamble: S = "", metadata: S = "", cells: []const DraftCell = &.{} };
/// One node of the dependency graph: a value definition or expectation
/// root, a local type declaration, or an imported module (`module:<name>`).
/// `binders` lists every name a definition binds; dependencies may name any
/// binder of a node.
pub const Node = struct { name: S, binders: []const S = &.{}, fingerprint: S, dependencies: []const S = &.{} };
/// The graph format `plan` understands; a baseline of another version is
/// never compared node by node.
pub const graph_version: u32 = 2;
/// The checked dependency graph of a document revision (graph version 2).
pub const Graph = struct {
    version: u32 = graph_version,
    context: S = "",
    scope: S = "module",
    definitions: []const Node = &.{},
    types: []const Node = &.{},
    modules: []const Node = &.{},

    /// Every node: definitions, then types, then modules.
    fn nodes(self: Graph, a: A) ![]const Node {
        return std.mem.concat(a, Node, &.{ self.definitions, self.types, self.modules });
    }
};
/// The planner's input. The engine fills `known`, `previous` and `available`
/// from its baseline (`baseline.zig`); requests only name forced roots.
pub const PlanInput = struct { known: bool = false, previous: Graph = .{}, current: Graph = .{}, available: []const S = &.{}, roots: []const S = &.{}, force: []const S = &.{} };
pub const Explanation = struct { root: S, reason: S, dependencies: []const S };
pub const Plan = struct { changed: []const S = &.{}, evaluate: []const S = &.{}, reused: []const S = &.{}, explanations: []const Explanation = &.{} };
pub const MetadataField = struct { key: S, value: S };
pub const Input = struct { compact: bool = false, reactivity: PlanInput = .{}, metadata_fields: []const MetadataField = &.{}, phase: S, format: S, target: S, source: S, facts: syntax.Facts = .{}, blocks: []const syntax.Block = &.{}, model: Model = .{}, draft: Draft = .{} };
pub const Mapping = struct { generated_start: u64, generated_end: u64, source_start: u64, source_end: u64, cell: u64 };
pub const Result = struct { plan: Plan = .{}, status: S = "ok", model: Model, draft: Draft, source: S = "", program: S = "", execution: S = "", roots: []const S = &.{}, expectations: []const Expectation = &.{}, mappings: []const Mapping = &.{} };
fn eq(x: S, y: S) bool {
    return std.mem.eql(u8, x, y);
}
fn starts(s: S, prefix: S) bool {
    return std.mem.startsWith(u8, s, prefix);
}
fn ends(s: S, suffix: S) bool {
    return std.mem.endsWith(u8, s, suffix);
}
fn trim(s: S) S {
    return std.mem.trim(u8, s, " \t\r\n");
}
fn trimEnd(s: S) S {
    return std.mem.trimEnd(u8, s, " \t\r\n");
}
fn trimStart(s: S) S {
    return std.mem.trimStart(u8, s, " \t\r\n");
}
fn drop(s: S, prefix: S) S {
    return if (starts(s, prefix)) s[prefix.len..] else s;
}
fn dropEnd(s: S, suffix: S) S {
    return if (ends(s, suffix)) s[0 .. s.len - suffix.len] else s;
}
fn contains(s: S, part: S) bool {
    return std.mem.find(u8, s, part) != null;
}
fn has(items: []const S, item: S) bool {
    for (items) |x| if (eq(x, item)) return true;
    return false;
}
fn oneOf(s: S, items: []const S) bool {
    return has(items, s);
}
fn cat(a: A, items: []const S) !S {
    return std.mem.concat(a, u8, items);
}
fn join(a: A, items: []const S, sep: S) !S {
    return std.mem.join(a, sep, items);
}
fn fmt(a: A, comptime pattern: S, args: anytype) !S {
    return std.fmt.allocPrint(a, pattern, args);
}
fn json(a: A, data: anytype) !S {
    var w: std.Io.Writer.Allocating = .init(a);
    try std.json.Stringify.value(data, .{}, &w.writer);
    return w.toOwnedSlice();
}
fn parse(comptime T: type, a: A, s: S) !T {
    return std.json.parseFromSliceLeaky(T, a, s, .{ .ignore_unknown_fields = true });
}
const Line = struct { start: usize, end: usize, text: S };
fn lines(a: A, s: S) ![]Line {
    var result: std.ArrayList(Line) = .empty;
    var it = std.mem.splitScalar(u8, s, '\n');
    var pos: usize = 0;
    while (it.next()) |line| {
        try result.append(a, .{ .start = pos, .end = pos + line.len, .text = dropEnd(line, "\r") });
        pos += line.len + 1;
    }
    return result.toOwnedSlice(a);
}
fn words(a: A, s: S) ![]S {
    var out: Strings = .empty;
    var it = std.mem.tokenizeAny(u8, s, " \t");
    while (it.next()) |w| try out.append(a, w);
    return out.toOwnedSlice(a);
}
fn kindAttr(a: A, attrs: S) !S {
    for (try words(a, attrs)) |w| if (oneOf(w, &.{ "code", "markdown", "generated" })) return w;
    return "";
}
fn idAttr(a: A, attrs: S) !S {
    for (try words(a, attrs)) |w| if (starts(w, "id=")) return drop(w, "id=");
    return "";
}
fn withoutKind(a: A, attrs: S) !S {
    var out: Strings = .empty;
    for (try words(a, attrs)) |w| if (!oneOf(w, &.{ "code", "markdown", "generated" })) try out.append(a, w);
    return join(a, out.items, " ");
}
fn safe(facts: syntax.Facts, pos: u64) bool {
    var before: ?syntax.Token = null;
    for (facts.tokens) |t| {
        if (t.start <= pos and pos < t.end) return false;
        if (t.end <= pos) before = t;
    }
    const t = before orelse return true;
    const depth = if (oneOf(t.tag, &.{ "OpenCurly", "OpenSquare", "OpenRound", "NoSpaceOpenRound", "StringStart", "MultilineStringStart", "OpenStringInterpolation" })) t.depth + 1 else if (oneOf(t.tag, &.{ "CloseCurly", "CloseSquare", "CloseRound", "StringEnd", "CloseStringInterpolation" })) t.depth -| 1 else t.depth;
    return depth == 0;
}
fn diagnostic(a: A, ds: *std.ArrayList(Diagnostic), code: S, message: S, start: u64, end: u64, index: usize) !void {
    try ds.append(a, .{ .code = code, .message = message, .start = start, .end = end, .cell = index });
}
fn makeCell(a: A, kind: S, source: S, attrs: S, start: u64, end: u64, body: u64) !Cell {
    return .{ .kind = kind, .source = source, .attributes = attrs, .id = try idAttr(a, attrs), .start = start, .end = end, .body_start = body, .source_map = try a.dupe(SourceMap, &.{.{ .start = 0, .end = source.len, .original_start = 0, .original_end = source.len }}) };
}
fn commentOnly(a: A, s: S) !bool {
    var any = false;
    for (try lines(a, s)) |l| if (trim(l.text).len > 0) {
        any = true;
        if (!starts(trim(l.text), "#")) return false;
    };
    return any;
}
fn comments(a: A, s: S, encode: bool) !S {
    var out: Strings = .empty;
    for (try lines(a, s)) |l| try out.append(a, if (encode) (if (l.text.len == 0) "#" else try cat(a, &.{ "# ", l.text })) else (if (starts(trimStart(l.text), "# ")) drop(trimStart(l.text), "# ") else drop(trimStart(l.text), "#")));
    return join(a, out.items, "\n");
}
fn clip(a: A, s: S, start: usize, end: usize) !syntax.Span {
    var first: ?usize = null;
    var last: usize = start;
    for (try lines(a, s[start..end])) |l| if (trim(l.text).len > 0) {
        if (first == null) first = start + l.start;
        last = start + l.start + l.text.len;
    };
    return .{ .start = first orelse start, .end = if (first == null) start else last };
}
const Restored = struct { source: S, source_map: []const SourceMap };
fn restore(a: A, source: S, facts: syntax.Facts, base: u64) !Restored {
    var cursor: usize = 0;
    var text: Strings = .empty;
    var maps: std.ArrayList(SourceMap) = .empty;
    var size: usize = 0;
    for (try lines(a, source)) |l| {
        if (l.start < cursor or !safe(facts, base + l.start) or !starts(l.text, "# roclet:literal-marker ")) continue;
        const literal = parse(S, a, drop(l.text, "# roclet:literal-marker ")) catch continue;
        if (contains(literal, "\n") or (!starts(literal, "# %%") and !starts(literal, "#%%"))) continue;
        const prefix = source[cursor..l.start];
        try maps.append(a, .{ .start = size, .end = size + prefix.len, .original_start = cursor, .original_end = l.start });
        try text.appendSlice(a, &.{ prefix, literal });
        size += prefix.len + literal.len;
        cursor = l.end;
    }
    const tail = source[cursor..];
    try maps.append(a, .{ .start = size, .end = size + tail.len, .original_start = cursor, .original_end = source.len });
    try text.append(a, tail);
    return .{ .source = try cat(a, text.items), .source_map = try maps.toOwnedSlice(a) };
}
fn segmentRoc(a: A, input: Input) !Model {
    const s = input.source;
    const ls = try lines(a, s);
    var boundaries: std.ArrayList(Line) = .empty;
    for (ls) |l| {
        const is_marker = starts(l.text, "# %%") or starts(l.text, "#%%");
        const rest = if (starts(l.text, "# %%")) drop(l.text, "# %%") else drop(l.text, "#%%");
        if (!is_marker or !(rest.len == 0 or starts(rest, " ") or starts(rest, "\t")) or !safe(input.facts, l.start)) continue;
        var overlap = false;
        for (input.facts.statements) |stmt| if (stmt.start < l.start and l.start < stmt.end) {
            overlap = true;
        };
        if (!overlap) try boundaries.append(a, l);
    }
    const preamble_end: usize = if (boundaries.items.len > 0) boundaries.items[0].start else @intCast(input.facts.header_end);
    var cells: std.ArrayList(Cell) = .empty;
    if (boundaries.items.len == 0) {
        const r = try clip(a, s, preamble_end, s.len);
        if (r.start != r.end) try cells.append(a, try makeCell(a, "code", s[@intCast(r.start)..@intCast(r.end)], "", r.start, r.end, r.start));
    }
    for (boundaries.items, 0..) |l, i| {
        const next = if (i + 1 < boundaries.items.len) boundaries.items[i + 1].start else s.len;
        const attrs = trim(if (starts(l.text, "# %%")) drop(l.text, "# %%") else drop(l.text, "#%%"));
        const r = try clip(a, s, @min(l.end + 1, s.len), next);
        const body = s[@intCast(r.start)..@intCast(r.end)];
        const override = try kindAttr(a, attrs);
        const kind = if (override.len > 0) override else if (try commentOnly(a, body)) "markdown" else "code";
        const restored = try restore(a, body, input.facts, r.start);
        var c = try makeCell(a, kind, if (eq(kind, "markdown")) try comments(a, body, false) else restored.source, try withoutKind(a, attrs), l.start, next, r.start);
        c.source_map = restored.source_map;
        try cells.append(a, c);
    }
    const raw = s[0..preamble_end];
    var meta_lines: std.ArrayList(Line) = .empty;
    var preamble: Strings = .empty;
    var ds: std.ArrayList(Diagnostic) = .empty;
    for (try lines(a, raw)) |l| {
        if (starts(l.text, "# roclet:document ") and safe(input.facts, l.start)) try meta_lines.append(a, l);
        if (starts(l.text, "# roclet:format=") and !eq(l.text, "# roclet:format=1")) try diagnostic(a, &ds, "format-version", "Unsupported format version", l.start, l.end, 0);
    }
    for (try lines(a, raw)) |l| if (!(meta_lines.items.len == 1 and meta_lines.items[0].start == l.start)) try preamble.append(a, l.text);
    if (meta_lines.items.len > 1) try diagnostic(a, &ds, "metadata", "Duplicate document metadata remains in the preamble", 0, preamble_end, 0);
    return .{ .format = "roc", .original = s, .preamble = try join(a, preamble.items, "\n"), .metadata = if (meta_lines.items.len == 1) drop(meta_lines.items[0].text, "# roclet:document ") else "", .cells = try cells.toOwnedSlice(a), .diagnostics = try ds.toOwnedSlice(a) };
}
fn markerInner(s: S) S {
    return trim(dropEnd(drop(trim(s), "<!--"), "-->"));
}
fn marker(s: S) bool {
    const t = trim(s);
    const inner = markerInner(t);
    return starts(t, "<!--") and ends(t, "-->") and (eq(inner, "%%") or starts(inner, "%% ")) and !contains(inner, "\n");
}
fn reserved(s: S) bool {
    return eq(s, "%%") or starts(s, "%% ") or starts(s, "roclet:document ") or starts(s, "roclet:outputs ");
}
fn flush(a: A, cells: *std.ArrayList(Cell), s: S, start: usize, end: usize, attrs: S, force: bool) !void {
    const r = try clip(a, s, start, end);
    if (r.start != r.end or force) try cells.append(a, try makeCell(a, "markdown", s[@intCast(r.start)..@intCast(r.end)], try withoutKind(a, attrs), start, end, r.start));
}
fn stripEol(s: S) S {
    return if (ends(s, "\r\n")) dropEnd(s, "\r\n") else dropEnd(s, "\n");
}
fn addOutputs(a: A, c: *Cell, extra: []const Output) !void {
    c.outputs = try std.mem.concat(a, Output, &.{ c.outputs, extra });
}
fn segmentMarkdown(a: A, input: Input) !Model {
    const s = input.source;
    var cells: std.ArrayList(Cell) = .empty;
    var cursor: usize = 0;
    var attrs: S = "";
    var empty = false;
    var outputs = false;
    var preamble: S = "";
    var metadata: S = "";
    var ds: std.ArrayList(Diagnostic) = .empty;
    for (input.blocks) |b| {
        const text = s[@intCast(b.start)..@intCast(b.end)];
        if (eq(b.kind, "html") and marker(text)) {
            try flush(a, &cells, s, cursor, @intCast(b.start), attrs, empty);
            cursor = @intCast(b.end);
            attrs = trim(drop(markerInner(text), "%%"));
            empty = eq(try kindAttr(a, attrs), "markdown");
            outputs = false;
        } else if (eq(b.kind, "html") and starts(trim(text), "<!-- roclet:document ")) {
            const raw = trim(dropEnd(drop(trim(text), "<!-- roclet:document "), "-->"));
            const meta = parse(struct { format: u64, rocPreamble: S }, a, raw) catch {
                try diagnostic(a, &ds, "metadata", "Invalid document metadata; preserved as prose", b.start, b.end, 0);
                outputs = false;
                continue;
            };
            if (metadata.len == 0) {
                try flush(a, &cells, s, cursor, @intCast(b.start), attrs, empty);
                preamble = meta.rocPreamble;
                metadata = raw;
                cursor = @intCast(b.end);
                attrs = "";
                empty = false;
                if (meta.format != 1) try diagnostic(a, &ds, "format-version", "Unsupported document format version", b.start, b.end, 0);
            } else try diagnostic(a, &ds, "metadata", "Duplicate document metadata is preserved as prose", b.start, b.end, 0);
            outputs = false;
        } else if (eq(b.kind, "fence") and eq(b.info, "roc")) {
            try flush(a, &cells, s, cursor, @intCast(b.start), attrs, empty);
            const effective = if (empty or trim(s[cursor..@intCast(b.start)]).len > 0) "" else attrs;
            const restored = try restore(a, stripEol(s[@intCast(b.body_start)..@intCast(b.body_end)]), b.facts, 0);
            var c = try makeCell(a, if (eq(try kindAttr(a, effective), "generated")) "generated" else "code", restored.source, try withoutKind(a, effective), b.start, b.end, b.body_start);
            c.source_map = restored.source_map;
            try cells.append(a, c);
            cursor = @intCast(b.end);
            attrs = "";
            empty = false;
            outputs = true;
        } else if (outputs and eq(b.kind, "html") and trim(s[cursor..@intCast(b.start)]).len == 0 and starts(trim(text), "<!-- roclet:outputs ")) {
            const raw = trim(dropEnd(drop(trim(text), "<!-- roclet:outputs "), "-->"));
            const extra = parse([]const Output, a, raw) catch {
                try diagnostic(a, &ds, "output-metadata", "Malformed output metadata is preserved as prose", b.start, b.end, 0);
                continue;
            };
            try addOutputs(a, &cells.items[cells.items.len - 1], extra);
            cursor = @intCast(b.end);
        } else if (outputs and trim(s[cursor..@intCast(b.start)]).len == 0 and ((eq(b.kind, "fence") and eq(b.info, "text")) or eq(b.kind, "table") or eq(b.kind, "image"))) {
            const o: Output = .{ .kind = if (eq(b.kind, "fence")) "text" else b.kind, .source = if (eq(b.kind, "fence")) stripEol(s[@intCast(b.body_start)..@intCast(b.body_end)]) else dropEnd(text, "\n") };
            try addOutputs(a, &cells.items[cells.items.len - 1], &.{o});
            cursor = @intCast(b.end);
        } else outputs = false;
    }
    try flush(a, &cells, s, cursor, s.len, attrs, empty);
    return .{ .format = "markdown", .original = s, .preamble = preamble, .metadata = metadata, .cells = try cells.toOwnedSlice(a), .diagnostics = try ds.toOwnedSlice(a) };
}
fn fresh(a: A, used: []const S, prefix: S, numbered: bool) !S {
    var index: u64 = 1;
    var name = if (numbered) try fmt(a, "{s}_1", .{prefix}) else prefix;
    while (has(used, name)) {
        index += 1;
        name = try fmt(a, "{s}_{d}", .{ prefix, index });
    }
    return name;
}
fn identifier(s: S) bool {
    if (s.len == 0) return false;
    for (s) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    return true;
}
fn displaySource(a: A, name: S) !S {
    return fmt(a, "{s} = |value| echo!(\"${{Str.inspect(value)}}\\n\")", .{name});
}
fn mainSource(a: A, roots: []const S, helper: S) !S {
    var parts: Strings = .empty;
    if (roots.len > 0) try parts.append(a, try cat(a, &.{ try displaySource(a, helper), "\n\n" }));
    try parts.append(a, "main! = |_args| {\n");
    for (roots) |root| try parts.append(a, try fmt(a, "    {s}({s})\n", .{ helper, root }));
    try parts.append(a, "    Ok({})\n}");
    return cat(a, parts.items);
}
fn validEntry(a: A, source: S) !bool {
    var ls: Strings = .empty;
    for (try lines(a, trim(source))) |l| if (trim(l.text).len > 0) try ls.append(a, trim(l.text));
    if (ls.items.len == 0) return false;
    const first = ls.items[0];
    const at = std.mem.find(u8, first, " = ") orelse first.len;
    const helper = first[0..at];
    const suffix = dropEnd(drop(helper, "display_"), "!");
    var digits = suffix.len > 0;
    for (suffix) |c| if (!std.ascii.isDigit(c)) {
        digits = false;
    };
    const has_helper = (eq(helper, "display!") or (starts(helper, "display_") and ends(helper, "!") and digits)) and eq(first, try displaySource(a, helper));
    const body = if (has_helper) ls.items[1..] else ls.items;
    if (body.len < 3 or !eq(body[0], "main! = |_args| {") or !eq(body[body.len - 1], "}") or !eq(body[body.len - 2], "Ok({})")) return false;
    for (body[1 .. body.len - 2]) |l| {
        if (!has_helper or !starts(l, try cat(a, &.{ helper, "(" })) or !ends(l, ")")) return false;
        const name = l[helper.len + 1 .. l.len - 1];
        if (!starts(name, "out_") or !identifier(name)) return false;
    }
    return true;
}
fn snapshotComments(a: A, c: Cell) ![]const Output {
    var texts: Strings = .empty;
    var rich: std.ArrayList(Output) = .empty;
    for (try lines(a, c.source)) |l| {
        if (std.mem.find(u8, l.text, "# =>")) |pos| if (safe(c.facts, l.start + pos)) {
            try texts.append(a, drop(l.text[pos + 4 ..], " "));
        };
        if (starts(l.text, "# roclet:outputs ") and safe(c.facts, l.start)) {
            const extra = parse([]const Output, a, drop(l.text, "# roclet:outputs ")) catch continue;
            try rich.appendSlice(a, extra);
        }
    }
    if (texts.items.len > 0) try rich.insert(a, 0, .{ .kind = "text", .source = try join(a, texts.items, "\n") });
    return rich.toOwnedSlice(a);
}
fn stripSnapshots(a: A, c: Cell) !S {
    var out: Strings = .empty;
    for (try lines(a, c.source)) |l| {
        if (starts(l.text, "# roclet:outputs ") and safe(c.facts, l.start)) {
            if (parse([]const Output, a, drop(l.text, "# roclet:outputs "))) |_| {
                try out.append(a, "");
                continue;
            } else |_| {}
        }
        if (std.mem.find(u8, l.text, "# =>")) |pos| if (safe(c.facts, l.start + pos)) {
            try out.append(a, trimEnd(l.text[0..pos]));
            continue;
        };
        try out.append(a, l.text);
    }
    return join(a, out.items, "\n");
}
fn mapping(gs: u64, ge: u64, ss: u64, se: u64, index: usize) Mapping {
    return .{ .generated_start = gs, .generated_end = ge, .source_start = ss, .source_end = se, .cell = index };
}
fn escapeRoc(a: A, code: S, c: Cell, base: u64, mappings: []const Mapping) !S {
    var out: Strings = .empty;
    for (try lines(a, code)) |l| {
        var escaped = false;
        if (starts(l.text, "# %%") or starts(l.text, "#%%")) {
            const pos = base + l.start;
            for (mappings) |m| if (m.generated_start <= pos and pos < m.generated_end) {
                escaped = safe(c.facts, m.source_start + pos - m.generated_start - c.body_start);
                break;
            };
        }
        try out.append(a, if (escaped) try cat(a, &.{ "# roclet:literal-marker ", try json(a, l.text) }) else l.text);
    }
    return join(a, out.items, "\n");
}
fn replace(a: A, s: S, old: S, new: S) !S {
    var parts: Strings = .empty;
    var it = std.mem.splitSequence(u8, s, old);
    while (it.next()) |part| try parts.append(a, part);
    return join(a, parts.items, new);
}
fn markers(a: A, source: S, marker_lines: []const u64, escape: bool) !S {
    var parts: Strings = .empty;
    for (try lines(a, source), 0..) |l, index| {
        var html = false;
        for (marker_lines) |n| if (n == index) {
            html = true;
        };
        const inner = markerInner(l.text);
        if (html and reserved(trimStart(try replace(a, inner, "\\", "")))) {
            if (escape) {
                const rest = drop(trimStart(l.text), "<!--");
                const pos = l.text.len - trimStart(rest).len;
                try parts.append(a, try cat(a, &.{ l.text[0..pos], "\\", l.text[pos..] }));
                continue;
            } else if (starts(inner, "\\")) {
                const pos = std.mem.find(u8, l.text, "\\").?;
                try parts.append(a, try cat(a, &.{ l.text[0..pos], l.text[pos + 1 ..] }));
                continue;
            }
        }
        try parts.append(a, l.text);
    }
    return join(a, parts.items, "\n");
}
fn outputAttributes(a: A, c: Cell, materialized: bool) !S {
    var ids: usize = 0;
    var out: Strings = .empty;
    for (try words(a, c.attributes)) |w| {
        if (starts(w, "id=")) ids += 1 else try out.append(a, w);
    }
    return if (materialized and ids == 1 and c.id.len > 0 and eq(try idAttr(a, c.attributes), c.id) and eq(c.id, drop(c.output, "out_"))) join(a, out.items, " ") else c.attributes;
}
fn fence(a: A, language: S, source: S) !S {
    var ticks: S = "```";
    while (contains(source, ticks)) ticks = try cat(a, &.{ ticks, "`" });
    return cat(a, &.{ ticks, language, "\n", source, "\n", ticks });
}
fn proseSource(a: A, c: Cell) !S {
    var cursor: usize = 0;
    var parts: Strings = .empty;
    for (c.blocks) |b| if (eq(b.kind, "fence") and eq(b.info, "roc")) {
        const opening = trimEnd(c.source[@intCast(b.start)..@intCast(b.body_start)]);
        try parts.append(a, try cat(a, &.{ c.source[cursor..@intCast(b.start)], dropEnd(opening, "roc"), "roc example\n" }));
        cursor = @intCast(b.body_start);
    };
    try parts.append(a, c.source[cursor..]);
    return cat(a, parts.items);
}
fn startsOutput(c: Cell) bool {
    const b = c.first_block;
    return starts(trimStart(c.source), "![") or (trim(c.source[0..@intCast(b.start)]).len == 0 and ((eq(b.kind, "fence") and eq(b.info, "text")) or eq(b.kind, "table") or eq(b.kind, "image")));
}
fn markdownCode(a: A, c: Cell) !S {
    const cleaned = try stripSnapshots(a, c);
    if (c.facts.statements.len > 0) {
        const stmt = c.facts.statements[c.facts.statements.len - 1];
        var explicit = false;
        for (c.facts.statements) |s| if (eq(s.kind, "decl") and starts(s.name, "out_")) {
            explicit = true;
        };
        if (eq(stmt.kind, "expr") and c.output.len > 0 and !explicit) {
            var prefix_cell = c;
            prefix_cell.source = c.source[0..@intCast(stmt.start)];
            const prefix = try stripSnapshots(a, prefix_cell);
            return cat(a, &.{ prefix, c.output, " = ", cleaned[prefix.len..] });
        }
    }
    return cleaned;
}
fn encodeRoc(a: A, model: Model, lowered: []const S, main: S, conflict: bool, header: bool, runnable: bool, fields: []const MetadataField) !S {
    const preamble = if (trim(model.preamble).len == 0) "app [main!] {}" else if (header) trimEnd(model.preamble) else try cat(a, &.{ "app [main!] {}\n\n", trimEnd(model.preamble) });
    var meta: Strings = .empty;
    for (fields) |f| if (!eq(f.key, "rocPreamble") and !(eq(f.key, "format") and eq(f.value, "1"))) try meta.append(a, try cat(a, &.{ try json(a, f.key), ":", f.value }));
    var parts: Strings = .empty;
    try parts.append(a, if (meta.items.len == 0) preamble else try cat(a, &.{ preamble, "\n# roclet:document {", try join(a, meta.items, ","), "}" }));
    for (model.cells, 0..) |c, i| {
        if (eq(c.kind, "generated") and !conflict) continue;
        const attributes = try outputAttributes(a, c, runnable and eq(c.kind, "code"));
        const attrs = if (attributes.len == 0) "" else try cat(a, &.{ " ", attributes });
        if (eq(c.kind, "markdown")) {
            try parts.append(a, try cat(a, &.{ "# %%", if (trim(c.source).len == 0) " markdown" else "", attrs, "\n", try comments(a, c.source, true) }));
        } else if (eq(c.kind, "generated")) try parts.append(a, try cat(a, &.{ "# %% generated", attrs, "\n", c.source })) else {
            const code = if (runnable) lowered[i] else try escapeRoc(a, c.source, c, 0, &.{mapping(0, c.source.len, c.body_start, c.body_start + c.source.len, i)});
            const existing = try snapshotComments(a, c);
            const extra = c.outputs[@min(existing.len, c.outputs.len)..];
            var suffix: S = "";
            if (extra.len == 1 and eq(extra[0].kind, "text")) {
                var snapshots: Strings = .empty;
                for (try lines(a, extra[0].source)) |l| try snapshots.append(a, try cat(a, &.{ "# => ", l.text }));
                suffix = try cat(a, &.{ "\n", try join(a, snapshots.items, "\n") });
            } else if (extra.len > 0) suffix = try cat(a, &.{ "\n# roclet:outputs ", try json(a, extra) });
            try parts.append(a, try cat(a, &.{ "# %%", if (try commentOnly(a, code)) " code" else "", attrs, "\n", code, suffix }));
        }
    }
    if (runnable and !conflict) {
        var attrs: S = "";
        for (model.cells) |c| if (eq(c.kind, "generated")) {
            attrs = c.attributes;
            break;
        };
        try parts.append(a, try cat(a, &.{ "# %% generated", if (attrs.len == 0) "" else try cat(a, &.{ " ", attrs }), "\n", main }));
    }
    return cat(a, &.{ try join(a, parts.items, "\n\n"), "\n" });
}
fn encodeMarkdown(a: A, model: Model, conflict: bool, fields: []const MetadataField, exporting: bool) !S {
    var extras: Strings = .empty;
    var version: S = "1";
    for (fields) |f| {
        if (eq(f.key, "format")) version = f.value else if (!eq(f.key, "rocPreamble")) try extras.append(a, try cat(a, &.{ try json(a, f.key), ":", f.value }));
    }
    var meta: Strings = .empty;
    try meta.append(a, try cat(a, &.{ "\"format\":", version }));
    try meta.append(a, try cat(a, &.{ "\"rocPreamble\":", try json(a, model.preamble) }));
    try meta.appendSlice(a, extras.items);
    var parts: Strings = .empty;
    if (exporting and (!(trim(model.preamble).len == 0 or eq(trim(model.preamble), "app [main!] {}")) or extras.items.len > 0 or !eq(version, "1"))) try parts.append(a, try cat(a, &.{ "<!-- roclet:document ", try replace(a, try cat(a, &.{ "{", try join(a, meta.items, ","), "}" }), "--", "\\u002d\\u002d"), " -->" }));
    var previous: S = "";
    for (model.cells) |c| {
        if (eq(c.kind, "markdown")) {
            const attrs = if (c.attributes.len == 0) "" else try cat(a, &.{ " ", c.attributes });
            if (c.source.len == 0) try parts.append(a, try cat(a, &.{ "<!-- %% markdown", attrs, " -->" })) else {
                if (eq(previous, "markdown") or attrs.len > 0 or (eq(previous, "code") and startsOutput(c))) try parts.append(a, try cat(a, &.{ "<!-- %%", attrs, " -->" }));
                try parts.append(a, try markers(a, try proseSource(a, c), c.marker_lines, true));
            }
            previous = "markdown";
        } else if (eq(c.kind, "code")) {
            const attrs = try outputAttributes(a, c, exporting);
            if (attrs.len > 0) try parts.append(a, try cat(a, &.{ "<!-- %% ", attrs, " -->" }));
            try parts.append(a, try fence(a, "roc", trimEnd(if (exporting) try markdownCode(a, c) else try stripSnapshots(a, c))));
            for (c.outputs) |o| try parts.append(a, if (eq(o.kind, "text")) try fence(a, "text", o.source) else if (eq(o.kind, "image") or eq(o.kind, "table")) o.source else try cat(a, &.{ "<!-- roclet:outputs ", try replace(a, try json(a, &.{o}), "--", "\\u002d\\u002d"), " -->" }));
            previous = "code";
        } else if (conflict or c.attributes.len > 0) {
            try parts.append(a, try cat(a, &.{ "<!-- %% generated ", c.attributes, " -->\n\n", try fence(a, "roc", c.source) }));
            previous = "generated";
        }
    }
    return cat(a, &.{ try join(a, parts.items, "\n\n"), "\n" });
}
fn finish(a: A, input: Input) !Result {
    var model = input.model;
    var ds: std.ArrayList(Diagnostic) = .empty;
    try ds.appendSlice(a, model.diagnostics);
    for (input.metadata_fields) |f| if (eq(f.key, "format") and !eq(f.value, "1")) try diagnostic(a, &ds, "format-version", "Unsupported document metadata version", 0, 0, 0);
    var used: Strings = .empty;
    var seen: Strings = .empty;
    var reserved_names: Strings = .empty;
    for (model.cells) |c| {
        if (eq(c.kind, "code")) for (c.facts.statements) |s| {
            if (s.name.len > 0) try used.append(a, s.name);
        };
        if (identifier(c.id)) try reserved_names.append(a, try cat(a, &.{ "out_", c.id }));
    }
    for (input.facts.statements) |s| if (s.name.len > 0) {
        try used.append(a, s.name);
        try seen.append(a, s.name);
    };
    const n = used.items.len;
    for (0..n) |i| try used.append(a, dropEnd(used.items[i], "!"));
    const prelude = model.preamble[@intCast(@min(input.facts.header_end, model.preamble.len))..];
    var execution: std.Io.Writer.Allocating = .init(a);
    if (trim(prelude).len > 0) {
        try execution.writer.writeAll(prelude);
        try execution.writer.writeAll("\n\n");
    }
    var roots: Strings = .empty;
    var maps: std.ArrayList(Mapping) = .empty;
    var expectations: std.ArrayList(Expectation) = .empty;
    var lowered: Strings = .empty;
    var ids: Strings = .empty;
    var handwritten = false;
    for (input.facts.statements) |s| {
        if (eq(s.kind, "expect")) try diagnostic(a, &ds, "expect-in-header", "Move this expect into a notebook code cell to run it; the App header holds packages, imports and shared declarations", s.start, s.end, 0);
        if (eq(s.kind, "dbg")) try diagnostic(a, &ds, "top-level-dbg", "dbg must be inside a Roc function or expression block", s.start, s.end, 0);
        if (eq(s.name, "main!")) {
            handwritten = true;
            try diagnostic(a, &ds, "handwritten-main", "The preamble contains a handwritten main!; it is preserved without execution", s.start, s.end, 0);
        }
    }
    for (input.facts.tokens) |t| if (t.depth == 0 and oneOf(t.tag, &.{ "KwModule", "KwPackage", "KwPlatform", "KwHosted" })) {
        try diagnostic(a, &ds, "unsupported-header", "A runnable Roclet notebook needs an app header; the existing header is preserved", 0, input.facts.header_end, 0);
        break;
    };
    for (model.cells, 0..) |*c, index| {
        if (eq(c.kind, "markdown") and eq(model.format, "markdown") and !input.draft.supplied) c.source = try markers(a, c.source, c.marker_lines, false);
        for (try words(a, c.attributes)) |w| {
            if (!contains(w, "=") or eq(w, "id=")) try diagnostic(a, &ds, "malformed-attribute", "Cell attributes must be nonempty key=value pairs", c.start, c.body_start, index);
            if (!starts(w, "id=")) {
                try diagnostic(a, &ds, "unknown-attribute", "Unknown cell metadata is preserved; its behavior is unsupported", c.start, c.body_start, index);
                ds.items[ds.items.len - 1].severity = "warning";
            }
        }
        if (eq(c.kind, "code")) {
            for (try lines(a, c.source)) |l| {
                if (starts(l.text, "# roclet:literal-marker ") and safe(c.facts, l.start)) try diagnostic(a, &ds, "literal-marker-conflict", "Malformed literal marker metadata is preserved", c.body_start + l.start, c.body_start + l.end, index);
                if (starts(l.text, "# roclet:outputs ") and safe(c.facts, l.start)) {
                    _ = parse([]const Output, a, drop(l.text, "# roclet:outputs ")) catch {
                        try diagnostic(a, &ds, "output-metadata", "Malformed output metadata is preserved", c.body_start + l.start, c.body_start + l.end, index);
                    };
                }
            }
            for (c.facts.errors) |e| try diagnostic(a, &ds, "roc-syntax", "Roc syntax error; source is preserved", c.body_start + e.start, c.body_start + e.end, index);
            var chosen: S = "";
            var bindings: usize = 0;
            for (c.facts.statements) |s| if (eq(s.kind, "decl") and starts(s.name, "out_")) {
                if (bindings == 0) chosen = s.name;
                bindings += 1;
            };
            if (bindings > 1) try diagnostic(a, &ds, "multiple-outputs", "A cell may define only one top-level out_* output", c.body_start, c.end, index);
            for (c.facts.statements) |s| {
                if (eq(s.kind, "dbg")) try diagnostic(a, &ds, "top-level-dbg", "dbg must be inside a Roc function or expression block; only a final expression may appear outside a top-level definition", c.body_start + s.start, c.body_start + s.end, index) else if (!oneOf(s.kind, &.{ "decl", "expr", "expect", "type_decl", "type_anno", "import", "file_import", "malformed" })) try diagnostic(a, &ds, "unsupported-statement", "This statement cannot be exported at module scope", c.body_start + s.start, c.body_start + s.end, index);
                if (eq(s.kind, "decl") and s.name.len == 0) try diagnostic(a, &ds, "unsupported-pattern", "Notebook output analysis currently requires simple top-level bindings", c.body_start + s.start, c.body_start + s.end, index);
                if (s.name.len > 0) {
                    if (has(seen.items, s.name)) try diagnostic(a, &ds, "duplicate-definition", try cat(a, &.{ "Duplicate top-level definition ", s.name }), c.body_start + s.start, c.body_start + s.end, index);
                    try seen.append(a, s.name);
                    if (eq(s.name, "main!")) {
                        handwritten = true;
                        try diagnostic(a, &ds, "handwritten-main", "An editable cell defines main!; it is preserved and will not be replaced or executed", c.body_start + s.start, c.body_start + s.end, index);
                    }
                }
            }
            c.output = chosen;
            var cursor: usize = 0;
            var code: std.Io.Writer.Allocating = .init(a);
            const base = execution.written().len;
            for (c.facts.statements, 0..) |s, si| if (eq(s.kind, "expr")) {
                const prefix = c.source[cursor..@intCast(s.start)];
                try maps.append(a, mapping(base + code.written().len, base + code.written().len + prefix.len, c.body_start + cursor, c.body_start + s.start, index));
                try code.writer.writeAll(prefix);
                const body = c.source[@intCast(s.start)..@intCast(s.end)];
                if (si + 1 != c.facts.statements.len or chosen.len > 0) {
                    try diagnostic(a, &ds, "ambiguous-expression", "Only a final expression in a cell without an explicit output can become its result", c.body_start + s.start, c.body_start + s.end, index);
                    try code.writer.writeAll(body);
                } else {
                    const named = identifier(c.id);
                    const preferred = if (named) try cat(a, &.{ "out_", c.id }) else "out";
                    var taken: Strings = .empty;
                    try taken.appendSlice(a, used.items);
                    const own = try cat(a, &.{ "out_", c.id });
                    for (reserved_names.items) |r| if (!eq(r, own)) try taken.append(a, r);
                    const name = try fresh(a, taken.items, preferred, !named);
                    try used.append(a, name);
                    c.output = name;
                    try code.writer.writeAll(name);
                    try code.writer.writeAll(" = ");
                    try maps.append(a, mapping(base + code.written().len, base + code.written().len + body.len, c.body_start + s.start, c.body_start + s.end, index));
                    try code.writer.writeAll(body);
                }
                cursor = @intCast(s.end);
            };
            const tail = c.source[cursor..];
            try maps.append(a, mapping(base + code.written().len, base + code.written().len + tail.len, c.body_start + cursor, c.body_start + c.source.len, index));
            try code.writer.writeAll(tail);
            var cell_expects: Strings = .empty;
            for (c.facts.statements) |statement| if (eq(statement.kind, "expect")) {
                const root = try fresh(a, used.items, "roclet_expect", true);
                try used.append(a, root);
                try cell_expects.append(a, root);
                // The source remains an ordinary top-level expect. Only its
                // parser-backed position identifies the checked test root.
                const original = c.body_start + statement.start;
                for (maps.items) |m| if (m.cell == index and original >= m.source_start and original < m.source_end) {
                    const start = m.generated_start + original - m.source_start;
                    try expectations.append(a, .{ .root = root, .start = start, .end = start + statement.end - statement.start, .cell = index });
                    break;
                };
            };
            c.expectations = try cell_expects.toOwnedSlice(a);
            try execution.writer.writeAll(code.written());
            try execution.writer.writeAll("\n\n");
            try lowered.append(a, if (input.compact) "" else try escapeRoc(a, code.written(), c.*, base, maps.items));
            if (c.output.len > 0) try roots.append(a, c.output);
            const snapshots = try snapshotComments(a, c.*);
            if (snapshots.len > 0 and c.outputs.len > 0) try diagnostic(a, &ds, "duplicate-snapshot", "Both Roc comments and Markdown blocks provide saved output; both are preserved", c.body_start, c.end, index);
            c.outputs = try std.mem.concat(a, Output, &.{ snapshots, c.outputs });
            if (c.outputs.len > 0 and c.output.len == 0) try diagnostic(a, &ds, "orphan-snapshot", "Saved output has no selected cell result", c.body_start, c.end, index);
            if (c.id.len == 0) {
                if (c.output.len > 0) c.id = drop(c.output, "out_") else {
                    var names: Strings = .empty;
                    for (c.facts.statements) |s| if (s.name.len > 0) try names.append(a, s.name);
                    c.id = try join(a, names.items, "_and_");
                }
            }
        } else try lowered.append(a, c.source);
        if (c.id.len > 0) {
            if (has(ids.items, c.id)) try diagnostic(a, &ds, "duplicate-id", try cat(a, &.{ "Cell ID ", c.id, " is not unique" }), c.start, c.end, index);
            try ids.append(a, c.id);
        }
    }
    const main = if (input.compact) "" else try mainSource(a, roots.items, try cat(a, &.{ try fresh(a, used.items, "display", false), "!" }));
    var generated: usize = 0;
    for (model.cells) |c| if (eq(c.kind, "generated")) {
        generated += 1;
    };
    var conflict = generated > 1;
    if (conflict) try diagnostic(a, &ds, "generated-conflict", "Multiple generated entry sections are preserved", 0, 0, 0);
    for (model.cells, 0..) |c, index| if (eq(c.kind, "generated") and !try validEntry(a, c.source)) {
        conflict = true;
        try diagnostic(a, &ds, "generated-conflict", "The generated entry differs from the supported structure; preserved without execution", c.body_start, c.end, index);
    };
    model.diagnostics = try ds.toOwnedSlice(a);
    const editing = oneOf(input.phase, &.{ "view", "compose" });
    const rendered = if (input.compact) "" else if (eq(input.target, "roc")) try encodeRoc(a, model, lowered.items, main, conflict or handwritten, input.facts.header_end > 0, !editing, input.metadata_fields) else try encodeMarkdown(a, model, conflict, input.metadata_fields, !editing);
    var draft_cells: std.ArrayList(DraftCell) = .empty;
    if (!input.compact) for (model.cells) |c| {
        const existing = if (eq(c.kind, "code")) (try snapshotComments(a, c)).len else 0;
        try draft_cells.append(a, .{ .kind = c.kind, .source = c.source, .attributes = c.attributes, .outputs = c.outputs[@min(existing, c.outputs.len)..] });
    };
    var status: S = "ok";
    for (model.diagnostics) |d| if (eq(d.severity, "error")) {
        status = "diagnostic";
    };
    return .{ .status = status, .model = model, .draft = .{ .supplied = true, .preamble = model.preamble, .metadata = model.metadata, .cells = try draft_cells.toOwnedSlice(a) }, .source = if (input.compact) "" else if (!input.draft.supplied and !oneOf(input.phase, &.{ "normalize", "export", "view", "compose" }) and eq(input.target, model.format)) model.original else rendered, .program = try a.dupe(u8, execution.written()), .execution = if (input.compact) "" else try cat(a, &.{ execution.written(), main, "\n" }), .roots = try roots.toOwnedSlice(a), .expectations = try expectations.toOwnedSlice(a), .mappings = try maps.toOwnedSlice(a) };
}
fn nodeEqual(x: Node, y: Node) bool {
    if (!eq(x.fingerprint, y.fingerprint) or x.dependencies.len != y.dependencies.len or x.binders.len != y.binders.len) return false;
    for (x.dependencies, y.dependencies) |xd, yd| if (!eq(xd, yd)) return false;
    for (x.binders, y.binders) |xb, yb| if (!eq(xb, yb)) return false;
    return true;
}
fn definitionEqual(old: []const Node, new: []const Node, name: S) bool {
    var oi: usize = 0;
    var ni: usize = 0;
    while (true) {
        while (oi < old.len and !eq(old[oi].name, name)) oi += 1;
        while (ni < new.len and !eq(new[ni].name, name)) ni += 1;
        if (oi == old.len or ni == new.len) return oi == old.len and ni == new.len;
        if (!nodeEqual(old[oi], new[ni])) return false;
        oi += 1;
        ni += 1;
    }
}
/// Whether `deps` names `node` itself or one of its binders.
fn reaches(deps: []const S, node: Node) bool {
    if (has(deps, node.name)) return true;
    for (node.binders) |binder| if (has(deps, binder)) return true;
    return false;
}
pub fn plan(a: A, input: PlanInput) !Plan {
    const previous = try input.previous.nodes(a);
    const current = try input.current.nodes(a);
    var names: Strings = .empty;
    for (current) |d| if (!has(names.items, d.name)) try names.append(a, d.name);
    for (previous) |d| if (!has(names.items, d.name)) try names.append(a, d.name);
    var changed: Strings = .empty;
    for (names.items) |name| if (!definitionEqual(previous, current, name)) try changed.append(a, name);
    const format_changed = input.known and input.previous.version != input.current.version;
    const global = !input.known or format_changed or !eq(input.previous.context, input.current.context) or !eq(input.previous.scope, input.current.scope) or (eq(input.current.scope, "module") and changed.items.len > 0);
    var explanations: std.ArrayList(Explanation) = .empty;
    var reused: Strings = .empty;
    var evaluate: Strings = .empty;
    for (input.roots) |root| {
        var deps: Strings = .empty;
        try deps.append(a, root);
        var growing = true;
        while (growing) {
            const old = deps.items.len;
            for (current) |d| if (reaches(deps.items, d)) {
                if (!has(deps.items, d.name)) try deps.append(a, d.name);
                for (d.dependencies) |dep| if (!has(deps.items, dep)) try deps.append(a, dep);
            };
            growing = deps.items.len > old;
        }
        var causes: Strings = .empty;
        for (changed.items) |name| if (has(deps.items, name)) try causes.append(a, name);
        const reason = if (format_changed) "Graph format changed" else if (global) "Document context changed or no checked baseline" else if (causes.items.len > 0) try cat(a, &.{ "Changed: ", try join(a, causes.items, ", ") }) else if (has(input.force, root)) "Explicit run" else if (!has(input.available, root)) "No successful result" else "Unchanged dependencies";
        try explanations.append(a, .{ .root = root, .reason = reason, .dependencies = try deps.toOwnedSlice(a) });
        if (eq(reason, "Unchanged dependencies")) try reused.append(a, root) else try evaluate.append(a, root);
    }
    return .{ .changed = try changed.toOwnedSlice(a), .evaluate = try evaluate.toOwnedSlice(a), .reused = try reused.toOwnedSlice(a), .explanations = try explanations.toOwnedSlice(a) };
}
pub fn run(a: A, input: Input) !Result {
    if (eq(input.phase, "plan")) return .{ .plan = try plan(a, input.reactivity), .model = input.model, .draft = input.draft };
    if (!eq(input.phase, "segment")) return finish(a, input);
    var model: Model = undefined;
    if (input.draft.supplied) {
        var cells: std.ArrayList(Cell) = .empty;
        for (input.draft.cells) |d| {
            var c = try makeCell(a, d.kind, d.source, d.attributes, 0, d.source.len, 0);
            c.outputs = d.outputs;
            try cells.append(a, c);
        }
        model = .{ .format = input.format, .original = input.source, .preamble = input.draft.preamble, .metadata = input.draft.metadata, .cells = try cells.toOwnedSlice(a) };
    } else model = if (eq(input.format, "roc")) try segmentRoc(a, input) else try segmentMarkdown(a, input);
    return .{ .model = model, .draft = input.draft, .source = model.original };
}

test "source assembly names results without losing UTF-8 source ranges or reserved cell IDs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cells = [_]Cell{
        try makeCell(a, "code", "\"héllo\"", "", 0, 8, 0),
        try makeCell(a, "code", "42", "id=1", 0, 2, 0),
    };
    cells[0].facts.statements = try a.dupe(syntax.Statement, &.{.{ .start = 0, .end = 8, .kind = "expr" }});
    cells[1].facts.statements = try a.dupe(syntax.Statement, &.{.{ .start = 0, .end = 2, .kind = "expr" }});
    const result = try run(a, .{ .phase = "evaluate", .format = "roc", .target = "roc", .source = "", .model = .{ .cells = &cells }, .draft = .{ .supplied = true } });
    try std.testing.expectEqualStrings("ok", result.status);
    try std.testing.expectEqualStrings("out_2 = \"héllo\"\n\nout_1 = 42\n\n", result.program);
    try std.testing.expectEqualStrings("out_2", result.roots[0]);
    try std.testing.expectEqualStrings("out_1", result.roots[1]);
    const m = result.mappings[1];
    try std.testing.expectEqualStrings("\"héllo\"", result.program[@intCast(m.generated_start)..@intCast(m.generated_end)]);
    try std.testing.expectEqual(@as(u64, 8), m.source_end);
    const compact = try run(a, .{ .compact = true, .phase = "evaluate", .format = "roc", .target = "roc", .source = "", .model = .{ .cells = &cells }, .draft = .{ .supplied = true } });
    try std.testing.expectEqualStrings(result.program, compact.program);
    try std.testing.expectEqualStrings(try json(a, result.roots), try json(a, compact.roots));
    try std.testing.expectEqualStrings(try json(a, result.mappings), try json(a, compact.mappings));
    try std.testing.expectEqualStrings("", compact.execution);
    try std.testing.expectEqualStrings("", compact.source);
    try std.testing.expectEqual(@as(usize, 0), compact.draft.cells.len);
}

test "reactive plan follows transitive dependencies and handles removed definitions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const old = [_]Node{
        .{ .name = "width", .fingerprint = "old" },
        .{ .name = "area", .fingerprint = "same", .dependencies = &.{"width"} },
        .{ .name = "out_area", .fingerprint = "same", .dependencies = &.{"area"} },
        .{ .name = "out_other", .fingerprint = "same" },
    };
    var current = old;
    current[0].fingerprint = "new";
    const p = try plan(a, .{ .known = true, .previous = .{ .scope = "definition", .definitions = &old }, .current = .{ .scope = "definition", .definitions = &current }, .roots = &.{ "out_area", "out_other" }, .available = &.{ "out_area", "out_other" } });
    try std.testing.expectEqual(@as(usize, 1), p.evaluate.len);
    try std.testing.expectEqualStrings("out_area", p.evaluate[0]);
    try std.testing.expectEqualStrings("out_other", p.reused[0]);
    try std.testing.expectEqualStrings("Changed: width", p.explanations[0].reason);
    const removed = try plan(a, .{ .known = true, .previous = .{ .scope = "definition", .definitions = &old }, .current = .{ .scope = "definition", .definitions = old[1..] }, .roots = &.{"out_area"}, .available = &.{"out_area"} });
    try std.testing.expectEqualStrings("width", removed.changed[0]);
    try std.testing.expectEqualStrings("out_area", removed.evaluate[0]);
}

test "module context change invalidates otherwise identical roots" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const p = try plan(arena.allocator(), .{ .known = true, .previous = .{ .context = "package-v1" }, .current = .{ .context = "package-v2" }, .roots = &.{"out_1"}, .available = &.{"out_1"} });
    try std.testing.expectEqualStrings("out_1", p.evaluate[0]);
    try std.testing.expectEqual(@as(usize, 0), p.reused.len);
}

test "reactive plan follows type and module nodes and resolves binders" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const definitions = [_]Node{
        .{ .name = "pair", .binders = &.{ "pair", "other" }, .fingerprint = "same" },
        .{ .name = "out_pair", .fingerprint = "same", .dependencies = &.{"other"} },
        .{ .name = "out_point", .fingerprint = "same", .dependencies = &.{"Point"} },
        .{ .name = "out_import", .fingerprint = "same", .dependencies = &.{"module:Geometry"} },
        .{ .name = "out_other", .fingerprint = "same" },
    };
    const types = [_]Node{.{ .name = "Point", .fingerprint = "old" }};
    const modules = [_]Node{.{ .name = "module:Geometry", .fingerprint = "old" }};
    const previous: Graph = .{ .scope = "definitions", .definitions = &definitions, .types = &types, .modules = &modules };
    const roots: []const S = &.{ "out_pair", "out_point", "out_import", "out_other" };
    var changed_types = types;
    changed_types[0].fingerprint = "new";
    const by_type = try plan(a, .{ .known = true, .previous = previous, .current = .{ .scope = "definitions", .definitions = &definitions, .types = &changed_types, .modules = &modules }, .roots = roots, .available = roots });
    try std.testing.expectEqualStrings("[\"out_point\"]", try json(a, by_type.evaluate));
    try std.testing.expectEqualStrings("Changed: Point", by_type.explanations[1].reason);
    var changed_modules = modules;
    changed_modules[0].fingerprint = "new";
    const by_module = try plan(a, .{ .known = true, .previous = previous, .current = .{ .scope = "definitions", .definitions = &definitions, .types = &types, .modules = &changed_modules }, .roots = roots, .available = roots });
    try std.testing.expectEqualStrings("[\"out_import\"]", try json(a, by_module.evaluate));
    var changed_definitions = definitions;
    changed_definitions[0].fingerprint = "new";
    const by_binder = try plan(a, .{ .known = true, .previous = previous, .current = .{ .scope = "definitions", .definitions = &changed_definitions, .types = &types, .modules = &modules }, .roots = roots, .available = roots });
    try std.testing.expectEqualStrings("[\"out_pair\"]", try json(a, by_binder.evaluate));
    try std.testing.expectEqualStrings("Changed: pair", by_binder.explanations[0].reason);
}

test "a baseline of another graph version invalidates every root" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const p = try plan(arena.allocator(), .{ .known = true, .previous = .{ .version = 1, .scope = "definitions" }, .current = .{ .scope = "definitions" }, .roots = &.{"out_1"}, .available = &.{"out_1"} });
    try std.testing.expectEqualStrings("out_1", p.evaluate[0]);
    try std.testing.expectEqualStrings("Graph format changed", p.explanations[0].reason);
}
