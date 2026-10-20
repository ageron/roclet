//! Zig source lints for the Roclet codebase.
//!
//! Adapted from the Roc compiler's `ci/zig_lints.zig`. Kept: the ban on
//! horizontal separator comments and the requirement that every Zig source
//! file opens with a `//!` comment that says what the file is for.
//!
//! Deliberately not ported: the exhaustive-switch rule (Roclet switches over
//! compiler enums and unions it does not own, so listing every variant would
//! couple it to each compiler pin), the pub-doc-comment rule, and the
//! DebugAllocator and dense-ID-map rules, which are about the compiler's own
//! build options and collections.
//!
//! `zig build run-check-zig-lints` runs it over `build.zig` and every Zig
//! file under `compiler-adapter/`, `tools/`, `tests/` and `ci/`.

const std = @import("std");

const Allocator = std.mem.Allocator;
const PathList = std.ArrayList([]u8);

const max_file_bytes: usize = 16 * 1024 * 1024;

const TermColor = struct {
    pub const red = "\x1b[0;31m";
    pub const green = "\x1b[0;32m";
    pub const reset = "\x1b[0m";
};

/// The directories that hold Roclet's Zig sources.
const zig_source_dirs: []const []const u8 = &.{ "compiler-adapter", "tools", "tests", "ci" };

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_state = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_state.interface;

    var zig_files: PathList = .empty;
    defer freePathList(&zig_files, gpa);
    for (zig_source_dirs) |dir| try walkTree(gpa, io, dir, &zig_files);
    try zig_files.append(gpa, try gpa.dupe(u8, "build.zig"));

    var found_errors = false;

    // Lint 1: Check for separator comments (// ====, // ----, // ────, etc.)
    try stdout.print("Checking for separator comments...\n", .{});

    for (zig_files.items) |file_path| {
        // This file documents the banned patterns.
        if (std.mem.endsWith(u8, file_path, "ci/zig_lints.zig")) continue;
        const errors = try checkSeparatorComments(gpa, io, file_path);
        defer gpa.free(errors);

        if (errors.len > 0) {
            try stdout.print("{s}", .{errors});
            found_errors = true;
        }
    }

    if (found_errors) {
        try stdout.print("\n", .{});
        try stdout.print("Horizontal line separator comments are not allowed (e.g. // ====, // ----, // ────).\n", .{});
        try stdout.print("Do not attempt to work around this by using different characters. Just don't put horizontal lines in the code.\n", .{});
        try stdout.print("\n", .{});
        try stdout.flush();
        std.process.exit(1);
    }

    // Lint 2: Every Zig source file starts with a top level comment.
    try stdout.print("Checking for top level comments in Zig files...\n", .{});

    var failed_files: PathList = .empty;
    defer freePathList(&failed_files, gpa);

    for (zig_files.items) |file_path| {
        // build.zig is the build script, not a module; its purpose is its name.
        if (std.mem.eql(u8, file_path, "build.zig")) continue;
        if (!try fileHasTopLevelComment(gpa, io, file_path)) {
            try stdout.print("Error: {s} is missing top level comment (//!)\n", .{file_path});
            try failed_files.append(gpa, try gpa.dupe(u8, file_path));
        }
    }

    if (failed_files.items.len > 0) {
        try stdout.print("\n", .{});
        try stdout.print("The following files are missing a top level comment:\n", .{});
        for (failed_files.items) |path| {
            try stdout.print("    {s}\n", .{path});
        }
        try stdout.print("\n", .{});
        try stdout.print("Start the file with a //! comment that explains its purpose, before any other code.\n", .{});
        try stdout.flush();
        std.process.exit(1);
    }

    try stdout.print("{s}[OK]{s} All lints passed!\n", .{ TermColor.green, TermColor.reset });
    try stdout.flush();
}

fn walkTree(allocator: Allocator, io: std.Io, dir_path: []const u8, zig_files: *PathList) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .sym_link) continue;

        const next_path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });

        if (entry.kind == .directory) {
            // Skip .zig-cache directories
            if (std.mem.eql(u8, entry.name, ".zig-cache")) {
                allocator.free(next_path);
                continue;
            }
            defer allocator.free(next_path);
            try walkTree(allocator, io, next_path, zig_files);
        } else if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".zig")) {
            try zig_files.append(allocator, next_path);
        } else {
            allocator.free(next_path);
        }
    }
}

fn checkSeparatorComments(allocator: Allocator, io: std.Io, file_path: []const u8) ![]u8 {
    const source = (try readSourceFileIfExists(allocator, io, file_path)) orelse return try allocator.dupe(u8, "");
    defer allocator.free(source);

    var errors: std.ArrayList(u8) = .empty;
    errdefer errors.deinit(allocator);

    var line_num: usize = 1;
    var lines = std.mem.splitScalar(u8, source, '\n');

    while (lines.next()) |line| {
        defer line_num += 1;

        // Trim leading whitespace
        const trimmed = std.mem.trimStart(u8, line, " \t");

        // Check if line starts with // and is a separator comment
        // Separator comments are lines like "// ====", "// ----", "// ────────"
        // We detect them by checking if, after the //, the line consists only of
        // whitespace, separator characters, and letters (for section titles)
        if (std.mem.startsWith(u8, trimmed, "//")) {
            const after_slashes = trimmed[2..];
            if (isSeparatorComment(after_slashes)) {
                const msg = try std.fmt.allocPrint(allocator, "{s}:{d}: horizontal line separator comment not allowed\n", .{ file_path, line_num });
                defer allocator.free(msg);
                try errors.appendSlice(allocator, msg);
            }
        }
    }

    return errors.toOwnedSlice(allocator);
}

/// Checks if a line (after the //) is a horizontal line separator comment.
/// These are lines consisting of repeated separator characters (=, -, ─)
/// with optional whitespace and a section title between them.
/// Examples that should match:
///   " ===="
///   " ===== Section ====="
///   " ----"
///   " ---- Title ----"
///   " ──────────"
/// Examples that should NOT match:
///   " 2. Stdout contains "=====""
///   " This is a normal comment about ===="
///   " --something"
///   " ┌─────────────┐"  (box art with corners)
///   " └───────┬─────┘"  (box art with corners)
fn isSeparatorComment(after_slashes: []const u8) bool {
    // Trim whitespace
    const content = std.mem.trim(u8, after_slashes, " \t");
    if (content.len == 0) return false;

    // Check for box-drawing horizontal line (U+2500 "─", encoded as 0xE2 0x94 0x80 in UTF-8).
    // Only flag if the line has 4+ consecutive ─ but NO box-drawing corners/intersections
    // (┌ ┐ └ ┘ ├ ┤ ┬ ┴ ┼ │ etc.), which would indicate it's part of a diagram.
    if (std.mem.find(u8, content, "\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80") != null) {
        if (!containsBoxDrawingCorner(content)) return true;
    }

    // For ASCII separators, must contain 4+ repeated chars and start with them
    const sep_char: u8 = if (std.mem.find(u8, content, "====") != null)
        '='
    else if (std.mem.find(u8, content, "----") != null)
        '-'
    else
        return false;

    // Must start with the separator character
    if (content[0] != sep_char) return false;

    // Find where the leading separator chars end
    var i: usize = 0;
    while (i < content.len and content[i] == sep_char) : (i += 1) {}

    // Everything after leading separators should be whitespace, letters, or trailing separators
    while (i < content.len) : (i += 1) {
        const c = content[i];
        if (c == sep_char or c == ' ' or c == '\t' or (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z')) {
            continue;
        }
        // Found a character that's not allowed in separator comments
        return false;
    }

    return true;
}

/// Returns true if the content contains any box-drawing corner or intersection
/// character (anything in the U+2500 block that isn't U+2500 "─" itself).
/// These characters (┌ ┐ └ ┘ ├ ┤ ┬ ┴ ┼ │ etc.) indicate the line is part
/// of a diagram, not a separator.
fn containsBoxDrawingCorner(content: []const u8) bool {
    var i: usize = 0;
    while (i + 2 < content.len) : (i += 1) {
        if (content[i] == 0xE2 and content[i + 1] == 0x94) {
            // U+2500 block: 0xE2 0x94 0x80-0xBF
            // U+2500 (─) is 0x80: skip it, everything else is a corner/intersection
            if (content[i + 2] != 0x80) return true;
            i += 2; // skip the rest of this UTF-8 sequence
        } else if (content[i] == 0xE2 and content[i + 1] == 0x95) {
            // U+2540-U+257F block: 0xE2 0x95 0x80-0xBF (double-line box drawing)
            return true;
        }
    }
    return false;
}

fn fileHasTopLevelComment(allocator: Allocator, io: std.Io, file_path: []const u8) !bool {
    const source = (try readSourceFileIfExists(allocator, io, file_path)) orelse return true;
    defer allocator.free(source);

    return std.mem.startsWith(u8, source, "//!");
}

fn readSourceFileIfExists(allocator: Allocator, io: std.Io, path: []const u8) !?[:0]u8 {
    return std.Io.Dir.cwd().readFileAllocOptions(
        io,
        path,
        allocator,
        .limited(max_file_bytes),
        std.mem.Alignment.of(u8),
        0,
    ) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
}

fn freePathList(list: *PathList, allocator: Allocator) void {
    for (list.items) |path| {
        allocator.free(path);
    }
    list.deinit(allocator);
}

test "separator comments are recognised without flagging prose or diagrams" {
    try std.testing.expect(isSeparatorComment(" ===="));
    try std.testing.expect(isSeparatorComment(" ===== Section ====="));
    try std.testing.expect(isSeparatorComment(" ---- Title ----"));
    try std.testing.expect(isSeparatorComment(" ──────────"));
    try std.testing.expect(!isSeparatorComment(" This is a normal comment about ===="));
    try std.testing.expect(!isSeparatorComment(" --something"));
    try std.testing.expect(!isSeparatorComment(" ┌─────────────┐"));
    try std.testing.expect(!isSeparatorComment(""));
}
