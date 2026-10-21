//! Code tidiness checks for the Roclet codebase.
//!
//! Adapted from the Roc compiler's `ci/tidy.zig`, which is itself adapted from
//! TigerBeetle's `src/tidy.zig`:
//! https://github.com/tigerbeetle/tigerbeetle/blob/main/src/tidy.zig
//! Copyright TigerBeetle, Inc. Licensed under the Apache License, Version 2.0,
//! https://www.apache.org/licenses/LICENSE-2.0. See THIRD_PARTY_NOTICES.md.
//!
//! `zig build run-check-tidy` runs the per-file checks over every git-tracked
//! file; `zig build run-check-git-lints` runs the dead-file detector. Both need
//! a git checkout (they read `git ls-files`), which CI has.
//!
//! Checks kept from Roc, with Roclet's layout (`compiler-adapter/`, `tools/`,
//! `tests/`, `ci/` and `build.zig`; there is no `src/`):
//! - carriage returns in any text file
//! - banned Zig patterns: `== error.` / `!= error.` (silent anyerror upcast),
//!   `usingnamespace`, deprecated `std.mem.indexOf*` spellings, `anyerror` in
//!   the engine (`compiler-adapter/`), leftover `FIXME` reminders
//! - dead private declarations: a non-pub `fn` or `const` mentioned exactly
//!   once in its file (Zig compiles lazily, so it never reports these)
//! - bitwise and arithmetic operators mixed without parentheses
//! - Markdown documents have exactly one top-level `# Title`
//! - `git+https://` dependencies in `build.zig.zon`
//! - `--git-lints`: a tracked Zig file that nothing imports, builds or runs
//!
//! Deliberately not ported: the checks about Roc compiler internals (CoreCtx
//! creation, `std.Io` in core modules, builtin formatting, `Builtin.roc`
//! exposed types, item terminology, glossary links, Zig version pins, the
//! `b.graph.host` ban that exists for Roc's multi-runner CI cache), the
//! inferred-error-set ban (Roclet's adapter uses `!T` throughout; changing
//! that is a separate decision), the em-dash spacing rule (prose style), and
//! the scratch-file rule (`wip/` plans are committed on purpose).

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const mem = std.mem;
const Ast = std.zig.Ast;

const MiB = 1024 * 1024;
const max_text_file_size = 4 * MiB;

/// Binary file extensions that are skipped entirely (not read into the buffer).
const binary_extensions: []const []const u8 = &.{
    ".ico",  ".png", ".webp", ".jpg", ".jpeg", ".gif",   ".bin",
    ".o",    ".obj", ".a",    ".lib", ".dll",  ".so",    ".dylib",
    ".wasm", ".zst", ".zip",  ".ttf", ".woff", ".woff2",
};

/// The directories that hold Roclet's Zig sources. `build.zig` is the only
/// Zig file outside them.
const zig_source_dirs: []const []const u8 = &.{ "compiler-adapter/", "tools/", "tests/", "ci/" };

fn isZigSourcePath(path: []const u8) bool {
    for (zig_source_dirs) |dir| {
        if (std.mem.startsWith(u8, path, dir)) return true;
    }
    return false;
}

const TermColor = struct {
    pub const red = "\x1b[0;31m";
    pub const green = "\x1b[0;32m";
    pub const reset = "\x1b[0m";
};

pub fn main(init: std.process.Init) !void {
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const io = init.io;

    var arg_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer arg_it.deinit();
    var arg_list = std.ArrayList([]const u8).empty;
    defer arg_list.deinit(gpa);
    while (arg_it.next()) |a| try arg_list.append(gpa, a);

    const mode = parseMode(arg_list.items);
    switch (mode) {
        .tidy => try runTidy(gpa, io),
        .git_lints => try runGitLints(gpa, io),
    }
}

const Mode = enum {
    tidy,
    git_lints,
};

fn parseMode(args: []const []const u8) Mode {
    if (args.len == 1) return .tidy;
    if (args.len == 2 and std.mem.eql(u8, args[1], "--git-lints")) return .git_lints;

    std.debug.print(
        \\usage:
        \\  zig build run-check-tidy
        \\  zig build run-check-git-lints
        \\
    , .{});
    std.process.exit(2);
}

fn runTidy(gpa: Allocator, io: std.Io) !void {
    var errors: Errors = .{};

    var counter: IdentifierCounter = try .init(gpa);
    defer counter.deinit(gpa);

    // NB: all checks are intentionally implemented in a streaming fashion,
    // such that we only need to read the files once.
    const file_buffer = try gpa.alloc(u8, max_text_file_size);
    defer gpa.free(file_buffer);

    const paths = try listFilePaths(gpa, io);
    defer {
        for (paths) |path| {
            gpa.free(path);
        }
        gpa.free(paths);
    }

    for (paths) |file_path| {
        const bytes_read = (std.Io.Dir.cwd().readFile(io, file_path, file_buffer) catch |err| {
            std.debug.print("Error reading {s}: {}\n", .{ file_path, err });
            continue;
        }).len;

        // Skip binary files without a recognized extension. A NUL byte in the
        // first chunk is a strong indicator of binary content.
        const sniff_len = @min(bytes_read, 1024);
        if (std.mem.findScalar(u8, file_buffer[0..sniff_len], 0) != null) continue;

        if (bytes_read >= file_buffer.len - 1) {
            std.debug.panic(
                \\File exceeds {d} MiB buffer limit: {s}
                \\
                \\If this is a binary file, add its extension to `binary_extensions` in ci/tidy.zig
                \\to exclude it from tidy checks.
            , .{ max_text_file_size / MiB, file_path });
        }
        file_buffer[bytes_read] = 0;

        const source_file = SourceFile{ .path = file_path, .text = file_buffer[0..bytes_read :0] };
        try tidyFile(gpa, &counter, source_file, &errors);
    }

    if (errors.count > 0) {
        std.debug.print("\n{s}[FAIL]{s} Found {d} tidy violations\n", .{ TermColor.red, TermColor.reset, errors.count });
        std.process.exit(1);
    }

    std.debug.print("{s}[OK]{s} All tidy checks passed!\n", .{ TermColor.green, TermColor.reset });
}

fn runGitLints(gpa: Allocator, io: std.Io) !void {
    var errors: Errors = .{};

    var dead_files_detector = DeadFilesDetector.init(gpa);
    defer dead_files_detector.deinit(gpa);

    const file_buffer = try gpa.alloc(u8, max_text_file_size);
    defer gpa.free(file_buffer);

    const paths = try listFilePaths(gpa, io);
    defer {
        for (paths) |path| {
            gpa.free(path);
        }
        gpa.free(paths);
    }

    for (paths) |file_path| {
        if (!std.mem.endsWith(u8, file_path, ".zig")) continue;

        const bytes_read = (std.Io.Dir.cwd().readFile(io, file_path, file_buffer) catch |err| {
            std.debug.print("Error reading {s}: {}\n", .{ file_path, err });
            continue;
        }).len;
        if (bytes_read >= file_buffer.len - 1) {
            std.debug.panic("File exceeds {d} MiB buffer limit: {s}", .{ max_text_file_size / MiB, file_path });
        }
        file_buffer[bytes_read] = 0;

        const source_file = SourceFile{ .path = file_path, .text = file_buffer[0..bytes_read :0] };
        try dead_files_detector.visit(gpa, source_file);
    }

    dead_files_detector.finish(&errors);

    if (errors.count > 0) {
        std.debug.print("\n{s}[FAIL]{s} Found {d} Git lint violations\n", .{ TermColor.red, TermColor.reset, errors.count });
        std.process.exit(1);
    }

    std.debug.print("{s}[OK]{s} All Git lints passed!\n", .{ TermColor.green, TermColor.reset });
}

const Errors = struct {
    count: u32 = 0,

    pub fn addControlCharacter(
        errors: *Errors,
        file: SourceFile,
        offset: usize,
        character: u8,
    ) void {
        errors.emit(
            "{s}:{d}: error: control character code={}\n",
            .{ file.path, file.lineNumber(offset), character },
        );
    }

    pub fn addBanned(
        errors: *Errors,
        file: SourceFile,
        offset: usize,
        banned_item: []const u8,
        replacement: []const u8,
    ) void {
        errors.emit(
            "{s}:{d}: error: {s} is banned, use {s}\n",
            .{ file.path, file.lineNumber(offset), banned_item, replacement },
        );
    }

    pub fn addBannedReminder(
        errors: *Errors,
        file: SourceFile,
        offset: usize,
        banned_item: []const u8,
    ) void {
        errors.emit(
            "{s}:{d}: error: leftover {s}, remove before merge\n",
            .{ file.path, file.lineNumber(offset), banned_item },
        );
    }

    pub fn addAmbiguousPrecedence(errors: *Errors, file: SourceFile, line_index: usize) void {
        const line_number = line_index + 1;
        errors.emit(
            "{s}:{d}: error: ambiguous operator precedence, add parentheses\n",
            .{ file.path, line_number },
        );
    }

    pub fn addDeadDeclaration(errors: *Errors, file: SourceFile, declaration: []const u8) void {
        errors.emit("{s}: error: '{s}' is dead code\n", .{ file.path, declaration });
    }

    pub fn addInvalidMarkdownTitle(errors: *Errors, file: SourceFile) void {
        errors.emit(
            "{s}: error: document should have exactly one top-level '# Title'\n",
            .{file.path},
        );
    }

    pub fn addGitDependency(errors: *Errors, file: SourceFile, offset: usize) void {
        errors.emit(
            "{s}:{d}: error: 'git+https://' dependency URLs are banned; use a GitHub archive " ++
                "tarball instead, e.g. 'https://github.com/OWNER/REPO/archive/<commit>.tar.gz'. " ++
                "'git+https' makes Zig fetch over the git smart-HTTP protocol, whose ref-discovery " ++
                "handshake intermittently fails in CI; a plain tarball URL is a reliable HTTP GET " ++
                "and, because Zig hashes the unpacked tree, produces the exact same package hash.\n",
            .{ file.path, file.lineNumber(offset) },
        );
    }

    pub fn addFileUntracked(errors: *Errors, file: []const u8) void {
        errors.emit(
            "{s}: error: imported file untracked by git\n",
            .{file},
        );
    }

    pub fn addFileDead(errors: *Errors, file: []const u8) void {
        errors.emit(
            "{s}: error: Zig file never imported, built or run from build.zig\n",
            .{file},
        );
    }

    fn emit(errors: *Errors, comptime fmt: []const u8, args: anytype) void {
        comptime assert(fmt[fmt.len - 1] == '\n');
        errors.count += 1;
        std.debug.print(fmt, args);
    }
};

const SourceFile = struct {
    path: []const u8,
    text: [:0]const u8,

    fn hasExtension(file: SourceFile, extension: []const u8) bool {
        assert(extension.len > 0);
        assert(extension[0] == '.');
        return std.mem.endsWith(u8, file.path, extension);
    }

    // O(n), but only invoked on the cold path (when there are errors).
    fn lineNumber(file: SourceFile, offset: usize) usize {
        assert(offset <= file.text.len);
        // +1: Line _index_ is zero-based, line _number_ is one-based.
        return std.mem.count(u8, file.text[0..offset], "\n") + 1;
    }
};

fn tidyFile(
    gpa: Allocator,
    counter: *IdentifierCounter,
    file: SourceFile,
    errors: *Errors,
) Allocator.Error!void {
    tidyControlCharacters(file, errors);
    if (file.hasExtension(".zig")) {
        tidyBanned(file, errors);
        tidyBannedAnyerror(file, errors);
        tidyBannedIndexOf(file, errors);

        var tree = try std.zig.Ast.parse(gpa, file.text, .{ .mode = .zig });
        defer tree.deinit(gpa);

        tidyDeadDeclarations(file, &tree, counter, errors);
        tidyAst(file, &tree, errors);
    }
    if (file.hasExtension(".md")) {
        tidyMarkdownTitle(file, errors);
    }
    if (file.hasExtension(".zon")) {
        tidyBannedGitDependency(file, errors);
    }
}

/// Ban `git+https://` dependency URLs in build.zig.zon. They make Zig fetch over
/// the git smart-HTTP protocol, whose ref-discovery handshake intermittently
/// fails in CI. GitHub archive tarball URLs hit a reliable plain HTTP GET and
/// resolve to the same package hash.
fn tidyBannedGitDependency(file: SourceFile, errors: *Errors) void {
    const banned = "git+https://";

    var line_start: usize = 0;
    while (line_start <= file.text.len) {
        const line_end = std.mem.findScalarPos(u8, file.text, line_start, '\n') orelse file.text.len;
        const line = file.text[line_start..line_end];
        const trimmed = std.mem.trim(u8, line, " \t");
        if (!std.mem.startsWith(u8, trimmed, "//")) {
            if (std.mem.find(u8, line, banned)) |index| {
                errors.addGitDependency(file, line_start + index);
            }
        }
        if (line_end == file.text.len) break;
        line_start = line_end + 1;
    }
}

fn tidyControlCharacters(file: SourceFile, errors: *Errors) void {
    // Check for carriage returns (CRLF line endings).
    // Tabs are intentionally allowed everywhere.
    // Windows batch files are allowed to have CRLF.
    if (file.hasExtension(".bat")) return;

    var remaining = file.text;
    while (mem.findScalar(u8, remaining, '\r')) |index| {
        const offset = index + (file.text.len - remaining.len);
        errors.addControlCharacter(file, offset, '\r');
        remaining = remaining[index + 1 ..];
    }
}

/// Zig 0.16 renamed `std.mem.indexOf*` / `lastIndexOf*` to `std.mem.find*`.
/// The old names still exist as deprecated aliases, so the compiler accepts them,
/// but new code must use the modern spellings to keep the rename sweep from drifting.
fn tidyBannedIndexOf(file: SourceFile, errors: *Errors) void {
    // Don't ban ourselves (this file documents the banned strings).
    if (std.mem.endsWith(u8, file.path, "ci/tidy.zig")) return;

    const banned_index_patterns: []const struct { []const u8, []const u8 } = &.{
        // Longest patterns first so substrings don't shadow them. The bare
        // `lastIndexOf` must stay last in this group, otherwise it would shadow
        // its `...None`/`...Linear` suffixes and emit the wrong replacement.
        .{ "std.mem.lastIndexOfScalar", "std.mem.findScalarLast" },
        .{ "std.mem.lastIndexOfAny", "std.mem.findLastAny" },
        .{ "std.mem.lastIndexOfNone", "std.mem.findLastNone" },
        .{ "std.mem.lastIndexOfLinear", "std.mem.findLastLinear" },
        .{ "std.mem.lastIndexOf", "std.mem.findLast" },
        .{ "std.mem.indexOfScalarPos", "std.mem.findScalarPos" },
        .{ "std.mem.indexOfScalar", "std.mem.findScalar" },
        .{ "std.mem.indexOfAny", "std.mem.findAny" },
        .{ "std.mem.indexOfPos", "std.mem.findPos" },
        .{ "std.mem.indexOfNone", "std.mem.findNone" },
        .{ "std.mem.indexOf", "std.mem.find" },
    };

    // Track offsets reported by longer patterns so we don't double-report
    // a shorter pattern that appears as a prefix (e.g. `indexOf` inside `indexOfScalar`).
    var reported_buf: [128]usize = undefined;
    var reported_count: usize = 0;

    for (banned_index_patterns) |ban_item| {
        const banned, const replacement = ban_item;
        var remaining: []const u8 = file.text;
        while (std.mem.find(u8, remaining, banned)) |index| {
            const offset = @intFromPtr(remaining.ptr) - @intFromPtr(file.text.ptr) + index;

            var already_reported = false;
            for (reported_buf[0..reported_count]) |prior| {
                if (prior == offset) {
                    already_reported = true;
                    break;
                }
            }
            if (!already_reported) {
                if (reported_count < reported_buf.len) {
                    reported_buf[reported_count] = offset;
                    reported_count += 1;
                }
                errors.addBanned(file, offset, banned, replacement);
            }
            remaining = remaining[index + banned.len ..];
        }
    }
}

fn tidyBanned(file: SourceFile, errors: *Errors) void {
    // Don't ban ourselves!
    if (std.mem.endsWith(u8, file.path, "ci/tidy.zig")) return;

    const ban_list: []const struct { []const u8, []const u8 } = &.{
        // Language footguns:
        .{ "== error.", "switch to avoid silent anyerror upcast" },
        .{ "!= error.", "switch to avoid silent anyerror upcast" },

        // Style:
        .{ "usingnamespace", "explicit imports" },
    };

    for (ban_list) |ban_item| {
        const banned, const replacement = ban_item;
        if (std.mem.find(u8, file.text, banned)) |offset| {
            errors.addBanned(file, offset, banned, replacement);
        }
    }

    // Reminders:
    // Do use FIXME comments proactively while iterating on the code when you want to make sure
    // something is revisited before getting into the main branch.
    inline for (.{"FIXME"}) |banned| {
        if (std.mem.find(u8, file.text, banned)) |offset| {
            errors.addBannedReminder(file, offset, banned);
        }
    }
}

/// `anyerror` hides the actual errors a function can return. Keep the engine
/// explicit by spelling out the concrete error set or a named union of concrete
/// error sets. Tools and test drivers surface many OS errors and are exempt.
fn tidyBannedAnyerror(file: SourceFile, errors: *Errors) void {
    if (!std.mem.startsWith(u8, file.path, "compiler-adapter/")) return;

    const banned = "anyerror";
    var remaining: []const u8 = file.text;
    while (std.mem.find(u8, remaining, banned)) |index| {
        const offset = @intFromPtr(remaining.ptr) - @intFromPtr(file.text.ptr) + index;
        errors.addBanned(file, offset, banned, "an explicit error set");
        remaining = remaining[index + banned.len ..];
    }
}

const IdentifierCounter = struct {
    const file_identifier_count_max = 100_000;

    map: std.StringHashMapUnmanaged(struct { count: u32, offset: u32 }) = .{},

    pub fn init(gpa: Allocator) !IdentifierCounter {
        var counter: IdentifierCounter = .{};
        try counter.map.ensureTotalCapacity(gpa, file_identifier_count_max + 1);
        return counter;
    }

    pub fn deinit(counter: *IdentifierCounter, gpa: Allocator) void {
        counter.map.deinit(gpa);
        counter.* = undefined;
    }

    pub fn empty(counter: *const IdentifierCounter) bool {
        return counter.map.count() == 0;
    }

    pub fn clear(counter: *IdentifierCounter) void {
        counter.map.clearRetainingCapacity();
    }

    pub fn record(
        counter: *IdentifierCounter,
        tree: *const Ast,
        token_text: []const u8,
        token_offset: u32,
    ) void {
        const gop = counter.map.getOrPutAssumeCapacity(token_text);
        if (counter.map.count() > file_identifier_count_max) @panic("file too large");

        if (gop.found_existing) {
            // Count occurrences on a single line as one, as a special case for imports:
            // const foo = std.foo;
            const between_tokens_text = tree.source[gop.value_ptr.offset..token_offset];
            const same_line_occurrence = mem.findScalar(u8, between_tokens_text, '\n') == null;
            if (same_line_occurrence) return;
        }

        if (!gop.found_existing) gop.value_ptr.* = .{ .count = 0, .offset = 0 };
        gop.value_ptr.count += 1;
        gop.value_ptr.offset = token_offset;
    }

    pub fn get(counter: *const IdentifierCounter, token_text: []const u8) u32 {
        return counter.map.get(token_text).?.count;
    }
};

/// Detects unused constants and functions.
///
/// This is a one-side heuristic: there might be false negatives, but no false positives.
///
/// Current algorithm:
/// - Two passes.
/// - Pass 1: count how many times each identifier is mentioned in the file.
/// - Pass 2: warn about any unique identifier which is a non-public declaration.
///
/// At the moment, this is implemented using only the lexer, without looking at the AST, as that
/// seemed simpler.
fn tidyDeadDeclarations(
    file: SourceFile,
    tree: *const Ast,
    counter: *IdentifierCounter,
    errors: *Errors,
) void {
    assert(counter.empty());
    defer counter.clear();

    var identifier_start: ?Ast.ByteOffset = 0;
    const Phase = enum { fill, check };
    inline for ([_]Phase{ .fill, .check }) |phase| {
        next_token: for (
            tree.tokens.items(.tag),
            tree.tokens.items(.start),
            0..,
        ) |tag, start, index_usize| {
            const index: Ast.TokenIndex = @intCast(index_usize);
            const identifier_start_previous = identifier_start;
            identifier_start = if (tag == .identifier) start else null;

            const start_previous = identifier_start_previous orelse continue :next_token;
            const token_text = std.mem.trim(
                u8,
                tree.source[start_previous..start],
                &std.ascii.whitespace,
            );

            switch (phase) {
                .fill => counter.record(tree, token_text, start),
                .check => {
                    const usages = counter.get(token_text);
                    assert(usages >= 1);
                    if (usages == 1) {
                        if (tidyDeadDeclarationsIsPrivateDeclaration(tree, index - 1)) {
                            errors.addDeadDeclaration(file, token_text);
                        }
                    }
                },
            }
        }
    }
}

// Checks if the given identifier token refers to non-public declaration.
fn tidyDeadDeclarationsIsPrivateDeclaration(
    tree: *const Ast,
    token_index: Ast.TokenIndex,
) bool {
    assert(tree.tokens.items(.tag)[token_index] == .identifier);
    var declaration_keyword: ?std.zig.Token.Tag = null;
    var saw_extern = false;
    for (0..4) |context_offset| {
        const context_tag = if (token_index - context_offset < 1)
            .eof
        else
            tree.tokens.items(.tag)[token_index - context_offset - 1];

        if (declaration_keyword == null) {
            if (context_tag != .keyword_fn and context_tag != .keyword_const) return false;
            declaration_keyword = context_tag;
        } else {
            if (context_tag == .keyword_inline or context_tag == .string_literal) continue;
            if (context_tag == .keyword_extern) {
                saw_extern = true;
                continue;
            }
            // Public declaration can be used in a different file.
            if (context_tag == .keyword_pub or context_tag == .keyword_export) return false;
            // []const u8 or *const u8, not a declaration.
            if (context_tag == .r_bracket or context_tag == .asterisk) return false;
            // Extern fn declarations are FFI bindings called by external code.
            if (saw_extern and declaration_keyword == .keyword_fn) return false;
            return true;
        }
    } else unreachable;
}

fn tidyAst(
    file: SourceFile,
    tree: *const Ast,
    errors: *Errors,
) void {
    // Skip build files - they often have longer functions
    if (std.mem.eql(u8, file.path, "build.zig")) return;
    if (std.mem.endsWith(u8, file.path, "/build.zig")) return;

    const tags = tree.nodes.items(.tag);

    for (tags, 0..) |tag, node_usize| {
        const node: u32 = @intCast(node_usize);
        if (isBinOp(tag)) { // Forbid mixing bitops and arithmetics without parentheses.
            const data = tree.nodeData(@fromBackingInt(@intCast(node)));
            const children = data.node_and_node;
            inline for (children) |child| {
                const child_tag = tags[@backingInt(child)];
                if ((isBinOpBitwise(tag) and isBinOpArithmetic(child_tag)) or
                    (isBinOpArithmetic(tag) and isBinOpBitwise(child_tag)))
                {
                    const token_opening = tree.nodeMainToken(@fromBackingInt(@intCast(node)));
                    const line_opening = tree.tokenLocation(0, token_opening).line;
                    errors.addAmbiguousPrecedence(file, line_opening);
                }
            }
        }
    }
}

fn isBinOp(tag: Ast.Node.Tag) bool {
    return isBinOpBitwise(tag) or isBinOpArithmetic(tag);
}

fn isBinOpBitwise(tag: Ast.Node.Tag) bool {
    return tag == .shl or tag == .shl_sat or tag == .shr or tag == .bit_xor or tag == .bit_or or tag == .bit_and;
}

fn isBinOpArithmetic(tag: Ast.Node.Tag) bool {
    return tag == .add or tag == .add_sat or tag == .add_wrap or
        tag == .sub or tag == .sub_sat or tag == .sub_wrap or
        tag == .mul or tag == .mul_sat or tag == .mul_wrap or
        tag == .div or tag == .mod;
}

/// Checks that each markdown document has exactly one h1.
///
/// A single `#` signifies the document _title_; sections use `##` and below.
/// We use markdown to create HTML, so `#` turns into h1, and MDN recommends a
/// single h1 per page:
/// <https://developer.mozilla.org/en-US/docs/Web/HTML/Element/Heading_Elements#avoid_using_multiple_h1_elements_on_one_page>
fn tidyMarkdownTitle(file: SourceFile, errors: *Errors) void {
    if (!markdownTitleValid(file.text)) errors.addInvalidMarkdownTitle(file);
}

/// A document is valid with exactly one `# Title`, or with none when it is a
/// short note of at most two lines. Fenced blocks are skipped so a `# comment`
/// in a shell example does not count.
fn markdownTitleValid(text: []const u8) bool {
    var fenced_block = false;
    var heading_count: u32 = 0;
    var line_count: u32 = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        line_count += 1;
        if (mem.startsWith(u8, line, "```")) fenced_block = !fenced_block;
        if (!fenced_block and mem.startsWith(u8, line, "# ")) heading_count += 1;
    }
    return switch (heading_count) {
        0 => line_count <= 2,
        1 => true,
        else => false,
    };
}

// Zig's lazy compilation model makes it too easy to forget to include a file into the build: if
// nothing imports a file, the compiler just doesn't see it and can't flag it as unused.
//
// DeadFilesDetector implements textual detection of unused files by scanning for
// import statements and build-registered Zig roots. A Zig file counts as used
// when some tracked Zig file `@import`s it, or `build.zig` names it (through
// `b.path("...")` or as a plain repository path such as the file passed to
// `zig run`). This gives false negatives for unreachable cycles of files, as
// well as for identically-named files, but it is good enough in practice.
const DeadFilesDetector = struct {
    const FileName = [64]u8;
    const FileState = struct {
        import_count: u32,
        definition_count: u32,
    };
    const FileMap = std.array_hash_map.Auto(FileName, FileState);

    files: FileMap,

    fn init(_: Allocator) DeadFilesDetector {
        return .{ .files = FileMap.empty };
    }

    fn deinit(detector: *DeadFilesDetector, gpa: Allocator) void {
        detector.files.deinit(gpa);
    }

    fn visit(detector: *DeadFilesDetector, gpa: Allocator, file: SourceFile) Allocator.Error!void {
        assert(file.hasExtension(".zig"));

        const is_source = isZigSourcePath(file.path);
        if (is_source) {
            const state = try detector.fileState(gpa, file.path);
            state.definition_count += 1;
        }

        const should_scan = is_source or std.mem.eql(u8, file.path, "build.zig");
        if (!should_scan) return;

        try detector.recordQuotedZigPaths(gpa, file.path, file.text, "@import(\"", false);
        try detector.recordQuotedZigPaths(gpa, file.path, file.text, "b.path(\"", true);
        // build.zig also names source roots as plain repository paths: the
        // root passed to its `adapter` helper, the unit-test list, and the
        // tool it runs with `zig run`.
        if (std.mem.eql(u8, file.path, "build.zig")) {
            try detector.recordRepoPathLiterals(gpa, file.path, file.text);
        }
    }

    /// Record each string literal in `text` that is a repository path to a
    /// Zig file under one of the Zig source directories.
    fn recordRepoPathLiterals(detector: *DeadFilesDetector, gpa: Allocator, file_path: []const u8, text: []const u8) Allocator.Error!void {
        var rest: []const u8 = text;
        for (0..16384) |_| {
            const open = std.mem.findScalar(u8, rest, '"') orelse return;
            rest = rest[open + 1 ..];
            const close = std.mem.findScalar(u8, rest, '"') orelse return;
            const literal = rest[0..close];
            rest = rest[close + 1 ..];
            if (!std.mem.endsWith(u8, literal, ".zig")) continue;
            if (!isZigSourcePath(literal)) continue;
            // A format string such as "tools/{s}.zig" names no single file.
            const is_path = for (literal) |byte| {
                if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-' and byte != '.' and byte != '/') break false;
            } else true;
            if (!is_path) continue;
            (try detector.fileState(gpa, literal)).import_count += 1;
        } else {
            std.debug.panic("file with too many string literals: {s}", .{file_path});
        }
    }

    fn finish(detector: *DeadFilesDetector, errors: *Errors) void {
        defer detector.files.clearRetainingCapacity();

        for (detector.files.keys(), detector.files.values()) |name, state| {
            if (state.definition_count == 0) {
                errors.addFileUntracked(std.mem.trimEnd(u8, &name, "\x00"));
            }
            if (state.definition_count > 0 and state.import_count == 0) {
                errors.addFileDead(std.mem.trimEnd(u8, &name, "\x00"));
            }
        }
    }

    fn fileState(detector: *DeadFilesDetector, gpa: Allocator, path: []const u8) !*FileState {
        const gop = try detector.files.getOrPut(gpa, pathToName(path));
        if (!gop.found_existing) gop.value_ptr.* = .{ .import_count = 0, .definition_count = 0 };
        return gop.value_ptr;
    }

    fn recordQuotedZigPaths(
        detector: *DeadFilesDetector,
        gpa: Allocator,
        file_path: []const u8,
        text: []const u8,
        marker: []const u8,
        require_repo_path: bool,
    ) Allocator.Error!void {
        var rest: []const u8 = text;
        for (0..4096) |_| {
            const result = cut(rest, marker) orelse break;
            rest = result[1];
            const result2 = cut(rest, "\")") orelse break;
            const path = result2[0];
            rest = result2[1];
            if (!std.mem.endsWith(u8, path, ".zig")) continue;
            if (require_repo_path and !isZigSourcePath(path)) continue;
            (try detector.fileState(gpa, path)).import_count += 1;
        } else {
            std.debug.panic("file with too many quoted Zig paths: {s}", .{file_path});
        }
    }

    fn pathToName(path: []const u8) FileName {
        assert(std.mem.endsWith(u8, path, ".zig"));
        const basename = std.fs.path.basename(path);
        var file_name: FileName = @splat(0);
        assert(basename.len <= file_name.len);
        @memcpy(file_name[0..basename.len], basename);
        return file_name;
    }
};

test "dead files detector counts imports, build paths and run paths" {
    const gpa = std.testing.allocator;
    var detector = DeadFilesDetector.init(gpa);
    defer detector.deinit(gpa);

    try detector.visit(gpa, .{
        .path = "compiler-adapter/bridge.zig",
        .text = "const runner = @import(\"engine.zig\");\nconst can = @import(\"can\");\n",
    });
    try detector.visit(gpa, .{
        .path = "build.zig",
        .text = "const native = adapter(b, roc, \"compiler-adapter/native.zig\");\n" ++
            "const tests = b.addTest(.{ .root_source_file = b.path(\"ci/tidy.zig\") });\n" ++
            "publish.addArgs(&.{ \"run\", \"tools/build-tool.zig\" });\n" ++
            "const fmt = b.fmt(\"tools/{s}.zig\", .{name});\n",
    });
    try detector.visit(gpa, .{ .path = "tools/serve.zig", .text = "const std = @import(\"std\");\n" });

    const engine = detector.files.get(DeadFilesDetector.pathToName("engine.zig")).?;
    try std.testing.expectEqual(@as(u32, 1), engine.import_count);
    try std.testing.expectEqual(@as(u32, 0), engine.definition_count);
    for ([_][]const u8{ "native.zig", "tidy.zig", "build-tool.zig" }) |name| {
        try std.testing.expect(detector.files.get(DeadFilesDetector.pathToName(name)).?.import_count > 0);
    }
    try std.testing.expect(!detector.files.contains(DeadFilesDetector.pathToName("{s}.zig")));
    const serve = detector.files.get(DeadFilesDetector.pathToName("serve.zig")).?;
    try std.testing.expectEqual(@as(u32, 1), serve.definition_count);
    try std.testing.expectEqual(@as(u32, 0), serve.import_count);
}

test "markdown titles count only unfenced top-level headings" {
    try std.testing.expect(markdownTitleValid("# Title\n\n```sh\n# comment\n```\n\n## Section\n"));
    try std.testing.expect(!markdownTitleValid("# One\n\n# Two\n"));
    try std.testing.expect(markdownTitleValid("short note\n"));
    try std.testing.expect(!markdownTitleValid("a\nb\nc\n"));
}

/// Lists all files in the repository.
///
/// Prefers `git ls-files` (matching CI, which runs in a git checkout). Falls
/// back to `jj file list` so the check also runs in a non-colocated jj
/// workspace, where there is no `.git` for git to use.
fn listFilePaths(allocator: Allocator, io: std.Io) ![][]const u8 {
    var result: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (result.items) |path| {
            allocator.free(path);
        }
        result.deinit(allocator);
    }

    // git ls-files -z: null-separated, exact CI behavior.
    if (try runForStdout(allocator, io, &.{ "git", "ls-files", "-z" })) |stdout| {
        defer allocator.free(stdout);
        try appendListedPaths(allocator, &result, stdout, 0);
        return result.toOwnedSlice(allocator);
    }

    // Fall back to jj for a non-colocated jj workspace: newline-separated.
    if (try runForStdout(allocator, io, &.{ "jj", "file", "list" })) |stdout| {
        defer allocator.free(stdout);
        try appendListedPaths(allocator, &result, stdout, '\n');
        return result.toOwnedSlice(allocator);
    }

    return error.GitFailed;
}

/// Runs `argv`, returning its stdout on success (caller owns it) or null if the
/// command is missing or exits non-zero. Only allocation failures propagate.
fn runForStdout(allocator: Allocator, io: std.Io, argv: []const []const u8) !?[]u8 {
    const run_result = std.process.run(allocator, io, .{ .argv = argv }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null, // command not found / failed to spawn
    };
    defer allocator.free(run_result.stderr);
    if (run_result.term != .exited or run_result.term.exited != 0) {
        allocator.free(run_result.stdout);
        return null;
    }
    return run_result.stdout;
}

/// Splits `output` on `separator` and appends each non-skipped path to `result`.
fn appendListedPaths(allocator: Allocator, result: *std.ArrayList([]const u8), output: []const u8, separator: u8) !void {
    var lines = std.mem.splitScalar(u8, output, separator);
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (shouldSkipListedFile(line)) continue;
        try result.append(allocator, try allocator.dupe(u8, line));
    }
}

fn shouldSkipTopLevelDir(path: []const u8) bool {
    const skip_dirs: []const []const u8 = &.{
        ".git",
        ".toolchain",
        ".zig-cache",
        "artifacts",
        "vendor",
        "zig-out",
        "zig-pkg",
    };
    for (skip_dirs) |dir| {
        if (isPathInTopLevelDir(path, dir)) return true;
    }
    return false;
}

fn shouldSkipListedFile(path: []const u8) bool {
    if (std.mem.eql(u8, path, ".git")) return true;
    if (shouldSkipTopLevelDir(path)) return true;
    // Vendored code anywhere (for example web/vendor/) keeps its upstream style.
    if (hasPathComponent(path, "vendor")) return true;
    if (hasPathComponent(path, "zig-out")) return true;

    // Skip binary files entirely - they shouldn't be read into the buffer.
    for (binary_extensions) |ext| {
        if (std.mem.endsWith(u8, path, ext)) return true;
    }
    return false;
}

fn isPathInTopLevelDir(path: []const u8, dir: []const u8) bool {
    if (std.mem.eql(u8, path, dir)) return true;
    return std.mem.startsWith(u8, path, dir) and
        path.len > dir.len and
        path[dir.len] == '/';
}

fn hasPathComponent(path: []const u8, component: []const u8) bool {
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, component)) return true;
    }
    return false;
}

/// Splits a string at the first occurrence of a delimiter.
/// Returns null if delimiter is not found.
fn cut(str: []const u8, delimiter: []const u8) ?struct { []const u8, []const u8 } {
    const index = std.mem.find(u8, str, delimiter) orelse return null;
    return .{ str[0..index], str[index + delimiter.len ..] };
}

test "listed files skip vendored and generated trees" {
    try std.testing.expect(shouldSkipListedFile("web/vendor/katex/katex.mjs"));
    try std.testing.expect(shouldSkipListedFile("vendor/md4c/md4c.c"));
    try std.testing.expect(shouldSkipListedFile("artifacts/roclet.wasm"));
    try std.testing.expect(shouldSkipListedFile("web/assets/roclet-logo.png"));
    try std.testing.expect(!shouldSkipListedFile("compiler-adapter/bridge.zig"));
    try std.testing.expect(!shouldSkipListedFile("wip/README.md"));
}
