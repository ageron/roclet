//! In-process engine tests: several engines in one process, observer
//! attribution, header parsing without workspace writes, and request resets.
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
