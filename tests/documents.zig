//! Format contracts and native/WASM parity fixtures. No scripting runtime required.
const std = @import("std");
const V = std.json.Value;
const A = std.mem.Allocator;
fn field(v: V, key: []const u8) V {
    return v.object.get(key).?;
}
fn str(v: V, key: []const u8) []const u8 {
    return field(v, key).string;
}
fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
fn json(a: A, data: anytype) ![]u8 {
    var w: std.Io.Writer.Allocating = .init(a);
    try std.json.Stringify.value(data, .{}, &w.writer);
    return w.toOwnedSlice();
}
fn parse(a: A, bytes: []const u8) !V {
    return std.json.parseFromSliceLeaky(V, a, bytes, .{ .allocate = .alloc_always });
}
fn expect(ok: bool) !void {
    if (!ok) return error.AssertionFailed;
}
pub const Suite = struct {
    a: A,
    io: std.Io,
    executable: []const u8,
    temp: []const u8,
    cases: std.ArrayList(V) = .empty,
    pub fn call(self: *Suite, name: []const u8, request: V) !V {
        try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = self.temp, .data = try json(self.a, request) });
        const result = try std.process.run(self.a, self.io, .{ .argv = &.{ self.executable, "--bridge", self.temp }, .stdout_limit = .limited(8 * 1024 * 1024), .stderr_limit = .limited(1024 * 1024), .timeout = .{ .duration = .{ .raw = .fromSeconds(60), .clock = .awake } } });
        if (result.term != .exited or result.term.exited != 0) {
            std.debug.print("FAIL {s}: {s}\n", .{ name, result.stderr });
            return error.AdapterFailed;
        }
        const response = try parse(self.a, result.stdout);
        try self.cases.append(self.a, try parse(self.a, try json(self.a, .{ .name = name, .request = request, .result = response })));
        return response;
    }
    fn run(self: *Suite, fixture: V) !void {
        const name = str(fixture, "name");
        const request = field(fixture, "request");
        const wanted = field(fixture, "expect");
        const result = try self.call(name, request);
        errdefer std.debug.print("FAIL {s}\n{s}\n", .{ name, json(self.a, result) catch "" });
        try expect(eq(str(result, "status"), str(wanted, "status")));
        const model = field(result, "model");
        const cells = field(model, "cells").array.items;
        if (wanted.object.get("compact")) |_| {
            for ([_][]const u8{ "draft", "source", "program", "execution" }) |key| try expect(result.object.get(key) == null);
            try expect(model.object.get("original") == null);
            try expect(result.object.get("mappings") != null);
            for (cells) |cell| {
                for ([_][]const u8{ "facts", "blocks", "first_block", "marker_lines", "source_map" }) |key| try expect(cell.object.get(key) == null);
                for ([_][]const u8{ "source", "body_start", "output", "outputs" }) |key| try expect(cell.object.get(key) != null);
            }
        }

        for ([_][]const u8{ "kinds", "ids" }) |key| if (wanted.object.get(key)) |expected| {
            var index: usize = 0;
            for (cells) |cell| {
                if (eq(str(cell, "kind"), "generated")) continue;
                try expect(index < expected.array.items.len);
                try expect(eq(str(cell, if (eq(key, "kinds")) "kind" else "id"), expected.array.items[index].string));
                index += 1;
            }
            try expect(index == expected.array.items.len);
        };
        if (wanted.object.get("roots")) |roots| try expect(eq(try json(self.a, roots), try json(self.a, field(result, "roots"))));
        if (wanted.object.get("outputs")) |outputs| {
            var index: usize = 0;
            for (cells) |cell| for (field(cell, "outputs").array.items) |output| {
                try expect(index < outputs.array.items.len);
                try expect(eq(str(output, "kind"), outputs.array.items[index].string));
                index += 1;
            };
            try expect(index == outputs.array.items.len);
        }
        if (wanted.object.get("diagnostic")) |code| {
            var found = false;
            for (field(model, "diagnostics").array.items) |d| if (eq(str(d, "code"), code.string)) {
                found = true;
            };
            try expect(found);
        }
        if (wanted.object.get("location_text")) |token| {
            var found = false;
            const input = str(request, "source");
            for (field(model, "diagnostics").array.items) |d| {
                if (!eq(str(d, "code"), str(wanted, "diagnostic"))) continue;
                const start: usize = @intCast(field(d, "start").integer);
                const end: usize = @intCast(field(d, "end").integer);
                if (end <= input.len and start <= end and eq(input[start..end], token.string)) found = true;
            }
            try expect(found);
        }
        if (wanted.object.get("contains")) |items| for (items.array.items) |item| try expect(std.mem.find(u8, str(result, "source"), item.string) != null);
        if (wanted.object.get("absent")) |items| for (items.array.items) |item| try expect(std.mem.find(u8, str(result, "source"), item.string) == null);
        if (wanted.object.get("no_evaluation")) |_| try expect(result.object.get("evaluation") == null);
        if (wanted.object.get("exact")) |_| try expect(eq(str(request, "source"), str(result, "source")));
        if (wanted.object.get("evaluated_values")) |expected| {
            const values = field(field(result, "evaluation"), "values").array.items;
            try expect(values.len == expected.array.items.len);
            for (values, expected.array.items) |actual, value_text| try expect(eq(str(actual, "text"), value_text.string));
        }
        if (wanted.object.get("evaluation_diagnostic_contains")) |expected| {
            const diagnostics = field(field(result, "evaluation"), "diagnostics").array.items;
            for (expected.array.items) |snippet| {
                var found = false;
                for (diagnostics) |diagnostic| if (std.mem.find(u8, str(diagnostic, "message"), snippet.string) != null) {
                    found = true;
                };
                try expect(found);
            }
        }
        if (wanted.object.get("root_errors")) |expected| {
            const errors = field(field(result, "evaluation"), "root_errors").array.items;
            try expect(errors.len == expected.array.items.len);
            for (errors, expected.array.items) |actual, root| try expect(eq(str(actual, "root"), root.string));
        }
        if (wanted.object.get("display_kinds")) |expected| {
            const outputs = field(field(result, "evaluation"), "values").array.items;
            try expect(outputs.len == expected.array.items.len);
            for (outputs, expected.array.items) |output, kind| {
                const display = output.object.get("display");
                if (kind == .null) try expect(display == null) else {
                    try expect(display != null);
                    try expect(eq(str(display.?, "kind"), kind.string));
                }
            }
        }
        if (wanted.object.get("preview_rows")) |expected| {
            const outputs = field(field(result, "evaluation"), "values").array.items;
            for (outputs, expected.array.items) |output, count| try expect(field(field(output, "display"), "rows").array.items.len == @as(usize, @intCast(count.integer)));
        }
        if (wanted.object.get("events")) |expected| {
            const events = field(field(result, "evaluation"), "events").array.items;
            try expect(events.len == expected.array.items.len);
            for (events, expected.array.items) |actual, event| {
                var fields = event.object.iterator();
                while (fields.next()) |entry| try expect(eq(try json(self.a, field(actual, entry.key_ptr.*)), try json(self.a, entry.value_ptr.*)));
            }
        }
        if (wanted.object.get("draft_roundtrip")) |_| {
            const again_request = try parse(self.a, try json(self.a, .{ .operation = "document", .action = "compose", .format = str(request, "format"), .source = "", .draft = field(result, "draft") }));
            const again = try self.call(try std.fmt.allocPrint(self.a, "{s}/draft-again", .{name}), again_request);
            try expect(eq(str(again, "status"), str(result, "status")));
            try expect(eq(try json(self.a, field(again, "draft")), try json(self.a, field(result, "draft"))));
            try expect(eq(try json(self.a, field(again, "roots")), try json(self.a, field(result, "roots"))));
        }
        if (wanted.object.get("normalized_stable")) |_| {
            const again_request = try parse(self.a, try json(self.a, .{ .operation = "document", .action = "normalize", .format = str(request, "target"), .target = str(request, "target"), .source = str(result, "source") }));
            const again = try self.call(try std.fmt.allocPrint(self.a, "{s}/normalize-again", .{name}), again_request);
            try expect(eq(str(again, "status"), "ok"));
            try expect(eq(str(result, "source"), str(again, "source")));
        }
        if (wanted.object.get("values")) |values| {
            var run_request = try parse(self.a, try json(self.a, request));
            try run_request.object.put(self.a, "action", .{ .string = "run" });
            const evaluated = try self.call(try std.fmt.allocPrint(self.a, "{s}/run", .{name}), run_request);
            try expect(eq(str(evaluated, "status"), "ok"));
            const evaluation = field(evaluated, "evaluation");
            var vi: usize = 0;
            var di: usize = 0;
            const debug = wanted.object.get("debug");
            for (field(evaluation, "events").array.items) |event| {
                if (eq(str(event, "kind"), "value")) {
                    try expect(vi < values.array.items.len);
                    try expect(eq(str(event, "message"), values.array.items[vi].string));
                    vi += 1;
                }
                if (eq(str(event, "kind"), "dbg")) {
                    try expect(debug != null and di < debug.?.array.items.len);
                    try expect(eq(str(event, "message"), debug.?.array.items[di].string));
                    di += 1;
                }
            }
            try expect(vi == values.array.items.len and di == (if (debug) |d| d.array.items.len else 0));
        }
        if (wanted.object.get("roundtrip")) |_| {
            const back_request = try parse(self.a, try json(self.a, .{ .operation = "document", .action = "convert", .format = str(request, "target"), .target = str(request, "format"), .source = str(result, "source") }));
            const back = try self.call(try std.fmt.allocPrint(self.a, "{s}/roundtrip", .{name}), back_request);
            try expect(eq(str(back, "status"), "ok"));
            const back_cells = field(field(back, "model"), "cells").array.items;
            var bi: usize = 0;
            for (cells) |cell| {
                if (eq(str(cell, "kind"), "generated")) continue;
                while (bi < back_cells.len and eq(str(back_cells[bi], "kind"), "generated")) : (bi += 1) {}
                try expect(bi < back_cells.len);
                const bc = back_cells[bi];
                bi += 1;
                try expect(eq(str(cell, "kind"), str(bc, "kind")));
                try expect(eq(str(cell, "id"), str(bc, "id")));
                if (eq(str(cell, "kind"), "markdown")) try expect(eq(str(cell, "source"), str(bc, "source")));
                try expect(eq(try json(self.a, field(cell, "outputs")), try json(self.a, field(bc, "outputs"))));
            }
            try expect(eq(try json(self.a, field(back, "roots")), try json(self.a, field(result, "roots"))));
        }
        std.debug.print("PASS document: {s}\n", .{name});
    }
};
pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    const root = args[1];
    const temp = try std.fs.path.join(a, &.{ root, "artifacts/document-request.tmp.json" });
    defer std.Io.Dir.cwd().deleteFile(init.io, temp) catch {};
    var suite: Suite = .{ .a = a, .io = init.io, .executable = args[2], .temp = temp };
    const fixtures = try parse(a, try std.Io.Dir.cwd().readFileAlloc(init.io, try std.fs.path.join(a, &.{ root, "tests/documents.json" }), a, .limited(1024 * 1024)));
    for (fixtures.array.items) |fixture| try suite.run(fixture);
    // Public CLI notebook runs share Roclet's named-root snapshot contract.
    for ([_][]const u8{ "roc", "md" }) |extension| {
        const cli_file = try std.fmt.allocPrint(a, "{s}/artifacts/cli-notebook-test.{s}", .{ root, extension });
        defer std.Io.Dir.cwd().deleteFile(init.io, cli_file) catch {};
        const cli_source = if (eq(extension, "roc")) "# %%\nout_1 = area\n# %%\nwidth = 5\nheight = 3\n# %%\narea = width * height\nout_dimensions = {\n    dbg area\n    area\n}\n" else "```roc\nout_1 = area\n```\n```roc\nwidth = 5\nheight = 3\n```\n```roc\narea = width * height\nout_dimensions = {\n    dbg area\n    area\n}\n```\n";
        try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = cli_file, .data = cli_source });
        const ran = try std.process.run(a, init.io, .{ .argv = &.{ args[2], "run", cli_file }, .stdout_limit = .limited(8 * 1024 * 1024), .stderr_limit = .limited(1024 * 1024), .timeout = .{ .duration = .{ .raw = .fromSeconds(60), .clock = .awake } } });
        try expect(ran.term == .exited and ran.term.exited == 0);
        const evaluated = field(try parse(a, ran.stdout), "evaluation");
        const values = field(evaluated, "values").array.items;
        try expect(values.len == 2);
        for (values) |v| try expect(eq(str(v, "text"), "15.0"));
        const events = field(evaluated, "events").array.items;
        try expect(events.len == 1 and eq(str(events[0], "root"), "out_dimensions"));
        try expect(field(events[0], "cell").integer == 2);
    }
    std.debug.print("PASS public CLI Roc/Markdown runs match Roclet named values and debug attribution\n", .{});
    const manifest = try parse(a, try std.Io.Dir.cwd().readFileAlloc(init.io, try std.fs.path.join(a, &.{ root, "artifacts/manifest.json" }), a, .limited(1024 * 1024)));
    const output = try json(a, .{ .manifest = manifest, .cases = suite.cases.items });
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = try std.fs.path.join(a, &.{ root, "artifacts/document-conformance.json" }), .data = output });
    std.debug.print("PASS {d} document contracts; {d} parity requests\n", .{ fixtures.array.items.len, suite.cases.items.len });
}
