//! Notebook dependency analysis of one checked application module: top-level
//! definitions with types, dependencies and rename-safe references, binders,
//! the checked dependency graph (value, type and module nodes with
//! fingerprints), and whether selective evaluation must fall back to module
//! scope. Computed at most once per retained revision (`notebook.State.analysis`).
const std = @import("std");
const base = @import("base");
const can = @import("can");
const engine = @import("engine.zig");
const frontend = @import("document_frontend.zig");
const syntax = @import("syntax.zig");
const hashField = @import("workspace.zig").hashField;
const A = std.mem.Allocator;
const CIR = can.CIR;
const Sha256 = std.crypto.hash.sha2.Sha256;

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

/// The checked dependency graph of the user program (graph version 2,
/// `document_frontend.Graph`) without the request context.
pub const Graph = struct {
    /// User definitions in source order, then one node per expectation.
    definitions: []const frontend.Node = &.{},
    /// Local type declarations in source order.
    types: []const frontend.Node = &.{},
    /// Imported modules a node refers to, by name.
    modules: []const frontend.Node = &.{},
    /// SHA-256 hex of the user program's parser tokens outside every node.
    context: []const u8 = "",
};

pub const Analysis = struct {
    /// User value definitions, then one synthetic `Bool` entry per expectation.
    definitions: []const Definition = &.{},
    binders: []const []const u8 = &.{},
    dependency_scope: DependencyScope = .definitions,
    graph: Graph = .{},
};

/// What a node's own CIR (every checked node inside its source span, nested
/// nodes excepted) refers to.
const Facts = struct {
    values: std.AutoArrayHashMapUnmanaged(CIR.Def.Idx, void) = .empty,
    types: std.AutoArrayHashMapUnmanaged(CIR.Statement.Idx, void) = .empty,
    imports: std.AutoArrayHashMapUnmanaged(CIR.Import.Idx, void) = .empty,
    identities: std.AutoArrayHashMapUnmanaged(base.ModuleIdentity.Idx, void) = .empty,
    /// A reference whose import resolution never settled.
    pending: bool = false,
};
/// A graph node's source span (absolute offsets) and its facts slot.
const Owner = struct { start: u32, end: u32, slot: usize };

fn inside(region: base.Region, start: u32, end: u32) bool {
    return region.start.offset >= start and region.end.offset <= end;
}

/// Record what checked node `i` refers to.
fn collect(a: A, env: *can.ModuleEnv, tag: can.CIR.Node.Tag, i: usize, patterns: *const std.AutoHashMapUnmanaged(CIR.Pattern.Idx, CIR.Def.Idx), facts: *Facts) !void {
    switch (tag) {
        .expr_var, .expr_external_lookup, .expr_nominal, .expr_nominal_external, .expr_associated_lookup_local, .expr_associated_lookup, .expr_associated_lookup_resolved, .expr_type_method_call, .expr_type_dispatch_call, .expr_type_dispatch_call_dispatcher, .expr_derived_method, .expr_deferred_import_ref, .expr_deferred_nominal_external => {
            switch (env.store.getExpr(@fromBackingInt(@intCast(i)))) {
                .e_lookup_local => |e| if (patterns.get(e.pattern_idx)) |def| try facts.values.put(a, def, {}),
                .e_lookup_external => |e| try facts.imports.put(a, e.module_idx, {}),
                .e_nominal => |e| try facts.types.put(a, e.nominal_type_decl, {}),
                .e_nominal_external => |e| try facts.imports.put(a, e.module_idx, {}),
                .e_lookup_associated_local => |e| try facts.types.put(a, @fromBackingInt(e.type_node_idx), {}),
                .e_lookup_associated => |e| try facts.imports.put(a, e.module_idx, {}),
                .e_lookup_associated_resolved => |e| if (e.module_identity == env.self_module_identity) {
                    try facts.values.put(a, e.target_def_idx, {});
                } else try facts.identities.put(a, e.module_identity, {}),
                .e_type_method_call => |e| try facts.types.put(a, e.type_dispatch_stmt, {}),
                .e_type_dispatch_call => |e| switch (e.owner) {
                    .statement => |statement| try facts.types.put(a, statement, {}),
                    .dispatcher => {},
                },
                .e_derived_method => |e| try facts.types.put(a, e.owner, {}),
                .e_deferred_import_ref => facts.pending = true,
                else => {},
            }
        },
        .ty_apply, .ty_apply_external, .ty_lookup, .ty_lookup_external => {
            const reference: CIR.TypeAnno.LocalOrExternal = switch (env.store.getTypeAnno(@fromBackingInt(@intCast(i)))) {
                .apply => |t| t.base,
                .lookup => |t| t.base,
                else => return,
            };
            switch (reference) {
                .builtin => {},
                .local => |t| try facts.types.put(a, t.decl_idx, {}),
                .external => |t| try facts.imports.put(a, t.module_idx, {}),
                .external_identity => |t| try facts.identities.put(a, t.module_identity, {}),
                .pending => facts.pending = true,
            }
        },
        .pattern_nominal, .pattern_nominal_external, .pattern_deferred_import_ref => switch (env.store.getPattern(@fromBackingInt(@intCast(i)))) {
            .nominal => |p| try facts.types.put(a, p.nominal_type_decl, {}),
            .nominal_external => |p| try facts.imports.put(a, p.module_idx, {}),
            .deferred_import_ref => facts.pending = true,
            else => {},
        },
        else => {},
    }
}

/// The slot of the innermost owner whose span holds `[start, end)`. Owners
/// are sorted by start, longer spans first, and properly nested.
fn ownerOf(owners: []const Owner, start: u32, end: u32) ?usize {
    var k = std.sort.partitionPoint(Owner, owners, start, struct {
        fn before(offset: u32, owner: Owner) bool {
            return owner.start <= offset;
        }
    }.before);
    while (k > 0) : (k -= 1) {
        const owner = owners[k - 1];
        if (end <= owner.end) return owner.slot;
    }
    return null;
}
fn hex(a: A, hash: *Sha256) ![]const u8 {
    var bytes: [32]u8 = undefined;
    hash.final(&bytes);
    return a.dupe(u8, &std.fmt.bytesToHex(bytes, .lower));
}

/// Analyse the user bytes `[prefix, prefix + user_bytes)` of the checked
/// module. Regions are relative to `prefix`. Everything is allocated in
/// `arena`, which must outlive the result.
pub fn analyze(arena: A, env: *can.ModuleEnv, prefix: u32, user_bytes: u32, expectations: []const Expectation) !Analysis {
    const user_end = prefix + user_bytes;
    const program = env.common.source[prefix..user_end];
    var scope: DependencyScope = .definitions;
    var result_binders: std.ArrayList([]const u8) = .empty;
    var definitions: std.ArrayList(Definition) = .empty;
    const defs = env.store.sliceDefs(env.all_defs);
    var patterns: std.AutoHashMapUnmanaged(CIR.Pattern.Idx, CIR.Def.Idx) = .{};
    var binders: std.ArrayList(CIR.Pattern.Idx) = .empty;
    var binder_stack: std.ArrayList(CIR.Pattern.Idx) = .empty;
    for (defs) |idx| {
        binders.clearRetainingCapacity();
        try can.DependencyGraph.appendPatternBinders(env, env.store.getDef(idx).pattern, &binders, &binder_stack, arena);
        for (binders.items) |binder| try patterns.put(arena, binder, idx);
        const d = env.store.getDef(idx);
        const r = env.store.getExprRegion(d.expr);
        if (r.start.offset >= prefix and r.end.offset <= user_end and env.store.getPattern(d.pattern) != .assign) scope = .module;
    }
    const tags = env.store.nodes.items.items(.tag);
    for (tags, 0..) |tag, i| {
        const r = env.store.regions.items.items[i];
        if (r.start.offset < prefix or r.end.offset > user_end) continue;
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

    // Graph nodes: user definitions, expectations and local type declarations,
    // each owning the checked nodes inside its source span.
    var owners: std.ArrayList(Owner) = .empty;
    var node_defs: std.AutoArrayHashMapUnmanaged(CIR.Def.Idx, usize) = .empty;
    var nodes: std.ArrayList(frontend.Node) = .empty;
    var node_types: std.ArrayList([]const u8) = .empty;
    for (defs) |idx| {
        const def = env.store.getDef(idx);
        const pattern_region = env.store.getPatternRegion(def.pattern);
        const expr_region = env.store.getExprRegion(def.expr);
        if (pattern_region.start.offset < prefix or expr_region.end.offset > user_end) continue;
        binders.clearRetainingCapacity();
        try can.DependencyGraph.appendPatternBinders(env, def.pattern, &binders, &binder_stack, arena);
        if (binders.items.len == 0) continue;
        std.mem.sort(CIR.Pattern.Idx, binders.items, env, struct {
            fn less(e: *can.ModuleEnv, x: CIR.Pattern.Idx, y: CIR.Pattern.Idx) bool {
                return e.store.getPatternRegion(x).start.offset < e.store.getPatternRegion(y).start.offset;
            }
        }.less);
        const names = try arena.alloc([]const u8, binders.items.len);
        for (names, binders.items) |*name, binder| name.* = try nodeName(arena, env, binderIdent(env, binder));
        var start = pattern_region.start.offset;
        if (def.annotation) |annotation| {
            const anno_region = env.store.getAnnotationRegion(annotation);
            if (anno_region.start.offset >= prefix and anno_region.start.offset < start) start = anno_region.start.offset;
            if (env.store.getAnnotation(annotation).name_region) |name_region| {
                if (name_region.start.offset >= prefix and name_region.start.offset < start) start = name_region.start.offset;
            }
        }
        const end = expr_region.end.offset;
        try node_defs.put(arena, idx, nodes.items.len);
        try owners.append(arena, .{ .start = start, .end = end, .slot = nodes.items.len });
        var tw = try engine.scratchTypeWriter(env, arena);
        defer tw.deinit();
        try tw.write(can.ModuleEnv.varFrom(idx), .one_line);
        try nodes.append(arena, .{ .name = names[0], .binders = names, .fingerprint = "" });
        try node_types.append(arena, try arena.dupe(u8, tw.get()));
    }
    const expectation_slot = nodes.items.len;
    for (expectations) |expectation| {
        try owners.append(arena, .{ .start = prefix + expectation.start, .end = prefix + expectation.end, .slot = nodes.items.len });
        try nodes.append(arena, .{ .name = expectation.root, .binders = try arena.dupe([]const u8, &.{expectation.root}), .fingerprint = "" });
        try node_types.append(arena, "Bool");
    }
    const type_slot = nodes.items.len;
    var type_decls: std.AutoArrayHashMapUnmanaged(CIR.Statement.Idx, usize) = .empty;
    for (env.store.sliceStatements(env.type_decls)) |statement| {
        const region = env.store.getStatementRegion(statement);
        if (!inside(region, prefix, user_end)) continue;
        const header = switch (env.store.getStatement(statement)) {
            .s_alias_decl => |s| s.header,
            .s_nominal_decl => |s| s.header,
            .s_where_alias_decl => |s| s.header,
            else => continue,
        };
        const type_header = env.store.getTypeHeader(header);
        try type_decls.put(arena, statement, nodes.items.len);
        try owners.append(arena, .{ .start = region.start.offset, .end = region.end.offset, .slot = nodes.items.len });
        const name = try arena.dupe(u8, env.getIdent(type_header.relative_name));
        try nodes.append(arena, .{ .name = name, .fingerprint = "" });
        try node_types.append(arena, "");
    }

    // Attribute every checked user node to the innermost node span holding it.
    std.mem.sort(Owner, owners.items, {}, struct {
        fn less(_: void, x: Owner, y: Owner) bool {
            return if (x.start != y.start) x.start < y.start else x.end > y.end;
        }
    }.less);
    const facts = try arena.alloc(Facts, nodes.items.len);
    @memset(facts, .{});
    for (tags, 0..) |tag, i| {
        const r = env.store.regions.items.items[i];
        if (r.start.offset < prefix or r.end.offset > user_end) continue;
        if (ownerOf(owners.items, r.start.offset, r.end.offset)) |slot| try collect(arena, env, tag, i, &patterns, &facts[slot]);
    }

    // Module nodes: the content identity of every module a node refers to.
    var module_names: std.AutoArrayHashMapUnmanaged(base.ModuleIdentity.Idx, []const u8) = .empty;
    var modules: std.StringArrayHashMapUnmanaged(std.ArrayList(u8)) = .empty;
    for (facts) |*f| {
        for (f.imports.keys()) |import| if (env.importIdentity(import)) |identity| {
            try f.identities.put(arena, identity, {});
        };
        for (f.identities.keys()) |identity| {
            if (identity == env.self_module_identity or module_names.contains(identity)) continue;
            const name = try std.mem.concat(arena, u8, &.{ "module:", env.moduleIdentityDisplayText(identity) });
            try module_names.put(arena, identity, name);
            const slot = try modules.getOrPut(arena, name);
            if (!slot.found_existing) slot.value_ptr.* = .empty;
            try slot.value_ptr.appendSlice(arena, &std.fmt.bytesToHex(env.moduleIdentityHash(identity).*, .lower));
        }
        if (f.pending) scope = .module;
    }
    const sorted_modules = try arena.dupe([]const u8, modules.keys());
    std.mem.sort([]const u8, sorted_modules, {}, struct {
        fn less(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.less);
    const module_nodes = try arena.alloc(frontend.Node, sorted_modules.len);
    for (module_nodes, sorted_modules) |*out, name| out.* = .{ .name = name, .fingerprint = modules.get(name).?.items };

    var refs: std.AutoHashMapUnmanaged(CIR.Def.Idx, void) = .{};
    var stack: std.ArrayList(CIR.Expr.Idx) = .empty;
    var defaults: std.AutoHashMapUnmanaged(CIR.Expr.Idx, void) = .{};
    for (defs) |idx| {
        const def = env.store.getDef(idx);
        const pattern = env.store.getPattern(def.pattern);
        if (pattern != .assign) continue;
        const name_region = env.store.getPatternRegion(def.pattern);
        const expr_region = env.store.getExprRegion(def.expr);
        if (name_region.start.offset < prefix or expr_region.end.offset > user_end) continue;
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
        if (node_defs.get(idx)) |slot| try setDependencies(arena, &nodes.items[slot], refs, defs, &node_defs, nodes.items, &facts[slot], &type_decls, &module_names);
        var occurrences: std.ArrayList(Region) = .empty;
        var rename_safe = true;
        for (tags, 0..) |tag, i| {
            if (tag == .expr_var) {
                const e: CIR.Expr.Idx = @fromBackingInt(@intCast(i));
                if (env.store.getExpr(e).e_lookup_local.pattern_idx != def.pattern) continue;
                const r = env.store.getExprRegion(e);
                if (r.start.offset < prefix or r.end.offset > user_end) continue;
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
    for (expectations, 0..) |expectation, e| {
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
            const slot = expectation_slot + e;
            try setDependencies(arena, &nodes.items[slot], refs, defs, &node_defs, nodes.items, &facts[slot], &type_decls, &module_names);
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
    // A type depends on what its declaration refers to and on every
    // associated item declared under it.
    for (type_slot..nodes.items.len) |slot| {
        refs.clearRetainingCapacity();
        try setDependencies(arena, &nodes.items[slot], refs, defs, &node_defs, nodes.items, &facts[slot], &type_decls, &module_names);
        var deps: std.ArrayList([]const u8) = .empty;
        try deps.appendSlice(arena, nodes.items[slot].dependencies);
        const type_name = nodes.items[slot].name;
        for (nodes.items[0..expectation_slot]) |item| if (associated(type_name, item.name)) try appendNew(arena, &deps, item.name);
        for (nodes.items[type_slot..]) |nested| if (associated(type_name, nested.name)) try appendNew(arena, &deps, nested.name);
        nodes.items[slot].dependencies = deps.items;
    }
    // Fingerprints: the parser tokens a node owns (tag and text, never
    // offsets, so comments and whitespace do not count) and, for a value or
    // expectation, its inferred type. Unowned tokens are the context.
    const hashes = try arena.alloc(Sha256, nodes.items.len);
    for (hashes, 0..) |*hash, slot| {
        hash.* = .init(.{});
        hashField(hash, if (slot < type_slot) "roclet-def-v2" else "roclet-type-v2");
    }
    var context = Sha256.init(.{});
    hashField(&context, "roclet-context-v2");
    for ((try syntax.roc(arena, program)).tokens) |token| {
        const start: u32 = @intCast(token.start);
        const end: u32 = @intCast(token.end);
        const hash = if (ownerOf(owners.items, prefix + start, prefix + end)) |slot| &hashes[slot] else &context;
        hashField(hash, token.tag);
        hashField(hash, program[start..end]);
    }
    for (nodes.items, hashes, node_types.items, 0..) |*item, *hash, node_type, slot| {
        if (slot < type_slot) hashField(hash, node_type);
        item.fingerprint = try hex(arena, hash);
    }

    return .{ .definitions = definitions.items, .binders = result_binders.items, .dependency_scope = scope, .graph = .{
        .definitions = nodes.items[0..type_slot],
        .types = nodes.items[type_slot..],
        .modules = module_nodes,
        .context = try hex(arena, &context),
    } };
}

fn appendNew(a: A, list: *std.ArrayList([]const u8), name: []const u8) !void {
    for (list.items) |existing| if (std.mem.eql(u8, existing, name)) return;
    try list.append(a, name);
}

/// A node's dependencies: the definitions in `refs` and in its own facts (in
/// source order), then the types and modules it refers to.
fn setDependencies(
    a: A,
    node: *frontend.Node,
    refs: std.AutoHashMapUnmanaged(CIR.Def.Idx, void),
    defs: []const CIR.Def.Idx,
    node_defs: *const std.AutoArrayHashMapUnmanaged(CIR.Def.Idx, usize),
    nodes: []const frontend.Node,
    facts: *const Facts,
    type_decls: *const std.AutoArrayHashMapUnmanaged(CIR.Statement.Idx, usize),
    module_names: *const std.AutoArrayHashMapUnmanaged(base.ModuleIdentity.Idx, []const u8),
) !void {
    var deps: std.ArrayList([]const u8) = .empty;
    for (defs) |idx| if (refs.contains(idx) or facts.values.contains(idx)) {
        const slot = node_defs.get(idx) orelse continue;
        if (!std.mem.eql(u8, nodes[slot].name, node.name)) try appendNew(a, &deps, nodes[slot].name);
    };
    for (type_decls.keys(), type_decls.values()) |statement, slot| if (facts.types.contains(statement)) {
        if (!std.mem.eql(u8, nodes[slot].name, node.name)) try appendNew(a, &deps, nodes[slot].name);
    };
    var module_deps: std.ArrayList([]const u8) = .empty;
    for (facts.identities.keys()) |identity| if (module_names.get(identity)) |name| try appendNew(a, &module_deps, name);
    std.mem.sort([]const u8, module_deps.items, {}, struct {
        fn less(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.less);
    try deps.appendSlice(a, module_deps.items);
    node.dependencies = deps.items;
}

/// Whether `item` is declared under type `type_name` (`Config.scale`).
fn associated(type_name: []const u8, item: []const u8) bool {
    return item.len > type_name.len and std.mem.startsWith(u8, item, type_name) and item[type_name.len] == '.';
}
fn binderIdent(env: *can.ModuleEnv, binder: CIR.Pattern.Idx) []const u8 {
    return env.getIdent(switch (env.store.getPattern(binder)) {
        .assign => |v| v.ident,
        .var_assign => |v| v.ident,
        .as => |v| v.ident,
        else => unreachable,
    });
}
/// A graph node name: associated items drop the module qualifier
/// (`main.Config.scale` is `Config.scale`).
fn nodeName(a: A, env: *can.ModuleEnv, ident: []const u8) ![]const u8 {
    const module = env.module_name;
    if (ident.len > module.len and std.mem.startsWith(u8, ident, module) and ident[module.len] == '.') return a.dupe(u8, ident[module.len + 1 ..]);
    return a.dupe(u8, ident);
}
