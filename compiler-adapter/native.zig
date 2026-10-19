//! Filesystem and process host. All document policy is shared with WASM.
const std = @import("std");
const bridge = @import("bridge.zig");
pub const std_options = bridge.std_options;
const usage =
    \\Usage: roclet [run] FILE.roc|FILE.md|snapshot.json
    \\       roclet parse FILE.roc|FILE.md
    \\       roclet check FILE.roc|FILE.md
    \\       roclet convert FILE --to roc|markdown [--output FILE] [--normalize] [--force] [--allow-relocation]
    \\       roclet --bridge request.json
    \\
    \\Conversion never executes the notebook. Same-format conversion is byte-exact
    \\unless --normalize is supplied. Invalid drafts are preserved with diagnostics.
    \\
;
fn stringify(a: std.mem.Allocator, data: anytype) ![]u8 {
    var w: std.Io.Writer.Allocating = .init(a);
    try std.json.Stringify.value(data, .{}, &w.writer);
    return w.toOwnedSlice();
}
pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    bridge.setNativeIo(init.io);
    const args = try init.minimal.args.toSlice(a);
    if (args.len == 1 or (args.len == 2 and std.mem.eql(u8, args[1], "--help"))) {
        try std.Io.File.stdout().writeStreamingAll(init.io, usage);
        if (args.len == 1) std.process.exit(2);
        return;
    }
    const raw = std.mem.eql(u8, args[1], "--bridge");
    const convert = std.mem.eql(u8, args[1], "convert");
    const action = if (raw) "bridge" else if (convert) "convert" else if (std.mem.eql(u8, args[1], "parse")) "parse" else if (std.mem.eql(u8, args[1], "check")) "check" else "run";
    const explicit = raw or convert or std.mem.eql(u8, args[1], "run") or std.mem.eql(u8, args[1], "check") or std.mem.eql(u8, args[1], "parse");
    const file_index: usize = if (explicit) 2 else 1;
    if (args.len <= file_index) return error.MissingFile;
    const file = args[file_index];
    const format = if (std.mem.endsWith(u8, file, ".roc")) "roc" else if (std.mem.endsWith(u8, file, ".md") or std.mem.endsWith(u8, file, ".markdown")) "markdown" else "json";
    var target: []const u8 = format;
    var output: ?[]const u8 = null;
    var normalize = false;
    var force = false;
    var allow_relocation = false;
    var i = file_index + 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--allow-relocation")) {
            allow_relocation = true;
            continue;
        }
        if (std.mem.eql(u8, args[i], "--normalize")) {
            normalize = true;
            continue;
        }
        if (std.mem.eql(u8, args[i], "--force")) {
            force = true;
            continue;
        }
        if (i + 1 >= args.len) return error.MissingOptionValue;
        if (std.mem.eql(u8, args[i], "--to")) target = args[i + 1] else if (std.mem.eql(u8, args[i], "--output")) output = args[i + 1] else return error.UnknownOption;
        i += 1;
    }
    if (std.mem.eql(u8, target, "md")) target = "markdown";
    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, file, a, .limited(4 * 1024 * 1024));
    const is_document = !raw and !std.mem.eql(u8, format, "json");
    if (is_document) {
        const actual = try std.Io.Dir.cwd().realPathFileAlloc(init.io, file, a);
        try bridge.setNativeSourceDirectory(std.fs.path.dirname(actual) orelse ".");
    }
    if (convert and !is_document) return error.ExpectedDocumentExtension;
    const request = if (is_document) try stringify(a, .{ .operation = "document", .action = if (normalize) "normalize" else if (std.mem.eql(u8, action, "run")) "evaluate" else action, .format = format, .target = target, .source = bytes }) else bytes;
    const result = try bridge.process(request);
    defer std.heap.page_allocator.free(result);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, result, .{});
    const object = parsed.value.object;
    if (convert) {
        const converted = object.get("source") orelse {
            try std.Io.File.stderr().writeStreamingAll(init.io, result);
            std.process.exit(1);
        };
        if (output) |dest| {
            // Relocation must not silently change the base of relative imports/assets.
            const src_dir = try std.Io.Dir.cwd().realPathFileAlloc(init.io, std.fs.path.dirname(file) orelse ".", a);
            const dst_dir = try std.Io.Dir.cwd().realPathFileAlloc(init.io, std.fs.path.dirname(dest) orelse ".", a);
            if (!allow_relocation and !std.mem.eql(u8, src_dir, dst_dir) and (std.mem.find(u8, bytes, "import ") != null or std.mem.find(u8, bytes, "](") != null or std.mem.find(u8, bytes, "]:") != null or std.mem.find(u8, bytes, "src=") != null)) return error.RelocatingAssetsRequiresExplicitPathRepair;
            const f = try std.Io.Dir.cwd().createFile(init.io, dest, .{ .exclusive = !force });
            defer f.close(init.io);
            try f.writeStreamingAll(init.io, converted.string);
        } else try std.Io.File.stdout().writeStreamingAll(init.io, converted.string);
        if (object.get("model")) |model| for (model.object.get("diagnostics").?.array.items) |d| {
            const msg = try std.fmt.allocPrint(a, "{s}:{d}:{d}: {s}: {s}\n", .{ file, d.object.get("location").?.object.get("line").?.integer, d.object.get("location").?.object.get("column").?.integer, d.object.get("code").?.string, d.object.get("message").?.string });
            try std.Io.File.stderr().writeStreamingAll(init.io, msg);
        };
    } else {
        try std.Io.File.stdout().writeStreamingAll(init.io, result);
        try std.Io.File.stdout().writeStreamingAll(init.io, "\n");
    }
    if (!raw and !std.mem.eql(u8, object.get("status").?.string, "ok")) std.process.exit(1);
}
