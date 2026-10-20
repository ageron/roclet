//! Execute the native adapter and publish the exact requests/results for browser parity.
const std = @import("std");
const V = std.json.Value;
const A = std.mem.Allocator;
const Case = struct { name: []const u8, raw: bool, snapshot: V, result: V };
const Suite = struct {
    gpa: A,
    io: std.Io,
    root: []const u8,
    executable: []const u8,
    request_file: []const u8,
    cases: std.ArrayList(Case) = .empty,

    fn run(self: *Suite, name: []const u8, submitted: V, expected: ?[]const []const u8, debug: []const []const u8, raw: bool) !void {
        var request = submitted;
        if (!raw) {
            if (!request.object.contains("requestId")) try request.object.put(self.gpa, "requestId", .{ .string = "test-1" });
            inline for (.{ .{ "documentRevision", 1 }, .{ "inputRevision", 0 }, .{ "workerGeneration", 1 } }) |field_default| {
                if (!request.object.contains(field_default[0])) try request.object.put(self.gpa, field_default[0], .{ .integer = field_default[1] });
            }
        }
        const bytes = try encode(self.gpa, request);
        try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = self.request_file, .data = bytes });
        const args: []const []const u8 = if (raw) &.{ self.executable, "--bridge", self.request_file } else &.{ self.executable, self.request_file };
        const process = try std.process.run(self.gpa, self.io, .{
            .argv = args,
            .stdout_limit = .limited(16 * 1024 * 1024),
            .stderr_limit = .limited(1024 * 1024),
            .timeout = .{ .duration = .{ .raw = .fromSeconds(60), .clock = .awake } },
        });
        const result = parse(self.gpa, process.stdout) catch {
            std.debug.print("FAIL {s}: invalid response\n{s}\n{s}\n", .{ name, process.stdout, process.stderr });
            return error.InvalidResponse;
        };
        const ok = std.mem.eql(u8, field(result, "status").string, "ok");
        if (process.term != .exited or process.term.exited != (if (raw or ok) @as(u8, 0) else @as(u8, 1))) return error.UnexpectedExitCode;
        if (ok != (expected != null)) {
            std.debug.print("FAIL {s}: {s}\n", .{ name, process.stdout });
            return error.UnexpectedStatus;
        }
        if (!raw) {
            const values = field(result, "values").array.items;
            if (expected) |texts| {
                if (values.len != texts.len) return error.UnexpectedValueCount;
                for (values, texts) |value, text| if (!std.mem.eql(u8, field(value, "text").string, text)) return error.UnexpectedValue;
                for (field(result, "definitions").array.items) |definition| if (field(definition, "cell") == .null) return error.UnmappedDefinition;
            } else if (values.len != 0) return error.StaleValues;
        }
        var i: usize = 0;
        for (field(result, "events").array.items) |event| {
            if (!std.mem.eql(u8, field(event, "kind").string, "dbg")) continue;
            if (i >= debug.len or !std.mem.eql(u8, field(event, "message").string, debug[i])) {
                std.debug.print("FAIL {s}: debug observations differ\n{s}\n", .{ name, process.stdout });
                return error.UnexpectedDebug;
            }
            i += 1;
        }
        if (i != debug.len) return error.MissingDebug;
        try self.cases.append(self.gpa, .{ .name = name, .raw = raw, .snapshot = try parse(self.gpa, bytes), .result = result });
        std.debug.print("PASS {s}\n", .{name});
    }
    fn permutations(self: *Suite, name: []const u8, fixture: V, cells: []V, index: usize, count: *usize) !void {
        if (index == cells.len) {
            var request = try parse(self.gpa, try encode(self.gpa, fixture));
            try request.object.put(self.gpa, "requestId", .{ .string = "test-1" });
            const expected = try strings(self.gpa, field(fixture, "expected"));
            const debug = if (fixture.object.get("expectedDebug")) |events| try strings(self.gpa, events) else &.{};
            try self.run(try std.fmt.allocPrint(self.gpa, "{s}/{d}", .{ name, count.* }), request, expected, debug, false);
            count.* += 1;
            return;
        }
        for (index..cells.len) |i| {
            std.mem.swap(V, &cells[index], &cells[i]);
            try self.permutations(name, fixture, cells, index + 1, count);
            std.mem.swap(V, &cells[index], &cells[i]);
        }
    }
    fn source(self: *Suite, name: []const u8, source_text: []const u8, roots: []const []const u8, expected: ?[]const []const u8, debug: []const []const u8) !void {
        const request = try parse(self.gpa, try encode(self.gpa, .{
            .requestId = "test-1",
            .documentRevision = 1,
            .inputRevision = 0,
            .workerGeneration = 1,
            .cells = .{.{ .key = "test", .source = source_text }},
            .roots = roots,
        }));
        try self.run(name, request, expected, debug, false);
    }
};
fn field(value: V, name: []const u8) V {
    return value.object.get(name).?;
}
fn parse(gpa: A, bytes: []const u8) !V {
    return std.json.parseFromSliceLeaky(V, gpa, bytes, .{ .allocate = .alloc_always });
}
fn encode(gpa: A, value: anytype) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(gpa);
    try std.json.Stringify.value(value, .{}, &writer.writer);
    return writer.toOwnedSlice();
}
fn strings(gpa: A, value: V) ![]const []const u8 {
    const result = try gpa.alloc([]const u8, value.array.items.len);
    for (result, value.array.items) |*slot, item| slot.* = item.string;
    return result;
}
fn read(gpa: A, io: std.Io, root: []const u8, relative: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(gpa, &.{ root, relative }), gpa, .limited(64 * 1024 * 1024));
}
pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const args = try init.minimal.args.toSlice(gpa);
    if (args.len != 3) return error.ExpectedRootAndExecutable;
    var random: [8]u8 = undefined;
    init.io.random(&random);
    const directory = try std.fs.path.join(gpa, &.{ args[1], ".toolchain", &std.fmt.bytesToHex(random, .lower) });
    try std.Io.Dir.cwd().createDirPath(init.io, directory);
    defer std.Io.Dir.cwd().deleteTree(init.io, directory) catch {};
    var suite: Suite = .{ .gpa = gpa, .io = init.io, .root = args[1], .executable = args[2], .request_file = try std.fs.path.join(gpa, &.{ directory, "request.json" }) };
    var permutations: usize = 0;
    for ([_][]const u8{ "forward", "dependencies", "anonymous", "recursion", "types", "imports", "debug" }) |name| {
        const fixture = try parse(gpa, try read(gpa, init.io, args[1], try std.fmt.allocPrint(gpa, "fixtures/{s}.json", .{name})));
        try suite.permutations(name, fixture, field(fixture, "cells").array.items, 0, &permutations);
    }
    try suite.source("valid before errors", "x = 42\nout_1 = x", &.{"out_1"}, &.{"42.0"}, &.{});
    for ([_][]const u8{ "out_1 = x", "out_1 = \"bad\" + 1", "out_1 = (", "x = 1\nx = 2\nout_1 = x" }, 0..) |source, i| {
        try suite.source(try std.fmt.allocPrint(gpa, "error/deletion/{d}", .{i}), source, &.{"out_1"}, null, &.{});
    }
    var imported = try parse(gpa,
        \\{"requestId":"test-1","cells":[{"key":"x","source":"import Fresh\nout_1 = Fresh.value"}],"roots":["out_1"],"modules":[{"name":"Fresh","content":"Fresh := [].{ value = 7 }"}]}
    );
    try suite.run("supplied import", imported, &.{"7.0"}, &.{}, false);
    try imported.object.put(gpa, "modules", .{ .array = std.array_list.Managed(V).init(gpa) });
    try suite.run("removed import", imported, null, &.{}, false);
    try suite.source("valid after errors", "x = 42\nout_1 = x", &.{"out_1"}, &.{"42.0"}, &.{});
    const core = try read(gpa, init.io, args[1], "fixtures/modules/Revision.roc");
    const core_source =
        \\import Revision
        \\state = Revision.edit(Revision.initial)
        \\current = { document: 1, input: 0, generation: 0 }
        \\old = { document: 0, input: 0, generation: 0 }
        \\out_1 = [Revision.accepts(state, current), Revision.accepts(state, old), Revision.finish(state, current).ready, Revision.finish(state, old).ready, Revision.accepts(Revision.restart(state), current), Revision.accepts(Revision.change_input(state), current)]
    ;
    const core_request = try parse(gpa, try encode(gpa, .{ .requestId = "test-1", .cells = .{.{ .key = "core", .source = core_source }}, .roots = .{"out_1"}, .modules = .{.{ .name = "Revision", .content = core }} }));
    try suite.run("Roc revision core", core_request, &.{"[True, False, True, False, False, False]"}, &.{}, false);
    const unicode = "# 🪨 café\nout_1 = 1 + 1";
    try suite.source("UTF-8 regions", unicode, &.{"out_1"}, &.{"2.0"}, &.{});
    const def = field(suite.cases.items[suite.cases.items.len - 1].result, "definitions").array.items[0];
    const region = field(def, "region");
    const start: usize = @intCast(field(region, "start").integer);
    const end: usize = @intCast(field(region, "end").integer);
    if (!std.mem.eql(u8, unicode[start..end], "out_1 = 1 + 1")) return error.InvalidSourceRegion;
    try suite.source("selected roots and repeated dbg", "unused = { dbg \"unused\"\n0 }\nout_1 = { dbg \"same\"\ndbg \"same\"\n42 }", &.{"out_1"}, &.{"42.0"}, &.{ "\"same\"", "\"same\"" });
    try suite.source("atomic output failure", "out_good = 42\nout_bad = { crash \"boom\"\n0 }", &.{ "out_good", "out_bad" }, null, &.{});
    const long = "abcdefghijklmnopqrstuvwxyz0123456789";
    try suite.source("heap-backed strings", try std.fmt.allocPrint(gpa, "out_1 = [\"{s}\", \"{s}\"]", .{ long, long }), &.{"out_1"}, &.{try std.fmt.allocPrint(gpa, "[\"{s}\", \"{s}\"]", .{ long, long })}, &.{});
    try suite.source("unknown output root", "x = 1", &.{"missing"}, null, &.{});
    const manifest = try parse(gpa, try read(gpa, init.io, args[1], "artifacts/manifest.json"));
    const report = try encode(gpa, .{ .manifest = manifest, .permutations = permutations, .cases = suite.cases.items });
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = try std.fs.path.join(gpa, &.{ args[1], "artifacts/native-conformance.json" }), .data = report });
    std.debug.print("PASS: {d} native cases ({d} cell permutations). Browser parity cases written to artifacts/native-conformance.json.\n", .{ suite.cases.items.len, permutations });
}
