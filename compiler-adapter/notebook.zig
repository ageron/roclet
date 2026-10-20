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
const A = std.mem.Allocator;
const gpa = if (builtin.cpu.arch == .wasm32) std.heap.wasm_allocator else std.heap.page_allocator;
pub const Expectation = struct { root: []const u8, start: u32, end: u32, cell: u64 = 0 };
pub const Metadata = struct { expectations: []const Expectation = &.{}, roots: []const []const u8, runtime_roots: []const []const u8 = &.{}, isolate_errors: bool = false };
pub const Options = struct {
    source: []const u8,
    app_header: []const u8,
    extras: []const engine.ExtraFile,
    paths: engine.Paths,
    metadata: Metadata,
    root: ?[]const u8,
    rich_support: bool,
    target_usize: base.target.TargetUsize,
    roc_target: @import("roc_target").RocTarget,
    diagnostics: engine.Diagnostics,
    analyze: *const fn (*can.ModuleEnv, u32) void,
};
const Label = struct { root: []const u8, text: []const u8, value: []const u8, rich: bool = false };
const Entry = struct { name: []const u8, request: check.CheckedArtifact.RootRequest };
const State = struct {
    key: [32]u8,
    buffer: []align(16) u8,
    fba: std.heap.FixedBufferAllocator,
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
    lowered: ?lir.CheckedPipeline.LoweredProgram = null,
    header: ?*lir.LirImage.Header = null,
    entry_names: []const []const u8 = &.{},
    cache_reported: compile.CacheStats = .{},

    fn deinit(self: *State) void {
        if (self.lowered) |*lowered| lowered.deinit();
        if (self.build) |build| {
            if (self.reports.len != 0) build.freeDrainedReports(self.reports);
            build.deinit();
        }
        gpa.free(self.buffer);
    }
    fn reportCache(self: *State) void {
        const now = if (self.build) |b| if (b.cache_manager) |cache| cache.getStats() else compile.CacheStats{} else compile.CacheStats{};
        inline for (@typeInfo(compile.CacheStats).@"struct".field_names) |name| @field(engine.request_cache_stats, name) += @field(now, name) - @field(self.cache_reported, name);
        self.cache_reported = now;
    }
    fn emitReports(self: *State, diag: engine.Diagnostics) void {
        var scratch = std.heap.ArenaAllocator.init(gpa);
        defer scratch.deinit();
        for (self.reports) |module| for (module.reports) |*report| diag.emitReport(scratch.allocator(), report);
    }
    fn prepare(self: *State, opts: Options) !void {
        const a = self.fba.allocator();
        const expectations = try a.dupe(Expectation, opts.metadata.expectations);
        for (expectations) |*expectation| expectation.root = try a.dupe(u8, expectation.root);
        self.expectations = expectations;
        self.expectation_expressions = try a.alloc(can.CIR.Expr.Idx, expectations.len);
        var output_count: usize = 0;
        for (opts.metadata.roots) |root| if (!isExpectation(opts.metadata, root)) {
            output_count += 1;
        };
        self.labels = try a.alloc(Label, output_count);
        var source_hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(opts.source, &source_hash, .{});
        const hash_text = std.fmt.bytesToHex(source_hash, .lower);
        var output_index: usize = 0;
        for (opts.metadata.roots) |root| {
            if (isExpectation(opts.metadata, root)) continue;
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
            try workspace.global.put("/internal/header.roc", opts.app_header, false);
            const parsed = try compile.app_header.parseAppHeader(workspace.global.io(a), a, a, "/internal/header.roc");
            for (parsed.non_platform_packages) |package| {
                try header.writer.print(", {s}: ", .{package.shorthand});
                try std.json.Stringify.value(package.spec, .{}, &header.writer);
            }
        }
        try header.writer.writeAll(" }\n\nimport pf.Echo\n\n");
        self.prefix = @intCast(header.written().len);
        var source: std.Io.Writer.Allocating = .init(a);
        try source.writer.writeAll(header.written());
        try source.writer.writeAll(opts.source);
        try source.writer.writeAll("\n\nmain! = |_args| Ok({})\necho! = |message| Echo.line!(message)\n");
        for (self.labels) |label| try source.writer.print("\n{s} = || Str.inspect({s})\n{s} = || {s}\n", .{ label.text, label.root, label.value, label.root });
        if (self.wire_name) |wire| try source.writer.print("\n{s} = |value| Display.to_wire(value)\n", .{wire});
        if (source.written().len > 2 * 1024 * 1024) return error.SourceTooLarge;
        const extras = try a.alloc(engine.ExtraFile, opts.extras.len);
        for (extras, opts.extras) |*dest, src| dest.* = .{ .name = try a.dupe(u8, src.name), .content = try a.dupe(u8, src.content) };
        const fs = try a.create(engine.EchoCtx);
        fs.* = .{ .paths = opts.paths, .synthetic_app_source = source.written(), .extras = extras, .fallback = workspace.global.io(a) };
        const build = try a.create(compile.BuildEnv);
        build.* = compile.BuildEnv.initBorrowingBuiltinModules(a, .single_threaded, 1, opts.roc_target, opts.paths.cwd, workspace.global.std_io, try engine.persistentBuiltins());
        self.build = build;
        build.filesystem = fs.io();
        build.package_cache_dir = try a.dupe(u8, "/packages");
        build.defer_post_check = true;
        build.setPostCheckPublicationMode(.none);
        build.compile_time_root_event_callback = .{ .context = &self.capture, .notify = engine.DebugCapture.observe };
        const owned_user_source = source.written()[self.prefix..][0..opts.source.len];
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
        engine.request_frontend_builds += 1;
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
        engine.request_lowerings += 1;
        self.lowered = try build.runtimeProgramSession().?.takeRuntime(a, request_set, runtime_target);
        const lowered = &self.lowered.?;
        const imports = try build.collectImportedArtifactViews(a, artifact);
        const relations = try build.collectRelationArtifactViews(a, artifact);
        const data = try eval.buildStaticDataForWidth(a, .{ .root = check.CheckedArtifact.loweringViewWithRelations(artifact, relations), .imports = imports }, lowered, lowered.target_usize, .{});
        const entrypoints = try a.alloc(lir.LirImage.PlatformEntrypoint, lowered.lir_result.root_procs.items.len);
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
        const image_header = try a.create(lir.LirImage.Header);
        const copied = try lir.LirImage.referenceProgramWithStaticDataInBuffer(a, self.buffer.ptr, self.buffer.len, &lowered.lir_result, entrypoints, data);
        try copied.fillHeader(image_header, self.fba.end_index);
        self.header = image_header;
    }
    fn ordinal(self: *State, name: []const u8) !u32 {
        for (self.entry_names, 0..) |actual, i| if (std.mem.eql(u8, actual, name)) return @intCast(i);
        return error.EntrypointNotFound;
    }
    fn execute(self: *State, opts: Options) !u8 {
        const root = opts.root.?;
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
        if (label != null) try self.capture.replay(self.build.?, root);
        if (expectation) |expression| try self.capture.replayExpression(self.build.?, expression);
        var scratch = std.heap.ArenaAllocator.init(gpa);
        defer scratch.deinit();
        const a = scratch.allocator();
        var view = try lir.LirImage.viewMappedImageWithAllocator(self.header.?, self.buffer.ptr, @intCast(self.header.?.image_size), opts.target_usize, a);
        defer view.deinit();
        var hosted_fns = [_]host.host_abi.HostedFn{host.echoLineHostedFn()};
        var environment: host.EchoEnv = .{ .std_io = workspace.global.std_io };
        var ops = host.makeDefaultRocOps(&environment, &hosted_fns);
        host.g_roc_ops = &ops;
        defer host.g_roc_ops = null;
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
                if (host.observer) |emit| emit("test_failed", switch (err) {
                    error.Crash => interpreter.getCrashMessage(),
                    error.ExpectErr => "An error propagated from the expect block",
                    else => interpreter.getRuntimeErrorMessage() orelse @errorName(err),
                });
                return 1;
            };
            const ok = passed != 0 and !environment.inline_expect_failed;
            if (host.observer) |emit| emit(if (ok) "test_passed" else "test_failed", if (ok) "Expectation passed" else "Expectation evaluated to False");
            return if (ok) 0 else 1;
        }
        const selected = label.?;
        var text: host.RocStr = undefined;
        _ = interpreter.runEntrypoint(&view, try self.ordinal(selected.text), null, @ptrCast(&text)) catch |err| return reportRuntime(&interpreter, opts.diagnostics, err);
        defer text.decref(&ops);
        if (host.observer) |emit| emit("value", text.asSlice());
        if (selected.rich) {
            const value_ordinal = try self.ordinal(selected.value);
            const proc = view.store.getProcSpec(view.platform_entrypoints[value_ordinal].root_proc);
            const size = view.layouts.layoutSize(view.layouts.getLayout(proc.ret_layout));
            const value = try a.alignedAlloc(u8, .@"16", @max(size, 16));
            _ = interpreter.runEntrypoint(&view, value_ordinal, null, value.ptr) catch |err| return reportRuntime(&interpreter, opts.diagnostics, err);
            var wire: host.RocStr = undefined;
            _ = interpreter.runEntrypoint(&view, try self.ordinal(self.wire_name.?), value.ptr, @ptrCast(&wire)) catch |err| return reportRuntime(&interpreter, opts.diagnostics, err);
            defer wire.decref(&ops);
            if (host.observer) |emit| emit("value", wire.asSlice());
        }
        return if (environment.inline_expect_failed) 1 else 0;
    }
};
var current: ?*State = null;
pub fn run(opts: Options) !u8 {
    const key = try inputKey(opts);
    if (current != null and !std.mem.eql(u8, &current.?.key, &key)) {
        current.?.deinit();
        gpa.destroy(current.?);
        current = null;
    }
    if (current != null) engine.request_prepared_hits += 1;
    if (current == null) {
        const buffer = try gpa.alignedAlloc(u8, .@"16", 512 * 1024 * 1024);
        errdefer gpa.free(buffer);
        const state = try gpa.create(State);
        errdefer gpa.destroy(state);
        state.* = .{ .key = key, .buffer = buffer, .fba = std.heap.FixedBufferAllocator.init(buffer), .capture = .{ .allocator = undefined } };
        state.capture.allocator = state.fba.allocator();
        state.prepare(opts) catch |err| {
            if (state.build) |build| build.deinit();
            return err;
        };
        state.key = try inputKey(opts);
        current = state;
    }
    const state = current.?;
    defer state.reportCache();
    state.emitReports(opts.diagnostics);
    if (state.failed or (state.constant_failures and !opts.metadata.isolate_errors)) {
        for (opts.metadata.runtime_roots) |root| {
            host.observation_root = root;
            defer host.observation_root = null;
            try state.capture.replay(state.build.?, root);
        }
        return error.CompilationFailed;
    }
    opts.analyze(state.build.?.getAppSemanticData().?.env, state.prefix);
    if (opts.root == null) return 0;
    host.observation_root = opts.root;
    defer host.observation_root = null;
    engine.request_executions += 1;
    return state.execute(opts);
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
fn reportRuntime(interpreter: *eval.LirInterpreter, diagnostics: engine.Diagnostics, err: anyerror) error{EvaluationFailed} {
    switch (err) {
        error.Crash => if (host.observer) |emit| emit("crashed", interpreter.getCrashMessage()),
        else => if (interpreter.getRuntimeErrorMessage()) |message| diagnostics.write(message),
    }
    return error.EvaluationFailed;
}

fn inputKey(opts: Options) ![32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    const field = workspace.hashField;
    field(&hash, "roclet-notebook-v1");
    field(&hash, opts.source);
    field(&hash, opts.app_header);
    field(&hash, opts.paths.app_abs);
    field(&hash, &.{ @intFromBool(opts.rich_support), @intCast(@backingInt(opts.target_usize)) });
    field(&hash, "roots");
    var count: [8]u8 = undefined;
    std.mem.writeInt(u64, &count, opts.metadata.roots.len, .little);
    hash.update(&count);
    for (opts.metadata.roots) |root| field(&hash, root);
    field(&hash, "expectations");
    for (opts.metadata.expectations) |expectation| {
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
    const workspace_hash = try workspace.global.contentIdentity(gpa);
    defer gpa.free(workspace_hash);
    field(&hash, workspace_hash);
    var key: [32]u8 = undefined;
    hash.final(&key);
    return key;
}

fn isExpectation(metadata: Metadata, root: []const u8) bool {
    for (metadata.expectations) |expectation| if (std.mem.eql(u8, expectation.root, root)) return true;
    return false;
}
