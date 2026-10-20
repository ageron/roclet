//! Notebook dependency analysis of one checked application module: top-level
//! definitions with types, dependencies and rename-safe references, binders,
//! and whether selective evaluation must fall back to module scope.
//! Computed at most once per retained revision (`notebook.State.analysis`).
const std = @import("std");
const can = @import("can");
const engine = @import("engine.zig");
const A = std.mem.Allocator;

pub const Region = struct { start: u32, end: u32 };
pub const Definition = struct {
    name: []const u8,
    type: []const u8,
    region: Region,
    name_region: Region,
    dependencies: []const []const u8,
    references: []const Region,
    rename_safe: bool,
};
/// `module` when a user definition's dependencies cannot be read reliably from
/// checked CIR (destructuring, nominal declarations, qualified names, ...).
pub const DependencyScope = enum { definitions, module };
/// A top-level `expect` root, with its byte span in the user program.
pub const Expectation = struct { root: []const u8, start: u32, end: u32, cell: u64 = 0 };

pub const Analysis = struct {
    /// User value definitions, then one synthetic `Bool` entry per expectation.
    definitions: []const Definition = &.{},
    binders: []const []const u8 = &.{},
    dependency_scope: DependencyScope = .definitions,
};

/// Analyse the user bytes `[prefix, prefix + user_bytes)` of the checked
/// module. Regions are relative to `prefix`. Everything is allocated in
/// `arena`, which must outlive the result.
pub fn analyze(arena: A, env: *can.ModuleEnv, prefix: u32, user_bytes: u32, expectations: []const Expectation) !Analysis {
    var scope: DependencyScope = .definitions;
    var result_binders: std.ArrayList([]const u8) = .empty;
    var definitions: std.ArrayList(Definition) = .empty;
    const defs = env.store.sliceDefs(env.all_defs);
    var patterns: std.AutoHashMapUnmanaged(can.CIR.Pattern.Idx, can.CIR.Def.Idx) = .{};
    var binders: std.ArrayList(can.CIR.Pattern.Idx) = .empty;
    var binder_stack: std.ArrayList(can.CIR.Pattern.Idx) = .empty;
    for (defs) |idx| {
        binders.clearRetainingCapacity();
        try can.DependencyGraph.appendPatternBinders(env, env.store.getDef(idx).pattern, &binders, &binder_stack, arena);
        for (binders.items) |binder| try patterns.put(arena, binder, idx);
        const d = env.store.getDef(idx);
        const r = env.store.getExprRegion(d.expr);
        if (r.start.offset >= prefix and r.end.offset <= prefix + user_bytes and env.store.getPattern(d.pattern) != .assign) scope = .module;
    }
    const tags = env.store.nodes.items.items(.tag);
    for (tags, 0..) |tag, i| {
        const r = env.store.regions.items.items[i];
        if (r.start.offset < prefix or r.end.offset > prefix + user_bytes) continue;
        // User-defined dispatch/defaults need checked-template dependencies, which
        // this pinned adapter does not expose. Never guess those edges.
        switch (tag) {
            .statement_nominal_decl, .statement_alias_decl, .statement_where_alias_decl, .expr_associated_lookup_local, .expr_associated_lookup_resolved => scope = .module,
            .pattern_identifier, .pattern_var_identifier, .pattern_as => {
                const p = env.store.getPattern(@fromBackingInt(@intCast(i)));
                const ident = switch (p) {
                    .assign => |v| v.ident,
                    .var_assign => |v| v.ident,
                    .as => |v| v.ident,
                    else => unreachable,
                };
                try result_binders.append(arena, try arena.dupe(u8, env.getIdent(ident)));
            },
            else => {},
        }
    }
    var refs: std.AutoHashMapUnmanaged(can.CIR.Def.Idx, void) = .{};
    var stack: std.ArrayList(can.CIR.Expr.Idx) = .empty;
    var defaults: std.AutoHashMapUnmanaged(can.CIR.Expr.Idx, void) = .{};
    for (defs) |idx| {
        const def = env.store.getDef(idx);
        const pattern = env.store.getPattern(def.pattern);
        if (pattern != .assign) continue;
        const name_region = env.store.getPatternRegion(def.pattern);
        const expr_region = env.store.getExprRegion(def.expr);
        if (name_region.start.offset < prefix or expr_region.end.offset > prefix + user_bytes) continue;
        const name = env.getIdent(pattern.assign.ident);
        if (std.mem.findScalar(u8, name, '.') != null) scope = .module;
        refs.clearRetainingCapacity();
        try can.DependencyGraph.collectNameReferences(env, &patterns, def.expr, &refs, &stack, &defaults, arena);
        var deps: std.ArrayList([]const u8) = .empty;
        // Source order is deterministic; references include uncalled lambda bodies.
        for (defs) |other| if (refs.contains(other)) {
            const p = env.store.getPattern(env.store.getDef(other).pattern);
            if (p == .assign) try deps.append(arena, try arena.dupe(u8, env.getIdent(p.assign.ident))) else scope = .module;
        };
        var occurrences: std.ArrayList(Region) = .empty;
        var rename_safe = true;
        for (tags, 0..) |tag, i| {
            if (tag == .expr_var) {
                const e: can.CIR.Expr.Idx = @fromBackingInt(@intCast(i));
                if (env.store.getExpr(e).e_lookup_local.pattern_idx != def.pattern) continue;
                const r = env.store.getExprRegion(e);
                if (r.start.offset < prefix or r.end.offset > prefix + user_bytes) continue;
                if (std.mem.eql(u8, env.common.source[r.start.offset..r.end.offset], name)) {
                    try occurrences.append(arena, .{ .start = r.start.offset - prefix, .end = r.end.offset - prefix });
                } else rename_safe = false;
            } else if (tag == .record_field) {
                const field = env.store.getRecordField(@fromBackingInt(@intCast(i)));
                const e = env.store.getExpr(field.value);
                // A shorthand field also names a public record label. Refuse
                // rename until an explicit shorthand expansion is available.
                if (e == .e_lookup_local and e.e_lookup_local.pattern_idx == def.pattern) rename_safe = false;
            }
        }
        var tw = try engine.scratchTypeWriter(env, arena);
        defer tw.deinit();
        try tw.write(can.ModuleEnv.varFrom(idx), .one_line);
        try definitions.append(arena, .{
            .name = try arena.dupe(u8, name),
            .type = try arena.dupe(u8, tw.get()),
            .region = .{ .start = name_region.start.offset - prefix, .end = expr_region.end.offset - prefix },
            .name_region = .{ .start = name_region.start.offset - prefix, .end = name_region.end.offset - prefix },
            .dependencies = deps.items,
            .references = occurrences.items,
            .rename_safe = rename_safe,
        });
    }
    // Tests are real checked statement roots rather than generated bindings.
    // Expose their resolved references to the same reactive graph as outputs.
    for (expectations) |expectation| {
        for (env.store.sliceStatements(env.all_statements)) |idx| {
            const statement = env.store.getStatement(idx);
            if (statement != .s_expect) continue;
            const region = env.store.getStatementRegion(idx);
            if (region.start.offset < prefix or region.start.offset - prefix < expectation.start or region.start.offset - prefix >= expectation.end) continue;
            refs.clearRetainingCapacity();
            try can.DependencyGraph.collectNameReferences(env, &patterns, statement.s_expect.body, &refs, &stack, &defaults, arena);
            var deps: std.ArrayList([]const u8) = .empty;
            for (defs) |other| if (refs.contains(other)) {
                const pattern = env.store.getPattern(env.store.getDef(other).pattern);
                if (pattern == .assign) try deps.append(arena, try arena.dupe(u8, env.getIdent(pattern.assign.ident))) else scope = .module;
            };
            try definitions.append(arena, .{
                .name = try arena.dupe(u8, expectation.root),
                .type = "Bool",
                .region = .{ .start = expectation.start, .end = expectation.end },
                .name_region = .{ .start = expectation.start, .end = expectation.start },
                .dependencies = deps.items,
                .references = &.{},
                .rename_safe = false,
            });
            break;
        }
    }
    return .{ .definitions = definitions.items, .binders = result_binders.items, .dependency_scope = scope };
}
