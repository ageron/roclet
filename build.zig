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
    const compiler_max_rss = b.option(u64, "compiler-max-rss", "Estimated peak bytes per compiler build for memory-aware scheduling") orelse 0;
    const roc = b.dependency("roc", .{ .target = b.graph.host, .optimize = optimize });
    const native = adapter(b, roc, b.graph.host, optimize, "roclet-native", "compiler-adapter/native.zig");
    native.step.max_rss = compiler_max_rss;
    b.step("native-adapter", "Build only the native engine").dependOn(&native.step);
    const wasm_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const wasm = adapter(b, roc, wasm_target, optimize, "roclet", "compiler-adapter/bridge.zig");
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
    const unit_step = b.step("test-unit", "Test the snapshot protocol and host utilities");
    inline for (.{ "compiler-adapter/snapshot.zig", "compiler-adapter/document.zig", "tools/build-tool.zig", "tools/serve.zig", "tools/package-proxy.zig" }) |file| {
        const tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path(file), .target = b.graph.host }) });
        unit_step.dependOn(&b.addRunArtifact(tests).step);
    }
    const test_exe = b.addExecutable(.{ .name = "roclet-conformance", .root_module = b.createModule(.{
        .root_source_file = b.path("tests/native.zig"),
        .target = b.graph.host,
        .optimize = .small,
    }) });
    const native_tests = b.addRunArtifact(test_exe);
    native_tests.addArg(root);
    native_tests.addFileArg(.{ .relative = .{ .base = .install_bin, .sub_path = "roclet" } });
    native_tests.has_side_effects = true;
    native_tests.step.dependOn(&cli.step);
    // Parity reports include the manifest for the exact native/WASM pair.
    // Installing the native runner alone does not publish that manifest.
    native_tests.step.dependOn(ready);
    const test_step = b.step("test", "Run native conformance and unit tests; generate browser parity cases");
    test_step.dependOn(unit_step);
    test_step.dependOn(&workspace_run.step);
    test_step.dependOn(&fixture_run.step);
    test_step.dependOn(&native_tests.step);
    const document_tests = b.addExecutable(.{ .name = "roclet-document-tests", .root_module = b.createModule(.{
        .root_source_file = b.path("tests/documents.zig"),
        .target = b.graph.host,
        .optimize = .small,
    }) });
    const documents = b.addRunArtifact(document_tests);
    documents.addArg(root);
    documents.addFileArg(.{ .relative = .{ .base = .install_bin, .sub_path = "roclet" } });
    documents.step.dependOn(&cli.step);
    documents.step.dependOn(ready);
    documents.has_side_effects = true;
    b.step("test-documents", "Test document formats and generate WASM parity cases").dependOn(&documents.step);
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
}

fn adapter(b: *std.Build, roc: *std.Build.Dependency, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, name: []const u8, root: []const u8) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{ .name = name, .root_module = b.createModule(.{
        .root_source_file = b.path(root),
        .target = target,
        .optimize = optimize,
        .link_libc = target.result.os.tag != .freestanding,
    }) });
    inline for (.{ "compile", "lir", "eval", "check", "base", "ctx", "builtins", "roc_target", "build_options", "can", "collections", "reporting", "parse", "unbundle" }) |module| exe.root_module.addImport(module, roc.module(module));
    const compiled_builtins = roc.module("eval").import_table.get("compiled_builtins").?;
    exe.root_module.addImport("compiled_builtins", compiled_builtins);
    if (target.result.cpu.arch == .wasm32) exe.root_module.addImport("compressed_builtins", compressedBuiltins(b, roc, compiled_builtins));
    exe.root_module.addCSourceFile(.{ .file = b.path("vendor/md4c/md4c.c"), .flags = &.{ "-std=c99", "-O2" } });
    exe.root_module.addIncludePath(b.path("vendor/md4c"));
    exe.root_module.addAnonymousImport("Display.roc", .{ .root_source_file = b.path("package/Display.roc") });
    exe.root_module.addAnonymousImport("display-package-url.txt", .{ .root_source_file = b.path("package/display-package-url.txt") });
    exe.root_module.addAnonymousImport("Document.roc", .{ .root_source_file = b.path("core/Document.roc") });
    return exe;
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
