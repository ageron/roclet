//! One checked module graph and one LIR image per notebook revision.
//! Output entrypoints are declared before checking and run independently.
const std = @import("std");
const builtin = @import("builtin");
const compile = @import("compile");
const check = @import("check");
const eval = @import("eval");
const lir = @import("lir");
const base = @import("base");
const can = @import("can");
const engine = @import("engine.zig");
const host = @import("platform.zig");
const workspace = @import("workspace.zig");
const image = @import("image.zig");
const Engine = @import("engine_state.zig").Engine;
const dependency = @import("analysis.zig");
const A = std.mem.Allocator;
const gpa = if (builtin.cpu.arch == .wasm32) std.heap.wasm_allocator else std.heap.page_allocator;
pub const Expectation = dependency.Expectation;
pub const Module = engine.ExtraFile;
pub const Metadata = struct { expectations: []const Expectation = &.{}, roots: []const []const u8, runtime_roots: []const []const u8 = &.{}, isolate_errors: bool = false };
/// Everything that determines the retained revision. Hashed once per request.
pub const Inputs = struct {
    /// The user program: notebook cells only, without `main!`.
    program: []const u8,
    /// The user app header (packages); may be empty.
    app_header: []const u8,
    /// Supplied modules plus Display (`engine.programModules`).
    extras: []const engine.ExtraFile,
    /// Every possible output and test root, in document order.
    roots: []const []const u8,
    /// Test roots with their byte spans in `program`.
    expectations: []const Expectation,
    /// Trusted `import Display` detected (`engine.programModules`).
    rich_support: bool,
    paths: engine.Paths,
    target_usize: base.target.TargetUsize = engine.host_target_usize,
    roc_target: @import("roc_target").RocTarget,
};
/// One root's execution against a prepared revision.
const Execution = struct {
    root: []const u8,
    target_usize: base.target.TargetUsize,
    /// Receives the interpreter's runtime error message as the root failure.
    diagnostics: engine.Diagnostics,
};
const Label = struct { root: []const u8, text: []const u8, value: []const u8, rich: bool = false };
/// A retained revision, owned by `Engine.revision`.
pub const State = struct {
    key: [32]u8,
    /// Everything retained for the revision except the image: inputs,
    /// BuildEnv and checked modules, cache manager, debug events, names.
    revision_arena: std.heap.ArenaAllocator,
    build: ?*compile.BuildEnv = null,
    capture: engine.DebugCapture,
    reports: []const compile.BuildEnv.DrainedModuleReports = &.{},
    failed: bool = false,
    constant_failures: bool = false,
    prefix: u32 = 0,
    labels: []Label = &.{},
    expectations: []const Expectation = &.{},
    expectation_expressions: []can.CIR.Expr.Idx = &.{},
    wire_name: ?[]const u8 = null,
    requests: []check.CheckedArtifact.RootRequest = &.{},
    request_names: []const []const u8 = &.{},
    image: ?image.Image = null,
    entry_names: []const []const u8 = &.{},
    cache_reported: compile.CacheStats = .{},
    /// Length of the user program after `prefix`.
    user_bytes: u32 = 0,
    analysis_cache: ?dependency.Analysis = null,

    /// The dependency analysis of this revision, computed on first use.
    pub fn analysis(self: *State, stats: *engine.RequestStats) !*const dependency.Analysis {
        if (self.analysis_cache == null) {
            const app = self.build.?.getAppSemanticData().?;
            self.analysis_cache = try dependency.analyze(self.revision_arena.allocator(), app.env, self.prefix, self.user_bytes, self.expectations);
            stats.analyses += 1;
        }
        return &self.analysis_cache.?;
    }

    fn deinit(self: *State) void {
        if (self.image) |*flat| flat.deinit(gpa);
        if (self.build) |build| {
            if (self.reports.len != 0) build.freeDrainedReports(self.reports);
            build.deinit();
        }
        self.revision_arena.deinit();
    }
    pub fn destroy(self: *State) void {
        self.deinit();
        gpa.destroy(self);
    }
    fn reportCache(self: *State, stats: *engine.RequestStats) void {
        const now = if (self.build) |b| if (b.cache_manager) |cache| cache.getStats() else compile.CacheStats{} else compile.CacheStats{};
        inline for (@typeInfo(compile.CacheStats).@"struct".field_names) |name| @field(stats.cache, name) += @field(now, name) - @field(self.cache_reported, name);
        self.cache_reported = now;
    }
    fn emitReports(self: *State, diag: engine.Diagnostics) void {
        var scratch = std.heap.ArenaAllocator.init(gpa);
        defer scratch.deinit();
        for (self.reports) |module| for (module.reports) |*report| diag.emitReport(scratch.allocator(), report);
    }
    fn prepare(self: *State, eng: *Engine, opts: Inputs) !void {
        const a = self.revision_arena.allocator();
        const expectations = try a.dupe(Expectation, opts.expectations);
        for (expectations) |*expectation| expectation.root = try a.dupe(u8, expectation.root);
        self.expectations = expectations;
        self.expectation_expressions = try a.alloc(can.CIR.Expr.Idx, expectations.len);
        var output_count: usize = 0;
        for (opts.roots) |root| if (!isExpectation(opts.expectations, root)) {
            output_count += 1;
        };
        self.labels = try a.alloc(Label, output_count);
        var source_hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(opts.program, &source_hash, .{});
        const hash_text = std.fmt.bytesToHex(source_hash, .lower);
        var output_index: usize = 0;
        for (opts.roots) |root| {
            if (isExpectation(opts.expectations, root)) continue;
            self.labels[output_index] = .{
                .root = try a.dupe(u8, root),
                .text = try std.fmt.allocPrint(a, "roclet_{s}_text_{s}", .{ hash_text, root }),
                .value = try std.fmt.allocPrint(a, "roclet_{s}_value_{s}", .{ hash_text, root }),
            };
            output_index += 1;
        }
        if (opts.rich_support) self.wire_name = try std.fmt.allocPrint(a, "roclet_{s}_display_wire", .{hash_text});
        var header: std.Io.Writer.Allocating = .init(a);
        try header.writer.writeAll("app [main!");
        for (self.labels) |label| try header.writer.print(", {s}, {s}", .{ label.text, label.value });
        if (self.wire_name) |wire| try header.writer.print(", {s}", .{wire});
        try header.writer.writeAll("] { pf: platform \"./.roc_echo_platform/main.roc\"");
        if (opts.app_header.len != 0) {
            for (try engine.parseHeaderPackages(a, eng.workspace.io(a), opts.app_header)) |package| {
                if (engine.isEmbeddedDisplayPackage(package.shorthand, package.spec)) continue;
                try header.writer.print(", {s}: ", .{package.shorthand});
                try std.json.Stringify.value(package.spec, .{}, &header.writer);
            }
        }
        try header.writer.writeAll(" }\n\nimport pf.Echo\n\n");
        self.prefix = @intCast(header.written().len);
        self.user_bytes = @intCast(opts.program.len);
        var source: std.Io.Writer.Allocating = .init(a);
        try source.writer.writeAll(header.written());
        try source.writer.writeAll(opts.program);
        try source.writer.writeAll("\n\nmain! = |_args| Ok({})\necho! = |message| Echo.line!(message)\n");
        for (self.labels) |label| try source.writer.print("\n{s} = || Str.inspect({s})\n{s} = || {s}\n", .{ label.text, label.root, label.value, label.root });
        if (self.wire_name) |wire| try source.writer.print("\n{s} = |value| Display.to_wire(value)\n", .{wire});
        if (source.written().len > 2 * 1024 * 1024) return error.SourceTooLarge;
        const extras = try a.alloc(engine.ExtraFile, opts.extras.len);
        for (extras, opts.extras) |*dest, src| dest.* = .{ .name = try a.dupe(u8, src.name), .content = try a.dupe(u8, src.content) };
        const fs = try a.create(engine.EchoCtx);
        fs.* = .{ .paths = opts.paths, .synthetic_app_source = source.written(), .extras = extras, .fallback = eng.workspace.io(a) };
        const build = try a.create(compile.BuildEnv);
        build.* = compile.BuildEnv.initBorrowingBuiltinModules(a, .single_threaded, 1, opts.roc_target, opts.paths.cwd, eng.workspace.std_io, try engine.persistentBuiltins());
        self.build = build;
        build.filesystem = fs.io();
        build.package_cache_dir = try a.dupe(u8, "/packages");
        build.defer_post_check = true;
        build.setPostCheckPublicationMode(.none);
        build.compile_time_root_event_callback = .{ .context = &self.capture, .notify = engine.DebugCapture.observe };
        const owned_user_source = source.written()[self.prefix..][0..opts.program.len];
        build.setSyntheticRootSourceMappingWithLineOffset(std.fs.path.basename(opts.paths.app_abs), owned_user_source, self.prefix, @intCast(std.mem.count(u8, header.written(), "\n")));
        const cache = try a.create(compile.CacheManager);
        cache.* = compile.CacheManager.init(a, .{ .cache_dir = "/cache", .roc_ctx = fs.io() }, fs.io());
        build.setCacheManager(cache);
        build.discoverDependencies(opts.paths.app_abs) catch |err| {
            self.reports = try build.drainReports();
            self.failed = true;
            if (self.reports.len == 0) return err;
            return;
        };
        eng.stats.frontend_builds += 1;
        build.compileDiscovered() catch |err| {
            self.reports = try build.drainReports();
            self.failed = true;
            if (self.reports.len == 0) return err;
            return;
        };
        if (build.coordinator.?.hasUserErrors()) {
            try build.finishCheckedProgram();
            self.reports = try build.drainReports();
            self.failed = true;
            return;
        }
        const app = build.getAppSemanticData() orelse return error.CompilationFailed;
        for (self.labels) |*label| {
            for (app.env.store.sliceDefs(app.env.all_defs)) |idx| {
                const def = app.env.store.getDef(idx);
                const pattern = app.env.store.getPattern(def.pattern);
                if (pattern != .assign or !std.mem.eql(u8, app.env.getIdent(pattern.assign.ident), label.root)) continue;
                var writer = try app.env.initTypeWriter();
                defer writer.deinit();
                try writer.write(can.ModuleEnv.varFrom(idx), .one_line);
                label.rich = opts.rich_support and std.mem.eql(u8, writer.get(), "Display");
            }
        }
        const artifact = app.checked_artifact orelse return error.CompilationFailed;
        const exported = try check.CheckedArtifact.exportedProcedureRoots(a, artifact);
        var selected: std.ArrayList(check.CheckedArtifact.RootRequest) = .empty;
        var names: std.ArrayList([]const u8) = .empty;
        var need_wire = false;
        for (self.labels) |label| {
            try appendRoot(a, app.env, exported, label.text, &selected, &names);
            if (label.rich) {
                try appendRoot(a, app.env, exported, label.value, &selected, &names);
                need_wire = true;
            }
        }
        // Select tests only from the notebook's checked root artifact. Imported
        // module/package test suites are deliberately never requested.
        for (self.expectations, 0..) |expectation, expectation_index| {
            var found = false;
            for (artifact.root_requests.requests) |request| {
                if (request.kind != .test_expect or request.source != .statement) continue;
                const region = app.env.store.getStatementRegion(request.source.statement);
                if (region.start.offset < self.prefix) continue;
                const start = region.start.offset - self.prefix;
                if (start < expectation.start or start >= expectation.end) continue;
                self.expectation_expressions[expectation_index] = app.env.store.getStatement(request.source.statement).s_expect.body;
                try selected.append(a, request);
                try names.append(a, expectation.root);
                found = true;
                break;
            }
            if (!found) return error.ExpectRootNotFound;
        }
        if (need_wire) try appendRoot(a, app.env, exported, self.wire_name.?, &selected, &names);
        self.requests = selected.items;
        self.request_names = names.items;
        const runtime_target: lir.CheckedPipeline.TargetConfig = .{ .target_usize = opts.target_usize };
        const request_set: lir.CheckedPipeline.RootRequestSet = .{ .requests = self.requests };
        build.setRuntimeLowering(.{ .explicit_roots = request_set, .root_module = artifact, .target = runtime_target });
        try build.finishCheckedProgram();
        self.reports = try build.drainReports();
        var errors = false;
        for (self.reports) |module| for (module.reports) |report| if (report.severity.isError()) {
            errors = true;
        };
        if (errors) {
            if (build.evaluationFailureSummary().onlyConstantCrashes()) {
                self.constant_failures = true;
            } else {
                self.failed = true;
                return;
            }
        }
        if (self.requests.len == 0) return;
        eng.stats.lowerings += 1;
        // Lowering output is scratch once copied into the image; only the
        // entry names (read by execute) stay on the revision allocator.
        var lowering = std.heap.ArenaAllocator.init(gpa);
        defer lowering.deinit();
        const la = lowering.allocator();
        var program = try build.runtimeProgramSession().?.takeRuntime(la, request_set, runtime_target);
        const lowered = &program;
        const imports = try build.collectImportedArtifactViews(la, artifact);
        const relations = try build.collectRelationArtifactViews(la, artifact);
        const data = try eval.buildStaticDataForWidth(la, .{ .root = check.CheckedArtifact.loweringViewWithRelations(artifact, relations), .imports = imports }, lowered, lowered.target_usize, .{});
        const entrypoints = try la.alloc(lir.LirImage.PlatformEntrypoint, lowered.lir_result.root_procs.items.len);
        self.entry_names = try a.alloc([]const u8, entrypoints.len);
        for (entrypoints, lowered.lir_result.root_procs.items, lowered.lir_result.root_metadata.items, 0..) |*entry, proc, metadata, i| {
            entry.* = .{ .ordinal = @intCast(i), .root_proc = proc };
            var found = false;
            for (self.requests, self.request_names) |request, name| if (request.order == metadata.order) {
                @constCast(self.entry_names)[i] = name;
                found = true;
                break;
            };
            if (!found) return error.EntrypointNotFound;
        }
        // The protocol reports an image over its cap as it always reported
        // an exhausted revision buffer.
        self.image = image.build(gpa, &lowered.lir_result, entrypoints, data, image.default_limits) catch |err| return switch (err) {
            error.ImageTooLarge => error.OutOfMemory,
            else => |other| other,
        };
        eng.stats.image_bytes = self.image.?.size;
        eng.stats.image_retries += self.image.?.attempts - 1;
    }
    fn ordinal(self: *State, name: []const u8) !u32 {
        for (self.entry_names, 0..) |actual, i| if (std.mem.eql(u8, actual, name)) return @intCast(i);
        return error.EntrypointNotFound;
    }
    fn execute(self: *State, std_io: std.Io, opts: Execution, observer: host.Observer) !u8 {
        const root = opts.root;
        var label: ?Label = null;
        for (self.labels) |candidate| if (std.mem.eql(u8, candidate.root, root)) {
            label = candidate;
            break;
        };
        var expectation: ?can.CIR.Expr.Idx = null;
        for (self.expectations, self.expectation_expressions) |candidate, expression| if (std.mem.eql(u8, candidate.root, root)) {
            expectation = expression;
            break;
        };
        if (label == null and expectation == null) return error.EntrypointNotFound;
        if (label != null) try self.capture.replay(self.build.?, root, observer);
        if (expectation) |expression| try self.capture.replayExpression(self.build.?, expression, observer);
        var scratch = std.heap.ArenaAllocator.init(gpa);
        defer scratch.deinit();
        const a = scratch.allocator();
        var view = try self.image.?.view(opts.target_usize, a);
        defer view.deinit();
        var hosted_fns = [_]host.host_abi.HostedFn{host.echoLineHostedFn()};
        var environment: host.EchoEnv = .{ .std_io = std_io, .observer = observer };
        var ops = host.makeDefaultRocOps(&environment, &hosted_fns);
        host.enterRocOps(&ops);
        defer host.leaveRocOps(&ops);
        var static_data = try eval.InterpreterStaticData.init(a, view.static_data, view.static_data_value_count);
        defer static_data.deinit();
        var strings = try eval.LirInterpreter.buildStaticStrings(a, &view.store);
        defer strings.deinit();
        var interpreter = try eval.LirInterpreter.initWithBoxyTables(a, &view.store, &view.layouts, eval.LirInterpreter.BoxyTables.fromImageView(&view), strings.view(), &ops);
        defer interpreter.deinit();
        static_data.install(&interpreter);
        static_data.ownByInterpreter(&interpreter);
        if (expectation != null) {
            var passed: u8 = 0;
            _ = interpreter.runEntrypoint(&view, try self.ordinal(root), null, @ptrCast(&passed)) catch |err| {
                observer.observe(.test_failed, switch (err) {
                    error.Crash => interpreter.getCrashMessage(),
                    error.ExpectErr => "An error propagated from the expect block",
                    else => interpreter.getRuntimeErrorMessage() orelse @errorName(err),
                });
                return 1;
            };
            const ok = passed != 0 and !environment.inline_expect_failed;
            observer.observe(if (ok) .test_passed else .test_failed, if (ok) "Expectation passed" else "Expectation evaluated to False");
            return if (ok) 0 else 1;
        }
        const selected = label.?;
        var text: host.RocStr = undefined;
        _ = interpreter.runEntrypoint(&view, try self.ordinal(selected.text), null, @ptrCast(&text)) catch |err| return reportRuntime(&interpreter, opts.diagnostics, observer, err);
        defer text.decref(&ops);
        observer.observe(.value, text.asSlice());
        if (selected.rich) {
            const value_ordinal = try self.ordinal(selected.value);
            const proc = view.store.getProcSpec(view.platform_entrypoints[value_ordinal].root_proc);
            const size = view.layouts.layoutSize(view.layouts.getLayout(proc.ret_layout));
            const value = try a.alignedAlloc(u8, .@"16", @max(size, 16));
            _ = interpreter.runEntrypoint(&view, value_ordinal, null, value.ptr) catch |err| return reportRuntime(&interpreter, opts.diagnostics, observer, err);
            var wire: host.RocStr = undefined;
            _ = interpreter.runEntrypoint(&view, try self.ordinal(self.wire_name.?), value.ptr, @ptrCast(&wire)) catch |err| return reportRuntime(&interpreter, opts.diagnostics, observer, err);
            defer wire.decref(&ops);
            observer.observe(.value, wire.asSlice());
        }
        return if (environment.inline_expect_failed) 1 else 0;
    }
};
/// The engine's retained revision for `opts`, preparing a new one when the
/// input key changed. Counts a `prepared_hits` when the retained one is reused.
fn revision(eng: *Engine, opts: Inputs) !*State {
    const key = try inputKey(eng, opts);
    if (eng.revision != null and !std.mem.eql(u8, &eng.revision.?.key, &key)) {
        eng.revision.?.destroy();
        eng.revision = null;
    }
    if (eng.revision != null) eng.stats.prepared_hits += 1;
    if (eng.revision == null) {
        const state = try gpa.create(State);
        errdefer gpa.destroy(state);
        state.* = .{ .key = key, .revision_arena = .init(gpa), .capture = .{ .allocator = undefined } };
        state.capture.allocator = state.revision_arena.allocator();
        errdefer state.deinit();
        try state.prepare(eng, opts);
        // Preparing may install package bundles into the workspace; key the
        // retained revision by the workspace it was actually built against.
        state.key = try inputKey(eng, opts);
        eng.revision = state;
    }
    return eng.revision.?;
}

/// Options of the protocol-1 raw `notebook` request (the M0 `cells` adapter).
pub const Options = struct {
    inputs: Inputs,
    metadata: Metadata,
    root: ?[]const u8,
    diagnostics: engine.Diagnostics,
    /// The request observer; `run` attributes each execution to its root.
    observer: host.Observer,
    /// Receives the revision's dependency analysis when the check passes.
    analysis: *?*const dependency.Analysis,
};
/// Run one raw notebook request against the engine's retained revision.
pub fn run(eng: *Engine, opts: Options) !u8 {
    const state = try revision(eng, opts.inputs);
    defer state.reportCache(&eng.stats);
    state.emitReports(opts.diagnostics);
    if (state.failed or (state.constant_failures and !opts.metadata.isolate_errors)) {
        for (opts.metadata.runtime_roots) |root| try state.capture.replay(state.build.?, root, opts.observer.forRoot(root));
        return error.CompilationFailed;
    }
    opts.analysis.* = try state.analysis(&eng.stats);
    const root = opts.root orelse return 0;
    eng.stats.executions += 1;
    return state.execute(eng.workspace.std_io, .{ .root = root, .target_usize = opts.inputs.target_usize, .diagnostics = opts.diagnostics }, opts.observer.forRoot(root));
}

// --- Typed document evaluation ---

pub const Region = dependency.Region;
/// A checked definition attributed to the cell whose byte range contains it.
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
pub const Event = struct { kind: host.EventKind, message: []const u8, root: []const u8, region: ?Region = null };
pub const TestResult = struct { root: []const u8, passed: bool, message: []const u8 };
pub const RootError = struct { root: []const u8, status: []const u8, failure: ?[]const u8 };
pub const Value = struct {
    root: []const u8,
    text: []const u8,
    /// The parsed Display wire of a rich root; absent when the wire was
    /// truncated or malformed (the text result is kept).
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
/// The protocol-1 evaluation result; fields in wire order.
pub const Evaluation = struct {
    protocol: u32 = 1,
    requestId: []const u8 = "cli-1",
    documentRevision: u64 = 1,
    inputRevision: u64 = 0,
    workerGeneration: u64 = 1,
    status: []const u8 = "ok",
    definitions: []const Definition = &.{},
    dependency_scope: []const u8 = "module",
    binders: []const []const u8 = &.{},
    root_errors: []const RootError = &.{},
    evaluated_roots: []const []const u8 = &.{},
    values: []const Value = &.{},
    tests: []const TestResult = &.{},
    events: []const Event = &.{},
    diagnostics: []const engine.Diagnostic = &.{},
    failure: ?[]const u8 = null,
};
/// A byte range of the user program that definitions are attributed to.
pub const CellRange = struct { key: []const u8, start: usize, end: usize };
pub const Request = struct {
    requestId: []const u8 = "cli-1",
    documentRevision: u64 = 1,
    inputRevision: u64 = 0,
    workerGeneration: u64 = 1,
    program: []const u8,
    app_header: []const u8 = "",
    /// Supplied modules, without the bundled Display module.
    modules: []const engine.ExtraFile = &.{},
    /// Every possible output and test root.
    roots: []const []const u8,
    expectations: []const Expectation = &.{},
    cells: []const CellRange,
    /// Roots whose compile-time observations are reported when checking fails.
    failure_roots: []const []const u8 = &.{},
    isolate_errors: bool = false,
};
pub const source_limit = 1024 * 1024;

/// One request's view of the retained revision: checked once, analysed once
/// per revision, then any number of roots executed against the same image.
pub const Checked = struct {
    eng: *Engine,
    arena: A,
    request: Request,
    /// Null when checking failed or the request was rejected after checking.
    state: ?*State,
    rich_support: bool = false,
    target_usize: base.target.TargetUsize = engine.host_target_usize,
    evaluation: Evaluation,
    values: std.ArrayList(Value) = .empty,
    failures: std.ArrayList(RootError) = .empty,
    evaluated_roots: std.ArrayList([]const u8) = .empty,
    events: std.ArrayList(Event) = .empty,
    tests: std.ArrayList(TestResult) = .empty,

    /// Execute `roots` in order, each in a fresh interpreter. Without
    /// `isolate_errors` the first failing output ends the evaluation and
    /// discards the values gathered so far; failing tests never do.
    pub fn evaluate(self: *Checked, roots: []const []const u8) !void {
        try validateRoots(roots);
        const state = self.state orelse return;
        const result = &self.evaluation;
        for (roots) |root| if (!self.defines(root)) {
            result.status = "diagnostic";
            result.failure = try std.fmt.allocPrint(self.arena, "Unknown output root: {s}", .{root});
            self.state = null;
            return;
        };
        for (roots) |root| {
            try self.evaluated_roots.append(self.arena, root);
            result.evaluated_roots = self.evaluated_roots.items;
            var rich = false;
            if (self.rich_support) for (result.definitions) |definition| {
                if (std.mem.eql(u8, definition.name, root) and std.mem.eql(u8, definition.type, "Display")) rich = true;
            };
            var events: host.EventBuffer = .{ .arena = self.arena, .rich = rich };
            var diagnostics: engine.DiagnosticList = .{ .arena = self.arena };
            self.eng.stats.executions += 1;
            const outcome = state.execute(self.eng.workspace.std_io, .{ .root = root, .target_usize = self.target_usize, .diagnostics = diagnostics.diagnostics() }, events.observer().forRoot(root));
            var status: []const u8 = "ok";
            var failure: ?[]const u8 = null;
            const exit_code = outcome catch |err| code: {
                status = "runtime_error";
                failure = diagnostics.failure orelse @errorName(err);
                break :code 0;
            };
            if (exit_code != 0) {
                status = "runtime_error";
                failure = diagnostics.failure;
            }
            if (events.failed or diagnostics.failed) return error.OutOfMemory;
            const ok = std.mem.eql(u8, status, "ok");
            if (isExpectation(self.request.expectations, root)) {
                var passed = ok;
                var message: []const u8 = if (passed) "Expectation passed" else failure orelse status;
                for (events.events.items) |event| switch (event.kind) {
                    .test_passed, .test_failed => {
                        passed = event.kind == .test_passed;
                        message = event.message;
                    },
                    else => try self.events.append(self.arena, .{ .kind = event.kind, .message = event.message, .root = root }),
                };
                try self.tests.append(self.arena, .{ .root = root, .passed = passed, .message = message });
                result.tests = self.tests.items;
                result.events = self.events.items;
                if (!passed) try self.failures.append(self.arena, .{ .root = root, .status = "test_failed", .failure = message });
                // Assertion failures do not discard independent notebook results.
                continue;
            }
            var wire: ?[]const u8 = null;
            var text: ?[]const u8 = null;
            var value_count: usize = 0;
            for (events.events.items) |event| {
                if (event.kind == .value) {
                    if (value_count == 0) text = event.message else wire = event.message;
                    value_count += 1;
                } else try self.events.append(self.arena, .{ .kind = event.kind, .message = event.message, .root = root });
            }
            result.events = self.events.items;
            if (!ok) {
                result.status = status;
                result.failure = failure;
                if (!self.request.isolate_errors) return self.stop();
                try self.failures.append(self.arena, .{ .root = root, .status = status, .failure = failure });
                continue;
            }
            if (value_count != @as(usize, if (rich) 2 else 1)) {
                result.status = "runtime_error";
                result.failure = "Expected exactly one designated result; platform effects are unsupported";
                if (!self.request.isolate_errors) return self.stop();
                try self.failures.append(self.arena, .{ .root = root, .status = result.status, .failure = result.failure });
                continue;
            }
            const display = if (rich and wire != null) std.json.parseFromSliceLeaky(std.json.Value, self.arena, wire.?, .{ .allocate = .alloc_always }) catch null else null;
            // A truncated/invalid rich payload never discards the already evaluated text.
            try self.values.append(self.arena, .{ .root = root, .text = text.?, .display = display });
        }
        result.values = self.values.items;
        result.root_errors = self.failures.items;
        if (self.failures.items.len > 0) result.status = "partial";
    }
    /// An atomic failure: no values or root errors, no further roots.
    fn stop(self: *Checked) void {
        self.state = null;
    }
    fn defines(self: *Checked, name: []const u8) bool {
        for (self.evaluation.definitions) |definition| if (std.mem.eql(u8, definition.name, name)) return true;
        return false;
    }
};

/// Check `request` against the engine's retained revision (preparing a new
/// one when its inputs changed) and analyse it. Rejected snapshots return an
/// error; compiler failures are reported in `evaluation`.
pub fn checkDocument(eng: *Engine, arena: A, request: Request) !Checked {
    for (request.roots, 0..) |root, i| {
        if (!identifier(root, false)) return error.InvalidRoot;
        for (request.roots[0..i]) |previous| if (std.mem.eql(u8, previous, root)) return error.DuplicateRoot;
    }
    for (request.modules, 0..) |module, i| {
        if (!identifier(module.name, true)) return error.InvalidModule;
        for (request.modules[0..i]) |previous| if (std.mem.eql(u8, previous.name, module.name)) return error.DuplicateModule;
    }
    if (request.program.len >= source_limit) return error.SourceTooLarge;
    var checked: Checked = .{ .eng = eng, .arena = arena, .request = request, .state = null, .evaluation = .{
        .requestId = request.requestId,
        .documentRevision = request.documentRevision,
        .inputRevision = request.inputRevision,
        .workerGeneration = request.workerGeneration,
        .dependency_scope = "definitions",
    } };
    const result = &checked.evaluation;
    try engine.prepareBuiltins();
    const modules = try engine.programModules(arena, eng.workspace.io(arena), eng.paths.extras_prefix, request.modules, request.program);
    checked.rich_support = modules.rich_support;
    var diagnostics: engine.DiagnosticList = .{ .arena = arena };
    const inputs: Inputs = .{
        .program = request.program,
        .app_header = request.app_header,
        .extras = modules.extras,
        .roots = request.roots,
        .expectations = request.expectations,
        .rich_support = modules.rich_support,
        .paths = eng.paths,
        .roc_target = engine.hostRocTarget(),
    };
    checked.target_usize = inputs.target_usize;
    const state = revision(eng, inputs) catch |err| {
        result.status = failureStatus(err);
        result.failure = diagnostics.failure orelse @errorName(err);
        return checked;
    };
    state.reportCache(&eng.stats);
    state.emitReports(diagnostics.diagnostics());
    result.diagnostics = diagnostics.items.items;
    if (state.failed or (state.constant_failures and !request.isolate_errors)) {
        var events: host.EventBuffer = .{ .arena = arena };
        var replayed = true;
        for (request.failure_roots) |root| state.capture.replay(state.build.?, root, events.observer().forRoot(root)) catch |err| {
            result.status = "runtime_error";
            result.failure = diagnostics.failure orelse @errorName(err);
            replayed = false;
            break;
        };
        if (replayed) {
            result.status = "diagnostic";
            result.failure = diagnostics.failure orelse "CompilationFailed";
        }
        if (events.failed or diagnostics.failed) return error.OutOfMemory;
        const fallback: []const u8 = if (request.failure_roots.len > 0) request.failure_roots[0] else "";
        const captured = try arena.alloc(Event, events.events.items.len);
        for (captured, events.events.items) |*out, event| out.* = .{ .kind = event.kind, .message = event.message, .root = event.root orelse fallback };
        result.events = captured;
        return checked;
    }
    const analyzed = try state.analysis(&eng.stats);
    if (diagnostics.failed) return error.OutOfMemory;
    const definitions = try arena.alloc(Definition, analyzed.definitions.len);
    for (definitions, analyzed.definitions) |*out, definition| {
        out.* = .{
            .name = definition.name,
            .type = definition.type,
            .region = definition.region,
            .name_region = definition.name_region,
            .dependencies = definition.dependencies,
            .references = definition.references,
            .rename_safe = definition.rename_safe,
        };
        for (request.cells) |cell| if (definition.region.start >= cell.start and definition.region.end <= cell.end) {
            out.cell = cell.key;
            break;
        };
    }
    result.definitions = definitions;
    result.dependency_scope = @tagName(analyzed.dependency_scope);
    result.binders = analyzed.binders;
    var names: std.StringHashMapUnmanaged(void) = .empty;
    for (definitions) |definition| {
        if ((try names.getOrPut(arena, definition.name)).found_existing) {
            result.status = "diagnostic";
            result.failure = try std.fmt.allocPrint(arena, "Duplicate notebook binding: {s}", .{definition.name});
            return checked;
        }
    }
    checked.state = state;
    return checked;
}

/// Protocol-1 status of a failed check or execution.
fn failureStatus(err: anytype) []const u8 {
    return switch (err) {
        error.CompilationFailed => "diagnostic",
        else => "runtime_error",
    };
}
fn validateRoots(roots: []const []const u8) !void {
    for (roots, 0..) |root, i| {
        if (!identifier(root, false)) return error.InvalidRoot;
        for (roots[0..i]) |previous| if (std.mem.eql(u8, previous, root)) return error.DuplicateRoot;
    }
}
pub fn identifier(name: []const u8, module: bool) bool {
    if (name.len == 0) return false;
    if (module) {
        if (!std.ascii.isUpper(name[0])) return false;
    } else if (!std.ascii.isLower(name[0])) return false;
    for (name[1..]) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    return true;
}
fn appendRoot(a: A, env: *can.ModuleEnv, exported: []const check.CheckedArtifact.RootRequest, name: []const u8, roots: *std.ArrayList(check.CheckedArtifact.RootRequest), names: *std.ArrayList([]const u8)) !void {
    for (exported) |request| {
        if (request.source != .def) continue;
        const pattern = env.store.getPattern(env.store.getDef(request.source.def).pattern);
        if (pattern == .assign and std.mem.eql(u8, env.getIdent(pattern.assign.ident), name)) {
            try roots.append(a, request);
            try names.append(a, name);
            return;
        }
    }
    return error.EntrypointNotFound;
}
fn reportRuntime(interpreter: *eval.LirInterpreter, diagnostics: engine.Diagnostics, observer: host.Observer, err: (eval.LirInterpreter.Error || error{EntrypointNotFound})) error{EvaluationFailed} {
    switch (err) {
        error.Crash => observer.observe(.crashed, interpreter.getCrashMessage()),
        else => if (interpreter.getRuntimeErrorMessage()) |message| diagnostics.write(message),
    }
    return error.EvaluationFailed;
}

fn inputKey(eng: *Engine, opts: Inputs) ![32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    const field = workspace.hashField;
    field(&hash, "roclet-notebook-v1");
    field(&hash, opts.program);
    field(&hash, opts.app_header);
    field(&hash, opts.paths.app_abs);
    field(&hash, &.{ @intFromBool(opts.rich_support), @intCast(@backingInt(opts.target_usize)) });
    field(&hash, "roots");
    var count: [8]u8 = undefined;
    std.mem.writeInt(u64, &count, opts.roots.len, .little);
    hash.update(&count);
    for (opts.roots) |root| field(&hash, root);
    field(&hash, "expectations");
    for (opts.expectations) |expectation| {
        field(&hash, expectation.root);
        var span: [8]u8 = undefined;
        std.mem.writeInt(u32, span[0..4], expectation.start, .little);
        std.mem.writeInt(u32, span[4..8], expectation.end, .little);
        hash.update(&span);
    }
    field(&hash, "modules");
    std.mem.writeInt(u64, &count, opts.extras.len, .little);
    hash.update(&count);
    for (opts.extras) |file| {
        field(&hash, file.name);
        field(&hash, file.content);
    }
    const workspace_hash = try eng.workspace.contentIdentity(gpa);
    defer gpa.free(workspace_hash);
    field(&hash, workspace_hash);
    var key: [32]u8 = undefined;
    hash.final(&key);
    return key;
}

fn isExpectation(expectations: []const Expectation, root: []const u8) bool {
    for (expectations) |expectation| if (std.mem.eql(u8, expectation.root, root)) return true;
    return false;
}
