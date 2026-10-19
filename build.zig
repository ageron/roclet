const std = @import("std");

pub fn build(b: *std.Build) void {
    const lock = std.json.parseFromSlice(std.json.Value, b.allocator, @embedFile("compiler.lock.json"), .{}) catch @panic("invalid compiler.lock.json");
    const zig_version = lock.value.object.get("zigVersion").?.string;
    if (!std.mem.eql(u8, zig_version, @import("builtin").zig_version_string)) {
        std.debug.panic("Roclet requires Zig {s}; found {s}", .{ zig_version, @import("builtin").zig_version_string });
    }
    const root = b.root.joinString(b.allocator, ".") catch @panic("OOM");
    const source = b.option([]const u8, "roc-source", "Roc checkout containing the pinned compiler commit");
    const jobs = b.option(u32, "compiler-jobs", "Maximum concurrent compiler build jobs") orelse 2;
    const tool = b.addExecutable(.{ .name = "roclet-build", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/build-tool.zig"),
        .target = b.graph.host,
        .optimize = .small,
    }) });
    const prepare = b.addRunArtifact(tool);
    prepare.addArgs(&.{ if (source != null) "prepare" else "check", root });
    prepare.has_side_effects = true;
    var ready: *std.Build.Step = &prepare.step;
    if (source) |checkout| {
        prepare.addArg(if (std.fs.path.isAbsolute(checkout)) checkout else b.root.joinString(b.allocator, checkout) catch @panic("OOM"));
        const compiler = b.addSystemCommand(&.{ b.graph.zig_exe, "build", "roclet-adapter", b.fmt("-Doptimize={s}", .{lock.value.object.get("nativeOptimize").?.string}), b.fmt("-j{d}", .{jobs}) });
        compiler.setCwd(b.path(".toolchain/compiler"));
        compiler.step.dependOn(&prepare.step);
        compiler.has_side_effects = true;
        const publish = b.addRunArtifact(tool);
        publish.addArgs(&.{ "publish", root });
        publish.step.dependOn(&compiler.step);
        publish.has_side_effects = true;
        ready = &publish.step;
    }
    const adapter_step = b.step("adapter", "Build the pinned adapter with -Droc-source, or verify existing artifacts");
    adapter_step.dependOn(ready);
    const cli = b.addInstallBinFile(b.path("artifacts/roclet-native"), "roclet");
    cli.step.dependOn(ready);
    b.getInstallStep().dependOn(&cli.step);
    const run = std.Build.Step.Run.create(b, "run Roclet");
    run.addFileArg(.{ .relative = .{ .base = .install_bin, .sub_path = "roclet" } });
    run.step.dependOn(&cli.step);
    run.addPassthruArgs();
    run.has_side_effects = true;
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

    const unit_step = b.step("test-unit", "Test the snapshot protocol and compiler-overlay safeguards");
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
