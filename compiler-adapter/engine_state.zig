//! One compiler engine instance: workspace, retained revision, request counters.
//! A native host may construct several engines in one process; the WASM export
//! layer owns exactly one per worker instance. Builtins are the only shared
//! compiler state (`engine.persistentBuiltins`, immutable once decoded).
const std = @import("std");
const Workspace = @import("workspace.zig").Workspace;
const notebook = @import("notebook.zig");
const runner = @import("engine.zig");
const Baseline = @import("baseline.zig").Baseline;

pub const Engine = struct {
    /// Owns engine-level allocations: native paths and the retained graph.
    gpa: std.mem.Allocator,
    /// Virtual filesystem, compiler artifact store and `packagesRequired`.
    workspace: Workspace,
    /// Synthetic app/platform paths; native sets a real source directory.
    paths: runner.Paths = .{},
    owns_paths: bool = false,
    /// Retained checked and lowered notebook revision.
    revision: ?*notebook.State = null,
    /// Counters reported as `workspaceCache`; zeroed by `beginRequest`.
    stats: runner.RequestStats = .{},
    /// Last confirmed dependency graph, injected into a legacy request's
    /// `reactivity.previous`.
    previous_graph: ?[]u8 = null,
    /// The reactive baseline of participating requests. Outlives revisions.
    baseline: Baseline,

    pub fn init(gpa: std.mem.Allocator, std_io: std.Io) Engine {
        return .{ .gpa = gpa, .workspace = .{ .std_io = std_io }, .baseline = .init(gpa) };
    }

    pub fn deinit(self: *Engine) void {
        if (self.revision) |state| state.destroy();
        if (self.previous_graph) |graph| self.gpa.free(graph);
        self.baseline.deinit();
        if (self.owns_paths) inline for (@typeInfo(runner.Paths).@"struct".field_names) |name| self.gpa.free(@field(self.paths, name));
        self.workspace.deinit();
        self.* = undefined;
    }

    /// Native only: serve a real directory under the synthetic paths.
    pub fn setNativeSourceDirectory(self: *Engine, directory: []const u8) !void {
        std.debug.assert(!self.owns_paths);
        self.workspace.native_files = @import("ctx").CoreCtx.default(self.gpa, self.gpa, self.workspace.std_io);
        var paths: runner.Paths = .{
            .app_abs = try std.fs.path.join(self.gpa, &.{ directory, "Main.roc" }),
            .platform_main = "",
            .echo_module = "",
            .cwd = "",
            .extras_prefix = "",
        };
        errdefer self.gpa.free(paths.app_abs);
        paths.platform_main = try std.fs.path.join(self.gpa, &.{ directory, ".roc_echo_platform/main.roc" });
        errdefer self.gpa.free(paths.platform_main);
        paths.echo_module = try std.fs.path.join(self.gpa, &.{ directory, ".roc_echo_platform/Echo.roc" });
        errdefer self.gpa.free(paths.echo_module);
        paths.cwd = try self.gpa.dupe(u8, directory);
        errdefer self.gpa.free(paths.cwd);
        paths.extras_prefix = try std.mem.concat(self.gpa, u8, &.{ directory, "/" });
        self.paths = paths;
        self.owns_paths = true;
    }

    /// Clear per-request state before dispatching a top-level request.
    pub fn beginRequest(self: *Engine) void {
        self.workspace.clearRequired();
        self.stats = .{};
    }
};
