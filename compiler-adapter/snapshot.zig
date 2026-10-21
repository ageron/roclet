//! Host-independent snapshot protocol. Notebook formats and policy belong in Roc.
const std = @import("std");
const Allocator = std.mem.Allocator;
pub const limit = 1024 * 1024;
pub const Cell = struct { key: []const u8, source: []const u8 };
pub const Module = struct { name: []const u8, content: []const u8 };
pub const Snapshot = struct {
    requestId: []const u8 = "cli-1",
    documentRevision: u64 = 1,
    inputRevision: u64 = 0,
    workerGeneration: u64 = 1,
    cells: []const Cell,
    roots: []const []const u8,
    expectations: []const struct { root: []const u8, start: u32, end: u32, cell: u64 = 0 } = &.{},
    possible_roots: []const []const u8 = &.{},
    failure_roots: []const []const u8 = &.{},
    modules: []const Module = &.{},
    app_header: []const u8 = "",
    isolate_errors: bool = false,
};
pub const Region = struct { start: usize, end: usize };
pub const Definition = struct {
    name: []const u8,
    type: []const u8,
    region: Region,
    cell: ?[]const u8 = null,
    name_region: ?Region = null,
    dependencies: []const []const u8 = &.{},
    references: []const Region = &.{},
    rename_safe: bool = false,
};
pub const Event = struct { kind: []const u8, message: []const u8, root: []const u8, region: ?Region = null };
const RawEvent = struct { kind: []const u8, message: []const u8, root: ?[]const u8 = null };
const RawResponse = struct {
    display_module: bool = false,
    protocol: u32,
    status: []const u8,
    definitions: []Definition = &.{},
    dependency_scope: []const u8 = "module",
    binders: []const []const u8 = &.{},
    events: []const RawEvent = &.{},
    diagnostics: []const std.json.Value = &.{},
    failure: ?[]const u8 = null,
};
const TestResult = struct { root: []const u8, passed: bool, message: []const u8 };
const RootError = struct { root: []const u8, status: []const u8, failure: ?[]const u8 };
const Value = struct {
    root: []const u8,
    text: []const u8,
    display: ?std.json.Value = null,
    pub fn jsonStringify(self: @This(), w: anytype) !void {
        try w.beginObject();
        try w.objectField("root");
        try w.write(self.root);
        try w.objectField("text");
        try w.write(self.text);
        if (self.display) |display| {
            try w.objectField("display");
            try w.write(display);
        }
        try w.endObject();
    }
};
const Result = struct {
    protocol: u32 = 1,
    requestId: []const u8,
    documentRevision: u64,
    inputRevision: u64,
    workerGeneration: u64,
    status: []const u8 = "ok",
    definitions: []const Definition = &.{},
    dependency_scope: []const u8 = "module",
    binders: []const []const u8 = &.{},
    root_errors: []const RootError = &.{},
    evaluated_roots: []const []const u8 = &.{},
    values: []const Value = &.{},
    tests: []const TestResult = &.{},
    events: []const Event = &.{},
    diagnostics: []const std.json.Value = &.{},
    failure: ?[]const u8 = null,
};
pub fn json(gpa: Allocator, value: anytype) ![]u8 {
    var w: std.Io.Writer.Allocating = .init(gpa);
    errdefer w.deinit();
    try std.json.Stringify.value(value, .{}, &w.writer);
    return w.toOwnedSlice();
}
fn identifier(name: []const u8, module: bool) bool {
    if (name.len == 0) return false;
    if (module) {
        if (!std.ascii.isUpper(name[0])) return false;
    } else if (!std.ascii.isLower(name[0])) return false;
    for (name[1..]) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    return true;
}
fn validate(s: Snapshot) !void {
    if (s.requestId.len == 0 or s.documentRevision > 9007199254740991 or s.inputRevision > 9007199254740991 or s.workerGeneration > 9007199254740991) return error.InvalidToken;
    for (s.cells, 0..) |cell, i| {
        if (cell.key.len == 0) return error.InvalidCellKey;
        for (s.cells[0..i]) |previous| if (std.mem.eql(u8, previous.key, cell.key)) return error.DuplicateCellKey;
    }
    for (s.roots, 0..) |root, i| {
        if (!identifier(root, false)) return error.InvalidRoot;
        for (s.roots[0..i]) |previous| if (std.mem.eql(u8, previous, root)) return error.DuplicateRoot;
    }
    for (s.possible_roots, 0..) |root, i| {
        if (!identifier(root, false)) return error.InvalidRoot;
        for (s.possible_roots[0..i]) |previous| if (std.mem.eql(u8, previous, root)) return error.DuplicateRoot;
    }
    for (s.modules, 0..) |module, i| {
        if (!identifier(module.name, true)) return error.InvalidModule;
        for (s.modules[0..i]) |previous| if (std.mem.eql(u8, previous.name, module.name)) return error.DuplicateModule;
    }
}
fn invoke(gpa: Allocator, arena: Allocator, s: Snapshot, source: []const u8, root: ?[]const u8, rich: bool, comptime compile: anytype) !RawResponse {
    if (source.len >= limit) return error.SourceTooLarge;
    const possible = if (s.possible_roots.len == 0) s.roots else s.possible_roots;
    const request = try json(arena, .{ .protocol = @as(u32, 1), .source = source, .user_bytes = source.len, .check_only = root == null, .rich_output = rich, .modules = s.modules, .app_header = s.app_header, .root = root, .notebook = .{ .expectations = s.expectations, .roots = possible, .runtime_roots = if (s.roots.len == 0) s.failure_roots else s.roots, .isolate_errors = s.isolate_errors } });
    const bytes = try compile(request);
    defer gpa.free(bytes);
    const response = try std.json.parseFromSliceLeaky(RawResponse, arena, bytes, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    if (response.protocol != 1) return error.ProtocolMismatch;
    return response;
}
pub fn evaluate(gpa: Allocator, bytes: []const u8, comptime compile: anytype) ![]u8 {
    var arena_impl = std.heap.ArenaAllocator.init(gpa);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();
    const s = try std.json.parseFromSliceLeaky(Snapshot, arena, bytes, .{ .ignore_unknown_fields = true });
    try validate(s);
    var result: Result = .{ .requestId = s.requestId, .documentRevision = s.documentRevision, .inputRevision = s.inputRevision, .workerGeneration = s.workerGeneration };
    var source: std.Io.Writer.Allocating = .init(arena);
    const ranges = try arena.alloc(Region, s.cells.len);
    for (s.cells, 0..) |cell, i| {
        if (i != 0) try source.writer.writeAll("\n\n");
        const start = source.written().len;
        if (cell.source.len > limit -| start) return error.SourceTooLarge;
        try source.writer.writeAll(cell.source);
        ranges[i] = .{ .start = start, .end = source.written().len };
    }
    const checked = try invoke(gpa, arena, s, source.written(), null, false, compile);
    for (checked.definitions) |*definition| {
        for (ranges, s.cells) |range, cell| {
            if (definition.region.start >= range.start and definition.region.end <= range.end) {
                definition.cell = cell.key;
                break;
            }
        }
    }
    result.definitions = checked.definitions;
    result.dependency_scope = checked.dependency_scope;
    result.binders = checked.binders;
    result.diagnostics = checked.diagnostics;
    if (!std.mem.eql(u8, checked.status, "ok")) {
        result.status = checked.status;
        result.failure = checked.failure;
        var captured: std.ArrayList(Event) = .empty;
        for (checked.events) |event| try captured.append(arena, .{ .kind = event.kind, .message = event.message, .root = event.root orelse if (s.roots.len > 0) s.roots[0] else "" });
        result.events = captured.items;
        return json(gpa, result);
    }
    var names: std.StringHashMapUnmanaged(void) = .empty;
    for (checked.definitions) |definition| {
        const found = try names.getOrPut(arena, definition.name);
        if (found.found_existing) {
            result.status = "diagnostic";
            result.failure = try std.fmt.allocPrint(arena, "Duplicate notebook binding: {s}", .{definition.name});
            return json(gpa, result);
        }
    }
    for (s.roots) |root| if (!names.contains(root)) {
        result.status = "diagnostic";
        result.failure = try std.fmt.allocPrint(arena, "Unknown output root: {s}", .{root});
        return json(gpa, result);
    };
    var values: std.ArrayList(Value) = .empty;
    var failures: std.ArrayList(RootError) = .empty;
    var evaluated_roots: std.ArrayList([]const u8) = .empty;
    var events: std.ArrayList(Event) = .empty;
    var tests: std.ArrayList(TestResult) = .empty;
    for (s.roots) |root| {
        try evaluated_roots.append(arena, root);
        result.evaluated_roots = evaluated_roots.items;
        var rich = false;
        if (checked.display_module) for (checked.definitions) |definition| {
            if (std.mem.eql(u8, definition.name, root) and std.mem.eql(u8, definition.type, "Display")) rich = true;
        };
        const evaluated = try invoke(gpa, arena, s, source.written(), root, rich, compile);
        var is_test = false;
        for (s.expectations) |expectation| if (std.mem.eql(u8, expectation.root, root)) {
            is_test = true;
            break;
        };
        if (is_test) {
            var passed = std.mem.eql(u8, evaluated.status, "ok");
            var message: []const u8 = if (passed) "Expectation passed" else evaluated.failure orelse evaluated.status;
            for (evaluated.events) |event| {
                if (std.mem.eql(u8, event.kind, "test_passed") or std.mem.eql(u8, event.kind, "test_failed")) {
                    passed = std.mem.eql(u8, event.kind, "test_passed");
                    message = event.message;
                } else try events.append(arena, .{ .kind = event.kind, .message = event.message, .root = root });
            }
            try tests.append(arena, .{ .root = root, .passed = passed, .message = message });
            result.tests = tests.items;
            result.events = events.items;
            if (!passed) try failures.append(arena, .{ .root = root, .status = "test_failed", .failure = message });
            // Assertion failures do not discard independent notebook results.
            continue;
        }
        var wire: ?[]const u8 = null;
        var text: ?[]const u8 = null;
        var value_count: usize = 0;
        for (evaluated.events) |event| {
            if (std.mem.eql(u8, event.kind, "value")) {
                if (value_count == 0) text = event.message else wire = event.message;
                value_count += 1;
            } else try events.append(arena, .{ .kind = event.kind, .message = event.message, .root = root });
        }
        result.events = events.items;
        if (!std.mem.eql(u8, evaluated.status, "ok")) {
            result.status = evaluated.status;
            result.failure = evaluated.failure;
            result.diagnostics = evaluated.diagnostics;
            if (!s.isolate_errors) return json(gpa, result);
            try failures.append(arena, .{ .root = root, .status = evaluated.status, .failure = evaluated.failure });
            continue;
        }
        if (value_count != @as(usize, if (rich) 2 else 1)) {
            result.status = "runtime_error";
            result.failure = "Expected exactly one designated result; platform effects are unsupported";
            if (!s.isolate_errors) return json(gpa, result);
            try failures.append(arena, .{ .root = root, .status = result.status, .failure = result.failure });
            continue;
        }
        const display = if (rich and wire != null) std.json.parseFromSliceLeaky(std.json.Value, arena, wire.?, .{ .allocate = .alloc_always }) catch null else null;
        // A truncated/invalid rich payload never discards the already evaluated text.
        try values.append(arena, .{ .root = root, .text = text.?, .display = display });
    }
    result.values = values.items;
    result.root_errors = failures.items;
    if (failures.items.len > 0) result.status = "partial";
    return json(gpa, result);
}

test "reject invalid snapshots before compilation" {
    const Mock = struct {
        fn compile(_: []const u8) ![]u8 {
            return error.MustNotCompile;
        }
    };
    const cases = .{
        .{ "{\"cells\":[],\"roots\":[\"x)\\ncrash \\\"bad\\\"\"]}", error.InvalidRoot },
        .{ "{\"cells\":[{\"key\":\"x\",\"source\":\"\"},{\"key\":\"x\",\"source\":\"\"}],\"roots\":[]}", error.DuplicateCellKey },
        .{ "{\"cells\":[],\"roots\":[\"x\",\"x\"]}", error.DuplicateRoot },
        .{ "{\"cells\":[],\"roots\":[],\"documentRevision\":9007199254740992}", error.InvalidToken },
        .{ "{\"cells\":[],\"roots\":[],\"modules\":[{\"name\":\"bad\",\"content\":\"\"}]}", error.InvalidModule },
    };
    inline for (cases) |case| try std.testing.expectError(case[1], evaluate(std.testing.allocator, case[0], Mock.compile));
}

test "snapshot output is atomic when a later root fails" {
    const Mock = struct {
        var calls: usize = 0;
        fn compile(_: []const u8) ![]u8 {
            calls += 1;
            const response = switch (calls) {
                1 =>
                \\{"protocol":1,"status":"ok","definitions":[{"name":"out_good","type":"Dec","region":{"start":0,"end":13}},{"name":"out_bad","type":"Dec","region":{"start":14,"end":25}}]}
                ,
                2 =>
                \\{"protocol":1,"status":"ok","events":[{"kind":"value","message":"42.0"}]}
                ,
                else =>
                \\{"protocol":1,"status":"runtime_error","failure":"boom","events":[{"kind":"crashed","message":"boom"}]}
                ,
            };
            return std.testing.allocator.dupe(u8, response);
        }
    };
    Mock.calls = 0;
    const result = try evaluate(std.testing.allocator,
        \\{"cells":[{"key":"outputs","source":"out_good = 42\nout_bad = 0"}],"roots":["out_good","out_bad"]}
    , Mock.compile);
    defer std.testing.allocator.free(result);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, result, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("runtime_error", parsed.value.object.get("status").?.string);
    try std.testing.expectEqual(@as(usize, 0), parsed.value.object.get("values").?.array.items.len);
    try std.testing.expectEqualStrings("out_bad", parsed.value.object.get("events").?.array.items[0].object.get("root").?.string);
    try std.testing.expectEqual(@as(usize, 3), Mock.calls);
}

test "generated entrypoint counts against the source limit" {
    const Mock = struct {
        fn compile(_: []const u8) ![]u8 {
            return error.MustNotCompile;
        }
    };
    const gpa = std.testing.allocator;
    const source = try gpa.alloc(u8, limit);
    defer gpa.free(source);
    @memset(source, ' ');
    const request = try json(gpa, .{ .cells = .{.{ .key = "large", .source = source }}, .roots = .{} });
    defer gpa.free(request);
    try std.testing.expectError(error.SourceTooLarge, evaluate(gpa, request, Mock.compile));
}
