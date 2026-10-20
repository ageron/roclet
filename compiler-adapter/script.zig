//! Whole-program script runs: `check`, `run` and `export` verification of a
//! document's runnable `execution` text, and the protocol-1 `program`
//! request. Each run checks, lowers and executes the exact program bytes in
//! a fresh pipeline (`engine.runEcho`); the notebook revision is not used.
const std = @import("std");
const builtin = @import("builtin");
const can = @import("can");
const engine = @import("engine.zig");
const analysis = @import("analysis.zig");
const host = @import("platform.zig");
const Engine = @import("engine_state.zig").Engine;
const RequiredPackage = @import("workspace.zig").RequiredPackage;
const A = std.mem.Allocator;
const gpa = if (builtin.cpu.arch == .wasm32) std.heap.wasm_allocator else std.heap.page_allocator;

pub const Inputs = struct {
    /// The headerless program; `main!` included.
    source: []const u8,
    /// The prefix of `source` that is user text (analysis and Display detection).
    user_bytes: u32,
    app_header: []const u8 = "",
    /// Supplied modules, without the bundled Display module.
    modules: []const engine.ExtraFile = &.{},
    check_only: bool = false,
    args: []const []const u8 = &.{},
    /// Root whose compile-time observations are replayed; `main!` by default.
    root: ?[]const u8 = null,
    /// The run's second designated value may use the rich wire bound.
    rich_output: bool = false,
};

/// The protocol-1 program response; fields in wire order.
pub const Outcome = struct {
    protocol: u32 = 1,
    display_module: bool = false,
    status: []const u8 = "ok",
    definitions: []const analysis.Definition = &.{},
    dependency_scope: []const u8 = "definitions",
    binders: []const []const u8 = &.{},
    diagnostics: []const engine.Diagnostic = &.{},
    events: []const host.Event = &.{},
    failure: ?[]const u8 = null,
    /// Engine state when the run finished.
    packagesRequired: []const RequiredPackage = &.{},
    workspaceCache: engine.RequestStats = .{},
};

/// A protocol error answered without running anything.
pub fn rejected(eng: *Engine, failure: []const u8) Outcome {
    return .{ .status = "protocol_error", .failure = failure, .packagesRequired = eng.workspace.required.items, .workspaceCache = eng.stats };
}

const Analyzer = struct {
    arena: A,
    user_bytes: u32,
    stats: *engine.RequestStats,
    result: ?analysis.Analysis = null,
    failed: bool = false,
    fn call(ctx: *anyopaque, env: *can.ModuleEnv, prefix: u32) void {
        const self: *Analyzer = @ptrCast(@alignCast(ctx));
        self.result = analysis.analyze(self.arena, env, prefix, self.user_bytes, &.{}) catch {
            self.failed = true;
            return;
        };
        self.stats.analyses += 1;
    }
};

/// Check (and unless `check_only`, run) one script. Everything the outcome
/// references is allocated in `arena`.
pub fn run(eng: *Engine, arena: A, inputs: Inputs) !Outcome {
    const modules = try engine.programModules(arena, eng.workspace.io(arena), eng.paths.extras_prefix, inputs.modules, inputs.source[0..inputs.user_bytes]);
    try engine.prepareBuiltins();
    var events: host.EventBuffer = .{ .arena = arena, .rich = inputs.rich_output };
    var diagnostics: engine.DiagnosticList = .{ .arena = arena };
    var analyzer: Analyzer = .{ .arena = arena, .user_bytes = inputs.user_bytes, .stats = &eng.stats };
    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();
    const result = engine.runEcho(.{
        .arena = scratch.allocator(),
        .image_allocator = gpa,
        .paths = eng.paths,
        .fallback_io = eng.workspace.io(scratch.allocator()),
        .std_io = eng.workspace.std_io,
        .stats = &eng.stats,
        .source = inputs.source,
        .app_header = inputs.app_header,
        .root_name = inputs.root,
        .extras = modules.extras,
        .diagnostics = diagnostics.diagnostics(),
        .analyze = .{ .ctx = &analyzer, .call = Analyzer.call },
        .observer = events.observer(),
        .args = inputs.args,
        .check_only = inputs.check_only,
        .target_usize = engine.host_target_usize,
        .roc_target = engine.hostRocTarget(),
    });
    var outcome: Outcome = .{ .display_module = modules.rich_support };
    const exit_code = result catch |err| code: {
        outcome.status = switch (err) {
            error.CompilationFailed => "diagnostic",
            else => "runtime_error",
        };
        if (diagnostics.failure == null) outcome.failure = @errorName(err);
        break :code 0;
    };
    if (exit_code != 0) outcome.status = "runtime_error";
    if (events.failed or diagnostics.failed or analyzer.failed) return error.OutOfMemory;
    if (analyzer.result) |analyzed| {
        outcome.definitions = analyzed.definitions;
        outcome.binders = analyzed.binders;
        outcome.dependency_scope = @tagName(analyzed.dependency_scope);
    }
    outcome.diagnostics = diagnostics.items.items;
    outcome.events = events.events.items;
    outcome.failure = diagnostics.failure orelse outcome.failure;
    outcome.packagesRequired = eng.workspace.required.items;
    outcome.workspaceCache = eng.stats;
    return outcome;
}
