//! Selective recomputation workloads, also replayed in WASM for complete parity.
const std = @import("std");
const docs = @import("documents.zig");
const V = std.json.Value;
fn json(a: std.mem.Allocator, data: anytype) ![]u8 {
    var w: std.Io.Writer.Allocating = .init(a);
    try std.json.Stringify.value(data, .{}, &w.writer);
    return w.toOwnedSlice();
}
fn value(a: std.mem.Allocator, data: anytype) !V {
    return std.json.parseFromSliceLeaky(V, a, try json(a, data), .{ .allocate = .alloc_always });
}
fn get(v: V, key: []const u8) V {
    return v.object.get(key).?;
}
fn equal(a: std.mem.Allocator, expected: V, actual: V) !void {
    if (!std.mem.eql(u8, try json(a, expected), try json(a, actual))) {
        std.debug.print("Expected {s}\nGot {s}\n", .{ try json(a, expected), try json(a, actual) });
        return error.M4Mismatch;
    }
}
/// One dependency analysis per checked request, however many roots it runs
/// (each native call is a fresh engine, so its revision is always new).
fn expectAnalysedOnce(response: V) !void {
    const expected: i64 = if (response.object.get("graph") != null) 1 else 0;
    const actual = get(get(response, "workspaceCache"), "analyses").integer;
    if (actual != expected) {
        std.debug.print("Expected {d} analyses, got {d}\n", .{ expected, actual });
        return error.M4AnalysisCount;
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
        var request = try value(a, .{ .operation = "document", .action = "evaluate", .format = "roc", .source = get(w, "before"), .isolateErrors = true });
        if (w.object.get("modules")) |m| try request.object.put(a, "modules", m);
        const before = try suite.call(try std.mem.concat(a, u8, &.{ name, "/before" }), request);
        try expectAnalysedOnce(before);
        try equal(a, try value(a, "ok"), get(before, "status"));
        try request.object.put(a, "source", get(w, "after"));
        if (w.object.get("afterModules")) |m| try request.object.put(a, "modules", m);
        const full = try suite.call(try std.mem.concat(a, u8, &.{ name, "/full" }), request);
        try expectAnalysedOnce(full);
        var available: std.ArrayList(V) = .empty;
        for (get(get(before, "evaluation"), "values").array.items) |v| try available.append(a, get(v, "root"));
        const graph = get(before, "graph");
        try request.object.put(a, "reactivity", try value(a, .{ .known = true, .previous = graph, .current = graph, .available = available.items, .roots = &[_]V{}, .force = &[_]V{} }));
        const selective = try suite.call(try std.mem.concat(a, u8, &.{ name, "/selective" }), request);
        try expectAnalysedOnce(selective);
        try equal(a, get(full, "status"), get(selective, "status"));
        if (selective.object.get("graph") == null) continue;
        const plan = get(selective, "plan");
        try equal(a, get(w, "evaluate"), get(plan, "evaluate"));
        try equal(a, get(w, "reused"), get(plan, "reused"));
        // Reassemble *presentation* values and compare with the clean run.
        var merged: std.ArrayList(V) = .empty;
        for (get(full, "roots").array.items) |r| {
            const reused = for (get(plan, "reused").array.items) |rr| {
                if (std.mem.eql(u8, r.string, rr.string)) break true;
            } else false;
            const result = if (reused) before else selective;
            for (get(get(result, "evaluation"), "values").array.items) |v| {
                if (std.mem.eql(u8, get(v, "root").string, r.string)) try merged.append(a, v);
            }
        }
        try equal(a, get(get(full, "evaluation"), "values"), try value(a, merged.items));
        try equal(a, get(plan, "evaluate"), get(get(selective, "evaluation"), "evaluated_roots"));
    }
    const manifest_path = try std.fs.path.join(a, &.{ root, "artifacts/manifest.json" });
    const manifest = try std.json.parseFromSliceLeaky(V, a, try std.Io.Dir.cwd().readFileAlloc(init.io, manifest_path, a, .limited(1024 * 1024)), .{});
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = try std.fs.path.join(a, &.{ root, "artifacts/m4-conformance.json" }), .data = try json(a, .{ .manifest = manifest, .cases = suite.cases.items }) });
    std.debug.print("PASS M4: {d} complete native responses\n", .{suite.cases.items.len});
}
