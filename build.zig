const std = @import("std");

pub fn build(b: *std.Build) void {
    const lock = std.json.parseFromSlice(std.json.Value, b.allocator, @embedFile("compiler.lock.json"), .{}) catch @panic("invalid compiler.lock.json");
    const zig_version = lock.value.object.get("zigVersion").?.string;
    if (!std.mem.eql(u8, zig_version, @import("builtin").zig_version_string)) {
        std.debug.panic("Roclet requires Zig {s}; found {s}", .{ zig_version, @import("builtin").zig_version_string });
    }
    const root = b.root.joinString(b.allocator, ".") catch @panic("OOM");
    _ = b.option([]const u8, "roc-source", "Deprecated: use the roc path dependency in build.zig.zon");
    _ = b.option(u32, "compiler-jobs", "Deprecated: use zig build -j");
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Optimization mode (default ReleaseFast)") orelse .fast;
    // Zig's self-hosted backend builds the native adapter in seconds instead of
    // minutes, but the result runs several times slower. Use -Dllvm=false for
    // local iteration; release artifacts and CI keep the default (LLVM).
    const use_llvm = b.option(bool, "llvm", "Use LLVM for the native and WASM adapters (default: Zig's choice, LLVM for release modes)");
    const compiler_max_rss = b.option(u64, "compiler-max-rss", "Estimated peak bytes per compiler build for memory-aware scheduling") orelse 0;
    const roc = b.dependency("roc", .{ .target = b.graph.host, .optimize = optimize });
    const option_values = b.addOptions();
    option_values.addOption(?u64, "image_initial_bytes", b.option(u64, "image-initial-bytes", "First LIR image buffer size, a power of two (default 1 MiB WASM, 64 MiB native)"));
    const options = option_values.createModule();
    const native = adapter(b, roc, options, b.graph.host, optimize, "roclet-native", "compiler-adapter/native.zig");
    native.use_llvm = use_llvm;
    native.step.max_rss = compiler_max_rss;
    b.step("native-adapter", "Build only the native engine").dependOn(&native.step);
    const wasm_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const wasm = adapter(b, roc, options, wasm_target, optimize, "roclet", "compiler-adapter/bridge.zig");
    wasm.use_llvm = use_llvm;
    wasm.step.max_rss = compiler_max_rss;
    b.step("wasm-adapter", "Build only the browser engine").dependOn(&wasm.step);
    wasm.entry = .disabled;
    wasm.rdynamic = true;
    wasm.stack_size = 8 * 1024 * 1024;
    const publish = b.addSystemCommand(&.{ b.graph.zig_exe, "run", "tools/build-tool.zig", "--", "publish", root });
    publish.addFileArg(native.getEmittedBin());
    publish.addFileArg(wasm.getEmittedBin());
    publish.addArg(switch (optimize) {
        .debug => "Debug",
        .safe => "ReleaseSafe",
        .fast => "ReleaseFast",
        .small => "ReleaseSmall",
    });
    publish.has_side_effects = true;
    const ready = &publish.step;
    b.step("adapter", "Build native and browser compiler workspace engines").dependOn(ready);
    const cli = b.addInstallArtifact(native, .{ .dest_sub_path = "roclet" });
    b.getInstallStep().dependOn(&cli.step);
    const run = b.addRunArtifact(native);
    run.addPassthruArgs();
    b.step("run", "Run the native CLI; arguments follow --").dependOn(&run.step);

    const server = b.addExecutable(.{ .name = "roclet-serve", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/serve.zig"),
        .target = b.graph.host,
        .optimize = .small,
    }) });
    b.installArtifact(server);
    const serve = b.addRunArtifact(server);
    serve.addArg(root);
    serve.addPassthruArgs();
    serve.step.dependOn(ready);
    b.step("serve", "Serve Roclet on localhost (optional port after --)").dependOn(&serve.step);

    const packager = b.addExecutable(.{ .name = "roclet-package", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/package.zig"),
        .target = b.graph.host,
        .optimize = .small,
    }) });
    const offline = b.addRunArtifact(packager);
    offline.addArg(root);
    offline.step.dependOn(ready);
    offline.has_side_effects = true;
    b.getInstallStep().dependOn(&offline.step);
    const package = b.addRunArtifact(packager);
    package.addArgs(&.{ root, "package" });
    package.step.dependOn(b.getInstallStep());
    package.has_side_effects = true;
    b.step("package", "Package the verified offline Roclet and host-platform headless runner").dependOn(&package.step);
    serve.step.dependOn(&offline.step);

    const demo_tests = b.addExecutable(.{ .name = "roclet-runnable-demos", .root_module = b.createModule(.{
        .root_source_file = b.path("tests/runnable-demos.zig"),
        .target = b.graph.host,
        .optimize = .small,
    }) });
    const demos = b.addRunArtifact(demo_tests);
    demos.addArgs(&.{ root, b.option([]const u8, "roc", "Ordinary Roc executable for demo tests") orelse "roc" });
    demos.has_side_effects = true;
    b.step("test-demos", "Run published demos with ordinary Roc and the local Display package").dependOn(&demos.step);

    const workspace_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("compiler-adapter/workspace.zig"), .target = b.graph.host, .optimize = .safe, .link_libc = true }) });
    inline for (.{ "ctx", "unbundle", "build_options" }) |module| workspace_tests.root_module.addImport(module, roc.module(module));
    const workspace_run = b.addRunArtifact(workspace_tests);
    b.step("test-workspace", "Verify compiler artifact persistence and package extraction").dependOn(&workspace_run.step);
    const fixture_tool = b.addExecutable(.{ .name = "roclet-package-fixture", .root_module = b.createModule(.{ .root_source_file = b.path("tools/package-fixture.zig"), .target = b.graph.host, .optimize = .small }) });
    const fixture_run = b.addRunArtifact(fixture_tool);
    fixture_run.setCwd(b.path("."));
    fixture_run.has_side_effects = true;
    b.step("package-fixture", "Write a verified local package for browser integration tests").dependOn(&fixture_run.step);
    const unit_step = b.step("test-unit", "Test the document layer and host utilities");
    inline for (.{ "tools/build-tool.zig", "tools/serve.zig", "tools/package-proxy.zig" }) |file| {
        const tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path(file), .target = b.graph.host }) });
        unit_step.dependOn(&b.addRunArtifact(tests).step);
    }
    const image_tests = b.addTest(.{ .use_llvm = use_llvm, .root_module = adapterModule(b, roc, options, b.graph.host, optimize, "compiler-adapter/image.zig") });
    unit_step.dependOn(&b.addRunArtifact(image_tests).step);
    // The document layer calls the engine's typed API.
    const document_unit_tests = b.addTest(.{ .use_llvm = use_llvm, .root_module = adapterModule(b, roc, options, b.graph.host, optimize, "compiler-adapter/document.zig") });
    unit_step.dependOn(&b.addRunArtifact(document_unit_tests).step);
    const test_step = b.step("test", "Run native conformance and unit tests; generate browser parity cases");
    test_step.dependOn(unit_step);
    test_step.dependOn(&workspace_run.step);
    test_step.dependOn(&fixture_run.step);
    const document_tests = b.addExecutable(.{ .name = "roclet-document-tests", .root_module = b.createModule(.{
        .root_source_file = b.path("tests/documents.zig"),
        .target = b.graph.host,
        .optimize = .small,
    }) });
    const documents = b.addRunArtifact(document_tests);
    documents.addArg(root);
    documents.addFileArg(.{ .relative = .{ .base = .install_bin, .sub_path = "roclet" } });
    documents.step.dependOn(&cli.step);
    // Parity cases record the manifest for this exact native/WASM pair.
    documents.step.dependOn(ready);
    documents.has_side_effects = true;
    test_step.dependOn(&documents.step);
    const m4 = b.addExecutable(.{ .name = "roclet-m4-tests", .root_module = b.createModule(.{
        .root_source_file = b.path("tests/m4.zig"),
        .target = b.graph.host,
        .optimize = .small,
    }) });
    const m4_tests = b.addRunArtifact(m4);
    m4_tests.addArg(root);
    m4_tests.addFileArg(.{ .relative = .{ .base = .install_bin, .sub_path = "roclet" } });
    m4_tests.step.dependOn(&cli.step);
    m4_tests.step.dependOn(ready);
    m4_tests.has_side_effects = true;
    b.step("test-m4", "Check selective evaluation against full recomputation").dependOn(&m4_tests.step);
    test_step.dependOn(&m4_tests.step);
    // The wire shape pin covers every request and result both suites record.
    const protocol_shape = b.addRunArtifact(document_tests);
    protocol_shape.addArgs(&.{ root, "--protocol-shape" });
    if (b.option(bool, "update-protocol-shape", "Rewrite tests/protocol-shape.json from the recorded document and M4 cases") orelse false) protocol_shape.addArg("--update");
    protocol_shape.step.dependOn(&documents.step);
    protocol_shape.step.dependOn(&m4_tests.step);
    protocol_shape.has_side_effects = true;
    test_step.dependOn(&protocol_shape.step);
    const documents_step = b.step("test-documents", "Test document formats, generate WASM parity cases and check the pinned wire shape");
    documents_step.dependOn(&documents.step);
    documents_step.dependOn(&protocol_shape.step);
    const engine_tests = b.addTest(.{ .use_llvm = use_llvm, .root_module = b.createModule(.{
        .root_source_file = b.path("tests/engine.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "bridge", .module = adapterModule(b, roc, options, b.graph.host, optimize, "compiler-adapter/bridge.zig") },
            .{ .name = "roclet_options", .module = options },
        },
    }) });
    const engine_run = b.addRunArtifact(engine_tests);
    b.step("test-engine", "Run in-process engine tests (several engines, attribution, request state)").dependOn(&engine_run.step);
    test_step.dependOn(&engine_run.step);

    // Code checks borrowed from the Roc compiler's CI (ci/tidy.zig, ci/zig_lints.zig).
    // `zig build check` runs them all; `zig build test` depends on it so CI runs them too.
    const check_step = b.step("check", "Check Zig formatting, tidy rules, lints, and dead Zig files");
    const zig_format = b.addFmt(.{ .paths = &.{ b.path("build.zig"), b.path("compiler-adapter"), b.path("tools"), b.path("tests"), b.path("ci") }, .check = true });
    b.step("run-check-zig-format", "Check Zig formatting (zig fmt --check)").dependOn(&zig_format.step);
    check_step.dependOn(&zig_format.step);
    const tidy = b.addExecutable(.{ .name = "tidy", .root_module = b.createModule(.{ .root_source_file = b.path("ci/tidy.zig"), .target = b.graph.host, .optimize = .debug }) });
    const run_tidy = b.addRunArtifact(tidy);
    run_tidy.setCwd(b.path("."));
    run_tidy.has_side_effects = true;
    b.step("run-check-tidy", "Run code tidiness checks over every tracked file").dependOn(&run_tidy.step);
    check_step.dependOn(&run_tidy.step);
    const run_git_lints = b.addRunArtifact(tidy);
    run_git_lints.addArg("--git-lints");
    run_git_lints.setCwd(b.path("."));
    run_git_lints.has_side_effects = true;
    b.step("run-check-git-lints", "Report tracked Zig files that nothing imports or builds").dependOn(&run_git_lints.step);
    check_step.dependOn(&run_git_lints.step);
    const zig_lints = b.addExecutable(.{ .name = "zig_lints", .root_module = b.createModule(.{ .root_source_file = b.path("ci/zig_lints.zig"), .target = b.graph.host, .optimize = .debug }) });
    const run_zig_lints = b.addRunArtifact(zig_lints);
    run_zig_lints.setCwd(b.path("."));
    run_zig_lints.has_side_effects = true;
    b.step("run-check-zig-lints", "Run Zig source lints").dependOn(&run_zig_lints.step);
    check_step.dependOn(&run_zig_lints.step);
    const globals = b.addExecutable(.{ .name = "globals", .root_module = b.createModule(.{ .root_source_file = b.path("ci/globals.zig"), .target = b.graph.host, .optimize = .debug }) });
    const run_globals = b.addRunArtifact(globals);
    run_globals.setCwd(b.path("."));
    run_globals.has_side_effects = true;
    b.step("check-globals", "Allow only the documented module-level variables in compiler-adapter").dependOn(&run_globals.step);
    check_step.dependOn(&run_globals.step);
    inline for (.{ "ci/tidy.zig", "ci/zig_lints.zig", "ci/globals.zig" }) |file| {
        const tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path(file), .target = b.graph.host }) });
        check_step.dependOn(&b.addRunArtifact(tests).step);
    }
    test_step.dependOn(check_step);
}

fn adapter(b: *std.Build, roc: *std.Build.Dependency, options: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, name: []const u8, root: []const u8) *std.Build.Step.Compile {
    return b.addExecutable(.{ .name = name, .root_module = adapterModule(b, roc, options, target, optimize, root) });
}

/// A module rooted in compiler-adapter/ with the compiler modules, builtins,
/// md4c, embedded package files and Roclet build options the adapter imports.
fn adapterModule(b: *std.Build, roc: *std.Build.Dependency, options: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, root: []const u8) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = b.path(root),
        .target = target,
        .optimize = optimize,
        .link_libc = target.result.os.tag != .freestanding,
    });
    inline for (.{ "compile", "lir", "eval", "check", "base", "ctx", "builtins", "roc_target", "build_options", "can", "collections", "reporting", "parse", "unbundle" }) |name| module.addImport(name, roc.module(name));
    const compiled_builtins = roc.module("eval").import_table.get("compiled_builtins").?;
    module.addImport("compiled_builtins", compiled_builtins);
    if (target.result.cpu.arch == .wasm32) module.addImport("compressed_builtins", compressedBuiltins(b, roc, compiled_builtins));
    module.addCSourceFile(.{ .file = b.path("vendor/md4c/md4c.c"), .flags = &.{ "-std=c99", "-O2" } });
    module.addIncludePath(b.path("vendor/md4c"));
    module.addAnonymousImport("Display.roc", .{ .root_source_file = b.path("package/Display.roc") });
    module.addAnonymousImport("display-package-url.txt", .{ .root_source_file = b.path("package/display-package-url.txt") });
    module.addImport("roclet_options", options);
    return module;
}

fn compressedBuiltins(b: *std.Build, roc: *std.Build.Dependency, builtins: *std.Build.Module) *std.Build.Module {
    const compressor = b.addExecutable(.{ .name = "roclet-compress-builtins", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/compress-builtins.zig"),
        .target = b.graph.host,
        .optimize = .fast,
        .link_libc = true,
    }) });
    const zstd = roc.builder.dependency("zstd", .{ .target = b.graph.host, .optimize = .fast });
    compressor.root_module.linkLibrary(zstd.artifact("zstd"));
    const files = b.addWriteFiles();
    b.step("compress-builtins", "Prepare compressed builtin images for the browser compiler").dependOn(&files.step);
    const dir = builtins.root_source_file.?.dirname();
    for ([_][]const u8{ "Builtin.bin", "Builtin.roc", "Builtin.artifact.bin" }) |name| {
        const run = b.addRunArtifact(compressor);
        run.addFileArg(dir.path(b, name));
        const compressed_name = b.fmt("{s}.zst", .{name});
        const frame = run.addOutputFileArg(compressed_name);
        _ = files.addCopyFile(frame, compressed_name);
    }
    return b.createModule(.{ .root_source_file = files.add("compressed_builtins.zig",
        \\pub const builtin_bin = @embedFile("Builtin.bin.zst");
        \\pub const builtin_source = @embedFile("Builtin.roc.zst");
        \\pub const builtin_artifact_bin = @embedFile("Builtin.artifact.bin.zst");
        \\
    ) });
}
