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
    const roc = b.dependency("roc", .{ .target = b.graph.host, .optimize = optimize });
    const native = adapter(b, roc, b.graph.host, optimize, "roclet-native", "compiler-adapter/native.zig");
    const wasm_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const wasm = adapter(b, roc, wasm_target, optimize, "roclet", "compiler-adapter/bridge.zig");
    wasm.entry = .disabled;
    wasm.rdynamic = true;
    wasm.stack_size = 8 * 1024 * 1024;
    const publish = b.addSystemCommand(&.{ b.graph.zig_exe, "run", "tools/build-tool.zig", "--", "publish", root });
    publish.addFileArg(native.getEmittedBin());
    publish.addFileArg(wasm.getEmittedBin());
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

    const unit_step = b.step("test-unit", "Test the snapshot protocol and host utilities");
    inline for (.{ "compiler-adapter/snapshot.zig", "tools/build-tool.zig", "tools/serve.zig" }) |file| {
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
    const test_step = b.step("test", "Run native conformance and unit tests; generate browser parity cases");
    test_step.dependOn(unit_step);
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
    exe.root_module.addImport("compiled_builtins", roc.module("eval").import_table.get("compiled_builtins").?);
    exe.root_module.addCSourceFile(.{ .file = b.path("vendor/md4c/md4c.c"), .flags = &.{ "-std=c99", "-O2" } });
    exe.root_module.addIncludePath(b.path("vendor/md4c"));
    exe.root_module.addAnonymousImport("Display.roc", .{ .root_source_file = b.path("library/Display.roc") });
    exe.root_module.addAnonymousImport("Document.roc", .{ .root_source_file = b.path("core/Document.roc") });
    return exe;
}
