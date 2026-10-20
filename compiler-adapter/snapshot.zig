//! The M0 snapshot protocol (`cells` + `roots`): cells are joined into one
//! program, evaluated through the typed notebook API, and definitions are
//! attributed back to the cell whose bytes contain them.
const std = @import("std");
const notebook = @import("notebook.zig");
const Engine = @import("engine_state.zig").Engine;
const Allocator = std.mem.Allocator;
pub const Cell = struct { key: []const u8, source: []const u8 };
pub const Snapshot = struct {
    requestId: []const u8 = "cli-1",
    documentRevision: u64 = 1,
    inputRevision: u64 = 0,
    workerGeneration: u64 = 1,
    cells: []const Cell,
    roots: []const []const u8,
    expectations: []const notebook.Expectation = &.{},
    possible_roots: []const []const u8 = &.{},
    failure_roots: []const []const u8 = &.{},
    modules: []const notebook.Module = &.{},
    app_header: []const u8 = "",
    isolate_errors: bool = false,
};
fn validate(s: Snapshot) !void {
    if (s.requestId.len == 0 or s.documentRevision > 9007199254740991 or s.inputRevision > 9007199254740991 or s.workerGeneration > 9007199254740991) return error.InvalidToken;
    for (s.cells, 0..) |cell, i| {
        if (cell.key.len == 0) return error.InvalidCellKey;
        for (s.cells[0..i]) |previous| if (std.mem.eql(u8, previous.key, cell.key)) return error.DuplicateCellKey;
    }
    inline for (.{ "roots", "possible_roots" }) |name| for (@field(s, name), 0..) |root, i| {
        if (!notebook.identifier(root, false)) return error.InvalidRoot;
        for (@field(s, name)[0..i]) |previous| if (std.mem.eql(u8, previous, root)) return error.DuplicateRoot;
    };
    for (s.modules, 0..) |module, i| {
        if (!notebook.identifier(module.name, true)) return error.InvalidModule;
        for (s.modules[0..i]) |previous| if (std.mem.eql(u8, previous.name, module.name)) return error.DuplicateModule;
    }
}
/// Evaluate one snapshot request. Rejected snapshots return an error before
/// anything is compiled; the result is allocated in `arena`.
pub fn evaluate(engine: *Engine, arena: Allocator, bytes: []const u8) !notebook.Evaluation {
    const s = try std.json.parseFromSliceLeaky(Snapshot, arena, bytes, .{ .ignore_unknown_fields = true });
    try validate(s);
    var source: std.Io.Writer.Allocating = .init(arena);
    const ranges = try arena.alloc(notebook.CellRange, s.cells.len);
    for (s.cells, ranges, 0..) |cell, *range, i| {
        if (i != 0) try source.writer.writeAll("\n\n");
        const start = source.written().len;
        if (cell.source.len > notebook.source_limit -| start) return error.SourceTooLarge;
        try source.writer.writeAll(cell.source);
        range.* = .{ .key = cell.key, .start = start, .end = source.written().len };
    }
    var checked = try notebook.checkDocument(engine, arena, .{
        .requestId = s.requestId,
        .documentRevision = s.documentRevision,
        .inputRevision = s.inputRevision,
        .workerGeneration = s.workerGeneration,
        .program = source.written(),
        .app_header = s.app_header,
        .modules = s.modules,
        .roots = if (s.possible_roots.len == 0) s.roots else s.possible_roots,
        .expectations = s.expectations,
        .cells = ranges,
        .failure_roots = if (s.roots.len == 0) s.failure_roots else s.roots,
        .isolate_errors = s.isolate_errors,
    });
    try checked.evaluate(s.roots);
    return checked.evaluation;
}

test "reject invalid snapshots before compilation" {
    var engine = Engine.init(std.testing.allocator, .failing);
    defer engine.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cases = .{
        .{ "{\"cells\":[],\"roots\":[\"x)\\ncrash \\\"bad\\\"\"]}", error.InvalidRoot },
        .{ "{\"cells\":[{\"key\":\"x\",\"source\":\"\"},{\"key\":\"x\",\"source\":\"\"}],\"roots\":[]}", error.DuplicateCellKey },
        .{ "{\"cells\":[],\"roots\":[\"x\",\"x\"]}", error.DuplicateRoot },
        .{ "{\"cells\":[],\"roots\":[],\"documentRevision\":9007199254740992}", error.InvalidToken },
        .{ "{\"cells\":[],\"roots\":[],\"modules\":[{\"name\":\"bad\",\"content\":\"\"}]}", error.InvalidModule },
    };
    inline for (cases) |case| try std.testing.expectError(case[1], evaluate(&engine, arena.allocator(), case[0]));
    try std.testing.expect(engine.revision == null);
    try std.testing.expectEqual(@as(u64, 0), engine.stats.frontend_builds);
}

test "snapshot output is atomic when a later root fails" {
    var engine = Engine.init(std.testing.allocator, .failing);
    defer engine.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evaluate(&engine, arena.allocator(),
        \\{"cells":[{"key":"outputs","source":"out_good = 42\nout_bad = {\n    crash \"boom\"\n    0\n}"}],"roots":["out_good","out_bad"]}
    );
    try std.testing.expect(!std.mem.eql(u8, "ok", result.status));
    try std.testing.expectEqual(@as(usize, 0), result.values.len);
    const isolated = try evaluate(&engine, arena.allocator(),
        \\{"cells":[{"key":"outputs","source":"out_good = 42\nout_bad = {\n    crash \"boom\"\n    0\n}"}],"roots":["out_good","out_bad"],"isolate_errors":true}
    );
    try std.testing.expectEqualStrings("partial", isolated.status);
    try std.testing.expectEqual(@as(usize, 1), isolated.values.len);
    try std.testing.expectEqualStrings("outputs", isolated.definitions[0].cell.?);
    try std.testing.expectEqualStrings("out_bad", isolated.root_errors[0].root);
}

test "generated entrypoint counts against the source limit" {
    var engine = Engine.init(std.testing.allocator, .failing);
    defer engine.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = try a.alloc(u8, notebook.source_limit);
    @memset(source, ' ');
    var request: std.Io.Writer.Allocating = .init(a);
    try std.json.Stringify.value(.{ .cells = .{.{ .key = "large", .source = source }}, .roots = .{} }, .{}, &request.writer);
    try std.testing.expectError(error.SourceTooLarge, evaluate(&engine, a, request.written()));
}
