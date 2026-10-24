//! Syntax facts only. Cell boundaries and notebook policy live in document_frontend.zig.
const std = @import("std");
const parse = @import("parse");
const base = @import("base");
const A = std.mem.Allocator;
pub const Span = struct { start: u64, end: u64 };
pub const Token = struct { start: u64, end: u64, depth: u64, tag: []const u8 };
pub const Statement = struct { start: u64, end: u64, kind: []const u8, name: []const u8 = "", body_start: u64 = 0, body_end: u64 = 0 };
pub const Facts = struct { tokens: []Token = &.{}, statements: []Statement = &.{}, errors: []Span = &.{}, header_end: u64 = 0 };
pub const Block = struct { start: u64, end: u64, body_start: u64, body_end: u64, kind: []const u8, info: []const u8 = "", facts: Facts = .{} };
fn span(ast: *parse.AST, region: parse.AST.TokenizedRegion) Span {
    const r = ast.tokenizedRegionToRegion(region);
    return .{ .start = @min(r.start.offset, ast.env.source.len), .end = @min(r.end.offset, ast.env.source.len) };
}
pub fn roc(a: A, source: []const u8) !Facts {
    var env = try base.CommonEnv.init(a, source);
    defer env.deinit(a);
    const ast = try parse.notebook(a, &env);
    defer ast.deinit();
    var tokens: std.ArrayList(Token) = .empty;
    var depth: u64 = 0;
    for (ast.tokens.tokens.items(.tag), 0..) |tag, i| {
        if (tag == .EndOfFile) break;
        const r = ast.tokens.resolve(i);
        try tokens.append(a, .{ .start = r.start.offset, .end = r.end.offset, .depth = depth, .tag = @tagName(tag) });
        // MultilineStringStart prefixes one line; it has no closing StringEnd.
        // Its StringPart tokens cover the literal bytes, while interpolations nest.
        switch (tag) {
            .OpenRound, .NoSpaceOpenRound, .OpenSquare, .OpenCurly, .OpenStringInterpolation, .StringStart => depth += 1,
            .CloseRound, .CloseSquare, .CloseCurly, .CloseStringInterpolation, .StringEnd => depth -|= 1,
            else => {},
        }
    }
    var statements: std.ArrayList(Statement) = .empty;
    const file = ast.store.getFile();
    for (ast.store.statementSlice(file.statements)) |idx| {
        const stmt = ast.store.getStatement(idx);
        const r = span(ast, switch (stmt) {
            inline else => |v| v.region,
        });
        var item: Statement = .{ .start = r.start, .end = r.end, .kind = @tagName(stmt) };
        switch (stmt) {
            .decl => |v| {
                const pattern = ast.store.getPattern(v.pattern);
                if (pattern == .ident) item.name = try a.dupe(u8, ast.resolve(pattern.ident.ident_tok));
                const br = span(ast, ast.store.getExpr(v.body).to_tokenized_region());
                item.body_start = br.start;
                item.body_end = br.end;
            },
            .dbg => |v| {
                const br = span(ast, ast.store.getExpr(v.expr).to_tokenized_region());
                item.body_start = br.start;
                item.body_end = br.end;
            },
            .expr => |v| {
                const br = span(ast, ast.store.getExpr(v.expr).to_tokenized_region());
                item.body_start = br.start;
                item.body_end = br.end;
            },
            else => {},
        }
        try statements.append(a, item);
    }
    var errors: std.ArrayList(Span) = .empty;
    for (ast.tokenize_diagnostics.items) |d| try errors.append(a, .{ .start = d.region.start.offset, .end = d.region.end.offset });
    for (ast.parse_diagnostics.items) |d| {
        const r = ast.resolveParseDiagnostic(d).region;
        try errors.append(a, .{ .start = r.start.offset, .end = r.end.offset });
    }
    const header = ast.store.getHeader(file.header);
    return .{ .tokens = try tokens.toOwnedSlice(a), .statements = try statements.toOwnedSlice(a), .errors = try errors.toOwnedSlice(a), .header_end = if (header == .default_app or header == .type_module) 0 else span(ast, header.to_tokenized_region()).end };
}

// MD4C's additional callback exposes top-level leaf spans before rendering.
// Nested blocks never become executable notebook cells.
const MdParser = extern struct {
    abi_version: c_uint = 0,
    flags: c_uint = 0x1100, // Tables and LaTeX math spans; shared native/WASM parsing.
    enter_block: *const fn (c_uint, ?*anyopaque, ?*anyopaque) callconv(.c) c_int = enterBlock,
    leave_block: *const fn (c_uint, ?*anyopaque, ?*anyopaque) callconv(.c) c_int = leaveBlock,
    enter_span: *const fn (c_uint, ?*anyopaque, ?*anyopaque) callconv(.c) c_int = enterSpan,
    leave_span: *const fn (c_uint, ?*anyopaque, ?*anyopaque) callconv(.c) c_int = leaveSpan,
    text: *const fn (c_uint, [*]const u8, c_uint, ?*anyopaque) callconv(.c) c_int = mdText,
    debug_log: ?*anyopaque = null,
    syntax: ?*anyopaque = null,
};
extern fn md_parse([*]const u8, c_uint, *const MdParser, ?*anyopaque) c_int;
const MdContext = struct {
    allocator: A,
    source: []const u8,
    blocks: std.ArrayList(Block) = .empty,
    block_depth: usize = 0,
    paragraph: ?usize = null,
    span_depth: usize = 0,
    image_depth: usize = 0,
    images: usize = 0,
    other_content: bool = false,
    render: bool = false,
    events: std.ArrayList(MarkdownEvent) = .empty,
};
// Typed MD4C events. The host renders a fixed set of DOM elements, never raw HTML.
pub const MarkdownEvent = struct { event: []const u8, kind: u32, text: []const u8 = "", detail: u32 = 0 };
const MdAttribute = extern struct { text: ?[*]const u8, size: c_uint, types: ?*anyopaque, offsets: ?*anyopaque };
fn markdownEvent(ctx: *MdContext, event: MarkdownEvent) c_int {
    if (ctx.render) ctx.events.append(ctx.allocator, event) catch return -1;
    return 0;
}
fn mdContext(p: ?*anyopaque) *MdContext {
    return @ptrCast(@alignCast(p.?));
}
fn enterBlock(kind: c_uint, detail: ?*anyopaque, user: ?*anyopaque) callconv(.c) c_int {
    const ctx = mdContext(user);
    if (kind == 9 and ctx.block_depth == 1 and ctx.blocks.items.len > 0) {
        ctx.paragraph = ctx.blocks.items.len - 1;
        ctx.images = 0;
        ctx.other_content = false;
    }
    ctx.block_depth += 1;
    const number: u32 = if ((kind == 3 or kind == 6) and detail != null) @as(*const c_uint, @ptrCast(@alignCast(detail.?))).* else 0;
    return markdownEvent(ctx, .{ .event = "block_start", .kind = kind, .detail = number });
}
fn leaveBlock(kind: c_uint, _: ?*anyopaque, user: ?*anyopaque) callconv(.c) c_int {
    const ctx = mdContext(user);
    if (kind == 9 and ctx.block_depth == 2) {
        if (ctx.paragraph) |index| {
            if (ctx.images == 1 and !ctx.other_content) ctx.blocks.items[index].kind = "image";
        }
        ctx.paragraph = null;
    }
    ctx.block_depth -= 1;
    return markdownEvent(ctx, .{ .event = "block_end", .kind = kind });
}
fn enterSpan(kind: c_uint, detail: ?*anyopaque, user: ?*anyopaque) callconv(.c) c_int {
    const ctx = mdContext(user);
    ctx.span_depth += 1;
    if (ctx.paragraph != null and ctx.image_depth == 0) {
        if (kind == 3) {
            ctx.images += 1;
            ctx.image_depth = ctx.span_depth;
        } else ctx.other_content = true;
    }
    var target: []const u8 = "";
    if ((kind == 2 or kind == 3) and detail != null) {
        const attr: *const MdAttribute = @ptrCast(@alignCast(detail.?));
        if (attr.text) |ptr| target = ctx.allocator.dupe(u8, ptr[0..attr.size]) catch return -1;
    }
    return markdownEvent(ctx, .{ .event = "span_start", .kind = kind, .text = target });
}
fn leaveSpan(kind: c_uint, _: ?*anyopaque, user: ?*anyopaque) callconv(.c) c_int {
    const ctx = mdContext(user);
    if (ctx.span_depth == ctx.image_depth) ctx.image_depth = 0;
    ctx.span_depth -= 1;
    return markdownEvent(ctx, .{ .event = "span_end", .kind = kind });
}
fn mdText(kind: c_uint, data: [*]const u8, size: c_uint, user: ?*anyopaque) callconv(.c) c_int {
    const ctx = mdContext(user);
    if (ctx.paragraph != null and ctx.image_depth == 0 and std.mem.trim(u8, data[0..size], " \t\r\n").len > 0) ctx.other_content = true;
    if (!ctx.render) return 0;
    return markdownEvent(ctx, .{ .event = "text", .kind = kind, .text = ctx.allocator.dupe(u8, data[0..size]) catch return -1 });
}
fn lineStart(s: []const u8, pos: usize) usize {
    var n = pos;
    while (n > 0 and s[n - 1] != '\n') n -= 1;
    return n;
}
fn lineEnd(s: []const u8, pos: usize) usize {
    var n = pos;
    while (n < s.len and s[n] != '\n') n += 1;
    return @min(n + 1, s.len);
}
export fn roclet_md_block(user: ?*anyopaque, kind: c_uint, start: c_uint, end: c_uint, fenced: c_uint) c_int {
    const ctx: *MdContext = @ptrCast(@alignCast(user.?));
    const s = ctx.source;
    var b: Block = .{ .start = lineStart(s, start), .end = lineEnd(s, end), .body_start = start, .body_end = end, .kind = "prose" };
    // MD_BLOCK_CODE=7, HTML=8, P=9, TABLE=10 in pinned MD4C 0.5.2.
    if (kind == 7 and fenced != 0) {
        const first_end = lineEnd(s, start);
        var n: usize = start;
        while (n < first_end and s[n] == s[start]) n += 1;
        b.info = std.mem.trim(u8, s[n..first_end], " \t\r\n");
        b.kind = "fence";
        b.body_start = first_end;
        b.body_end = b.end;
        // The closing fence is not included in MD4C's content lines.
        const close_end = lineEnd(s, @intCast(b.end));
        const close = std.mem.trim(u8, s[@intCast(b.end)..close_end], " \t\r\n");
        var k: usize = 0;
        while (k < close.len and close[k] == s[start]) k += 1;
        if (k >= n - start and k == close.len) b.end = close_end;
    } else if (kind == 8) b.kind = "html" else if (kind == 9) b.kind = "paragraph" else if (kind == 10) b.kind = "table";
    ctx.blocks.append(ctx.allocator, b) catch return -1;
    return 0;
}
pub fn markdown(a: A, source: []const u8) ![]Block {
    var ctx: MdContext = .{ .allocator = a, .source = source };
    if (md_parse(source.ptr, @intCast(source.len), &.{}, &ctx) != 0) return error.MarkdownParseFailed;
    for (ctx.blocks.items) |*block| {
        if (std.mem.eql(u8, block.kind, "fence") and std.mem.eql(u8, block.info, "roc")) block.facts = try roc(a, source[@intCast(block.body_start)..@intCast(block.body_end)]);
    }
    return ctx.blocks.toOwnedSlice(a);
}
pub fn renderMarkdown(a: A, source: []const u8) ![]MarkdownEvent {
    var ctx: MdContext = .{ .allocator = a, .source = source, .render = true };
    if (md_parse(source.ptr, @intCast(source.len), &.{}, &ctx) != 0) return error.MarkdownParseFailed;
    return ctx.events.toOwnedSlice(a);
}
const md_allocator = if (@import("builtin").cpu.arch == .wasm32) std.heap.wasm_allocator else std.heap.page_allocator;
export fn roclet_md_alloc(size: usize) ?*anyopaque {
    const mem = md_allocator.alignedAlloc(u8, .@"16", size + 16) catch return null;
    std.mem.writeInt(usize, mem[0..@sizeOf(usize)], mem.len, .little);
    return mem.ptr + 16;
}
export fn roclet_md_free(ptr: ?*anyopaque) void {
    if (ptr) |p| {
        const base_ptr: [*]align(16) u8 = @alignCast(@as([*]u8, @ptrCast(p)) - 16);
        const len = std.mem.readInt(usize, base_ptr[0..@sizeOf(usize)], .little);
        md_allocator.free(base_ptr[0..len]);
    }
}
export fn roclet_md_realloc(ptr: ?*anyopaque, size: usize) ?*anyopaque {
    const next = roclet_md_alloc(size) orelse return null;
    if (ptr) |p| {
        const b: [*]u8 = @as([*]u8, @ptrCast(p)) - 16;
        const len = std.mem.readInt(usize, b[0..@sizeOf(usize)], .little) - 16;
        const dest: [*]u8 = @ptrCast(next);
        const src: [*]const u8 = @ptrCast(p);
        @memcpy(dest[0..@min(len, size)], src[0..@min(len, size)]);
        roclet_md_free(p);
    }
    return next;
}
