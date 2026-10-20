//! Selective recomputation workloads, also replayed in WASM for complete parity.
const std = @import("std");
const docs = @import("documents.zig");
const V = std.json.Value;
const A = std.mem.Allocator;
fn json(a: A, data: anytype) ![]u8 {
    var w: std.Io.Writer.Allocating = .init(a);
    try std.json.Stringify.value(data, .{}, &w.writer);
    return w.toOwnedSlice();
}
fn value(a: A, data: anytype) !V {
    return std.json.parseFromSliceLeaky(V, a, try json(a, data), .{ .allocate = .alloc_always });
}
fn get(v: V, key: []const u8) V {
    return v.object.get(key).?;
}
fn equal(a: A, expected: V, actual: V) !void {
    if (!std.mem.eql(u8, try json(a, expected), try json(a, actual))) {
        std.debug.print("Expected {s}\nGot {s}\n", .{ try json(a, expected), try json(a, actual) });
        return error.M4Mismatch;
    }
}
fn has(list: V, root: []const u8) bool {
    for (list.array.items) |item| if (std.mem.eql(u8, item.string, root)) return true;
    return false;
}
/// Values, tests or events without their `reused` flags.
fn withoutReused(a: A, items: V) !V {
    const copy = try value(a, items);
    for (copy.array.items) |*item| _ = item.object.orderedRemove("reused");
    return copy;
}
/// One dependency analysis per newly checked revision, however many roots it
/// runs; a request that reuses the retained revision analyses nothing.
fn expectAnalysedOnce(response: V) !void {
    const cache = get(response, "workspaceCache");
    const fresh_revision = get(cache, "prepared_hits").integer == 0;
    const expected: i64 = if (response.object.get("graph") != null and fresh_revision) 1 else 0;
    const actual = get(cache, "analyses").integer;
    if (actual != expected) {
        std.debug.print("Expected {d} analyses, got {d}\n", .{ expected, actual });
        return error.M4AnalysisCount;
    }
}
const Workload = struct {
    name: []const u8,
    w: V,
    /// The `after` request without `reactivity`.
    after: V,
    before: V,

    fn status(self: Workload) V {
        return self.w.object.get("beforeStatus") orelse .{ .string = "ok" };
    }
    fn force(self: Workload, a: A) V {
        return self.w.object.get("force") orelse .{ .array = .init(a) };
    }
};
fn reactive(a: A, request: V, reactivity: anytype) !V {
    var copy = try value(a, request);
    try copy.object.put(a, "reactivity", try value(a, reactivity));
    return copy;
}

/// The engine-owned baseline: `before` and `selective` participate in one
/// process; the stateless `full` run is the reference.
fn engine(a: A, suite: *docs.Suite, workload: Workload) !void {
    const name = workload.name;
    const responses = try suite.callSequence(&.{
        try std.mem.concat(a, u8, &.{ name, "/engine/before" }),
        try std.mem.concat(a, u8, &.{ name, "/engine/selective" }),
        try std.mem.concat(a, u8, &.{ name, "/engine/full" }),
    }, &.{
        try reactive(a, workload.before, .{ .reset = true }),
        try reactive(a, workload.after, .{ .force = workload.force(a) }),
        workload.after,
    });
    const before, const selective, const full = responses[0..3].*;
    for (responses) |response| try expectAnalysedOnce(response);
    try equal(a, workload.status(), get(before, "status"));
    try equal(a, get(full, "status"), get(selective, "status"));
    if (selective.object.get("graph") == null) return;
    const plan = get(selective, "plan");
    try equal(a, get(workload.w, "evaluate"), get(plan, "evaluate"));
    try equal(a, get(workload.w, "reused"), get(plan, "reused"));
    const evaluation = get(selective, "evaluation");
    try equal(a, get(plan, "evaluate"), get(evaluation, "evaluated_roots"));
    try equal(a, get(get(full, "evaluation"), "root_errors"), get(evaluation, "root_errors"));
    // Complete presentations: equal to the clean run apart from `reused`,
    // which is set exactly for the roots the plan reused.
    inline for (.{ "values", "tests", "events" }) |key| {
        try equal(a, try withoutReused(a, get(get(full, "evaluation"), key)), try withoutReused(a, get(evaluation, key)));
        for (get(evaluation, key).array.items) |item| {
            if (get(item, "reused").bool != has(get(plan, "reused"), get(item, "root").string)) return error.M4ReusedFlag;
        }
        for (get(get(full, "evaluation"), key).array.items) |item| if (get(item, "reused").bool) return error.M4ReusedFlag;
    }
    if (workload.w.object.get("testMoved")) |_| {
        // A reused test is located in the current revision, not the old one.
        const old = get(get(before, "evaluation"), "tests").array.items[0];
        const now = get(evaluation, "tests").array.items[0];
        if (!get(now, "reused").bool or get(old, "start").integer == get(now, "start").integer) return error.M4StaleTestLocation;
    }
}

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    const root = args[1];
    const temp = try std.fs.path.join(a, &.{ root, "m4-test.tmp.json" });
    defer std.Io.Dir.cwd().deleteFile(init.io, temp) catch {};
    var suite: docs.Suite = .{ .a = a, .io = init.io, .executable = args[2], .temp = temp };
    const path = try std.fs.path.join(a, &.{ root, "tests/m4-workloads.json" });
    const workloads = try std.json.parseFromSliceLeaky(V, a, try std.Io.Dir.cwd().readFileAlloc(init.io, path, a, .limited(1024 * 1024)), .{});
    for (workloads.array.items) |w| {
        const name = get(w, "name").string;
        std.debug.print("M4 {s}\n", .{name});
        var before = try value(a, .{ .operation = "document", .action = "evaluate", .format = "roc", .source = get(w, "before"), .isolateErrors = true });
        if (w.object.get("modules")) |m| try before.object.put(a, "modules", m);
        var after = try value(a, before);
        try after.object.put(a, "source", get(w, "after"));
        if (w.object.get("afterModules")) |m| try after.object.put(a, "modules", m);
        const workload: Workload = .{ .name = name, .w = w, .before = before, .after = after };
        try engine(a, &suite, workload);
    }
    const manifest_path = try std.fs.path.join(a, &.{ root, "artifacts/manifest.json" });
    const manifest = try std.json.parseFromSliceLeaky(V, a, try std.Io.Dir.cwd().readFileAlloc(init.io, manifest_path, a, .limited(1024 * 1024)), .{});
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = try std.fs.path.join(a, &.{ root, "artifacts/m4-conformance.json" }), .data = try json(a, .{ .manifest = manifest, .cases = suite.cases.items }) });
    std.debug.print("PASS M4: {d} complete native responses\n", .{suite.cases.items.len});
}
