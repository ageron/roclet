//! The engine-owned reactive baseline: the dependency graph of the last
//! participating request and, per root, the presentation of that root's last
//! successful evaluation in this engine. Memory only: never persisted, never
//! imported, never Roc values. Reuse is a scheduling hint over deterministic
//! evaluation; `frontend.plan` decides it from the graphs alone.
const std = @import("std");
const notebook = @import("notebook.zig");
const frontend = @import("document_frontend.zig");
const A = std.mem.Allocator;
const S = []const u8;

/// Retained presentation bytes above this are evicted, least recently stored
/// first, before the next participating request plans.
pub const retained_limit: usize = 64 * 1024 * 1024;

/// One root's observable result: a value (output roots) or a test outcome
/// (expectation roots), plus the root's events in execution order.
pub const Presentation = struct {
    value: ?notebook.Value = null,
    test_result: ?notebook.TestResult = null,
    events: []const notebook.Event = &.{},
};

/// Values, tests and events of a set of roots, in root order.
pub const Outcomes = struct {
    values: []const notebook.Value = &.{},
    tests: []const notebook.TestResult = &.{},
    events: []const notebook.Event = &.{},
};

pub const Baseline = struct {
    gpa: A,
    limit: usize = retained_limit,
    /// Null until a participating request checks successfully.
    graph: ?*Snapshot = null,
    /// Keyed by root; each key is owned by its entry.
    entries: std.StringArrayHashMapUnmanaged(*Entry) = .empty,
    /// Sum of retained presentation sizes.
    bytes: usize = 0,
    /// Commit counter; an entry's tick is the commit that stored it.
    tick: u64 = 0,

    const Snapshot = struct { arena: std.heap.ArenaAllocator, graph: frontend.Graph };
    const Entry = struct {
        arena: std.heap.ArenaAllocator,
        presentation: Presentation,
        size: usize,
        tick: u64,

        fn create(gpa: A, presentation: Presentation, tick: u64) !*Entry {
            var arena = std.heap.ArenaAllocator.init(gpa);
            errdefer arena.deinit();
            const a = arena.allocator();
            const entry = try a.create(Entry);
            var size: usize = 0;
            var copy: Presentation = .{};
            if (presentation.value) |value| {
                var display: ?std.json.Value = null;
                if (value.display) |shown| {
                    const wire = try stringify(gpa, shown);
                    defer gpa.free(wire);
                    size += wire.len;
                    display = try std.json.parseFromSliceLeaky(std.json.Value, a, wire, .{ .allocate = .alloc_always });
                }
                copy.value = .{ .root = try a.dupe(u8, value.root), .text = try a.dupe(u8, value.text), .display = display };
                size += value.root.len + value.text.len;
            }
            if (presentation.test_result) |result| {
                copy.test_result = .{ .root = try a.dupe(u8, result.root), .passed = result.passed, .message = try a.dupe(u8, result.message) };
                size += result.root.len + result.message.len;
            }
            const events = try a.alloc(notebook.Event, presentation.events.len);
            for (events, presentation.events) |*out, event| {
                out.* = .{ .kind = event.kind, .message = try a.dupe(u8, event.message), .root = try a.dupe(u8, event.root), .region = event.region };
                size += event.message.len + event.root.len;
            }
            copy.events = events;
            entry.* = .{ .arena = arena, .presentation = copy, .size = size, .tick = tick };
            return entry;
        }
        fn root(self: *const Entry) S {
            const p = self.presentation;
            return if (p.value) |value| value.root else p.test_result.?.root;
        }
        fn destroy(self: *Entry) void {
            self.arena.deinit();
        }
    };

    pub fn init(gpa: A) Baseline {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Baseline) void {
        self.clear();
        self.entries.deinit(self.gpa);
        self.* = undefined;
    }

    /// Forget the graph and every presentation (`reactivity.reset`).
    pub fn clear(self: *Baseline) void {
        for (self.entries.values()) |entry| entry.destroy();
        self.entries.clearRetainingCapacity();
        self.bytes = 0;
        if (self.graph) |snapshot| snapshot.arena.deinit();
        self.graph = null;
    }

    /// The planner input for `current` against this baseline. `previous` is
    /// copied into `a` because the plan may name definitions only it has.
    /// Evicts over-limit entries first, so they are simply re-evaluated.
    pub fn planInput(self: *Baseline, a: A, current: frontend.Graph, roots: []const S, force: []const S) !frontend.Reactive {
        self.trim();
        const snapshot = self.graph orelse return .{ .current = current, .roots = roots, .force = force };
        const available = try a.alloc(S, self.entries.count());
        for (available, self.entries.values()) |*out, entry| out.* = try a.dupe(u8, entry.root());
        return .{ .known = true, .previous = try copyGraph(a, snapshot.graph), .current = current, .available = available, .roots = roots, .force = force };
    }

    /// The complete outcomes of `roots`: the retained presentation of each
    /// root in `reused`, the fresh one otherwise, in `roots` order. Fresh items
    /// of other roots follow. Retained items borrow from this baseline and stay
    /// valid until the next `planInput`, `clear` or `deinit`.
    pub fn merge(self: *const Baseline, a: A, roots: []const S, reused: []const S, fresh: Outcomes) !Outcomes {
        var grouped: std.StringArrayHashMapUnmanaged(std.ArrayList(notebook.Event)) = .empty;
        for (fresh.events) |event| {
            const slot = try grouped.getOrPut(a, event.root);
            if (!slot.found_existing) slot.value_ptr.* = .empty;
            try slot.value_ptr.append(a, event);
        }
        var values: std.ArrayList(notebook.Value) = .empty;
        var tests: std.ArrayList(notebook.TestResult) = .empty;
        var events: std.ArrayList(notebook.Event) = .empty;
        var placed: std.StringHashMapUnmanaged(void) = .empty;
        for (roots) |root| {
            try placed.put(a, root, {});
            if (contains(reused, root)) {
                const entry = self.entries.get(root) orelse continue;
                const p = entry.presentation;
                if (p.value) |value| try values.append(a, value);
                if (p.test_result) |result| try tests.append(a, result);
                try events.appendSlice(a, p.events);
                continue;
            }
            for (fresh.values) |value| if (eql(value.root, root)) try values.append(a, value);
            for (fresh.tests) |result| if (eql(result.root, root)) try tests.append(a, result);
            if (grouped.get(root)) |list| try events.appendSlice(a, list.items);
        }
        for (fresh.values) |value| if (!placed.contains(value.root)) try values.append(a, value);
        for (fresh.tests) |result| if (!placed.contains(result.root)) try tests.append(a, result);
        for (fresh.events) |event| if (!placed.contains(event.root)) try events.append(a, event);
        return .{ .values = values.items, .tests = tests.items, .events = events.items };
    }

    /// Remember `graph` and, for each of `roots`: keep the presentation of a
    /// root in `reused`, store a fresh successful one (a value, or a passed
    /// test), and drop everything else. On failure the baseline is emptied.
    pub fn commit(self: *Baseline, graph: frontend.Graph, roots: []const S, reused: []const S, fresh: Outcomes) !void {
        errdefer self.clear();
        self.tick += 1;
        var next: std.StringArrayHashMapUnmanaged(*Entry) = .empty;
        errdefer {
            for (next.values()) |entry| entry.destroy();
            next.deinit(self.gpa);
        }
        try next.ensureTotalCapacity(self.gpa, roots.len);
        var bytes: usize = 0;
        for (roots) |root| {
            if (next.contains(root)) continue;
            var entry: *Entry = undefined;
            if (contains(reused, root)) {
                entry = (self.entries.fetchSwapRemove(root) orelse continue).value;
            } else {
                const presentation = successful(fresh, root) orelse continue;
                entry = try Entry.create(self.gpa, presentation, self.tick);
            }
            next.putAssumeCapacity(entry.root(), entry);
            bytes += entry.size;
        }
        var snapshot = std.heap.ArenaAllocator.init(self.gpa);
        errdefer snapshot.deinit();
        const stored = try snapshot.allocator().create(Snapshot);
        stored.graph = try copyGraph(snapshot.allocator(), graph);
        stored.arena = snapshot;
        // Infallible from here on.
        for (self.entries.values()) |entry| entry.destroy();
        self.entries.deinit(self.gpa);
        self.entries = next;
        self.bytes = bytes;
        if (self.graph) |old| old.arena.deinit();
        self.graph = stored;
    }

    /// Evict the least recently stored entries until within `limit`.
    fn trim(self: *Baseline) void {
        while (self.bytes > self.limit and self.entries.count() > 0) {
            var oldest: usize = 0;
            for (self.entries.values(), 0..) |entry, i| if (entry.tick < self.entries.values()[oldest].tick) {
                oldest = i;
            };
            const entry = self.entries.values()[oldest];
            self.entries.swapRemoveAt(oldest);
            self.bytes -= entry.size;
            entry.destroy();
        }
    }
};

/// `root`'s fresh presentation when its evaluation succeeded.
fn successful(fresh: Outcomes, root: S) ?Presentation {
    var presentation: Presentation = .{};
    for (fresh.values) |value| if (eql(value.root, root)) {
        presentation.value = value;
    };
    for (fresh.tests) |result| if (eql(result.root, root)) {
        presentation.test_result = result;
    };
    const ok = if (presentation.test_result) |result| result.passed else presentation.value != null;
    if (!ok) return null;
    var first: ?usize = null;
    var last: usize = 0;
    for (fresh.events, 0..) |event, i| if (eql(event.root, root)) {
        if (first == null) first = i;
        last = i + 1;
    };
    // Evaluation appends one root's events contiguously.
    if (first) |start| presentation.events = fresh.events[start..last];
    return presentation;
}

fn copyGraph(a: A, graph: frontend.Graph) !frontend.Graph {
    const definitions = try a.alloc(frontend.Definition, graph.definitions.len);
    for (definitions, graph.definitions) |*out, definition| {
        const dependencies = try a.alloc(S, definition.dependencies.len);
        for (dependencies, definition.dependencies) |*dependency, name| dependency.* = try a.dupe(u8, name);
        out.* = .{ .name = try a.dupe(u8, definition.name), .fingerprint = try a.dupe(u8, definition.fingerprint), .dependencies = dependencies };
    }
    return .{ .context = try a.dupe(u8, graph.context), .scope = try a.dupe(u8, graph.scope), .definitions = definitions };
}

fn stringify(a: A, value: anytype) ![]u8 {
    var w: std.Io.Writer.Allocating = .init(a);
    errdefer w.deinit();
    try std.json.Stringify.value(value, .{}, &w.writer);
    return w.toOwnedSlice();
}
fn eql(x: S, y: S) bool {
    return std.mem.eql(u8, x, y);
}
fn contains(items: []const S, item: S) bool {
    for (items) |candidate| if (eql(candidate, item)) return true;
    return false;
}

// --- Tests: pure, no compiler ---

const graph_v1: frontend.Graph = .{ .context = "c", .scope = "definitions", .definitions = &.{
    .{ .name = "out_a", .fingerprint = "a1" },
    .{ .name = "out_b", .fingerprint = "b1" },
    .{ .name = "roclet_expect_1", .fingerprint = "t1" },
} };

fn freshOutcomes(a: A, tag: S) !Outcomes {
    return .{
        .values = try a.dupe(notebook.Value, &.{
            .{ .root = "out_a", .text = try std.fmt.allocPrint(a, "a-{s}", .{tag}) },
            .{ .root = "out_b", .text = try std.fmt.allocPrint(a, "b-{s}", .{tag}), .display = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"kind\":\"table\",\"rows\":[1,2.5]}", .{}) },
        }),
        .tests = try a.dupe(notebook.TestResult, &.{.{ .root = "roclet_expect_1", .passed = true, .message = "Expectation passed" }}),
        .events = try a.dupe(notebook.Event, &.{
            .{ .kind = .dbg, .message = "a1", .root = "out_a" },
            .{ .kind = .dbg, .message = "b1", .root = "out_b" },
            .{ .kind = .dbg, .message = "b2", .root = "out_b" },
        }),
    };
}

const all_roots: []const S = &.{ "out_a", "out_b", "roclet_expect_1" };

test "merged outcomes follow root order and mix retained with fresh presentations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var baseline: Baseline = .init(std.testing.allocator);
    defer baseline.deinit();
    const first = try freshOutcomes(a, "old");
    try baseline.commit(graph_v1, all_roots, &.{}, first);
    try std.testing.expectEqual(@as(usize, 3), baseline.entries.count());

    const input = try baseline.planInput(a, graph_v1, all_roots, &.{"out_a"});
    try std.testing.expect(input.known);
    try std.testing.expectEqual(@as(usize, 3), input.available.len);
    const plan = try frontend.plan(a, input);
    try std.testing.expectEqualStrings("out_a", plan.evaluate[0]);
    try std.testing.expectEqual(@as(usize, 2), plan.reused.len);

    // Only out_a ran; its fresh event precedes out_b's retained ones.
    const fresh: Outcomes = .{
        .values = try a.dupe(notebook.Value, &.{.{ .root = "out_a", .text = "a-new" }}),
        .events = try a.dupe(notebook.Event, &.{.{ .kind = .dbg, .message = "a2", .root = "out_a" }}),
    };
    const merged = try baseline.merge(a, all_roots, plan.reused, fresh);
    try std.testing.expectEqual(@as(usize, 2), merged.values.len);
    try std.testing.expectEqualStrings("a-new", merged.values[0].text);
    try std.testing.expectEqualStrings("b-old", merged.values[1].text);
    try std.testing.expectEqualStrings(try stringify(a, first.values[1].display.?), try stringify(a, merged.values[1].display.?));
    try std.testing.expectEqual(@as(usize, 1), merged.tests.len);
    try std.testing.expect(merged.tests[0].passed);
    try std.testing.expectEqual(@as(usize, 3), merged.events.len);
    for ([_]S{ "a2", "b1", "b2" }, merged.events) |message, event| try std.testing.expectEqualStrings(message, event.message);
}

test "commit drops failed, unevaluated and removed roots and keeps reused ones" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var baseline: Baseline = .init(std.testing.allocator);
    defer baseline.deinit();
    try baseline.commit(graph_v1, all_roots, &.{}, try freshOutcomes(a, "old"));
    const kept = baseline.entries.get("out_b").?;

    // out_a failed (no value), the test failed, out_b was reused.
    try baseline.commit(graph_v1, all_roots, &.{"out_b"}, .{
        .tests = try a.dupe(notebook.TestResult, &.{.{ .root = "roclet_expect_1", .passed = false, .message = "boom" }}),
    });
    try std.testing.expectEqual(@as(usize, 1), baseline.entries.count());
    try std.testing.expectEqual(kept, baseline.entries.get("out_b").?);

    // An analyze lists out_b in evaluate but runs nothing: dropped.
    try baseline.commit(graph_v1, all_roots, &.{}, .{});
    try std.testing.expectEqual(@as(usize, 0), baseline.entries.count());
    try std.testing.expectEqual(@as(usize, 0), baseline.bytes);

    // Roots no longer in the document are dropped too.
    try baseline.commit(graph_v1, all_roots, &.{}, try freshOutcomes(a, "new"));
    try baseline.commit(graph_v1, &.{"out_a"}, &.{"out_a"}, .{});
    try std.testing.expectEqual(@as(usize, 1), baseline.entries.count());
    try std.testing.expect(baseline.entries.get("out_a") != null);
}

test "a failed root is planned again and the reset baseline knows nothing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var baseline: Baseline = .init(std.testing.allocator);
    defer baseline.deinit();
    var outcomes = try freshOutcomes(a, "old");
    outcomes.values = outcomes.values[1..];
    try baseline.commit(graph_v1, all_roots, &.{}, outcomes);
    const plan = try frontend.plan(a, try baseline.planInput(a, graph_v1, all_roots, &.{}));
    try std.testing.expectEqualStrings("out_a", plan.evaluate[0]);
    try std.testing.expectEqualStrings("No successful result", plan.explanations[0].reason);

    baseline.clear();
    try std.testing.expect(baseline.graph == null);
    const input = try baseline.planInput(a, graph_v1, all_roots, &.{});
    try std.testing.expect(!input.known);
    const fresh_plan = try frontend.plan(a, input);
    try std.testing.expectEqual(@as(usize, 0), fresh_plan.reused.len);
    try std.testing.expectEqual(@as(usize, 3), fresh_plan.evaluate.len);
}

test "retained bytes above the limit evict the least recently stored entries first" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var baseline: Baseline = .init(std.testing.allocator);
    defer baseline.deinit();
    const big = try a.alloc(u8, 1000);
    @memset(big, 'x');
    try baseline.commit(graph_v1, all_roots, &.{}, .{ .values = try a.dupe(notebook.Value, &.{.{ .root = "out_a", .text = big }}) });
    // out_a is reused while out_b is stored after it.
    try baseline.commit(graph_v1, all_roots, &.{"out_a"}, .{ .values = try a.dupe(notebook.Value, &.{.{ .root = "out_b", .text = big }}) });
    try std.testing.expectEqual(@as(usize, 2 * (1000 + 5)), baseline.bytes);
    // Within the limit nothing is evicted.
    try std.testing.expectEqual(@as(usize, 2), (try baseline.planInput(a, graph_v1, all_roots, &.{})).available.len);
    baseline.limit = 1500;
    const input = try baseline.planInput(a, graph_v1, all_roots, &.{});
    try std.testing.expectEqual(@as(usize, 1), input.available.len);
    try std.testing.expectEqualStrings("out_b", input.available[0]);
    try std.testing.expectEqual(@as(usize, 1005), baseline.bytes);
    // The default limit is the documented 64 MiB.
    try std.testing.expectEqual(@as(usize, 64 * 1024 * 1024), Baseline.init(std.testing.allocator).limit);
}
