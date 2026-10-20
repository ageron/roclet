//! Shared compile-and-run pipeline for the echo platform.
//!
//! Both the wasm export (`echo.zig`) and the native CLI (`echo_native.zig`)
//! drive this function. Keeping the pipeline in one place means a native
//! reproduction with a real stack trace exercises identical code to the
//! browser path.

const std = @import("std");
const base = @import("base");
const check = @import("check");
const can = @import("can");
const compile = @import("compile");
const echo_platform = @import("platform.zig");
const eval = @import("eval");
const lir = @import("lir");
const roc_target = @import("roc_target");
const reporting = @import("reporting");

const Allocator = std.mem.Allocator;
const BuildEnv = compile.BuildEnv;
const Io = compile.CoreCtx;
const RocTarget = roc_target.RocTarget;
const HostedFn = echo_platform.host_abi.HostedFn;

/// Errors that can occur while building and running the echo platform.
pub const RunEchoError = error{ WriteFailed, InvalidPath } || Allocator.Error ||
    compile.build.InitError ||
    compile.build.BuildError ||
    compile.build.CompileDiscoveredError ||
    lir.CheckedPipeline.LowerResourceError ||
    lir.LirImage.ImageError ||
    eval.LirInterpreter.Error ||
    error{
        CompilationFailed,
        EvaluationFailed,
        EntrypointNotFound,
        UnsupportedTarget,
    };

/// Diagnostic-emission interface. The browser wasm host writes terminal text
/// to `js_stderr`; the native host writes terminal text to its real stderr.
pub const Diagnostics = struct {
    ctx: ?*anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Emit a free-form message (e.g. "echo: step 'X' failed: Y").
        write: *const fn (ctx: ?*anyopaque, msg: []const u8) void,
        /// Render & emit a single compiler Report.
        emitReport: *const fn (ctx: ?*anyopaque, gpa: Allocator, report: *reporting.Report) void,
    };

    pub fn write(self: Diagnostics, msg: []const u8) void {
        self.vtable.write(self.ctx, msg);
    }

    pub fn emitReport(self: Diagnostics, gpa: Allocator, report: *reporting.Report) void {
        self.vtable.emitReport(self.ctx, gpa, report);
    }

    /// Format a labelled step-failure message and emit it.
    pub fn step(self: Diagnostics, comptime label: []const u8, err: RunEchoError) void {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "echo: step '" ++ label ++ "' failed: {s}\n", .{@errorName(err)}) catch {
            self.write("echo: step '" ++ label ++ "' failed (and message formatting failed)\n");
            return;
        };
        self.write(msg);
    }
};

/// A user-supplied module file (e.g. `Greeting.roc`).
pub const ExtraFile = struct {
    name: []const u8,
    content: []const u8,
};

fn countNewlines(bytes: []const u8) u32 {
    var count: u32 = 0;
    for (bytes) |byte| {
        if (byte == '\n') count += 1;
    }
    return count;
}

/// Caller-controlled paths for the synthetic app & embedded platform files.
/// Both the wasm and native flows generate a synthetic app whose `app [main!]`
/// header references these paths.
pub const Paths = struct {
    app_abs: []const u8 = "/workspace/main.roc",
    platform_main: []const u8 = "/workspace/.roc_echo_platform/main.roc",
    echo_module: []const u8 = "/workspace/.roc_echo_platform/Echo.roc",
    cwd: []const u8 = "/workspace",
    /// Prefix prepended to extra-file paths so `addFile("Greeting", ...)`
    /// resolves as `<extras_prefix>Greeting.roc`. Must end with `/`.
    extras_prefix: []const u8 = "/workspace/",
};

/// Inputs to `runEcho`. See field doc comments for the contract on each.
pub const CachedProgram = struct { allocator: Allocator, bytes: ?[]u8 = null };
pub fn isEmbeddedDisplayPackage(shorthand: []const u8, spec: []const u8) bool {
    return std.mem.eql(u8, shorthand, "roclet") and std.mem.eql(u8, spec, std.mem.trim(u8, @embedFile("display-package-url.txt"), "\r\n"));
}
pub const RunOptions = struct {
    app_header: []const u8 = "",
    root_name: ?[]const u8 = null,
    analyze: ?*const fn (*@import("can").ModuleEnv, u32) void = null,
    check_only: bool = false,
    args: []const []const u8 = &.{},
    cached_program: ?*CachedProgram = null,
    /// Single contiguous arena used for the entire pipeline (BuildEnv,
    /// lowering, LIR image, interpreter). Must own a flat virtual
    /// region—`std.heap.ArenaAllocator` will not work because the
    /// LIR image step computes offsets via `ptr - base_ptr` arithmetic
    /// (see `src/compile/README.md` "Runtime arena").
    runtime_fba: *std.heap.FixedBufferAllocator,
    /// Fallback Io that handles everything not served by EchoCtx (i.e. paths
    /// not in `Paths` and not in `extras`).
    fallback_io: Io,
    /// `std.Io` instance used for any real OS I/O on native targets—passed
    /// to `BuildEnv.init`, the WasmFilesystem fallback, and stored in
    /// `EchoEnv` so `echoHostedFn` can call `writeStreamingAll`. On WASM
    /// builds the value is unused (freestanding stubs trap), but callers
    /// must still pass a value; a default CoreCtx's `std_io` on freestanding
    /// is a valid sentinel.
    std_io: std.Io,
    /// The headerless user source (the body of the synthetic app).
    source: []const u8,
    /// Extra user-supplied modules, available as `import <name>`.
    extras: []const ExtraFile,
    /// Where to send diagnostics.
    diagnostics: Diagnostics,
    /// Filesystem paths used by the synthetic app + embedded platform.
    paths: Paths = .{},
    /// Target word width. `.u32` for wasm32 builds.
    target_usize: base.target.TargetUsize = .u32,
    /// Roc compilation target.
    roc_target: RocTarget = .wasm32,
};

/// Compile and execute a headerless Roc source through the echo platform.
///
/// Wraps the user `source` in a synthetic `app [main!]` header that imports
/// the embedded echo platform, then walks the canonical embedding sequence
/// (see `src/compile/README.md`): BuildEnv discovery → check → LIR lowering
/// → `LirImage.referenceProgramWithStaticDataInBuffer` → `viewMappedImage` →
/// `LirInterpreter.runEntrypoint`.
///
/// Returns the Roc program's exit code (or 1 if an inline `expect` failed
/// while the program otherwise returned 0). On compilation/runtime error,
/// emits a labelled diagnostic through `opts.diagnostics` and propagates
/// the error so the caller can decide on an exit code.
pub fn runEcho(opts: RunOptions) RunEchoError!u8 {
    const allocator = opts.runtime_fba.allocator();
    const diag = opts.diagnostics;

    var header_writer: std.Io.Writer.Allocating = .init(allocator);
    try header_writer.writer.writeAll("app [main!] { pf: platform \"./.roc_echo_platform/main.roc\"");
    if (opts.app_header.len > 0) {
        try @import("workspace.zig").global.put("/internal/header.roc", opts.app_header, false);
        const header = compile.app_header.parseAppHeader(opts.fallback_io, allocator, allocator, "/internal/header.roc") catch null;
        if (header) |parsed_header| for (parsed_header.non_platform_packages) |package| {
            if (isEmbeddedDisplayPackage(package.shorthand, package.spec)) continue;
            try header_writer.writer.print(", {s}: ", .{package.shorthand});
            try std.json.Stringify.value(package.spec, .{}, &header_writer.writer);
        };
    }
    try header_writer.writer.writeAll(" }\n\nimport pf.Echo\n\n");
    const header_str = header_writer.written();
    const footer_str =
        "\n\necho! = |msg| Echo.line!(msg)\n";

    const synthetic_source = std.mem.concat(allocator, u8, &.{ header_str, opts.source, footer_str }) catch |err| {
        diag.step("std.mem.concat (synthetic source)", err);
        return err;
    };

    var echo_ctx = EchoCtx{
        .paths = opts.paths,
        .synthetic_app_source = synthetic_source,
        .extras = opts.extras,
        .fallback = opts.fallback_io,
    };

    // BuildEnv stores std_io for any real-OS reads its workers initiate.
    // On WASM the echo pipeline only touches synthetic / extra paths served
    // by EchoCtx, so the std_io is never actually dereferenced—but the
    // field still must be a concrete value (no `undefined`) to avoid UB if
    // a future refactor adds a real-OS call path.
    var build_env = BuildEnv.initBorrowingBuiltinModules(allocator, .single_threaded, 1, opts.roc_target, opts.paths.cwd, opts.std_io, try persistentBuiltins());
    defer build_env.deinit();

    build_env.setSyntheticRootSourceMappingWithLineOffset(
        std.fs.path.basename(opts.paths.app_abs),
        opts.source,
        header_str.len,
        countNewlines(header_str),
    );
    build_env.filesystem = echo_ctx.io();
    var event_context: DebugCapture = .{ .allocator = allocator };
    build_env.compile_time_root_event_callback = .{ .context = &event_context, .notify = DebugCapture.observe };
    build_env.package_cache_dir = try allocator.dupe(u8, "/packages");
    const cache = try allocator.create(compile.CacheManager);
    cache.* = compile.CacheManager.init(allocator, .{ .enabled = true, .cache_dir = "/cache", .roc_ctx = echo_ctx.io() }, echo_ctx.io());
    build_env.setCacheManager(cache);
    defer {
        last_cache_stats = cache.getStats();
        inline for (@typeInfo(compile.CacheStats).@"struct".field_names) |field| @field(request_cache_stats, field) += @field(last_cache_stats, field);
    }
    const runtime_target: lir.CheckedPipeline.TargetConfig = .{ .target_usize = opts.target_usize };
    if (!opts.check_only) build_env.setRuntimeLowering(.{ .target = runtime_target });
    if (opts.check_only) build_env.setPostCheckPublicationMode(.none);

    build_env.discoverDependencies(opts.paths.app_abs) catch |err| {
        if (!try emitDiagnostics(&build_env, diag, allocator)) {
            diag.step("discoverDependencies", err);
        }
        return err;
    };
    request_frontend_builds += 1;
    build_env.compileDiscovered() catch |err| {
        if (!try emitDiagnostics(&build_env, diag, allocator)) {
            diag.step("compileDiscovered", err);
        }
        return err;
    };

    // Bail before lowering if canonicalization or type-checking produced
    // blocking-severity reports (e.g. `module_not_found`, `undefined_variable`).
    // The CIR contains runtime_error placeholder nodes in that state, and
    // mono lowering asserts they don't appear as runtime values—proceeding
    // would trap. The reports themselves are the user-facing output.
    if (try emitDiagnostics(&build_env, diag, allocator)) {
        return error.CompilationFailed;
    }

    // Defense in depth: even with no blocking reports, the artifact may be
    // missing in some unexpected state. Bail cleanly instead of trapping in
    // the asserting variant (compile_build.zig:executableRootCheckedArtifact).
    const root_semantic = build_env.getExecutableRootSemanticData() orelse {
        diag.step("executableRootCheckedArtifact", error.CompilationFailed);
        return error.CompilationFailed;
    };
    const root_artifact = root_semantic.checked_artifact orelse {
        diag.step("executableRootCheckedArtifact", error.CompilationFailed);
        return error.CompilationFailed;
    };

    if (opts.analyze) |analyze| {
        if (build_env.getAppSemanticData()) |app| analyze(app.env, @intCast(header_str.len));
    }
    if (opts.check_only) return 0;
    try event_context.replay(&build_env, opts.root_name orelse "main!");

    const import_views = build_env.collectImportedArtifactViews(allocator, root_artifact) catch |err| {
        diag.step("collectImportedArtifactViews", err);
        return err;
    };
    defer allocator.free(import_views);
    const relation_views = build_env.collectRelationArtifactViews(allocator, root_artifact) catch |err| {
        diag.step("collectRelationArtifactViews", err);
        return err;
    };
    defer allocator.free(relation_views);

    const lir_roots = lir.CheckedPipeline.selectPlatformEntrypointRoots(allocator, root_artifact.root_requests.runtime_requests) catch |err| {
        diag.step("selectPlatformEntrypointRoots", err);
        return err;
    };
    defer allocator.free(lir_roots);

    request_lowerings += 1;
    var lowered = build_env.runtimeProgramSession().?.takeRuntime(
        allocator,
        .{ .requests = lir_roots },
        runtime_target,
    ) catch |err| {
        diag.step("lowerCheckedModulesToLir", err);
        return err;
    };
    defer lowered.deinit();

    // Canonical embedding sequence: build entrypoints + LIR image, then
    // view it and execute via runEntrypoint. The viewMappedImage step
    // re-constructs the layout Store with the correct target_usize, which
    // matters for cross-compile cases.
    const entrypoints = lowered.platformEntrypoints(allocator) catch |err| {
        diag.step("platformEntrypoints", err);
        return err;
    };

    const image_header = allocator.create(lir.LirImage.Header) catch |err| {
        diag.step("create LirImage.Header", err);
        return err;
    };
    const image_data = try eval.buildStaticDataForWidth(allocator, .{
        .root = check.CheckedArtifact.loweringViewWithRelations(root_artifact, relation_views),
        .imports = import_views,
    }, &lowered, lowered.target_usize, .{});
    defer eval.deinitStaticData(allocator, image_data);
    const copied = try lir.LirImage.referenceProgramWithStaticDataInBuffer(
        allocator,
        opts.runtime_fba.buffer.ptr,
        opts.runtime_fba.buffer.len,
        &lowered.lir_result,
        entrypoints,
        image_data,
    );
    try copied.fillHeader(image_header, opts.runtime_fba.end_index);

    var view = lir.LirImage.viewMappedImage(
        image_header,
        opts.runtime_fba.buffer.ptr,
        opts.runtime_fba.end_index,
        lowered.target_usize,
    ) catch |err| {
        diag.step("LirImage.viewMappedImage", err);
        return err;
    };
    defer view.deinit();

    request_executions += 1;
    return runEchoView(allocator, &view, diag, opts.std_io, opts.args) catch |err| {
        diag.step("runEchoView", err);
        return err;
    };
}

fn runEchoView(
    allocator: Allocator,
    view: *const lir.LirImage.ProgramView,
    diag: Diagnostics,
    std_io: std.Io,
    args: []const []const u8,
) RunEchoError!u8 {
    // HostedFn array order matters: the interpreter calls
    // `roc_ops.hosted_fns.fns[dispatch_index]`, and a dispatch index is the
    // function's position in the platform header's `hosted` section. The echo
    // platform's section lists only `Echo.line!`, so order is trivially
    // correct—but additions must follow that section's order or the wrong
    // function will be called silently. See README "Host functions".
    var hosted_fn_array = [_]HostedFn{echo_platform.echoLineHostedFn()};
    var echo_env: echo_platform.EchoEnv = .{ .std_io = std_io };
    var roc_ops = echo_platform.makeDefaultRocOps(&echo_env, &hosted_fn_array);
    echo_platform.g_roc_ops = &roc_ops;
    var cli_args_list = try echo_platform.buildCliArgs(args, &roc_ops);
    var result_buf: [16]u8 align(16) = undefined;

    var static_data = try eval.InterpreterStaticData.init(allocator, view.static_data, view.static_data_value_count);
    defer static_data.deinit();
    var static_strings = try eval.LirInterpreter.buildStaticStrings(allocator, &view.store);
    defer static_strings.deinit();

    var interpreter = eval.LirInterpreter.initWithBoxyTables(
        allocator,
        &view.store,
        &view.layouts,
        eval.LirInterpreter.BoxyTables.fromImageView(view),
        static_strings.view(),
        &roc_ops,
    ) catch |err| {
        diag.step("LirInterpreter.init", err);
        return err;
    };
    defer interpreter.deinit();
    static_data.install(&interpreter);
    static_data.ownByInterpreter(&interpreter);

    _ = interpreter.runEntrypoint(view, 0, @ptrCast(&cli_args_list), @ptrCast(&result_buf)) catch |err| switch (err) {
        error.RuntimeError, error.DivisionByZero => {
            if (interpreter.getRuntimeErrorMessage()) |msg| diag.write(msg);
            diag.step("interpreter.runEntrypoint", err);
            return error.EvaluationFailed;
        },
        error.Crash => {
            if (echo_platform.observer) |emit| emit("crashed", interpreter.getCrashMessage());
            return error.EvaluationFailed;
        },
        error.ComptimeExhaustiveness => {
            diag.step("interpreter.runEntrypoint", err);
            return error.EvaluationFailed;
        },
        error.OutOfMemory => {
            diag.step("interpreter.runEntrypoint", err);
            return error.OutOfMemory;
        },
        error.EntrypointNotFound => {
            diag.step("interpreter.runEntrypoint", err);
            return error.EntrypointNotFound;
        },
        // expect_err statements only occur in top-level expect test roots,
        // never in program entrypoints.
        error.ExpectErr => unreachable,
        error.UnsupportedHostedFunction, error.InvalidHostedFunctionSignature => unreachable,
    };

    if (echo_env.inline_expect_failed) return 1;
    return result_buf[0];
}

/// Drain BuildEnv reports through `diag` and return true if any
/// had `runtime_error` or `fatal` severity (i.e. compile-blocking).
fn emitDiagnostics(build_env: *BuildEnv, diag: Diagnostics, gpa: Allocator) Allocator.Error!bool {
    const drained = try build_env.drainReports();
    defer build_env.freeDrainedReports(drained);

    var has_blocking_error = false;
    for (drained) |mod| {
        for (mod.reports) |*report| {
            if (report.severity.isError()) has_blocking_error = true;
            diag.emitReport(gpa, report);
        }
    }
    return has_blocking_error;
}

// --- Echo I/O context ---

/// Unified I/O context for the echo platform. Intercepts readFile/fileExists
/// for synthetic app source, embedded platform files, and extras; delegates
/// everything else to `fallback`.
pub const EchoCtx = struct {
    paths: Paths,
    synthetic_app_source: []const u8,
    extras: []const ExtraFile,
    fallback: Io,

    pub fn io(self: *EchoCtx) Io {
        return .{
            .ctx = @ptrCast(self),
            .vtable = echo_vtable,
            .std_io = self.fallback.std_io,
            .gpa = self.fallback.gpa,
            .arena = self.fallback.arena,
        };
    }

    /// Return the content for a synthetic/embedded path, or null if not synthetic.
    pub fn getSyntheticContent(self: *const EchoCtx, path: []const u8) ?[]const u8 {
        if (std.mem.eql(u8, path, self.paths.app_abs)) return self.synthetic_app_source;
        if (std.mem.eql(u8, path, self.paths.platform_main)) return echo_platform.platform_main_source;
        if (std.mem.eql(u8, path, self.paths.echo_module)) return echo_platform.echo_module_source;
        for (self.extras) |ef| {
            if (matchesExtra(self.paths.extras_prefix, ef.name, path)) return ef.content;
        }
        return null;
    }

    /// Check if `path` is one of the synthetic/embedded paths.
    pub fn isSyntheticPath(self: *const EchoCtx, path: []const u8) bool {
        return self.getSyntheticContent(path) != null;
    }
};

fn matchesExtra(prefix: []const u8, name: []const u8, path: []const u8) bool {
    const suffix = ".roc";
    if (path.len != prefix.len + name.len + suffix.len) return false;
    if (!std.mem.startsWith(u8, path, prefix)) return false;
    if (!std.mem.eql(u8, path[prefix.len..][0..name.len], name)) return false;
    return std.mem.eql(u8, path[prefix.len + name.len ..][0..suffix.len], suffix);
}

fn echoGetCtx(ctx_ptr: ?*anyopaque) *EchoCtx {
    return @ptrCast(@alignCast(ctx_ptr.?));
}

fn echoReadFile(ctx_ptr: ?*anyopaque, _: std.Io, path: []const u8, gpa: Allocator) Io.ReadError![]u8 {
    const self = echoGetCtx(ctx_ptr);
    if (self.getSyntheticContent(path)) |content|
        return gpa.dupe(u8, content) catch return error.OutOfMemory;
    return self.fallback.readFile(path, gpa);
}

fn echoFileExists(ctx_ptr: ?*anyopaque, _: std.Io, path: []const u8) bool {
    const self = echoGetCtx(ctx_ptr);
    if (self.isSyntheticPath(path)) return true;
    return self.fallback.fileExists(path);
}

fn echoReadFileInto(ctx_ptr: ?*anyopaque, _: std.Io, path: []const u8, buf: []u8) Io.ReadError!usize {
    return echoGetCtx(ctx_ptr).fallback.readFileInto(path, buf);
}
fn echoWriteFile(ctx_ptr: ?*anyopaque, _: std.Io, path: []const u8, data: []const u8) Io.WriteError!void {
    return echoGetCtx(ctx_ptr).fallback.writeFile(path, data);
}
fn echoWriteFileStream(ctx_ptr: ?*anyopaque, _: std.Io, path: []const u8, stream: Io.FileStream) Io.WriteError!void {
    return echoGetCtx(ctx_ptr).fallback.writeFileStream(path, stream);
}
fn echoListDirTop(ctx_ptr: ?*anyopaque, _: std.Io, path: []const u8, gpa: Allocator) Io.ListError![]Io.FileEntry {
    return echoGetCtx(ctx_ptr).fallback.listDirTop(path, gpa);
}
fn echoStat(ctx_ptr: ?*anyopaque, _: std.Io, path: []const u8) Io.StatError!Io.FileInfo {
    return echoGetCtx(ctx_ptr).fallback.stat(path);
}
fn echoListDir(ctx_ptr: ?*anyopaque, _: std.Io, path: []const u8, gpa: Allocator) Io.ListError![]Io.FileEntry {
    return echoGetCtx(ctx_ptr).fallback.listDir(path, gpa);
}
fn echoDirName(ctx_ptr: ?*anyopaque, _: std.Io, path: []const u8) ?[]const u8 {
    return echoGetCtx(ctx_ptr).fallback.dirName(path);
}
fn echoBaseName(ctx_ptr: ?*anyopaque, _: std.Io, path: []const u8) []const u8 {
    return echoGetCtx(ctx_ptr).fallback.baseName(path);
}
fn echoJoinPath(ctx_ptr: ?*anyopaque, _: std.Io, parts: []const []const u8, gpa: Allocator) Allocator.Error![]const u8 {
    return echoGetCtx(ctx_ptr).fallback.joinPath(parts, gpa);
}
fn echoCanonicalize(ctx_ptr: ?*anyopaque, _: std.Io, path: []const u8, gpa: Allocator) Io.CanonicalizeError![]const u8 {
    const self = echoGetCtx(ctx_ptr);
    if (self.isSyntheticPath(path)) return gpa.dupe(u8, path);
    return self.fallback.canonicalize(path, gpa);
}
fn echoMakePath(ctx_ptr: ?*anyopaque, _: std.Io, path: []const u8) Io.MakePathError!void {
    return echoGetCtx(ctx_ptr).fallback.makePath(path);
}
fn echoRename(ctx_ptr: ?*anyopaque, _: std.Io, old: []const u8, new: []const u8) Io.RenameError!void {
    return echoGetCtx(ctx_ptr).fallback.rename(old, new);
}
fn echoGetEnvVar(ctx_ptr: ?*anyopaque, _: std.Io, key: []const u8, gpa: Allocator) Io.GetEnvVarError![]u8 {
    return echoGetCtx(ctx_ptr).fallback.getEnvVar(key, gpa);
}
fn echoFetchUrl(ctx_ptr: ?*anyopaque, _: std.Io, gpa: Allocator, url: []const u8, dest: []const u8, max_expanded_bytes: ?u64) Io.FetchUrlError!u64 {
    return echoGetCtx(ctx_ptr).fallback.fetchUrl(gpa, url, dest, max_expanded_bytes);
}
fn echoWriteStdout(ctx_ptr: ?*anyopaque, _: std.Io, data: []const u8) Io.StdioError!void {
    return echoGetCtx(ctx_ptr).fallback.writeStdout(data);
}
fn echoWriteStderr(ctx_ptr: ?*anyopaque, _: std.Io, data: []const u8) Io.StdioError!void {
    return echoGetCtx(ctx_ptr).fallback.writeStderr(data);
}
fn echoReadStdin(ctx_ptr: ?*anyopaque, _: std.Io, buf: []u8) Io.StdioError!usize {
    return echoGetCtx(ctx_ptr).fallback.readStdin(buf);
}
fn echoIsTty(ctx_ptr: ?*anyopaque, _: std.Io) bool {
    return echoGetCtx(ctx_ptr).fallback.isTty();
}
fn echoTerminalWidth(ctx_ptr: ?*anyopaque, _: std.Io) ?u16 {
    return echoGetCtx(ctx_ptr).fallback.terminalWidth();
}
fn echoDeleteFile(ctx_ptr: ?*anyopaque, _: std.Io, path: []const u8) Io.DeleteError!void {
    return echoGetCtx(ctx_ptr).fallback.deleteFile(path);
}
fn echoDeleteDir(ctx_ptr: ?*anyopaque, _: std.Io, path: []const u8) Io.DeleteError!void {
    return echoGetCtx(ctx_ptr).fallback.deleteDir(path);
}
fn echoDeleteTree(ctx_ptr: ?*anyopaque, _: std.Io, path: []const u8) Io.DeleteError!void {
    return echoGetCtx(ctx_ptr).fallback.deleteTree(path);
}
fn echoCreateDir(ctx_ptr: ?*anyopaque, _: std.Io, path: []const u8) Io.MakePathError!void {
    return echoGetCtx(ctx_ptr).fallback.createDir(path);
}
fn echoCopyFile(ctx_ptr: ?*anyopaque, _: std.Io, src: []const u8, dst: []const u8) Io.CopyError!void {
    return echoGetCtx(ctx_ptr).fallback.copyFile(src, dst);
}
fn echoTimestampNow(ctx_ptr: ?*anyopaque, _: std.Io) i128 {
    return echoGetCtx(ctx_ptr).fallback.timestampNow();
}

const echo_vtable = Io.VTable{
    .readFile = &echoReadFile,
    .readFileInto = &echoReadFileInto,
    .writeFile = &echoWriteFile,
    .writeFileStream = &echoWriteFileStream,
    .fileExists = &echoFileExists,
    .stat = &echoStat,
    .listDir = &echoListDir,
    .listDirTop = &echoListDirTop,
    .dirName = &echoDirName,
    .baseName = &echoBaseName,
    .joinPath = &echoJoinPath,
    .canonicalize = &echoCanonicalize,
    .makePath = &echoMakePath,
    .rename = &echoRename,
    .getEnvVar = &echoGetEnvVar,
    .fetchUrl = &echoFetchUrl,
    .deleteFile = &echoDeleteFile,
    .deleteDir = &echoDeleteDir,
    .deleteTree = &echoDeleteTree,
    .createDir = &echoCreateDir,
    .copyFile = &echoCopyFile,
    .timestampNow = &echoTimestampNow,
    .writeStdout = &echoWriteStdout,
    .writeStderr = &echoWriteStderr,
    .readStdin = &echoReadStdin,
    .isTty = &echoIsTty,
    .terminalWidth = &echoTerminalWidth,
};

var builtin_modules: ?eval.BuiltinModules = null;
pub fn persistentBuiltins() !*eval.BuiltinModules {
    if (builtin_modules == null) builtin_modules = try eval.BuiltinModules.init(if (@import("builtin").cpu.arch == .wasm32) std.heap.wasm_allocator else std.heap.page_allocator);
    return &builtin_modules.?;
}

pub var last_cache_stats: compile.CacheStats = .{};

pub var request_cache_stats: compile.CacheStats = .{};

// Finalization evaluates constants for the whole checked graph. Keep their
// observations, then replay only the constants reachable from this output.
// Provenance comes from checked artifacts, never from matching debug messages.
pub const DebugCapture = struct {
    allocator: Allocator,
    events: std.ArrayList(eval.CompileTimeFinalization.ModuleRootEvent) = .empty,
    failed: bool = false,
    pub fn observe(context: *anyopaque, incoming: eval.CompileTimeFinalization.ModuleRootEvent) void {
        const self: *@This() = @ptrCast(@alignCast(context));
        var event = incoming;
        event.message = self.allocator.dupe(u8, incoming.message) catch {
            self.failed = true;
            return;
        };
        self.events.append(self.allocator, event) catch {
            self.failed = true;
        };
    }
    const Item = struct { env: *can.ModuleEnv, def: ?can.CIR.Def.Idx = null, expr: can.CIR.Expr.Idx };
    pub fn replay(self: *@This(), build_env: *BuildEnv, root_name: []const u8) !void {
        try self.replayFrom(build_env, .{ .name = root_name });
    }
    pub fn replayExpression(self: *@This(), build_env: *BuildEnv, expression: can.CIR.Expr.Idx) !void {
        try self.replayFrom(build_env, .{ .expression = expression });
    }
    fn replayFrom(self: *@This(), build_env: *BuildEnv, root: union(enum) { name: []const u8, expression: can.CIR.Expr.Idx }) !void {
        if (self.failed) return error.OutOfMemory;
        if (self.events.items.len == 0) return;
        var temporary = std.heap.ArenaAllocator.init(if (@import("builtin").cpu.arch == .wasm32) std.heap.wasm_allocator else std.heap.page_allocator);
        defer temporary.deinit();
        const a = temporary.allocator();
        const app = build_env.getAppSemanticData() orelse return;
        const modules = try build_env.getCompiledModules(a);
        var pending: std.ArrayList(Item) = .empty;
        var reachable: std.AutoHashMapUnmanaged(Item, void) = .{};
        switch (root) {
            .name => |name| for (app.env.store.sliceDefs(app.env.all_defs)) |idx| {
                const def = app.env.store.getDef(idx);
                const pattern = app.env.store.getPattern(def.pattern);
                if (pattern == .assign and std.mem.eql(u8, app.env.getIdent(pattern.assign.ident), name)) try pending.append(a, .{ .env = app.env, .def = idx, .expr = def.expr });
            },
            .expression => |expr| try pending.append(a, .{ .env = app.env, .expr = expr }),
        }
        while (pending.pop()) |item| {
            if ((try reachable.getOrPut(a, item)).found_existing) continue;
            const env = item.env;
            var pattern_defs: std.AutoHashMapUnmanaged(can.CIR.Pattern.Idx, can.CIR.Def.Idx) = .{};
            var binders: std.ArrayList(can.CIR.Pattern.Idx) = .empty;
            var binder_stack: std.ArrayList(can.CIR.Pattern.Idx) = .empty;
            for (env.store.sliceDefs(env.all_defs)) |idx| {
                binders.clearRetainingCapacity();
                try can.DependencyGraph.appendPatternBinders(env, env.store.getDef(idx).pattern, &binders, &binder_stack, a);
                for (binders.items) |binder| try pattern_defs.put(a, binder, idx);
            }
            const expr = item.expr;
            var references: std.AutoHashMapUnmanaged(can.CIR.Def.Idx, void) = .{};
            var stack: std.ArrayList(can.CIR.Expr.Idx) = .empty;
            var defaults: std.AutoHashMapUnmanaged(can.CIR.Expr.Idx, void) = .{};
            try can.DependencyGraph.collectNameReferences(env, &pattern_defs, expr, &references, &stack, &defaults, a);
            var refs = references.keyIterator();
            while (refs.next()) |def| try pending.append(a, .{ .env = env, .def = def.*, .expr = env.store.getDef(def.*).expr });
            const region = env.store.getExprRegion(expr);
            for (env.store.nodes.items.items(.tag), 0..) |tag, i| {
                if (tag != .expr_external_lookup and tag != .expr_associated_lookup_resolved) continue;
                const occurrence = env.store.regions.items.items[i];
                if (occurrence.start.offset < region.start.offset or occurrence.end.offset > region.end.offset) continue;
                const external = env.store.getExpr(@fromBackingInt(@intCast(i)));
                const identity = switch (external) {
                    .e_lookup_external => |ref| env.moduleIdentityHash(env.importIdentity(ref.module_idx) orelse continue),
                    .e_lookup_associated_resolved => |ref| env.moduleIdentityHash(ref.module_identity),
                    else => continue,
                };
                const target = switch (external) {
                    .e_lookup_external => |ref| ref.target_node_idx,
                    .e_lookup_associated_resolved => |ref| ref.target_node_idx,
                    else => unreachable,
                };
                for (modules) |module| {
                    const owner = module.semantic.env;
                    if (!std.mem.eql(u8, identity, (owner.contentIdentityHash() orelse continue))) continue;
                    for (owner.store.sliceDefs(owner.all_defs)) |def| {
                        const d = owner.store.getDef(def);
                        if (@backingInt(def) == target or @backingInt(d.pattern) == target or @backingInt(d.expr) == target) try pending.append(a, .{ .env = owner, .def = def, .expr = d.expr });
                    }
                }
            }
        }
        for (self.events.items) |event| {
            for (modules) |module| {
                const artifact = module.semantic.checked_artifact orelse continue;
                if (!std.meta.eql(artifact.key, event.module)) continue;
                const env = module.semantic.env;
                var include = false;
                if (event.source) |source| if (source == .def) {
                    include = reachable.contains(.{ .env = env, .def = source.def, .expr = env.store.getDef(source.def).expr });
                };
                if (!include) {
                    const region = event.region orelse if (event.source) |source| switch (source) {
                        .def => env.store.getExprRegion(env.store.getDef(source.def).expr),
                        .expr => |expr| env.store.getExprRegion(expr),
                        .hoisted => |hoisted| env.store.getExprRegion(hoisted.expr),
                        else => continue,
                    } else continue;
                    var it = reachable.keyIterator();
                    while (it.next()) |item| {
                        if (item.env != env) continue;
                        const owner = env.store.getExprRegion(item.expr);
                        if (region.start.offset >= owner.start.offset and region.end.offset <= owner.end.offset) {
                            include = true;
                            break;
                        }
                    }
                }
                if (include) if (echo_platform.observer) |emit| emit("dbg", event.message);
                break;
            }
        }
    }
};

pub var request_frontend_builds: u64 = 0;
pub var request_lowerings: u64 = 0;
pub var request_executions: u64 = 0;
pub var request_prepared_hits: u64 = 0;
pub const RequestStats = struct {
    cache: compile.CacheStats,
    frontend_builds: u64,
    lowerings: u64,
    executions: u64,
    prepared_hits: u64,
    pub fn jsonStringify(self: @This(), w: anytype) !void {
        try w.beginObject();
        inline for (@typeInfo(compile.CacheStats).@"struct".field_names) |name| {
            try w.objectField(name);
            try w.write(@field(self.cache, name));
        }
        inline for (.{ "frontend_builds", "lowerings", "executions", "prepared_hits" }) |name| {
            try w.objectField(name);
            try w.write(@field(self, name));
        }
        try w.endObject();
    }
};
pub fn stats() RequestStats {
    return .{ .cache = request_cache_stats, .frontend_builds = request_frontend_builds, .lowerings = request_lowerings, .executions = request_executions, .prepared_hits = request_prepared_hits };
}

pub const ScratchTypeWriter = @typeInfo(@typeInfo(@TypeOf(can.ModuleEnv.initTypeWriter)).@"fn".return_type.?).error_union.payload;
pub fn scratchTypeWriter(env: *can.ModuleEnv, allocator: Allocator) !ScratchTypeWriter {
    var writer = try ScratchTypeWriter.initFromParts(allocator, &env.types, env.getIdentStore(), null);
    writer.setDefaultSourceResolver(env, can.ModuleEnv.typeWriterDefaultSource);
    return writer;
}
