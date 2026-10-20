//! In-process engine tests: several engines in one process, observer
//! attribution, header parsing without workspace writes, request resets and
//! image buffer sizing.
const std = @import("std");
const bridge = @import("bridge");
const Engine = bridge.Engine;
const platform = bridge.platform;
const V = std.json.Value;
pub const std_options = bridge.std_options;

/// Responses are owned by the adapter's page allocator.
const response_allocator = std.heap.page_allocator;

const Response = struct {
    parsed: std.json.Parsed(V),

    fn deinit(self: *Response) void {
        self.parsed.deinit();
    }
    fn field(self: Response, name: []const u8) V {
        return self.parsed.value.object.get(name) orelse .null;
    }
    fn evaluation(self: Response, name: []const u8) []V {
        const value = self.field("evaluation").object.get(name) orelse return &.{};
        return value.array.items;
    }
    fn counter(self: Response, name: []const u8) i64 {
        return self.field("workspaceCache").object.get(name).?.integer;
    }
};

fn evaluate(engine: *Engine, source: []const u8) !Response {
    const gpa = std.testing.allocator;
    var request: std.Io.Writer.Allocating = .init(gpa);
    defer request.deinit();
    try std.json.Stringify.value(.{ .operation = "document", .action = "evaluate", .format = "roc", .source = source }, .{}, &request.writer);
    const bytes = try bridge.process(engine, request.written());
    defer response_allocator.free(bytes);
    try std.testing.expect(!platform.rocOpsActive());
    return .{ .parsed = try std.json.parseFromSlice(V, gpa, bytes, .{}) };
}

fn expectOnlyDebug(response: Response, message: []const u8) !void {
    const events = response.evaluation("events");
    try std.testing.expect(events.len > 0);
    for (events) |event| {
        try std.testing.expectEqualStrings("dbg", event.object.get("kind").?.string);
        try std.testing.expectEqualStrings(message, event.object.get("message").?.string);
        try std.testing.expectEqualStrings("out_1", event.object.get("root").?.string);
    }
}

test "two engines in one process keep revisions, counters and events apart" {
    var a = Engine.init(std.testing.allocator, .failing);
    defer a.deinit();
    var b = Engine.init(std.testing.allocator, .failing);
    defer b.deinit();
    const source_a = "# %%\nshared = {\n    dbg \"from-a\"\n    1\n}\n# %%\nshared";
    const source_b = "# %%\nshared = {\n    dbg \"from-b\"\n    2\n}\n# %%\nshared";

    var first = try evaluate(&a, source_a);
    defer first.deinit();
    try std.testing.expectEqualStrings("ok", first.field("status").string);
    try expectOnlyDebug(first, "\"from-a\"");
    try std.testing.expectEqual(@as(i64, 1), first.counter("frontend_builds"));
    const a_revision = a.revision.?;

    var second = try evaluate(&b, source_b);
    defer second.deinit();
    try std.testing.expectEqualStrings("ok", second.field("status").string);
    try expectOnlyDebug(second, "\"from-b\"");
    try std.testing.expectEqual(@as(i64, 1), second.counter("frontend_builds"));
    try std.testing.expectEqual(a_revision, a.revision.?);
    const b_revision = b.revision.?;
    const b_stats = b.stats;

    var third = try evaluate(&a, source_a);
    defer third.deinit();
    try expectOnlyDebug(third, "\"from-a\"");
    try std.testing.expectEqual(@as(i64, 0), third.counter("frontend_builds"));
    try std.testing.expectEqual(@as(i64, 0), third.counter("lowerings"));
    try std.testing.expect(third.counter("prepared_hits") > 0);
    try std.testing.expectEqual(a_revision, a.revision.?);
    try std.testing.expectEqual(b_revision, b.revision.?);
    try std.testing.expectEqual(b_stats, b.stats);
    try std.testing.expectEqual(@as(u64, 0), a.stats.frontend_builds);
}

test "observations carry the root of the execution that produced them" {
    var engine = Engine.init(std.testing.allocator, .failing);
    defer engine.deinit();
    var response = try evaluate(&engine, "# %%\nshared = {\n    dbg \"s\"\n    1\n}\n# %%\nshared\n# %%\nshared + 1");
    defer response.deinit();
    try std.testing.expectEqualStrings("ok", response.field("status").string);
    const events = response.evaluation("events");
    try std.testing.expectEqual(@as(usize, 2), events.len);
    inline for (.{ "out_1", "out_2" }, 0..) |root, i| {
        try std.testing.expectEqualStrings("dbg", events[i].object.get("kind").?.string);
        try std.testing.expectEqualStrings("\"s\"", events[i].object.get("message").?.string);
        try std.testing.expectEqualStrings(root, events[i].object.get("root").?.string);
    }
    try std.testing.expectEqual(@as(usize, 2), response.evaluation("values").len);
}

test "header parsing leaves the workspace untouched and requests reset per-request state" {
    var engine = Engine.init(std.testing.allocator, .failing);
    defer engine.deinit();
    const gpa = std.testing.allocator;
    const before = try engine.workspace.contentIdentity(gpa);
    defer gpa.free(before);
    const url = "https://github.com/lukewilliamboswell/roc-time/releases/download/0.2.0/roc-time-7QH5VBiCwDLu3UkizpgB3FESJitahxR82Vgg2bWkJvHL.tar.zst";
    var packaged = try evaluate(&engine, "app [main!] { time: \"" ++ url ++ "\" }\n\n# %%\n1 + 1");
    defer packaged.deinit();
    const required = packaged.field("packagesRequired").array.items;
    try std.testing.expectEqual(@as(usize, 1), required.len);
    try std.testing.expectEqualStrings(url, required[0].object.get("url").?.string);
    try std.testing.expect(!engine.workspace.files.contains("/internal/header.roc"));
    const after = try engine.workspace.contentIdentity(gpa);
    defer gpa.free(after);
    try std.testing.expectEqualStrings(before, after);

    engine.beginRequest();
    try std.testing.expectEqual(@as(usize, 0), engine.workspace.required.items.len);
    try std.testing.expectEqual(@TypeOf(engine.stats){}, engine.stats);
    var plain = try evaluate(&engine, "# %%\n1 + 1");
    defer plain.deinit();
    try std.testing.expectEqualStrings("ok", plain.field("status").string);
    try std.testing.expectEqual(@as(usize, 0), plain.field("packagesRequired").array.items.len);
    try std.testing.expectEqual(@as(i64, 1), plain.counter("frontend_builds"));
    try std.testing.expectEqual(@as(i64, 1), plain.counter("executions"));
}

test "a revision's image is reported and grows its buffer only when it must" {
    var engine = Engine.init(std.testing.allocator, .failing);
    defer engine.deinit();
    const source = "# %%\nwidth = 8\nheight = 3\n# %%\nwidth * height";
    var first = try evaluate(&engine, source);
    defer first.deinit();
    try std.testing.expectEqualStrings("ok", first.field("status").string);
    try std.testing.expectEqual(@as(i64, 1), first.counter("lowerings"));
    const image = engine.revision.?.image.?;
    const bytes = first.counter("image_bytes");
    const retries = first.counter("image_retries");
    try std.testing.expectEqual(@as(i64, @intCast(image.size)), bytes);
    try std.testing.expectEqual(@as(i64, image.attempts - 1), retries);
    try std.testing.expect(image.size <= image.buffer.len);
    if (@import("roclet_options").image_initial_bytes) |initial| {
        // A forced small first buffer doubles until the image fits.
        try std.testing.expectEqual(initial << @intCast(retries), image.buffer.len);
        try std.testing.expectEqual(image.size > initial, retries > 0);
    } else {
        // The default first buffer holds an ordinary notebook's image.
        try std.testing.expectEqual(@as(i64, 0), retries);
    }

    var reused = try evaluate(&engine, source);
    defer reused.deinit();
    try std.testing.expectEqual(@as(i64, 0), reused.counter("lowerings"));
    try std.testing.expectEqual(@as(i64, 0), reused.counter("image_bytes"));
    try std.testing.expectEqual(@as(i64, 0), reused.counter("image_retries"));
}

const notebook = bridge.notebook;

/// A typed document request over `program`: every `out_*` binding is an
/// output root, and the single `expect` statement is the test root.
fn typedRequest(a: std.mem.Allocator, program: []const u8, roots: []const []const u8, isolate_errors: bool) !notebook.Request {
    var expectations: []const notebook.Expectation = &.{};
    if (std.mem.find(u8, program, "expect")) |start| {
        const end = std.mem.findScalarPos(u8, program, start, '\n') orelse program.len;
        expectations = try a.dupe(notebook.Expectation, &.{.{ .root = "roclet_expect_1", .start = @intCast(start), .end = @intCast(end) }});
    }
    return .{
        .program = program,
        .roots = roots,
        .expectations = expectations,
        .cells = try a.dupe(notebook.CellRange, &.{.{ .key = "document", .start = 0, .end = program.len }}),
        .isolate_errors = isolate_errors,
    };
}

test "typed evaluation checks, analyses and lowers once for every root" {
    var engine = Engine.init(std.testing.allocator, .failing);
    defer engine.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const program = "a = 1\n\nout_1 = a + 1\n\nout_2 = {\n    dbg a\n    a + 2\n}\n\nexpect a == 1\n";
    const roots: []const []const u8 = &.{ "out_1", "out_2", "roclet_expect_1" };
    engine.beginRequest();
    var checked = try notebook.checkDocument(&engine, arena.allocator(), try typedRequest(arena.allocator(), program, roots, false));
    try std.testing.expectEqualStrings("ok", checked.evaluation.status);
    try std.testing.expectEqualStrings("definitions", checked.evaluation.dependency_scope);
    try checked.evaluate(roots);
    const result = checked.evaluation;
    try std.testing.expect(!platform.rocOpsActive());
    try std.testing.expectEqualStrings("ok", result.status);
    try std.testing.expectEqual(@as(u64, 1), engine.stats.frontend_builds);
    try std.testing.expectEqual(@as(u64, 1), engine.stats.lowerings);
    try std.testing.expectEqual(@as(u64, 1), engine.stats.analyses);
    try std.testing.expectEqual(@as(u64, 3), engine.stats.executions);
    try std.testing.expectEqual(@as(u64, 0), engine.stats.prepared_hits);
    try std.testing.expectEqual(roots.len, result.evaluated_roots.len);
    for (roots, result.evaluated_roots) |expected, actual| try std.testing.expectEqualStrings(expected, actual);
    try std.testing.expectEqual(@as(usize, 2), result.values.len);
    try std.testing.expectEqualStrings("2.0", result.values[0].text);
    try std.testing.expectEqualStrings("3.0", result.values[1].text);
    try std.testing.expectEqual(@as(usize, 1), result.tests.len);
    try std.testing.expect(result.tests[0].passed);
    try std.testing.expectEqual(@as(usize, 1), result.events.len);
    try std.testing.expectEqual(platform.EventKind.dbg, result.events[0].kind);
    try std.testing.expectEqualStrings("out_2", result.events[0].root);
    for (result.definitions) |definition| try std.testing.expectEqualStrings("document", definition.cell.?);

    // A second request against the same inputs reuses the revision and its analysis.
    engine.beginRequest();
    var again = try notebook.checkDocument(&engine, arena.allocator(), try typedRequest(arena.allocator(), program, roots, false));
    try again.evaluate(roots[0..1]);
    try std.testing.expectEqualStrings("ok", again.evaluation.status);
    try std.testing.expectEqual(@as(u64, 0), engine.stats.frontend_builds);
    try std.testing.expectEqual(@as(u64, 0), engine.stats.lowerings);
    try std.testing.expectEqual(@as(u64, 0), engine.stats.analyses);
    try std.testing.expectEqual(@as(u64, 1), engine.stats.executions);
    try std.testing.expectEqual(@as(u64, 1), engine.stats.prepared_hits);
}

test "typed evaluation isolates a crashing root or fails the revision" {
    var engine = Engine.init(std.testing.allocator, .failing);
    defer engine.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const program = "out_good = 42\n\nout_bad = {\n    crash \"boom\"\n    0\n}\n";
    const roots: []const []const u8 = &.{ "out_good", "out_bad" };
    var isolated = try notebook.checkDocument(&engine, arena.allocator(), try typedRequest(arena.allocator(), program, roots, true));
    try isolated.evaluate(roots);
    try std.testing.expectEqualStrings("partial", isolated.evaluation.status);
    try std.testing.expectEqual(@as(usize, 1), isolated.evaluation.values.len);
    try std.testing.expectEqualStrings("out_good", isolated.evaluation.values[0].root);
    try std.testing.expectEqual(@as(usize, 1), isolated.evaluation.root_errors.len);
    try std.testing.expectEqualStrings("out_bad", isolated.evaluation.root_errors[0].root);
    try std.testing.expectEqualStrings("runtime_error", isolated.evaluation.root_errors[0].status);

    // Without isolation a constant crash fails the whole revision: no values.
    var request = try typedRequest(arena.allocator(), program, roots, false);
    request.failure_roots = roots;
    var atomic = try notebook.checkDocument(&engine, arena.allocator(), request);
    try atomic.evaluate(roots);
    try std.testing.expectEqualStrings("diagnostic", atomic.evaluation.status);
    try std.testing.expectEqual(@as(usize, 0), atomic.evaluation.values.len);
    try std.testing.expectEqual(@as(usize, 0), atomic.evaluation.evaluated_roots.len);
    try std.testing.expectEqual(@as(usize, 0), atomic.evaluation.definitions.len);
}

test "event buffer keeps protocol-1 observation bounds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var many: platform.EventBuffer = .{ .arena = a };
    for (0..1001) |_| many.observe(.dbg, "x", "out_1");
    // 1,000 observations, then the single marker; the 1,001st is dropped.
    try std.testing.expectEqual(@as(usize, 1001), many.events.items.len);
    try std.testing.expectEqual(platform.EventKind.truncated, many.events.items[1000].kind);
    for (many.events.items[0..1000]) |event| try std.testing.expectEqualStrings("out_1", event.root.?);
    // Designated values are never dropped, even past the event limit.
    many.observe(.value, "42", "out_1");
    try std.testing.expectEqualStrings("42", many.events.items[1001].message);

    var long: platform.EventBuffer = .{ .arena = a };
    const message = try a.alloc(u8, 70 * 1024);
    @memset(message, 'a');
    long.observe(.dbg, message, null);
    try std.testing.expectEqual(platform.EventKind.truncated, long.events.items[0].kind);
    try std.testing.expectEqual(@as(usize, 64 * 1024), long.events.items[1].message.len);
    long.observe(.dbg, message, null);
    try std.testing.expectEqual(@as(usize, 3), long.events.items.len);

    // A cut never splits a UTF-8 sequence: "é" straddles the 64 KiB boundary.
    var utf8: platform.EventBuffer = .{ .arena = a };
    const accented = try a.alloc(u8, 64 * 1024 + 1);
    @memset(accented, 'a');
    accented[64 * 1024 - 1] = 0xc3;
    accented[64 * 1024] = 0xa9;
    utf8.observe(.dbg, accented, null);
    try std.testing.expectEqual(@as(usize, 64 * 1024 - 1), utf8.events.items[1].message.len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(utf8.events.items[1].message));

    // A rich root's second designated value (its Display wire) may use 512 KiB.
    var rich: platform.EventBuffer = .{ .arena = a, .rich = true };
    const wire = try a.alloc(u8, 600 * 1024);
    @memset(wire, 'w');
    rich.observe(.value, wire[0 .. 70 * 1024], null);
    rich.observe(.value, wire, null);
    try std.testing.expectEqual(@as(usize, 64 * 1024), rich.events.items[1].message.len);
    try std.testing.expectEqual(@as(usize, 512 * 1024), rich.events.items[2].message.len);
    try std.testing.expectEqual(@as(usize, 3), rich.events.items.len);
}

test "one app header synthesiser serves scripts and revisions" {
    const runner = bridge.runner;
    var engine = Engine.init(std.testing.allocator, .failing);
    defer engine.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings(
        "app [main!] { pf: platform \"./.roc_echo_platform/main.roc\" }\n\nimport pf.Echo\n\n",
        try runner.synthesizeAppHeader(a, &.{}, &.{}),
    );
    const header = try std.fmt.allocPrint(a, "app [] {{ time: \"https://example.com/time.tar.zst\", roclet: \"{s}\", geo: \"./geo/main.roc\" }}", .{runner.display_package_url});
    const packages = try runner.parseHeaderPackages(a, engine.workspace.io(a), header);
    try std.testing.expectEqual(@as(usize, 3), packages.len);
    // The embedded Display package is a module, never a package dependency.
    try std.testing.expectEqualStrings(
        "app [main!, out_text, out_value] { pf: platform \"./.roc_echo_platform/main.roc\", time: \"https://example.com/time.tar.zst\", geo: \"./geo/main.roc\" }\n\nimport pf.Echo\n\n",
        try runner.synthesizeAppHeader(a, &.{ "out_text", "out_value" }, packages),
    );
}

test "a script run reports its program response without the notebook revision" {
    var engine = Engine.init(std.testing.allocator, .failing);
    defer engine.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source = "main! = |args| {\n    dbg args\n    Ok({})\n}";
    const outcome = try bridge.script.run(&engine, arena.allocator(), .{ .source = source, .user_bytes = @intCast(source.len), .args = &.{"x"} });
    try std.testing.expectEqualStrings("ok", outcome.status);
    try std.testing.expectEqual(@as(usize, 1), outcome.events.len);
    try std.testing.expectEqual(platform.EventKind.dbg, outcome.events[0].kind);
    try std.testing.expectEqualStrings("[\"x\"]", outcome.events[0].message);
    try std.testing.expectEqualStrings("main!", outcome.definitions[0].name);
    try std.testing.expect(engine.revision == null);
    try std.testing.expectEqual(@as(u64, 1), engine.stats.analyses);
    try std.testing.expectEqual(@as(u64, 1), engine.stats.executions);

    // The same run through the JSON boundary, as `operation: "program"`.
    const bytes = try bridge.process(&engine,
        \\{"operation":"program","protocol":1,"source":"main! = |args| {\n    dbg args\n    Ok({})\n}","user_bytes":0,"args":["y"]}
    );
    defer response_allocator.free(bytes);
    const parsed = try std.json.parseFromSlice(V, std.testing.allocator, bytes, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("ok", parsed.value.object.get("status").?.string);
    const events = parsed.value.object.get("events").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualStrings("[\"y\"]", events[0].object.get("message").?.string);
    try std.testing.expect(events[0].object.get("root") == null);
}
